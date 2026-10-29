//! The exact layer: a validating JSON parser that records the values at a set of key paths,
//! and JSON string decoding. Lines the byte-level prefilter can't rule out are parsed here.
const std = @import("std");
const builtin = @import("builtin");
const utf8 = @import("utf8.zig");

const validUtf8 = utf8.validUtf8;

pub const Error = error{Invalid};

/// Lines nested deeper than this are treated as invalid.
pub const MAX_DEPTH = 64 * 1024;

/// The key paths a query needs, as a tree of object keys. Each requested path has a slot that
/// the parser fills with the raw text of its value. A node's slot and those of everything
/// below it are contiguous, so a repeated key can clear its whole subtree at once.
pub const PathTrie = struct {
    nodes: []const Node,
    slot_count: usize,

    pub const Node = struct {
        /// Decoded key (empty for the root).
        seg: []const u8,
        children: []const u32,
        slot: ?u32,
        slot_lo: u32,
        slot_hi: u32,
    };

    /// `paths` are lists of decoded keys. Writes the slot of each path to `path_slots`;
    /// equal paths share a slot.
    pub fn init(allocator: std.mem.Allocator, paths: []const []const []const u8, path_slots: []u32) !PathTrie {
        const Build = struct { seg: []const u8, children: std.ArrayListUnmanaged(u32) = .empty, terminal: bool = false };
        var b: std.ArrayListUnmanaged(Build) = .empty;
        try b.append(allocator, .{ .seg = "" });
        const path_nodes = try allocator.alloc(u32, paths.len);
        for (paths, path_nodes) |path, *pn| {
            var n: u32 = 0;
            for (path) |seg| {
                n = for (b.items[n].children.items) |c| {
                    if (std.mem.eql(u8, b.items[c].seg, seg)) break c;
                } else blk: {
                    const c: u32 = @intCast(b.items.len);
                    try b.append(allocator, .{ .seg = seg });
                    try b.items[n].children.append(allocator, c);
                    break :blk c;
                };
            }
            b.items[n].terminal = true;
            pn.* = n;
        }
        const nodes = try allocator.alloc(Node, b.items.len);
        var next_slot: u32 = 0;
        assign(b.items, nodes, 0, &next_slot);
        for (path_nodes, path_slots) |pn, *s| s.* = nodes[pn].slot.?;
        return .{ .nodes = nodes, .slot_count = next_slot };
    }

    fn assign(b: anytype, nodes: []Node, n: u32, next_slot: *u32) void {
        nodes[n] = .{
            .seg = b[n].seg,
            .children = b[n].children.items,
            .slot = if (b[n].terminal) next_slot.* else null,
            .slot_lo = next_slot.*,
            .slot_hi = undefined,
        };
        if (b[n].terminal) next_slot.* += 1;
        for (b[n].children.items) |c| assign(b, nodes, c, next_slot);
        nodes[n].slot_hi = next_slot.*;
    }
};

pub const Str = struct { raw: []const u8, escaped: bool };

/// Bytes per stage-1 chunk, one bit each in a u64 mask.
const CHUNK = 64;
const CV = @Vector(CHUNK, u8);

/// A validating parser in two stages, after simdjson. Stage 1 classifies the line 64 bytes at
/// a time with SIMD and marks its structural characters in a bitmask: `{}[]:,`, every quote
/// that isn't escaped, and the first byte of every number or literal. Along the way it
/// rejects control characters in strings, malformed escapes and invalid UTF-8. Stage 2 checks
/// the grammar and records the values at the trie's paths, visiting only the marked
/// positions, so it never looks inside a string. It takes them straight from the bitmask and
/// has stage 1 classify the next chunk when that runs out, so no index is stored however long
/// the line is.
pub const Parser = struct {
    s: []const u8 = &.{},
    trie: *const PathTrie,
    /// Raw text of the value at each path (strings with their quotes), or null if absent.
    slots: []?[]const u8,
    /// One bit per open container while skipping a value: set for objects.
    stack: [MAX_DEPTH / 64]u64 = undefined,

    /// Start of the next chunk for stage 1.
    chunk_pos: usize = 0,
    /// Carried from one chunk to the next: bit 0 if the first byte is escaped, all ones if
    /// the chunk starts inside a string, bit 0 if the last byte was part of a scalar.
    carry_escaped: u64 = 0,
    carry_in_string: u64 = 0,
    carry_scalar: u64 = 0,
    non_ascii: bool = false,
    has_backslash: bool = false,

    /// Validates `line` as a single JSON value (RFC 8259, UTF-8) and fills `slots`. When a
    /// key repeats, the last occurrence wins. A path through a non-object value is absent.
    pub fn parse(self: *Parser, line: []const u8) Error!void {
        self.s = line;
        self.chunk_pos = 0;
        self.carry_escaped = 0;
        self.carry_in_string = 0;
        self.carry_scalar = 0;
        self.non_ascii = false;
        self.has_backslash = false;
        @memset(self.slots, null);
        var cur: Cursor = .{};
        _ = try self.tracked(&cur, 0, try self.need(&cur));
        if (try self.next(&cur) != null) return error.Invalid;
    }

    // -- Stage 1 --

    /// The structural positions of the next chunk, or null at the end of the line after the
    /// checks that need the whole line.
    fn nextChunk(self: *Parser) Error!?Cursor {
        const s = self.s;
        const pos = self.chunk_pos;
        var masks: Masks = undefined;
        if (pos + CHUNK <= s.len) {
            masks = classify(s[pos..][0..CHUNK].*);
            self.chunk_pos += CHUNK;
        } else if (pos < s.len) {
            const rest = s.len - pos;
            if (s.len >= CHUNK) {
                // The last 64 bytes of the line, shifted so the bytes already indexed drop out.
                masks = classify(s[s.len - CHUNK ..][0..CHUNK].*);
                const shift: u6 = @intCast(CHUNK - rest);
                inline for (.{ "backslash", "quote", "op", "space", "ctrl" }) |f| @field(masks, f) >>= shift;
            } else {
                var buf: [CHUNK]u8 = @splat(' ');
                @memcpy(buf[0..rest], s[pos..]);
                masks = classify(buf);
            }
            // Whatever follows the line counts as space, which adds nothing to the index.
            masks.space |= ~@as(u64, 0) << @intCast(rest);
            self.chunk_pos = s.len;
        } else {
            if (self.carry_in_string != 0) return error.Invalid;
            if (self.non_ascii and !validUtf8(s)) return error.Invalid;
            return null;
        }
        return .{ .bits = try self.structurals(pos, masks), .base = pos };
    }

    /// One bit per byte of a chunk.
    const Masks = struct { backslash: u64, quote: u64, op: u64, space: u64, ctrl: u64, non_ascii: bool };

    fn classify(c: CV) Masks {
        const zero: CV = @splat(0);
        // '[' and ']' differ from '{' and '}' only in bit 0x20.
        const c20 = c | @as(CV, @splat(0x20));
        const op = @select(u8, c20 == @as(CV, @splat('{')), ones, zero) | @select(u8, c20 == @as(CV, @splat('}')), ones, zero) |
            @select(u8, c == @as(CV, @splat(':')), ones, zero) | @select(u8, c == @as(CV, @splat(',')), ones, zero);
        var space = movemask(@select(u8, c == @as(CV, @splat(' ')), ones, zero));
        // Control characters, '\t', '\n' and '\r' among them, are rare in JSONL.
        var ctrl: u64 = 0;
        if (@reduce(.Min, c) < 0x20) {
            ctrl = movemask(@select(u8, c < @as(CV, @splat(0x20)), ones, zero));
            space |= movemask(@select(u8, c == @as(CV, @splat('\t')), ones, zero) | @select(u8, c == @as(CV, @splat('\n')), ones, zero) |
                @select(u8, c == @as(CV, @splat('\r')), ones, zero));
        }
        return .{
            .backslash = movemask(@select(u8, c == @as(CV, @splat('\\')), ones, zero)),
            .quote = movemask(@select(u8, c == @as(CV, @splat('"')), ones, zero)),
            .op = movemask(op),
            .space = space,
            .ctrl = ctrl,
            .non_ascii = @reduce(.Max, c) >= 0x80,
        };
    }

    /// The structural positions in the chunk at `base`, as a bitmask.
    fn structurals(self: *Parser, base: usize, masks: Masks) Error!u64 {
        var escaped = self.carry_escaped;
        self.carry_escaped = 0;
        if (masks.backslash != 0) {
            // Escapes are rare enough to walk one by one. A backslash escaped by the one
            // before it starts nothing.
            self.has_backslash = true;
            var m = masks.backslash & ~escaped;
            while (m != 0) {
                const i = @ctz(m);
                try self.checkEscape(base + i);
                if (i == CHUNK - 1) self.carry_escaped = 1 else escaped |= @as(u64, 2) << @intCast(i);
                m &= ~(@as(u64, 3) << @intCast(i));
            }
        }
        const quote = masks.quote & ~escaped;
        // Set from each opening quote up to its closing quote, excluding the latter.
        const in_string = prefixXor(quote) ^ self.carry_in_string;
        self.carry_in_string = @bitCast(@as(i64, @bitCast(in_string)) >> CHUNK - 1);
        if (masks.ctrl & in_string != 0) return error.Invalid;
        self.non_ascii = self.non_ascii or masks.non_ascii;

        const scalars = ~(masks.op | masks.space | quote | in_string);
        const scalar_start = scalars & ~(scalars << 1 | self.carry_scalar);
        self.carry_scalar = scalars >> CHUNK - 1;

        return (masks.op & ~in_string) | quote | scalar_start;
    }

    /// Checks the escape whose backslash is at `pos`.
    fn checkEscape(self: *const Parser, pos: usize) Error!void {
        const s = self.s;
        if (pos + 1 >= s.len) return error.Invalid;
        switch (s[pos + 1]) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
            'u' => if (hex4(s[pos + 2 ..]) == null) return error.Invalid,
            else => return error.Invalid,
        }
    }

    // -- Stage 2 --

    /// The structural positions not yet consumed in the chunk at `base`. Passed around rather
    /// than kept in the parser, so that it can live in registers.
    const Cursor = struct { bits: u64 = 0, base: usize = 0 };

    /// The next structural position, or null at the end of the line.
    inline fn next(self: *Parser, cur: *Cursor) Error!?usize {
        while (cur.bits == 0) cur.* = try self.nextChunk() orelse return null;
        defer cur.bits &= cur.bits - 1;
        return cur.base + @ctz(cur.bits);
    }

    inline fn need(self: *Parser, cur: *Cursor) Error!usize {
        return try self.next(cur) orelse error.Invalid;
    }

    /// Parses the value at `p` of trie node `n`, descending into the members it has children
    /// for. Returns the end of the value.
    fn tracked(self: *Parser, cur: *Cursor, n: u32, p: usize) Error!usize {
        const node = &self.trie.nodes[n];
        if (node.children.len == 0 or self.s[p] != '{') return self.value(cur, p);
        var q = try self.need(cur);
        if (self.s[q] == '}') return q + 1;
        while (true) {
            const key = try self.string(cur, q);
            try self.colon(cur);
            const v = try self.need(cur);
            if (findChild(self.trie, node, key)) |c| {
                const cn = &self.trie.nodes[c];
                // A leaf's only slot is about to be set.
                const end = if (cn.children.len == 0) try self.value(cur, v) else blk: {
                    @memset(self.slots[cn.slot_lo..cn.slot_hi], null);
                    break :blk try self.tracked(cur, c, v);
                };
                if (cn.slot) |slot| self.slots[slot] = self.s[v..end];
            } else _ = try self.value(cur, v);
            const d = try self.need(cur);
            switch (self.s[d]) {
                ',' => q = try self.need(cur),
                '}' => return d + 1,
                else => return error.Invalid,
            }
        }
    }

    fn findChild(trie: *const PathTrie, node: *const PathTrie.Node, key: Str) ?u32 {
        for (node.children) |c| {
            const seg = trie.nodes[c].seg;
            if (key.escaped) {
                if (decodedEql(key.raw, seg)) return c;
            } else if (key.raw.len == seg.len and std.mem.eql(u8, key.raw, seg)) return c;
        }
        return null;
    }

    /// Validates the value at `p` and returns its end. Only containers need `skipValue`.
    inline fn value(self: *Parser, cur: *Cursor, p: usize) Error!usize {
        return switch (self.s[p]) {
            '"' => try self.need(cur) + 1,
            '{', '[' => self.skipValue(cur, p),
            else => self.scalar(p),
        };
    }

    /// The string whose opening quote should be at `p`. Its contents were checked in stage 1,
    /// and the next structural is its closing quote.
    inline fn string(self: *Parser, cur: *Cursor, p: usize) Error!Str {
        const close = try self.skipString(cur, p);
        const raw = self.s[p + 1 .. close];
        return .{ .raw = raw, .escaped = self.has_backslash and std.mem.findScalar(u8, raw, '\\') != null };
    }

    /// Returns the position of the closing quote.
    inline fn skipString(self: *Parser, cur: *Cursor, p: usize) Error!usize {
        if (self.s[p] != '"') return error.Invalid;
        return self.need(cur);
    }

    inline fn colon(self: *Parser, cur: *Cursor) Error!void {
        if (self.s[try self.need(cur)] != ':') return error.Invalid;
    }

    /// Validates the value at `first` without recursion, so nesting depth doesn't use stack.
    /// Returns its end.
    fn skipValue(self: *Parser, outer: *Cursor, first: usize) Error!usize {
        var local = outer.*;
        defer outer.* = local;
        const cur = &local;
        const s = self.s;
        var p = first;
        var depth: usize = 0;
        while (true) {
            // At the start of a value.
            const c = s[p];
            var end = switch (c) {
                '{', '[' => blk: {
                    const q = try self.need(cur);
                    if (s[q] == c + 2) break :blk q + 1; // '}' and ']' are 2 after their openers
                    if (depth == MAX_DEPTH) return error.Invalid;
                    const bit = @as(u64, 1) << @intCast(depth % 64);
                    if (c == '{') self.stack[depth / 64] |= bit else self.stack[depth / 64] &= ~bit;
                    depth += 1;
                    p = q;
                    if (c == '{') {
                        _ = try self.skipString(cur, q);
                        try self.colon(cur);
                        p = try self.need(cur);
                    }
                    continue;
                },
                '"' => try self.need(cur) + 1,
                else => try self.scalar(p),
            };
            // After a value: close containers until one continues with another element.
            while (true) {
                if (depth == 0) return end;
                const in_object = self.stack[(depth - 1) / 64] >> @intCast((depth - 1) % 64) & 1 == 1;
                const d = try self.need(cur);
                if (s[d] == ',') {
                    p = try self.need(cur);
                    if (in_object) {
                        _ = try self.skipString(cur, p);
                        try self.colon(cur);
                        p = try self.need(cur);
                    }
                    break;
                }
                if (s[d] != @as(u8, if (in_object) '}' else ']')) return error.Invalid;
                end = d + 1;
                depth -= 1;
            }
        }
    }

    /// Validates the number or literal starting at `p` and returns its end. Stage 1 indexed
    /// only its first byte, so it must run up to whitespace or a structural character.
    fn scalar(self: *const Parser, p: usize) Error!usize {
        const s = self.s;
        const end = switch (s[p]) {
            't' => try literal(s, p, "true"),
            'f' => try literal(s, p, "false"),
            'n' => try literal(s, p, "null"),
            else => try number(s, p),
        };
        if (end < s.len) switch (s[end]) {
            ' ', '\t', '\r', '\n', ',', ':', '{', '}', '[', ']', '"' => {},
            else => return error.Invalid,
        };
        return end;
    }

    /// The first byte of `lit` is already known to match.
    fn literal(s: []const u8, p: usize, comptime lit: []const u8) Error!usize {
        if (s.len - p < lit.len) return error.Invalid;
        const tail = comptime std.mem.readInt(u32, lit[lit.len - 4 ..][0..4], .little);
        if (std.mem.readInt(u32, s[p + lit.len - 4 ..][0..4], .little) != tail) return error.Invalid;
        return p + lit.len;
    }

    /// The end of the run of digits at `start`, eight bytes at a time.
    fn digits(s: []const u8, start: usize) usize {
        const lanes: u64 = 0x0101010101010101;
        var i = start;
        while (i + 8 <= s.len) : (i += 8) {
            const w = std.mem.readInt(u64, s[i..][0..8], .little);
            // A digit has high nibble 3 and low nibble at most 9. `bad` has a nonzero high
            // nibble in every other byte.
            const bad = ((w & 0xf0 * lanes) ^ 0x30 * lanes) | (((w & 0x0f * lanes) + 0x06 * lanes) & 0x10 * lanes);
            const nonzero = (((bad >> 4) & 0x0f * lanes) + 0x0f * lanes) & 0x10 * lanes;
            if (nonzero != 0) return i + @ctz(nonzero) / 8;
        }
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        return i;
    }

    fn number(s: []const u8, p: usize) Error!usize {
        var i = p;
        if (s[i] == '-') i += 1;
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
        return i;
    }
};

const ones: CV = @splat(0xff);

const V16 = @Vector(16, u8);
/// The NEON instruction below is called as an LLVM intrinsic, which Zig's own backends
/// (the default for x86_64 debug builds) don't provide.
const llvm = builtin.zig_backend == .stage2_llvm;

extern fn @"llvm.aarch64.neon.addp.v16i8"(V16, V16) V16;

/// Bit i is set when byte i of `v`, all ones or zero, is set. NEON has no movemask, and the
/// generic lowering of a bool vector bitcast is about three times as long as these pairwise adds.
inline fn movemask(v: CV) u64 {
    if (!llvm or builtin.cpu.arch != .aarch64) return @bitCast(v != @as(CV, @splat(0)));
    const weights: CV = @bitCast(@as([8]u64, @splat(0x8040201008040201)));
    const b: [4]V16 = @bitCast(v & weights);
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const sum = addp(addp(b[0], b[1]), addp(b[2], b[3]));
    return @as([2]u64, @bitCast(addp(sum, sum)))[0];
}

/// XOR of each bit with all bits below it.
inline fn prefixXor(x: u64) u64 {
    var y = x;
    inline for (.{ 1, 2, 4, 8, 16, 32 }) |k| y ^= y << k;
    return y;
}

pub fn hex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var v: u16 = 0;
    for (s[0..4]) |c| v = v * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    return v;
}

/// Decodes the character at `raw[i.*]`, an escape or a plain byte, into `buf` and advances
/// `i` past it. Lone surrogates decode to U+FFFD. Malformed escapes (only possible in input
/// that wasn't validated) decode to the escaped byte.
pub fn nextUnit(raw: []const u8, i: *usize, buf: *[4]u8) []const u8 {
    const c = raw[i.*];
    if (c != '\\' or i.* + 1 == raw.len) {
        i.* += 1;
        buf[0] = c;
        return buf[0..1];
    }
    const e = raw[i.* + 1];
    i.* += 2;
    buf[0] = switch (e) {
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => {
            const unit = hex4(raw[i.*..]) orelse {
                buf[0] = 'u';
                return buf[0..1];
            };
            i.* += 4;
            var cp: u21 = unit;
            if (unit >= 0xd800 and unit <= 0xdbff and i.* + 6 <= raw.len and raw[i.*] == '\\' and raw[i.* + 1] == 'u') {
                if (hex4(raw[i.* + 2 ..])) |low| {
                    if (low >= 0xdc00 and low <= 0xdfff) {
                        cp = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                        i.* += 6;
                    }
                }
            }
            const n = std.unicode.utf8Encode(cp, buf) catch {
                buf[0..3].* = "\u{fffd}".*;
                return buf[0..3];
            };
            return buf[0..n];
        },
        else => e,
    };
    return buf[0..1];
}

/// Appends the decoded contents of a JSON string to `out`.
pub fn decodeInto(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < raw.len) {
        const run_end = std.mem.findScalarPos(u8, raw, i, '\\') orelse raw.len;
        try out.appendSlice(gpa, raw[i..run_end]);
        i = run_end;
        if (i < raw.len) try out.appendSlice(gpa, nextUnit(raw, &i, &buf));
    }
}

/// Whether the raw contents of a JSON string decode to `target`.
pub fn decodedEql(raw: []const u8, target: []const u8) bool {
    var i: usize = 0;
    var t: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < raw.len) {
        const unit = nextUnit(raw, &i, &buf);
        if (!std.mem.startsWith(u8, target[t..], unit)) return false;
        t += unit.len;
    }
    return t == target.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const ReferenceParser = @import("json_reference.zig").ReferenceParser;

test {
    _ = utf8;
}

fn expectValid(line: []const u8, valid: bool) !void {
    const trie: PathTrie = .{ .nodes = &.{.{ .seg = "", .children = &.{}, .slot = null, .slot_lo = 0, .slot_hi = 0 }}, .slot_count = 0 };
    const p = try testing.allocator.create(Parser);
    defer testing.allocator.destroy(p);
    p.* = .{ .trie = &trie, .slots = &.{} };
    const got = if (p.parse(line)) true else |_| false;
    if (got != valid) {
        std.debug.print("line: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
}

test "validation" {
    for ([_][]const u8{
        "{}",                 " {\"a\" : [1, -2.5e+3, true, false, null, {}, []]}\r",
        "\"x\"",              "0",
        "[[[[]]]]",           "{\"\\u00e9\\ud83d\\ude00\\n\\/\":\"\xc3\xa9\"}",
        "{\"a\":{\"b\":{}}}", "-0.0E-0",
    }) |l| try expectValid(l, true);
    for ([_][]const u8{
        "",        "{",         "{\"a\"}",           "{\"a\":}", "{\"a\":1,}",       "[1,]",  "01",
        "1.",      ".5",        "1e",                "+1",       "tru",              "nul",   "\"a",
        "\"\\x\"", "\"\\u12\"", "\"\x01\"",          "\"\xc3\"", "\"\xed\xa0\x80\"", "{} {}", "{'a':1}",
        "[1 2]",   "{\"a\" 1}", "{\"a\":1 \"b\":2}", "]",        "{]",               "[}",    "\"\xff\"",
    }) |l| try expectValid(l, false);
}

test "path slots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const []const u8{ &.{"a"}, &.{ "a", "b" }, &.{"c"}, &.{ "x", "y", "z" }, &.{"a"} };
    var slots: [paths.len]u32 = undefined;
    const trie = try PathTrie.init(a, &paths, &slots);
    try testing.expectEqual(slots[0], slots[4]);
    const p = try a.create(Parser);
    p.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };

    try p.parse("{\"a\": {\"b\": [1]}, \"c\":\"s\", \"x\":{\"y\":{\"z\":null}}}");
    try testing.expectEqualStrings("{\"b\": [1]}", p.slots[slots[0]].?);
    try testing.expectEqualStrings("[1]", p.slots[slots[1]].?);
    try testing.expectEqualStrings("\"s\"", p.slots[slots[2]].?);
    try testing.expectEqualStrings("null", p.slots[slots[3]].?);

    // The last duplicate wins, and clears what the earlier one found below it.
    try p.parse("{\"a\":{\"b\":1},\"a\":2,\"n\":{\"c\":1}}");
    try testing.expectEqualStrings("2", p.slots[slots[0]].?);
    try testing.expectEqual(@as(?[]const u8, null), p.slots[slots[1]]);
    try testing.expectEqual(@as(?[]const u8, null), p.slots[slots[2]]);

    // Keys are compared decoded.
    try p.parse("{\"\\u0061\":{\"\\u0062\":3}}");
    try testing.expectEqualStrings("3", p.slots[slots[1]].?);
}

test "decoding" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try decodeInto(&out, testing.allocator, "a\\\"b\\\\c\\/\\n\\u00e9\\ud83d\\ude00\\ud800x");
    try testing.expectEqualStrings("a\"b\\c/\n\u{e9}\u{1f600}\u{fffd}x", out.items);
    try testing.expect(decodedEql("caf\\u00e9", "caf\u{e9}"));
    try testing.expect(!decodedEql("caf\\u00e9", "cafe"));
    try testing.expect(!decodedEql("ab", "abc"));
}

test "deep nesting is skipped without recursion" {
    const n = 100_000;
    const line = try testing.allocator.alloc(u8, 2 * n);
    defer testing.allocator.free(line);
    @memset(line[0..n], '[');
    @memset(line[n..], ']');
    try expectValid(line, false);
    try expectValid(line[n - 1000 .. n + 1000], true);
}

/// Appends a random JSON value, valid or nearly so, rich in what stage 1 has to get right:
/// escapes, backslash runs, structural characters inside strings, non-ASCII text, and
/// strings and numbers crossing the 64-byte chunk boundaries.
fn fuzzValue(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, rand: std.Random, depth: u32) !void {
    const spaces = [_][]const u8{ "", "", "", " ", "\t", "\r\n", "  " };
    const keys = [_][]const u8{ "a", "b", "c", "\\u0061", "\u{e9}", "\\u00e9", "a\\\\", "" };
    // The last few of each are invalid, and picked less often.
    const pieces = [_][]const u8{ "x", "yz", "\\\"", "\\\\", "\\\\\\\\", "\\u00e9", "\\ud83d\\ude00", "\u{e9}", "\u{65e5}\u{672c}", "\u{1f600}", "\\n", "\\/", " ", "{", "}", ",", ":", "[", "]", "\\", "\x01", "\xc3", "\\u12" };
    const scalars = [_][]const u8{ "0", "-1", "12345678901234567890", "2.5", "-0.0e+10", "1E3", "true", "false", "null", "01", "1.", "-", "tru", "nul" };
    const pick = struct {
        fn f(r: std.Random, pool: []const []const u8, invalid: usize) []const u8 {
            return pool[r.uintLessThan(usize, if (r.uintLessThan(u32, 40) == 0) pool.len else pool.len - invalid)];
        }
    }.f;
    const kind = rand.uintLessThan(u32, if (depth > 3) 2 else 4);
    switch (kind) {
        0 => try out.appendSlice(a, pick(rand, &scalars, 5)),
        1 => {
            try out.append(a, '"');
            const n = rand.uintLessThan(usize, 12);
            for (0..n) |_| try out.appendSlice(a, pick(rand, &pieces, 4));
            // Padding moves everything relative to the chunks.
            try out.appendNTimes(a, '.', rand.uintLessThan(usize, 70));
            try out.append(a, '"');
        },
        2, 3 => {
            const obj = kind == 2;
            try out.append(a, if (obj) '{' else '[');
            const n = rand.uintLessThan(usize, 5);
            for (0..n) |i| {
                if (i > 0) try out.append(a, ',');
                try out.appendSlice(a, spaces[rand.uintLessThan(usize, spaces.len)]);
                if (obj) {
                    try out.print(a, "\"{s}\"", .{keys[rand.uintLessThan(usize, keys.len)]});
                    try out.appendSlice(a, spaces[rand.uintLessThan(usize, spaces.len)]);
                    try out.append(a, ':');
                    try out.appendSlice(a, spaces[rand.uintLessThan(usize, spaces.len)]);
                }
                try fuzzValue(out, a, rand, depth + 1);
                try out.appendSlice(a, spaces[rand.uintLessThan(usize, spaces.len)]);
            }
            try out.append(a, if (obj) '}' else ']');
        },
        else => unreachable,
    }
}

test "differential: Parser agrees with the single-pass parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const []const u8{ &.{"a"}, &.{ "a", "b" }, &.{"\u{e9}"}, &.{ "b", "a", "c" }, &.{"a\\"}, &.{""} };
    var path_slots: [paths.len]u32 = undefined;
    const trie = try PathTrie.init(a, &paths, &path_slots);
    const p = try a.create(Parser);
    p.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };
    const ref = try a.create(ReferenceParser);
    ref.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };

    var prng = std.Random.DefaultPrng.init(0x51d);
    const rand = prng.random();
    const noise = [_]u8{ '"', '\\', '{', '}', '[', ']', ',', ':', ' ', '\t', '\n', 0x01, 0x7f, 0x80, 0xbf, 0xc3, 0xe9, 0xf0, 'u', '0', 'a', 't', '-', '.', 'e' };
    var line: std.ArrayListUnmanaged(u8) = .empty;
    var valid: usize = 0;
    for (0..30_000) |_| {
        line.clearRetainingCapacity();
        try line.appendSlice(a, ([_][]const u8{ "", " ", "\t" })[rand.uintLessThan(usize, 3)]);
        try fuzzValue(&line, a, rand, 0);
        // Byte edits put every kind of byte at every offset relative to the chunks.
        for (0..rand.uintLessThan(u32, 4) -| 1) |_| {
            if (line.items.len == 0) break;
            const i = rand.uintLessThan(usize, line.items.len);
            const b = noise[rand.uintLessThan(usize, noise.len)];
            switch (rand.uintLessThan(u32, 4)) {
                0 => line.items[i] = b,
                1 => try line.insert(a, i, b),
                2 => _ = line.orderedRemove(i),
                else => line.items.len = i,
            }
        }

        const want = if (ref.parse(line.items)) true else |_| false;
        const got = if (p.parse(line.items)) true else |_| false;
        var same = want == got;
        if (same and want) {
            valid += 1;
            for (ref.slots, p.slots) |w, g| {
                if ((w == null) != (g == null) or (w != null and !std.mem.eql(u8, w.?, g.?))) same = false;
            }
        }
        if (!same) {
            std.debug.print("line: {s}\nwant valid: {}, got valid: {}\n", .{ line.items, want, got });
            return error.TestUnexpectedResult;
        }
    }
    // The generator must produce enough valid lines for the slots to be compared.
    try testing.expect(valid > 10_000);
}
