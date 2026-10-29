//! The byte-level search: finds quoted keys and values in raw JSONL without parsing it.
const std = @import("std");
const json = @import("json.zig");
const simd = @import("simd.zig");

const VECTOR_LEN = simd.VECTOR_LEN;
const V = simd.V;
const BoolV = simd.BoolV;
const Mask = simd.Mask;
const QUOTE_VEC = simd.QUOTE_VEC;
const NL_VEC = simd.NL_VEC;
const BACKSLASH_VEC = simd.BACKSLASH_VEC;
const U_VEC = simd.U_VEC;
const SLASH_VEC = simd.SLASH_VEC;
const FALSE_VEC = simd.FALSE_VEC;
const has_shuffle = simd.has_shuffle;
const load = simd.load;
const vand = simd.vand;
const vor = simd.vor;
const lookup16 = simd.lookup16;

pub const Hit = struct { key_pos: usize, val_pos: usize };

/// Finds keys: a quoted key followed by ':'. Requiring the colon means a value that
/// happens to equal the key is not mistaken for it. Candidates are filtered with SIMD on
/// four bytes (both quotes plus the first and last key byte) before a full compare.
pub const KeyFinder = struct {
    key: []const u8,
    first: V,
    last: V,

    pub fn init(key_quoted: []const u8) KeyFinder {
        return .{
            .key = key_quoted,
            .first = @splat(key_quoted[1]),
            .last = @splat(key_quoted[key_quoted.len - 2]),
        };
    }

    /// Candidate mask without the opening-quote test, given the bytes after it (`c1`).
    inline fn rest(self: *const KeyFinder, c1: V, hay: []const u8, i: usize) BoolV {
        const k = self.key.len;
        return vand(vand(c1 == self.first, load(hay, i + k - 2) == self.last), load(hay, i + k - 1) == QUOTE_VEC);
    }

    inline fn candidates(self: *const KeyFinder, hay: []const u8, i: usize) Mask {
        const k = self.key.len;
        const m = vand(
            vand(load(hay, i) == QUOTE_VEC, load(hay, i + 1) == self.first),
            vand(load(hay, i + k - 2) == self.last, load(hay, i + k - 1) == QUOTE_VEC),
        );
        // Candidates are rare; on NEON an any-test is one instruction, a bitmask several.
        if (!@reduce(.Or, m)) return 0;
        return @bitCast(m);
    }

    pub fn next(self: *const KeyFinder, hay: []const u8, start: usize) ?Hit {
        const k = self.key.len;
        var i = start;
        if (start + k - 1 + VECTOR_LEN <= hay.len) {
            const last_chunk = hay.len - (k - 1) - VECTOR_LEN;
            while (true) {
                var bits = self.candidates(hay, i);
                while (bits != 0) : (bits &= bits - 1) {
                    const pos = i + @ctz(bits);
                    if (self.verify(hay, pos)) |val_pos| return .{ .key_pos = pos, .val_pos = val_pos };
                }
                if (i == last_chunk) return null;
                i += VECTOR_LEN;
                if (i > last_chunk) {
                    // Finish with one chunk aligned to the end, skipping positions already checked.
                    var tail = self.candidates(hay, last_chunk) >> @intCast(i - last_chunk);
                    while (tail != 0) : (tail &= tail - 1) {
                        const pos = i + @ctz(tail);
                        if (self.verify(hay, pos)) |val_pos| return .{ .key_pos = pos, .val_pos = val_pos };
                    }
                    return null;
                }
            }
        }
        // Haystack shorter than one chunk. Not std.mem.findPos: it builds a 2KB Boyer-Moore
        // table per call for haystacks of 52+ bytes.
        while (std.mem.findScalarPos(u8, hay, i, '"')) |pos| {
            if (pos + k > hay.len) break;
            if (self.verify(hay, pos)) |val_pos| return .{ .key_pos = pos, .val_pos = val_pos };
            i = pos + 1;
        }
        return null;
    }

    /// Returns the start of the value if the key at `pos` is a real key.
    inline fn verify(self: *const KeyFinder, hay: []const u8, pos: usize) ?usize {
        const k = self.key.len;
        if (!std.mem.eql(u8, hay[pos..][0..k], self.key)) return null;
        // An opening quote preceded by an odd number of backslashes is escaped text inside a string.
        var b = pos;
        while (b > 0 and hay[b - 1] == '\\') b -= 1;
        if ((pos - b) % 2 == 1) return null;
        var j = pos + k;
        while (j < hay.len and isSpace(hay[j])) j += 1;
        if (j == hay.len or hay[j] != ':') return null;
        j += 1;
        while (j < hay.len and isSpace(hay[j])) j += 1;
        return j;
    }
};

/// JSON whitespace, minus the newline that ends a line.
inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Escapes that can hide a needle from the byte search. The search compares escaped text,
/// and every character has exactly one escaped form as zog writes it, except that any
/// character may also be written `\uXXXX` and '/' may be written `\/`. Such an escape only
/// matters if it stands for a character some needle contains. A line with one of those is
/// never ruled out by the byte search.
pub const Hazards = struct {
    ascii: std.StaticBitSet(128) = .initEmpty(),
    non_ascii: bool = false,

    pub fn add(self: *Hazards, text: []const u8) void {
        for (text) |c| {
            if (c < 0x80) self.ascii.set(c) else self.non_ascii = true;
        }
    }

    /// Whether the backslash at `pos` starts an escape for a needle character. Backslash
    /// parity isn't checked, so an escaped backslash can be reported too, which only costs
    /// a parse.
    fn at(self: *const Hazards, hay: []const u8, pos: usize) bool {
        if (pos + 1 >= hay.len) return false;
        switch (hay[pos + 1]) {
            '/' => return self.ascii.isSet('/'),
            'u' => {
                const esc = hay[pos..@min(pos + 12, hay.len)];
                var i: usize = 0;
                var buf: [4]u8 = undefined;
                const unit = json.nextUnit(esc, &i, &buf);
                if (i == 2) return false; // not followed by 4 hex digits
                return if (unit.len == 1 and unit[0] < 0x80) self.ascii.isSet(unit[0]) else self.non_ascii;
            },
            else => return false,
        }
    }

    pub fn inLine(self: *const Hazards, line: []const u8) bool {
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, line, i, '\\')) |pos| {
            if (self.at(line, pos)) return true;
            i = pos + 2;
        }
        return false;
    }
};

/// A quoted string to search for: a key, or the string value of the key `value_of`.
pub const Needle = struct { finder: KeyFinder, value_of: ?[]const u8 = null };

/// Hyperscan's Teddy: needles are spread over 8 buckets, and for each of the bytes after
/// the opening quote, two nibble tables give the buckets that allow that byte there. ANDing
/// the lookups over all positions leaves, per haystack position, the buckets whose needles
/// may start there. The cost per chunk is fixed, however many needles there are.
const Teddy = struct {
    lo: [teddy_bytes]V,
    hi: [teddy_bytes]V,

    /// Fingerprinted bytes after the opening quote.
    const teddy_bytes = 3;
    const LOW_NIBBLE: V = @splat(0x0f);

    fn init(finders: []const KeyFinder) Teddy {
        var lo = [_][16]u8{[_]u8{0} ** 16} ** teddy_bytes;
        var hi = lo;
        for (finders, 0..) |f, ki| {
            const bit = bucketBit(ki);
            for (0..teddy_bytes) |j| {
                if (j + 1 < f.key.len) {
                    const c = f.key[j + 1];
                    lo[j][c & 0x0f] |= bit;
                    hi[j][c >> 4] |= bit;
                } else {
                    // The needle is shorter: any byte is allowed here.
                    for (&lo[j], &hi[j]) |*l, *h| {
                        l.* |= bit;
                        h.* |= bit;
                    }
                }
            }
        }
        var self: Teddy = undefined;
        for (0..teddy_bytes) |j| {
            var l: [VECTOR_LEN]u8 = undefined;
            var h: [VECTOR_LEN]u8 = undefined;
            for (&l, &h, 0..) |*lb, *hb, b| {
                lb.* = lo[j][b % 16];
                hb.* = hi[j][b % 16];
            }
            self.lo[j] = l;
            self.hi[j] = h;
        }
        return self;
    }

    fn bucketBit(ki: usize) u8 {
        return @as(u8, 1) << @intCast(ki % 8);
    }

    /// Per position, the buckets with a needle that may start there. Reads two chunks.
    inline fn buckets(self: *const Teddy, hay: []const u8, i: usize) V {
        // The shifted views are built from two loads: given loads at i+1, i+2 and i+3, LLVM
        // merged them into byte-by-byte inserts and the scan ran ~50% slower.
        const c0 = load(hay, i);
        const c1 = load(hay, i + VECTOR_LEN);
        var m: V = @splat(0xff);
        inline for (0..teddy_bytes) |j| {
            const c = @shuffle(u8, c0, c1, shiftMask(j + 1));
            m &= lookup16(self.lo[j], c & LOW_NIBBLE) & lookup16(self.hi[j], c >> @splat(4));
        }
        return @select(u8, c0 == QUOTE_VEC, m, @as(V, @splat(0)));
    }

    /// Shuffle mask selecting bytes `n..n + VECTOR_LEN` of two concatenated chunks.
    fn shiftMask(n: usize) @Vector(VECTOR_LEN, i32) {
        var mask: [VECTOR_LEN]i32 = undefined;
        for (&mask, 0..) |*e, b| e.* = if (b + n < VECTOR_LEN) @intCast(b + n) else ~@as(i32, @intCast(b + n - VECTOR_LEN));
        return mask;
    }
};

/// Searches for several distinct needles in one pass, so an OR of N keys costs one scan of
/// the block rather than N. The quote and first-byte vectors are shared by all needles.
pub const MultiFinder = struct {
    finders: []const KeyFinder,
    value_of: []const ?[]const u8,
    max_len: usize,
    /// Set when there are enough needles that a fixed-cost Teddy scan beats testing each.
    teddy: ?Teddy,
    /// Escapes reported by `nextOrHazard`.
    hazards: Hazards = .{},

    /// `pos` is where the needle was found: the key, or for a value needle the value.
    /// For a hazard, `key` is `hazard_key` and all positions are the backslash's.
    const MultiHit = struct { hit: Hit, key: usize, pos: usize };
    pub const hazard_key = std.math.maxInt(usize);

    /// How candidates are found: comparing against each needle's bytes, with the needle
    /// count known at compile time (so the key vectors stay in registers) or looped over at
    /// runtime, or with Teddy.
    const Mode = union(enum) { unrolled: usize, looped, teddy };

    /// Measured on GH Archive: below this, testing each needle is faster than Teddy.
    const teddy_min_needles = 4;

    pub fn init(allocator: std.mem.Allocator, needles: []const Needle) !MultiFinder {
        const finders = try allocator.alloc(KeyFinder, needles.len);
        const value_of = try allocator.alloc(?[]const u8, needles.len);
        var max_len: usize = 0;
        for (needles, finders, value_of) |n, *f, *v| {
            f.* = n.finder;
            v.* = n.value_of;
            max_len = @max(max_len, n.finder.key.len);
        }
        const use_teddy = has_shuffle and needles.len >= teddy_min_needles;
        return .{
            .finders = finders,
            .value_of = value_of,
            .max_len = max_len,
            .teddy = if (use_teddy) .init(finders) else null,
        };
    }

    /// Bytes past a chunk's start that `mask` reads, beyond the chunk itself.
    inline fn reach(self: *const MultiFinder, comptime mode: Mode) usize {
        return if (mode == .teddy) VECTOR_LEN else self.max_len - 1;
    }

    /// Per position, the buckets of needles that may start there (any nonzero value when
    /// buckets aren't tracked). With `hz`, also `\u` and `\/` positions, as 0xff.
    inline fn mask(self: *const MultiFinder, comptime mode: Mode, comptime hz: bool, hay: []const u8, i: usize) V {
        const c1 = load(hay, i + 1);
        const hazard = if (hz) vand(load(hay, i) == BACKSLASH_VEC, vor(c1 == U_VEC, c1 == SLASH_VEC)) else FALSE_VEC;
        if (mode == .teddy) {
            const b = self.teddy.?.buckets(hay, i);
            return if (hz) @select(u8, hazard, @as(V, @splat(0xff)), b) else b;
        }
        var m = FALSE_VEC;
        switch (mode) {
            .unrolled => |count| inline for (self.finders[0..count]) |*f| {
                m = vor(m, f.rest(c1, hay, i));
            },
            .looped => for (self.finders) |*f| {
                m = vor(m, f.rest(c1, hay, i));
            },
            .teddy => unreachable,
        }
        return @select(u8, vor(vand(m, load(hay, i) == QUOTE_VEC), hazard), @as(V, @splat(0xff)), @as(V, @splat(0)));
    }

    inline fn anyCandidate(m: V) bool {
        return @reduce(.Or, m != @as(V, @splat(0)));
    }

    const Candidates = struct { bits: Mask, buckets: [VECTOR_LEN]u8 };

    inline fn candidates(self: *const MultiFinder, comptime mode: Mode, comptime hz: bool, hay: []const u8, i: usize) Candidates {
        const m = self.mask(mode, hz, hay, i);
        if (!anyCandidate(m)) return .{ .bits = 0, .buckets = undefined };
        return .{ .bits = @bitCast(m != @as(V, @splat(0))), .buckets = m };
    }

    /// Checks the needles at `pos`, only those in `buckets` when Teddy found the candidate.
    inline fn verify(self: *const MultiFinder, comptime mode: Mode, comptime hz: bool, hay: []const u8, pos: usize, buckets: u8) ?MultiHit {
        if (hz and hay[pos] == '\\') {
            if (!self.hazards.at(hay, pos)) return null;
            return .{ .hit = .{ .key_pos = pos, .val_pos = pos }, .key = hazard_key, .pos = pos };
        }
        for (self.finders, self.value_of, 0..) |*f, value_of, ki| {
            if (mode == .teddy and Teddy.bucketBit(ki) & buckets == 0) continue;
            if (pos + f.key.len > hay.len) continue;
            if (value_of) |key| {
                if (!std.mem.eql(u8, hay[pos..][0..f.key.len], f.key)) continue;
                const key_pos = keyBefore(hay, pos, key) orelse continue;
                return .{ .hit = .{ .key_pos = key_pos, .val_pos = pos }, .key = ki, .pos = pos };
            }
            if (f.verify(hay, pos)) |val_pos| return .{ .hit = .{ .key_pos = pos, .val_pos = val_pos }, .key = ki, .pos = pos };
        }
        return null;
    }

    pub fn next(self: *const MultiFinder, hay: []const u8, start: usize) ?MultiHit {
        return self.find(false, hay, start);
    }

    /// Like `next`, but also stops at escapes in `hazards`.
    pub fn nextOrHazard(self: *const MultiFinder, hay: []const u8, start: usize) ?MultiHit {
        return self.find(true, hay, start);
    }

    fn find(self: *const MultiFinder, comptime hz: bool, hay: []const u8, start: usize) ?MultiHit {
        if (has_shuffle and self.teddy != null) return self.nextN(.teddy, hz, hay, start);
        return switch (self.finders.len) {
            1 => if (hz or self.value_of[0] != null)
                self.nextN(.{ .unrolled = 1 }, hz, hay, start)
            else if (self.finders[0].next(hay, start)) |hit|
                .{ .hit = hit, .key = 0, .pos = hit.key_pos }
            else
                null,
            inline 2...8 => |n| self.nextN(.{ .unrolled = n }, hz, hay, start),
            else => self.nextN(.looped, hz, hay, start),
        };
    }

    /// Verifies the candidates of the chunk at `base`, from position `base + skip` on.
    inline fn verifyChunk(self: *const MultiFinder, comptime mode: Mode, comptime hz: bool, hay: []const u8, base: usize, skip: usize) ?MultiHit {
        const c = self.candidates(mode, hz, hay, base);
        var bits = c.bits >> @intCast(skip);
        while (bits != 0) : (bits &= bits - 1) {
            const off = skip + @ctz(bits);
            if (self.verify(mode, hz, hay, base + off, c.buckets[off])) |mh| return mh;
        }
        return null;
    }

    fn nextN(self: *const MultiFinder, comptime mode: Mode, comptime hz: bool, hay: []const u8, start: usize) ?MultiHit {
        const r = self.reach(mode);
        var i = start;
        if (start + r + VECTOR_LEN <= hay.len) {
            const last_chunk = hay.len - r - VECTOR_LEN;
            const end = last_chunk + VECTOR_LEN;
            while (true) {
                // Skip two chunks per branch while there are no candidates.
                while (i + VECTOR_LEN <= last_chunk) : (i += 2 * VECTOR_LEN) {
                    if (anyCandidate(self.mask(mode, hz, hay, i) | self.mask(mode, hz, hay, i + VECTOR_LEN))) break;
                }
                // Verify the two chunks the skip stopped at, then go back to skipping rather
                // than going chunk by chunk until a real hit. Past `last_chunk`, the chunk
                // aligned to the end is used, minus the positions already seen.
                const stop = @min(i + 2 * VECTOR_LEN, end);
                while (i < stop) : (i += VECTOR_LEN) {
                    const base = @min(i, last_chunk);
                    if (self.verifyChunk(mode, hz, hay, base, i - base)) |mh| return mh;
                }
                if (i >= end) break;
            }
            // Needles can still start in the last `r` bytes.
            i = end;
        }
        while (if (hz) std.mem.findAnyPos(u8, hay, i, "\"\\") else std.mem.findScalarPos(u8, hay, i, '"')) |pos| {
            if (self.verify(.looped, hz, hay, pos, 0xff)) |mh| return mh;
            i = pos + 1;
        }
        return null;
    }
};

/// If the string value at `pos` belongs to `key` (`"key": "value"`), returns the key's position.
fn keyBefore(hay: []const u8, pos: usize, key: []const u8) ?usize {
    var j = pos;
    while (j > 0 and isSpace(hay[j - 1])) j -= 1;
    if (j == 0 or hay[j - 1] != ':') return null;
    j -= 1;
    while (j > 0 and isSpace(hay[j - 1])) j -= 1;
    if (j < key.len or !std.mem.eql(u8, hay[j - key.len .. j], key)) return null;
    const key_pos = j - key.len;
    var b = key_pos;
    while (b > 0 and hay[b - 1] == '\\') b -= 1;
    if ((key_pos - b) % 2 == 1) return null;
    return key_pos;
}

/// Index of the first '\n' at or after `start`, or `data.len`. Kept out of line so the
/// loop is register-only: inlined into the per-line scan, LLVM spilled the index to the stack.
pub noinline fn findNewline(data: []const u8, start: usize) usize {
    var i = start;
    while (i + VECTOR_LEN <= data.len) : (i += VECTOR_LEN) {
        const m = load(data, i) == NL_VEC;
        if (@reduce(.Or, m)) return i + @ctz(@as(Mask, @bitCast(m)));
    }
    while (i < data.len and data[i] != '\n') i += 1;
    return i;
}

/// Index of the last '\n' in data[lo..hi].
pub fn lastNewline(data: []const u8, lo: usize, hi: usize) ?usize {
    var i = hi;
    while (i >= lo + VECTOR_LEN) {
        i -= VECTOR_LEN;
        const m = load(data, i) == NL_VEC;
        if (@reduce(.Or, m)) {
            const bits: Mask = @bitCast(m);
            return i + (VECTOR_LEN - 1 - @clz(bits));
        }
    }
    while (i > lo) {
        i -= 1;
        if (data[i] == '\n') return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Teddy finds the same needles as testing each" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x7edd7);
    const rand = prng.random();
    // A small alphabet makes prefix collisions, shared buckets and near misses common.
    const alphabet = "abAB\\\":, \xe9";
    for (0..300) |round| {
        const count = 4 + round % 14;
        const needles = try a.alloc(Needle, count);
        for (needles) |*n| {
            const len = 1 + rand.uintLessThan(usize, 5);
            const key = try a.alloc(u8, len + 2);
            key[0] = '"';
            key[len + 1] = '"';
            for (key[1 .. len + 1]) |*c| c.* = "abAB\xe9"[rand.uintLessThan(usize, 5)];
            n.* = .{ .finder = .init(key), .value_of = if (rand.boolean()) "\"k\"" else null };
        }
        const teddy: MultiFinder = try .init(a, needles);
        if (teddy.teddy == null) return error.SkipZigTest;
        var plain = teddy;
        plain.teddy = null;

        const hay = try a.alloc(u8, rand.uintLessThan(usize, 400));
        for (hay) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        // Plant needles, half of them as `"k": value`, so there are real hits.
        for (0..hay.len / 20) |_| {
            const n = needles[rand.uintLessThan(usize, count)];
            const text = if (n.value_of != null) try std.mem.concat(a, u8, &.{ "\"k\": ", n.finder.key }) else try std.mem.concat(a, u8, &.{ n.finder.key, ":" });
            if (text.len > hay.len) continue;
            @memcpy(hay[rand.uintLessThan(usize, hay.len - text.len + 1)..][0..text.len], text);
        }

        var pos: usize = 0;
        while (true) {
            const want = plain.next(hay, pos);
            const got = teddy.next(hay, pos);
            try testing.expectEqualDeep(want, got);
            pos = (want orelse break).pos + 1;
        }
    }
}

test "KeyFinder finds keys at every offset" {
    var line: [200]u8 = undefined;
    const finder = KeyFinder.init("\"key\"");
    for (0..150) |off| {
        @memset(&line, ' ');
        @memcpy(line[off..][0..7], "\"key\":1");
        const hit = finder.next(&line, 0) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(off, hit.key_pos);
        try testing.expectEqual(off + 6, hit.val_pos);
    }
    const one = KeyFinder.init("\"k\"");
    try testing.expectEqual(@as(?usize, 5), if (one.next("{\"k\":1}", 0)) |h| h.val_pos else null);
}

test "lastNewline" {
    const s = "ab\ncdefghijklmnopqrstuvwxyz0123456789\nxyz";
    try testing.expectEqual(@as(?usize, 37), lastNewline(s, 0, s.len));
    try testing.expectEqual(@as(?usize, 2), lastNewline(s, 0, 37));
    try testing.expectEqual(@as(?usize, null), lastNewline(s, 3, 37));
}
