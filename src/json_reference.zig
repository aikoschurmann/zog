//! The single-pass parser that `json.Parser` replaced, kept to test it against.
const std = @import("std");
const json = @import("json.zig");

const Error = json.Error;
const PathTrie = json.PathTrie;
const Str = json.Str;
const MAX_DEPTH = json.MAX_DEPTH;
const hex4 = json.hex4;
const decodedEql = json.decodedEql;

const VECTOR_LEN = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(VECTOR_LEN, u8);
const BoolV = @Vector(VECTOR_LEN, bool);
const Mask = std.meta.Int(.unsigned, VECTOR_LEN);

inline fn vor(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, @as(BoolV, @splat(true)), b);
}

/// Index of the first byte at or after `start` that a string can't simply contain: '"', '\\',
/// a control character or a non-ASCII byte. `s.len` if there is none.
fn findSpecial(s: []const u8, start: usize) usize {
    var i = start;
    while (i + VECTOR_LEN <= s.len) : (i += VECTOR_LEN) {
        const c: V = s[i..][0..VECTOR_LEN].*;
        // Outside 0x20..0x7f exactly when c - 0x20 wraps to 0x60 or more.
        const m = vor(vor(c == @as(V, @splat('"')), c == @as(V, @splat('\\'))), c -% @as(V, @splat(0x20)) >= @as(V, @splat(0x60)));
        if (@reduce(.Or, m)) return i + @ctz(@as(Mask, @bitCast(m)));
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20 or c >= 0x80) return i;
    }
    return i;
}

/// The single-pass parser that `Parser` replaced, kept to test it against.
pub const ReferenceParser = struct {
    s: []const u8 = &.{},
    i: usize = 0,
    trie: *const PathTrie,
    /// Raw text of the value at each path (strings with their quotes), or null if absent.
    slots: []?[]const u8,
    /// One bit per open container while skipping a value: set for objects.
    stack: [MAX_DEPTH / 64]u64 = undefined,

    /// Validates `line` as a single JSON value (RFC 8259, UTF-8) and fills `slots`. When a
    /// key repeats, the last occurrence wins. A path through a non-object value is absent.
    pub fn parse(self: *ReferenceParser, line: []const u8) Error!void {
        self.s = line;
        self.i = 0;
        @memset(self.slots, null);
        self.ws();
        try self.tracked(0);
        self.ws();
        if (self.i != line.len) return error.Invalid;
    }

    inline fn cur(self: *const ReferenceParser) Error!u8 {
        if (self.i >= self.s.len) return error.Invalid;
        return self.s[self.i];
    }

    inline fn ws(self: *ReferenceParser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    /// Parses the value of trie node `n`, descending into the members it has children for.
    fn tracked(self: *ReferenceParser, n: u32) Error!void {
        const node = &self.trie.nodes[n];
        if (node.children.len == 0 or try self.cur() != '{') return self.skipValue();
        self.i += 1;
        self.ws();
        if (try self.cur() == '}') {
            self.i += 1;
            return;
        }
        while (true) {
            const key = try self.string();
            try self.colon();
            const start = self.i;
            if (findChild(self.trie, node, key)) |c| {
                const cn = &self.trie.nodes[c];
                @memset(self.slots[cn.slot_lo..cn.slot_hi], null);
                try self.tracked(c);
                if (cn.slot) |slot| self.slots[slot] = self.s[start..self.i];
            } else try self.skipValue();
            self.ws();
            switch (try self.cur()) {
                ',' => {
                    self.i += 1;
                    self.ws();
                },
                '}' => {
                    self.i += 1;
                    return;
                },
                else => return error.Invalid,
            }
        }
    }

    fn findChild(trie: *const PathTrie, node: *const PathTrie.Node, key: Str) ?u32 {
        for (node.children) |c| {
            const seg = trie.nodes[c].seg;
            if (if (key.escaped) decodedEql(key.raw, seg) else std.mem.eql(u8, key.raw, seg)) return c;
        }
        return null;
    }

    /// After a key: whitespace, ':' and whitespace.
    inline fn colon(self: *ReferenceParser) Error!void {
        self.ws();
        if (try self.cur() != ':') return error.Invalid;
        self.i += 1;
        self.ws();
    }

    /// Validates one value without recursion, so nesting depth doesn't use stack.
    fn skipValue(self: *ReferenceParser) Error!void {
        var depth: usize = 0;
        while (true) {
            // At the start of a value.
            const c = try self.cur();
            switch (c) {
                '{', '[' => {
                    self.i += 1;
                    self.ws();
                    if (try self.cur() == @as(u8, if (c == '{') '}' else ']')) {
                        self.i += 1;
                    } else {
                        if (depth == MAX_DEPTH) return error.Invalid;
                        const bit = @as(u64, 1) << @intCast(depth % 64);
                        if (c == '{') self.stack[depth / 64] |= bit else self.stack[depth / 64] &= ~bit;
                        depth += 1;
                        if (c == '{') {
                            _ = try self.string();
                            try self.colon();
                        }
                        continue;
                    }
                },
                '"' => _ = try self.string(),
                't' => try self.literal("true"),
                'f' => try self.literal("false"),
                'n' => try self.literal("null"),
                else => try self.number(),
            }
            // After a value: close containers until one continues with another element.
            while (true) {
                if (depth == 0) return;
                self.ws();
                const in_object = self.stack[(depth - 1) / 64] >> @intCast((depth - 1) % 64) & 1 == 1;
                const d = try self.cur();
                self.i += 1;
                if (d == ',') {
                    self.ws();
                    if (in_object) {
                        _ = try self.string();
                        try self.colon();
                    }
                    break;
                }
                if (d != @as(u8, if (in_object) '}' else ']')) return error.Invalid;
                depth -= 1;
            }
        }
    }

    fn literal(self: *ReferenceParser, comptime lit: []const u8) Error!void {
        if (!std.mem.startsWith(u8, self.s[self.i..], lit)) return error.Invalid;
        self.i += lit.len;
    }

    fn digits(s: []const u8, start: usize) usize {
        var i = start;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        return i;
    }

    fn number(self: *ReferenceParser) Error!void {
        const s = self.s;
        var i = self.i;
        if (i < s.len and s[i] == '-') i += 1;
        if (i >= s.len) return error.Invalid;
        if (s[i] == '0') {
            i += 1;
        } else if (s[i] >= '1' and s[i] <= '9') {
            i = digits(s, i);
        } else return error.Invalid;
        if (i < s.len and s[i] == '.') {
            const j = digits(s, i + 1);
            if (j == i + 1) return error.Invalid;
            i = j;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const j = digits(s, i);
            if (j == i) return error.Invalid;
            i = j;
        }
        self.i = i;
    }

    /// Parses a string at the current position, returning its raw contents.
    fn string(self: *ReferenceParser) Error!Str {
        if (try self.cur() != '"') return error.Invalid;
        const s = self.s;
        const start = self.i + 1;
        var i = start;
        var escaped = false;
        while (true) {
            i = findSpecial(s, i);
            if (i >= s.len) return error.Invalid;
            const c = s[i];
            if (c == '"') break;
            if (c == '\\') {
                escaped = true;
                if (i + 1 >= s.len) return error.Invalid;
                switch (s[i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => i += 2,
                    'u' => {
                        if (hex4(s[i + 2 ..]) == null) return error.Invalid;
                        i += 6;
                    },
                    else => return error.Invalid,
                }
            } else if (c < 0x20) {
                return error.Invalid;
            } else {
                // A run of non-ASCII bytes holds whole UTF-8 sequences.
                var j = i + 1;
                while (j < s.len and s[j] >= 0x80) j += 1;
                if (!std.unicode.utf8ValidateSlice(s[i..j])) return error.Invalid;
                i = j;
            }
        }
        self.i = i + 1;
        return .{ .raw = s[start..i], .escaped = escaped };
    }
};
