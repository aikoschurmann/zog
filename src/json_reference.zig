//! The single-pass parser that `json.Parser` replaced, kept to test it against.
const std = @import("std");
const json = @import("json.zig");

const Error = json.Error;
const PathTrie = json.PathTrie;

const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(vector_len, u8);
const BoolV = @Vector(vector_len, bool);
const Mask = std.meta.Int(.unsigned, vector_len);

inline fn vor(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, @as(BoolV, @splat(true)), b);
}

/// Index of the first byte at or after `start` that a string can't simply contain: '"', '\\',
/// a control character or a non-ASCII byte. `text.len` if there is none.
fn findSpecial(text: []const u8, start: usize) usize {
    var index = start;
    while (index + vector_len <= text.len) : (index += vector_len) {
        const chunk: V = text[index..][0..vector_len].*;

        // Outside 0x20..0x7f exactly when chunk - 0x20 wraps to 0x60 or more.
        const special = vor(
            vor(chunk == @as(V, @splat('"')), chunk == @as(V, @splat('\\'))),
            chunk -% @as(V, @splat(0x20)) >= @as(V, @splat(0x60)),
        );
        if (@reduce(.Or, special)) return index + @ctz(@as(Mask, @bitCast(special)));
    }

    // Fewer than a vector's worth of bytes is left.
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) return index;
    }
    return index;
}

/// The single-pass parser that `Parser` replaced, kept to test it against.
pub const ReferenceParser = struct {
    input: []const u8 = &.{},
    pos: usize = 0,
    trie: *const PathTrie,
    /// Raw text of the value at each path (strings with their quotes), or null if absent.
    slots: []?[]const u8,
    /// Container kinds while skipping a value, one bit per depth: set for objects. Sized for
    /// `json.max_depth` levels.
    stack: [json.max_depth / 64]u64 = undefined,

    /// Validates `line` as a single JSON value (RFC 8259, UTF-8) and fills `slots`. When a
    /// key repeats, the last occurrence wins. A path through a non-object value is absent.
    pub fn parse(self: *ReferenceParser, line: []const u8) Error!void {
        self.input = line;
        self.pos = 0;
        @memset(self.slots, null);

        self.skipWhitespace();
        try self.parseTracked(PathTrie.root);
        self.skipWhitespace();

        if (self.pos != line.len) return error.Invalid;
    }

    inline fn peek(self: *const ReferenceParser) Error!u8 {
        if (self.pos >= self.input.len) return error.Invalid;
        return self.input[self.pos];
    }

    inline fn skipWhitespace(self: *ReferenceParser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    /// Parses the value of trie node `node_index`. Only an object can lead to a child path, so
    /// an object with children is walked member by member, and any other value is validated and
    /// skipped.
    fn parseTracked(self: *ReferenceParser, node_index: u32) Error!void {
        const node = &self.trie.nodes[node_index];
        if (node.children.len == 0 or try self.peek() != '{') return self.skipValue();

        self.pos += 1;
        self.skipWhitespace();

        // An empty object. Handling it here means the member loop below always starts at a key.
        if (try self.peek() == '}') {
            self.pos += 1;
            return;
        }

        while (true) {
            const key = try self.parseString();
            try self.expectColon();
            const value_start = self.pos;

            if (findChild(self.trie, node, key)) |child_index| {
                const child = &self.trie.nodes[child_index];
                // Clear the slots under this key first. A repeated key then replaces the earlier
                // value, even where the new value doesn't reach those slots.
                @memset(self.slots[child.slot_lo..child.slot_hi], null);
                try self.parseTracked(child_index);
                if (child.slot) |slot| self.slots[slot] = self.input[value_start..self.pos];
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            switch (try self.peek()) {
                // After a comma another member must follow. `{"a":1,}` fails in parseString at
                // the `}`, because a key has to be a string.
                ',' => {
                    self.pos += 1;
                    self.skipWhitespace();
                },
                '}' => {
                    self.pos += 1;
                    return;
                },
                else => return error.Invalid,
            }
        }
    }

    /// The trie child of `node` whose segment is `key`, if any. An escaped key is compared decoded.
    fn findChild(trie: *const PathTrie, node: *const PathTrie.Node, key: json.Str) ?u32 {
        for (node.children) |child_index| {
            const segment = trie.nodes[child_index].seg;
            const matches = if (key.escaped)
                json.decodedEql(key.raw, segment)
            else
                std.mem.eql(u8, key.raw, segment);
            if (matches) return child_index;
        }
        return null;
    }

    /// After a key: whitespace, ':' and whitespace.
    inline fn expectColon(self: *ReferenceParser) Error!void {
        self.skipWhitespace();
        if (try self.peek() != ':') return error.Invalid;
        self.pos += 1;
        self.skipWhitespace();
    }

    /// Validates one value without recursion, so nesting depth doesn't use stack. The open
    /// containers are kept in `self.stack`: bit `depth` is set when the container at that depth
    /// is an object. That bit picks the closing bracket and whether a member name follows.
    fn skipValue(self: *ReferenceParser) Error!void {
        var depth: usize = 0;
        while (true) {
            // At the start of a value.
            const first = try self.peek();
            switch (first) {
                '{', '[' => {
                    self.pos += 1;
                    self.skipWhitespace();

                    // An empty container opens and closes here, so it never gets a bit.
                    if (try self.peek() == @as(u8, if (first == '{') '}' else ']')) {
                        self.pos += 1;
                    } else {
                        if (depth == json.max_depth) return error.Invalid;

                        const bit = @as(u64, 1) << @intCast(depth % 64);
                        const word = &self.stack[depth / 64];
                        if (first == '{') {
                            word.* |= bit;
                        } else {
                            word.* &= ~bit;
                        }
                        depth += 1;

                        // An object's first member name comes before its value.
                        if (first == '{') {
                            _ = try self.parseString();
                            try self.expectColon();
                        }
                        continue;
                    }
                },
                '"' => _ = try self.parseString(),
                't' => try self.expectLiteral("true"),
                'f' => try self.expectLiteral("false"),
                'n' => try self.expectLiteral("null"),
                else => try self.parseNumber(),
            }

            // A value is complete. Close containers until one takes another element. A comma
            // always means another element follows, so `[1,]` and `{"a":1,}` fail on the token
            // after the comma.
            while (true) {
                if (depth == 0) return;
                self.skipWhitespace();

                const in_object = (self.stack[(depth - 1) / 64] >> @intCast((depth - 1) % 64)) & 1 == 1;
                const next = try self.peek();
                self.pos += 1;

                if (next == ',') {
                    self.skipWhitespace();
                    // In an object the next member name comes before its value.
                    if (in_object) {
                        _ = try self.parseString();
                        try self.expectColon();
                    }
                    break;
                }

                if (next != @as(u8, if (in_object) '}' else ']')) return error.Invalid;
                depth -= 1;
            }
        }
    }

    fn expectLiteral(self: *ReferenceParser, comptime lit: []const u8) Error!void {
        if (!std.mem.startsWith(u8, self.input[self.pos..], lit)) return error.Invalid;
        self.pos += lit.len;
    }

    /// Index of the first byte at or after `start` that isn't an ASCII digit.
    fn skipDigits(text: []const u8, start: usize) usize {
        var end = start;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
        return end;
    }

    /// Validates a number and advances past it. The grammar is RFC 8259's:
    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`. A leading zero ends the integer
    /// part, so `01` leaves the `1` behind for the caller to reject.
    fn parseNumber(self: *ReferenceParser) Error!void {
        const text = self.input;
        var cursor = self.pos;

        if (cursor < text.len and text[cursor] == '-') cursor += 1;
        if (cursor >= text.len) return error.Invalid;

        if (text[cursor] == '0') {
            cursor += 1;
        } else if (text[cursor] >= '1' and text[cursor] <= '9') {
            cursor = skipDigits(text, cursor);
        } else {
            return error.Invalid;
        }

        // A fraction and an exponent each need at least one digit after them.
        if (cursor < text.len and text[cursor] == '.') {
            const fraction_end = skipDigits(text, cursor + 1);
            if (fraction_end == cursor + 1) return error.Invalid;
            cursor = fraction_end;
        }

        if (cursor < text.len and (text[cursor] == 'e' or text[cursor] == 'E')) {
            cursor += 1;
            if (cursor < text.len and (text[cursor] == '+' or text[cursor] == '-')) cursor += 1;
            const exponent_end = skipDigits(text, cursor);
            if (exponent_end == cursor) return error.Invalid;
            cursor = exponent_end;
        }

        self.pos = cursor;
    }

    /// Parses a string at the current position, returning its raw contents.
    fn parseString(self: *ReferenceParser) Error!json.Str {
        if (try self.peek() != '"') return error.Invalid;

        const text = self.input;
        const start = self.pos + 1;
        var index = start;
        var escaped = false;

        while (true) {
            // Skip the plain ASCII bytes. This stops at a quote, a backslash, a control byte or a
            // non-ASCII byte.
            index = findSpecial(text, index);
            if (index >= text.len) return error.Invalid;

            const byte = text[index];
            if (byte == '"') break;

            if (byte == '\\') {
                escaped = true;
                if (index + 1 >= text.len) return error.Invalid;
                switch (text[index + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => index += 2,
                    'u' => {
                        // `\uXXXX`: four hex digits follow the `u`.
                        if (json.hex4(text[index + 2 ..]) == null) return error.Invalid;
                        index += 6;
                    },
                    else => return error.Invalid,
                }
            } else if (byte < 0x20) {
                return error.Invalid;
            } else {
                // A run of non-ASCII bytes holds whole UTF-8 sequences.
                var run_end = index + 1;
                while (run_end < text.len and text[run_end] >= 0x80) run_end += 1;
                if (!std.unicode.utf8ValidateSlice(text[index..run_end])) return error.Invalid;
                index = run_end;
            }
        }

        self.pos = index + 1;
        return .{ .raw = text[start..index], .escaped = escaped };
    }
};
