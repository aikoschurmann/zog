//! The exact layer: a validating JSON parser that records the values at a set of key paths,
//! and JSON string decoding. Lines the byte-level prefilter can't rule out are parsed here.
const std = @import("std");
const builtin = @import("builtin");
const utf8 = @import("utf8.zig");

const validUtf8 = utf8.validUtf8;

pub const Error = error{Invalid};

/// Lines nested deeper than this are treated as invalid.
pub const max_depth = 64 * 1024;

/// The key paths a query needs, as a tree of object keys. Each requested path has a slot that
/// the parser fills with the raw text of its value. A node's slot and those of everything
/// below it are contiguous, so a repeated key can clear its whole subtree at once.
pub const PathTrie = struct {
    nodes: []const Node,
    slot_count: usize,

    pub const root: u32 = 0;

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
    pub fn init(
        allocator: std.mem.Allocator,
        paths: []const []const []const u8,
        path_slots: []u32,
    ) !PathTrie {
        // Build the trie with growable child lists first, then freeze it into `nodes`.
        const Build = struct {
            seg: []const u8,
            children: std.ArrayList(u32) = .empty,
            // Set on the node that a path ends at. Only those nodes get a slot.
            terminal: bool = false,
        };

        // Nodes refer to each other by index: `append` may reallocate `builder_nodes`, which
        // would invalidate pointers into it.
        var builder_nodes: std.ArrayList(Build) = .empty;
        try builder_nodes.append(allocator, .{ .seg = "" });

        // The node each path ends at.
        const path_nodes = try allocator.alloc(u32, paths.len);
        for (paths, path_nodes) |path, *path_node| {
            // Walk down from the root, adding a child for each segment not seen yet.
            var node_index: u32 = 0;
            for (path) |seg| {
                node_index = for (builder_nodes.items[node_index].children.items) |child| {
                    if (std.mem.eql(u8, builder_nodes.items[child].seg, seg)) break child;
                } else blk: {
                    const child: u32 = @intCast(builder_nodes.items.len);
                    try builder_nodes.append(allocator, .{ .seg = seg });
                    try builder_nodes.items[node_index].children.append(allocator, child);
                    break :blk child;
                };
            }
            builder_nodes.items[node_index].terminal = true;
            path_node.* = node_index;
        }

        // Slots are numbered depth-first, so each subtree's slots form one range.
        const nodes = try allocator.alloc(Node, builder_nodes.items.len);
        var next_slot: u32 = 0;
        assign(builder_nodes.items, nodes, 0, &next_slot);

        for (path_nodes, path_slots) |path_node, *slot| {
            // Every path ends at a terminal node, and terminal nodes always have a slot.
            slot.* = nodes[path_node].slot.?;
        }
        return .{ .nodes = nodes, .slot_count = next_slot };
    }

    /// Copies node `node_index` and its subtree into `nodes`, giving each path's end a slot in
    /// preorder. `slot_lo..slot_hi` then covers `node_index`'s slot and those of all nodes below it.
    fn assign(builder_nodes: anytype, nodes: []Node, node_index: u32, next_slot: *u32) void {
        nodes[node_index] = .{
            .seg = builder_nodes[node_index].seg,
            .children = builder_nodes[node_index].children.items,
            .slot = if (builder_nodes[node_index].terminal) next_slot.* else null,
            .slot_lo = next_slot.*,
            // Filled in below, once the children have been numbered.
            .slot_hi = undefined,
        };

        // A node's own slot comes before the slots of its children, so the range starts at it.
        if (builder_nodes[node_index].terminal) next_slot.* += 1;

        for (builder_nodes[node_index].children.items) |child| {
            assign(builder_nodes, nodes, child, next_slot);
        }
        nodes[node_index].slot_hi = next_slot.*;
    }
};

pub const Str = struct { raw: []const u8, escaped: bool };

/// Bytes per stage-1 chunk, one bit each in a u64 mask.
const chunk_len = 64;
const CV = @Vector(chunk_len, u8);

/// A validating parser in two stages, after simdjson. Stage 1 classifies the line 64 bytes at
/// a time with SIMD and marks its structural characters in a bitmask: `{}[]:,`, every quote
/// that isn't escaped, and the first byte of every number or literal. Along the way it
/// rejects control characters in strings, malformed escapes and invalid UTF-8. Stage 2 checks
/// the grammar and records the values at the trie's paths, visiting only the marked
/// positions, so it never looks inside a string. It takes them straight from the bitmask and
/// has stage 1 classify the next chunk when that runs out, so no index is stored however long
/// the line is.
pub const Parser = struct {
    input: []const u8 = &.{},
    trie: *const PathTrie,
    /// Raw text of the value at each path (strings with their quotes), or null if absent.
    slots: []?[]const u8,
    /// One bit per open container while skipping a value: set for objects.
    stack: [max_depth / 64]u64 = undefined,

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
        self.input = line;
        self.chunk_pos = 0;
        self.carry_escaped = 0;
        self.carry_in_string = 0;
        self.carry_scalar = 0;
        self.non_ascii = false;
        self.has_backslash = false;
        @memset(self.slots, null);

        var cur: Cursor = .{};
        _ = try self.parseTracked(&cur, PathTrie.root, try self.expectStructural(&cur));
        if (try self.nextStructural(&cur) != null) return error.Invalid;
    }

    // -- Stage 1 --

    /// The structural positions of the next chunk, or null at the end of the line after the
    /// checks that need the whole line.
    fn nextChunk(self: *Parser) Error!?Cursor {
        const input = self.input;
        const pos = self.chunk_pos;
        var masks: Masks = undefined;

        if (pos + chunk_len <= input.len) {
            // A full chunk.
            masks = classify(input[pos..][0..chunk_len].*);
            self.chunk_pos += chunk_len;
        } else if (pos < input.len) {
            // The tail: fewer than 64 bytes left.
            const rest = input.len - pos;
            if (input.len >= chunk_len) {
                // Classify the last 64 bytes of the line instead of copying the tail, then shift
                // out the `chunk_len - rest` bytes the previous chunk already covered, so bit 0 is
                // the byte at `pos` again. `non_ascii` still sees those bytes, which at worst
                // costs a UTF-8 check that wasn't needed.
                masks = classify(input[input.len - chunk_len ..][0..chunk_len].*);
                const shift: u6 = @intCast(chunk_len - rest);
                inline for (.{ "backslash", "quote", "op", "space", "ctrl" }) |field| {
                    @field(masks, field) >>= shift;
                }
            } else {
                // The whole line is shorter than a chunk: pad it with spaces, which are never
                // structural.
                var buf: [chunk_len]u8 = @splat(' ');
                @memcpy(buf[0..rest], input[pos..]);
                masks = classify(buf);
            }
            // Whatever follows the line counts as space, which adds nothing to the index.
            masks.space |= ~@as(u64, 0) << @intCast(rest);
            self.chunk_pos = input.len;
        } else {
            // End of the line. A string still open here was never closed. UTF-8 is validated
            // once for the whole line, and only if some byte was non-ASCII.
            if (self.carry_in_string != 0) return error.Invalid;
            if (self.non_ascii and !validUtf8(input)) return error.Invalid;
            return null;
        }

        return .{ .bits = try self.structurals(pos, masks), .base = pos };
    }

    /// One bit per byte of a chunk.
    const Masks = struct {
        backslash: u64,
        quote: u64,
        op: u64,
        space: u64,
        ctrl: u64,
        non_ascii: bool,
    };

    /// Per-byte masks for one chunk. Each compare gives 0xff or 0 per byte, which `movemask`
    /// packs into one bit per byte.
    fn classify(c: CV) Masks {
        const zero: CV = @splat(0);
        // '[' and ']' differ from '{' and '}' only in bit 0x20.
        const c20 = c | @as(CV, @splat(0x20));

        // The structural operators: braces and brackets (through `c20`), ':' and ','.
        const op = @select(u8, c20 == @as(CV, @splat('{')), ones, zero) |
            @select(u8, c20 == @as(CV, @splat('}')), ones, zero) |
            @select(u8, c == @as(CV, @splat(':')), ones, zero) |
            @select(u8, c == @as(CV, @splat(',')), ones, zero);

        var space = movemask(@select(u8, c == @as(CV, @splat(' ')), ones, zero));

        // Control characters, '\t', '\n' and '\r' among them, are rare in JSONL, so both
        // masks are skipped when no byte is below 0x20.
        var ctrl: u64 = 0;
        if (@reduce(.Min, c) < 0x20) {
            ctrl = movemask(@select(u8, c < @as(CV, @splat(0x20)), ones, zero));
            space |= movemask(@select(u8, c == @as(CV, @splat('\t')), ones, zero) |
                @select(u8, c == @as(CV, @splat('\n')), ones, zero) |
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
        // Bytes preceded by a backslash that is itself not escaped. Bit 0 comes from the
        // previous chunk when it ended in such a backslash.
        var escaped = self.carry_escaped;
        self.carry_escaped = 0;

        if (masks.backslash != 0) {
            // Escapes are rare enough to walk one by one. A backslash escaped by the one
            // before it starts nothing.
            self.has_backslash = true;
            var unchecked_backslashes = masks.backslash & ~escaped;
            while (unchecked_backslashes != 0) {
                const bit = @ctz(unchecked_backslashes);
                try self.checkEscape(base + bit);

                // Mark the byte after the backslash, which may be the first of the next chunk.
                if (bit == chunk_len - 1) {
                    self.carry_escaped = 1;
                } else {
                    escaped |= @as(u64, 2) << @intCast(bit);
                }

                // Drop this backslash and the byte it escapes: in `\\\\` the second backslash
                // starts nothing.
                unchecked_backslashes &= ~(@as(u64, 3) << @intCast(bit));
            }
        }

        // An escaped quote is string content, not a delimiter.
        const quote = masks.quote & ~escaped;

        // Set from each opening quote up to its closing quote, excluding the latter. XOR with
        // the carry inverts the chunk when it starts inside a string.
        const in_string = prefixXor(quote) ^ self.carry_in_string;
        // Bit 63 copied to every bit: whether the next chunk starts inside a string.
        self.carry_in_string = @bitCast(@as(i64, @bitCast(in_string)) >> chunk_len - 1);

        // Raw control characters are invalid inside strings. Outside, '\t', '\n' and '\r' are
        // whitespace, and any other one ends up as a scalar that `parseScalar` rejects.
        if (masks.ctrl & in_string != 0) return error.Invalid;
        self.non_ascii = self.non_ascii or masks.non_ascii;

        // What is left belongs to numbers and literals. Only the first byte of each run is
        // structural: a scalar byte whose predecessor (from the last chunk, for bit 0) isn't.
        const scalars = ~(masks.op | masks.space | quote | in_string);
        const scalar_start = scalars & ~(scalars << 1 | self.carry_scalar);
        self.carry_scalar = scalars >> chunk_len - 1;

        // Both quotes of a string are structural, so stage 2 steps over a string in one move.
        return (masks.op & ~in_string) | quote | scalar_start;
    }

    /// Checks the escape whose backslash is at `pos`.
    fn checkEscape(self: *const Parser, pos: usize) Error!void {
        const input = self.input;

        // A backslash at the very end of the line has nothing to escape.
        if (pos + 1 >= input.len) return error.Invalid;

        switch (input[pos + 1]) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
            // `\u` needs four hex digits after it. Lone surrogates pass this check and decode
            // to U+FFFD in `nextUnit`.
            'u' => if (hex4(input[pos + 2 ..]) == null) return error.Invalid,
            else => return error.Invalid,
        }
    }

    // -- Stage 2 --

    /// The structural positions not yet consumed in the chunk at `base`. Passed around rather
    /// than kept in the parser, so that it can live in registers.
    const Cursor = struct { bits: u64 = 0, base: usize = 0 };

    /// The next structural position, or null at the end of the line.
    inline fn nextStructural(self: *Parser, cur: *Cursor) Error!?usize {
        // Chunks inside a long string have no structurals: keep classifying until one does.
        while (cur.bits == 0) {
            cur.* = try self.nextChunk() orelse return null;
        }

        // Pop the lowest bit once its position has been read.
        defer cur.bits &= cur.bits - 1;
        return cur.base + @ctz(cur.bits);
    }

    inline fn expectStructural(self: *Parser, cur: *Cursor) Error!usize {
        return try self.nextStructural(cur) orelse error.Invalid;
    }

    /// Parses the value at `pos` of trie node `node_index`, descending into the members it has
    /// children for. Returns the end of the value.
    fn parseTracked(self: *Parser, cur: *Cursor, node_index: u32, pos: usize) Error!usize {
        const node = &self.trie.nodes[node_index];

        // Only an object with tracked members is worth descending into; anything else is
        // only validated.
        if (node.children.len == 0 or self.input[pos] != '{') return self.parseValue(cur, pos);

        // The first key's opening quote, or '}' for an empty object.
        var member_pos = try self.expectStructural(cur);
        if (self.input[member_pos] == '}') return member_pos + 1;

        while (true) {
            const key = try self.parseString(cur, member_pos);
            try self.expectColon(cur);
            const value_pos = try self.expectStructural(cur);

            if (findChild(self.trie, node, key)) |child_index| {
                const child = &self.trie.nodes[child_index];
                // When a key repeats the last value wins, so forget what an earlier value filled
                // in below this node. A leaf has no slots below it, and its own slot is set
                // right after.
                const end = if (child.children.len == 0)
                    try self.parseValue(cur, value_pos)
                else blk: {
                    @memset(self.slots[child.slot_lo..child.slot_hi], null);
                    break :blk try self.parseTracked(cur, child_index, value_pos);
                };
                if (child.slot) |slot| self.slots[slot] = self.input[value_pos..end];
            } else {
                _ = try self.parseValue(cur, value_pos);
            }

            // After a member: ',' and the next key, or the end of the object.
            const delim_pos = try self.expectStructural(cur);
            switch (self.input[delim_pos]) {
                ',' => member_pos = try self.expectStructural(cur),
                '}' => return delim_pos + 1,
                else => return error.Invalid,
            }
        }
    }

    /// The child of `node` whose segment is `key`, or null. A key with escapes is compared
    /// decoded, so `"\u0061"` matches `a`. A key without escapes is its own decoded text, so a
    /// plain byte comparison is enough.
    fn findChild(trie: *const PathTrie, node: *const PathTrie.Node, key: Str) ?u32 {
        for (node.children) |child| {
            const seg = trie.nodes[child].seg;
            if (key.escaped) {
                if (decodedEql(key.raw, seg)) return child;
            } else if (key.raw.len == seg.len and std.mem.eql(u8, key.raw, seg)) {
                return child;
            }
        }
        return null;
    }

    /// Validates the value at `pos` and returns its end. Only containers need `skipValue`.
    inline fn parseValue(self: *Parser, cur: *Cursor, pos: usize) Error!usize {
        return switch (self.input[pos]) {
            // The next structural is the closing quote.
            '"' => try self.expectStructural(cur) + 1,
            '{', '[' => self.skipValue(cur, pos),
            else => self.parseScalar(pos),
        };
    }

    /// The string whose opening quote should be at `pos`. Its contents were checked in stage 1,
    /// and the next structural is its closing quote.
    inline fn parseString(self: *Parser, cur: *Cursor, pos: usize) Error!Str {
        const close = try self.skipString(cur, pos);
        const raw = self.input[pos + 1 .. close];

        // Only search the key for a backslash if stage 1 saw one somewhere in the line.
        const escaped = self.has_backslash and std.mem.findScalar(u8, raw, '\\') != null;
        return .{ .raw = raw, .escaped = escaped };
    }

    /// Returns the position of the closing quote.
    inline fn skipString(self: *Parser, cur: *Cursor, pos: usize) Error!usize {
        if (self.input[pos] != '"') return error.Invalid;
        return self.expectStructural(cur);
    }

    inline fn expectColon(self: *Parser, cur: *Cursor) Error!void {
        if (self.input[try self.expectStructural(cur)] != ':') return error.Invalid;
    }

    /// Validates the value at `first` without recursion, so nesting depth doesn't use stack.
    /// Returns its end.
    fn skipValue(self: *Parser, outer: *Cursor, first: usize) Error!usize {
        // Work on a local copy of the cursor so it stays in registers during the loop.
        var local = outer.*;
        defer outer.* = local;
        const cur = &local;
        const input = self.input;

        var value_pos = first;
        var depth: usize = 0;
        while (true) {
            // At the start of a value.
            const opener = input[value_pos];
            var end = switch (opener) {
                '{', '[' => blk: {
                    const member_pos = try self.expectStructural(cur);

                    // An empty container is a complete value. '}' and ']' are 2 after their
                    // openers in ASCII.
                    if (input[member_pos] == opener + 2) break :blk member_pos + 1;

                    // Push: one bit per level, set for an object and clear for an array.
                    if (depth == max_depth) return error.Invalid;
                    const bit = @as(u64, 1) << @intCast(depth % 64);
                    if (opener == '{') {
                        self.stack[depth / 64] |= bit;
                    } else {
                        self.stack[depth / 64] &= ~bit;
                    }
                    depth += 1;

                    // `member_pos` starts the first element. In an object that is a key, and the
                    // value comes after the colon.
                    value_pos = member_pos;
                    if (opener == '{') {
                        _ = try self.skipString(cur, member_pos);
                        try self.expectColon(cur);
                        value_pos = try self.expectStructural(cur);
                    }
                    continue;
                },
                '"' => try self.expectStructural(cur) + 1,
                else => try self.parseScalar(value_pos),
            };

            // After a value: close containers until one continues with another element.
            while (true) {
                if (depth == 0) return end;

                // Whether the innermost open container is an object.
                const in_object = self.stack[(depth - 1) / 64] >> @intCast((depth - 1) % 64) & 1 == 1;
                const delim_pos = try self.expectStructural(cur);

                if (input[delim_pos] == ',') {
                    // Another element. After a trailing comma `value_pos` is a closer, which
                    // fails as a value on the next round.
                    value_pos = try self.expectStructural(cur);
                    if (in_object) {
                        _ = try self.skipString(cur, value_pos);
                        try self.expectColon(cur);
                        value_pos = try self.expectStructural(cur);
                    }
                    break;
                }

                // Otherwise it must close the innermost container, completing the value one
                // level up.
                if (input[delim_pos] != @as(u8, if (in_object) '}' else ']')) return error.Invalid;
                end = delim_pos + 1;
                depth -= 1;
            }
        }
    }

    /// Validates the number or literal starting at `pos` and returns its end. Stage 1 indexed
    /// only its first byte, so it must run up to whitespace or a structural character.
    fn parseScalar(self: *const Parser, pos: usize) Error!usize {
        const input = self.input;
        const end = switch (input[pos]) {
            't' => try expectLiteral(input, pos, "true"),
            'f' => try expectLiteral(input, pos, "false"),
            'n' => try expectLiteral(input, pos, "null"),
            else => try parseNumber(input, pos),
        };

        // The scalar must end at a token boundary: `truex` or `01` leave a byte that isn't.
        // What may follow is up to the grammar.
        if (end < input.len) switch (input[end]) {
            ' ', '\t', '\r', '\n', ',', ':', '{', '}', '[', ']', '"' => {},
            else => return error.Invalid,
        };
        return end;
    }

    /// The first byte of `lit` is already known to match. The last four bytes are compared as
    /// one u32: all of `true` and `null`, and all of `false` after the 'f'.
    fn expectLiteral(input: []const u8, pos: usize, comptime lit: []const u8) Error!usize {
        if (input.len - pos < lit.len) return error.Invalid;
        const tail = comptime std.mem.readInt(u32, lit[lit.len - 4 ..][0..4], .little);
        if (std.mem.readInt(u32, input[pos + lit.len - 4 ..][0..4], .little) != tail) {
            return error.Invalid;
        }
        return pos + lit.len;
    }

    /// The end of the run of digits at `start`, eight bytes at a time.
    fn skipDigits(input: []const u8, start: usize) usize {
        const lanes: u64 = 0x0101010101010101;
        var pos = start;
        while (pos + 8 <= input.len) : (pos += 8) {
            const word = std.mem.readInt(u64, input[pos..][0..8], .little);

            // SWAR, one byte per lane. A digit has high nibble 3 and low nibble at most 9:
            // `(w & 0xf0) ^ 0x30` is zero exactly when the high nibble is 3, and adding 6 to
            // the low nibble carries into bit 4 exactly when it is 10 or more. Both land in
            // the high nibble, so `bad` has a nonzero high nibble in every non-digit byte.
            const bad = ((word & 0xf0 * lanes) ^ 0x30 * lanes) |
                (((word & 0x0f * lanes) + 0x06 * lanes) & 0x10 * lanes);

            // Move each high nibble down and add 0x0f: bit 4 is set exactly when the nibble
            // was nonzero. Neither step carries into the next lane. The lowest set bit is the
            // first non-digit, the input having been read little-endian.
            const nonzero = (((bad >> 4) & 0x0f * lanes) + 0x0f * lanes) & 0x10 * lanes;
            if (nonzero != 0) return pos + @ctz(nonzero) / 8;
        }

        while (pos < input.len and input[pos] >= '0' and input[pos] <= '9') pos += 1;
        return pos;
    }

    /// `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`. A leading 0 ends the integer
    /// part, so `01` stops before the '1' and `parseScalar` rejects it.
    fn parseNumber(input: []const u8, pos: usize) Error!usize {
        var end = pos;

        // Optional sign, then the integer part.
        if (input[end] == '-') end += 1;
        if (end >= input.len) return error.Invalid;
        if (input[end] == '0') {
            end += 1;
        } else if (input[end] >= '1' and input[end] <= '9') {
            end = skipDigits(input, end);
        } else {
            return error.Invalid;
        }

        // Optional fraction: a '.' must be followed by at least one digit.
        if (end < input.len and input[end] == '.') {
            const digits_end = skipDigits(input, end + 1);
            if (digits_end == end + 1) return error.Invalid;
            end = digits_end;
        }

        // Optional exponent: an 'e' must be followed by at least one digit.
        if (end < input.len and (input[end] == 'e' or input[end] == 'E')) {
            end += 1;
            if (end < input.len and (input[end] == '+' or input[end] == '-')) end += 1;
            const digits_end = skipDigits(input, end);
            if (digits_end == end) return error.Invalid;
            end = digits_end;
        }
        return end;
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

    // Byte i keeps only bit `i % 8`, its weight in the output byte for its group of 8.
    const weights: CV = @bitCast(@as([8]u64, @splat(0x8040201008040201)));
    const parts: [4]V16 = @bitCast(v & weights);

    // Each pairwise add sums neighbouring bytes, halving their number. After three rounds
    // every byte is the sum of 8 weighted bytes: the mask byte for those 8 input bytes.
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const sum = addp(addp(parts[0], parts[1]), addp(parts[2], parts[3]));
    return @as([2]u64, @bitCast(addp(sum, sum)))[0];
}

/// Bit i of the result is the XOR of bits 0..i of `x`. Applied to the quote positions it is
/// set from each opening quote up to the byte before the closing one. Doubling the shift each
/// step covers 64 bits in six steps.
inline fn prefixXor(x: u64) u64 {
    var y = x;
    inline for (.{ 1, 2, 4, 8, 16, 32 }) |k| y ^= y << k;
    return y;
}

/// The value of the first 4 hex digits of `text`, or null if there aren't 4 or one of them
/// isn't a hex digit.
pub fn hex4(text: []const u8) ?u16 {
    if (text.len < 4) return null;

    var value: u16 = 0;
    // Each digit moves the value up one hex place. `charToDigit` rejects anything that isn't a
    // hex digit, which makes the whole result null.
    for (text[0..4]) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch return null;
        value = value * 16 + digit;
    }
    return value;
}

/// Decodes the character at `raw[pos.*]`, an escape or a plain byte, into `buf` and advances
/// `pos` past it. Lone surrogates decode to U+FFFD. Malformed escapes (only possible in input
/// that wasn't validated) decode to the escaped byte.
pub fn nextUnit(raw: []const u8, pos: *usize, buf: *[4]u8) []const u8 {
    const c = raw[pos.*];

    // A plain byte, or a backslash with nothing after it.
    if (c != '\\' or pos.* + 1 == raw.len) {
        pos.* += 1;
        buf[0] = c;
        return buf[0..1];
    }

    const escape_char = raw[pos.* + 1];
    pos.* += 2;
    buf[0] = switch (escape_char) {
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => {
            const unit = hex4(raw[pos.*..]) orelse {
                buf[0] = 'u';
                return buf[0..1];
            };
            pos.* += 4;

            // A high surrogate followed by an escaped low surrogate is one code point.
            var code_point: u21 = unit;
            if (unit >= 0xd800 and unit <= 0xdbff and pos.* + 6 <= raw.len and
                raw[pos.*] == '\\' and raw[pos.* + 1] == 'u')
            {
                if (hex4(raw[pos.* + 2 ..])) |low| {
                    if (low >= 0xdc00 and low <= 0xdfff) {
                        code_point = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                        pos.* += 6;
                    }
                }
            }

            // utf8Encode refuses lone surrogates.
            const len = std.unicode.utf8Encode(code_point, buf) catch {
                buf[0..3].* = "\u{fffd}".*;
                return buf[0..3];
            };
            return buf[0..len];
        },
        // `\"`, `\\`, `\/`, and malformed escapes: the escaped byte itself.
        else => escape_char,
    };
    return buf[0..1];
}

/// Appends the decoded contents of a JSON string to `out`.
pub fn decodeInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    var pos: usize = 0;
    var buf: [4]u8 = undefined;
    while (pos < raw.len) {
        // Copy the plain bytes up to the next backslash in one go, then decode the escape.
        const run_end = std.mem.findScalarPos(u8, raw, pos, '\\') orelse raw.len;
        try out.appendSlice(gpa, raw[pos..run_end]);
        pos = run_end;

        if (pos < raw.len) try out.appendSlice(gpa, nextUnit(raw, &pos, &buf));
    }
}

/// Whether the raw contents of a JSON string decode to `target`.
pub fn decodedEql(raw: []const u8, target: []const u8) bool {
    var pos: usize = 0;
    var target_pos: usize = 0;
    var buf: [4]u8 = undefined;

    // Decode one character at a time and compare it in place, so nothing is allocated.
    while (pos < raw.len) {
        const unit = nextUnit(raw, &pos, &buf);
        if (!std.mem.startsWith(u8, target[target_pos..], unit)) return false;
        target_pos += unit.len;
    }
    return target_pos == target.len;
}

const testing = std.testing;

const ReferenceParser = @import("json_reference.zig").ReferenceParser;

test {
    _ = utf8;
}

fn expectValid(line: []const u8, valid: bool) !void {
    const trie: PathTrie = .{ .nodes = &.{.{ .seg = "", .children = &.{}, .slot = null, .slot_lo = 0, .slot_hi = 0 }}, .slot_count = 0 };
    const parser = try testing.allocator.create(Parser);
    defer testing.allocator.destroy(parser);
    parser.* = .{ .trie = &trie, .slots = &.{} };

    const got = if (parser.parse(line)) true else |_| false;
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
    }) |line| try expectValid(line, true);
    for ([_][]const u8{
        "",        "{",         "{\"a\"}",           "{\"a\":}", "{\"a\":1,}",       "[1,]",  "01",
        "1.",      ".5",        "1e",                "+1",       "tru",              "nul",   "\"a",
        "\"\\x\"", "\"\\u12\"", "\"\x01\"",          "\"\xc3\"", "\"\xed\xa0\x80\"", "{} {}", "{'a':1}",
        "[1 2]",   "{\"a\" 1}", "{\"a\":1 \"b\":2}", "]",        "{]",               "[}",    "\"\xff\"",
    }) |line| try expectValid(line, false);
}

test "path slots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paths = [_][]const []const u8{ &.{"a"}, &.{ "a", "b" }, &.{"c"}, &.{ "x", "y", "z" }, &.{"a"} };
    var slots: [paths.len]u32 = undefined;
    const trie = try PathTrie.init(a, &paths, &slots);
    try testing.expectEqual(slots[0], slots[4]);
    const parser = try a.create(Parser);
    parser.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };

    try parser.parse("{\"a\": {\"b\": [1]}, \"c\":\"s\", \"x\":{\"y\":{\"z\":null}}}");
    try testing.expectEqualStrings("{\"b\": [1]}", parser.slots[slots[0]].?);
    try testing.expectEqualStrings("[1]", parser.slots[slots[1]].?);
    try testing.expectEqualStrings("\"s\"", parser.slots[slots[2]].?);
    try testing.expectEqualStrings("null", parser.slots[slots[3]].?);

    // The last duplicate wins, and clears what the earlier one found below it.
    try parser.parse("{\"a\":{\"b\":1},\"a\":2,\"n\":{\"c\":1}}");
    try testing.expectEqualStrings("2", parser.slots[slots[0]].?);
    try testing.expectEqual(@as(?[]const u8, null), parser.slots[slots[1]]);
    try testing.expectEqual(@as(?[]const u8, null), parser.slots[slots[2]]);

    // Keys are compared decoded.
    try parser.parse("{\"\\u0061\":{\"\\u0062\":3}}");
    try testing.expectEqualStrings("3", parser.slots[slots[1]].?);
}

test "decoding" {
    var out: std.ArrayList(u8) = .empty;
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
fn fuzzValue(out: *std.ArrayList(u8), a: std.mem.Allocator, rand: std.Random, depth: u32) !void {
    const spaces = [_][]const u8{ "", "", "", " ", "\t", "\r\n", "  " };
    const keys = [_][]const u8{ "a", "b", "c", "\\u0061", "\u{e9}", "\\u00e9", "a\\\\", "" };
    // The last few of each are invalid, and picked less often.
    const pieces = [_][]const u8{ "x", "yz", "\\\"", "\\\\", "\\\\\\\\", "\\u00e9", "\\ud83d\\ude00", "\u{e9}", "\u{65e5}\u{672c}", "\u{1f600}", "\\n", "\\/", " ", "{", "}", ",", ":", "[", "]", "\\", "\x01", "\xc3", "\\u12" };
    const scalars = [_][]const u8{ "0", "-1", "12345678901234567890", "2.5", "-0.0e+10", "1E3", "true", "false", "null", "01", "1.", "-", "tru", "nul" };
    const pick = struct {
        fn f(random: std.Random, pool: []const []const u8, invalid: usize) []const u8 {
            return pool[random.uintLessThan(usize, if (random.uintLessThan(u32, 40) == 0) pool.len else pool.len - invalid)];
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
    const parser = try a.create(Parser);
    parser.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };
    const ref = try a.create(ReferenceParser);
    ref.* = .{ .trie = &trie, .slots = try a.alloc(?[]const u8, trie.slot_count) };

    var prng = std.Random.DefaultPrng.init(0x51d);
    const rand = prng.random();
    const noise = [_]u8{ '"', '\\', '{', '}', '[', ']', ',', ':', ' ', '\t', '\n', 0x01, 0x7f, 0x80, 0xbf, 0xc3, 0xe9, 0xf0, 'u', '0', 'a', 't', '-', '.', 'e' };
    var line: std.ArrayList(u8) = .empty;
    var valid: usize = 0;
    for (0..30_000) |_| {
        line.clearRetainingCapacity();
        try line.appendSlice(a, ([_][]const u8{ "", " ", "\t" })[rand.uintLessThan(usize, 3)]);
        try fuzzValue(&line, a, rand, 0);

        // Byte edits put every kind of byte at every offset relative to the chunks.
        for (0..rand.uintLessThan(u32, 4) -| 1) |_| {
            if (line.items.len == 0) break;
            const i = rand.uintLessThan(usize, line.items.len);
            const byte = noise[rand.uintLessThan(usize, noise.len)];
            switch (rand.uintLessThan(u32, 4)) {
                0 => line.items[i] = byte,
                1 => try line.insert(a, i, byte),
                2 => _ = line.orderedRemove(i),
                else => line.items.len = i,
            }
        }

        const want = if (ref.parse(line.items)) true else |_| false;
        const got = if (parser.parse(line.items)) true else |_| false;
        var same = want == got;
        if (same and want) {
            valid += 1;
            for (ref.slots, parser.slots) |want_slot, got_slot| {
                if ((want_slot == null) != (got_slot == null) or
                    (want_slot != null and !std.mem.eql(u8, want_slot.?, got_slot.?)))
                {
                    same = false;
                }
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
