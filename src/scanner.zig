const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const json = @import("json.zig");

const BLOCK_SIZE = 8 * 1024 * 1024;
/// Pipe input is handed over in small blocks: the consumer then scans data the reader just
/// copied while it is still in L2. Measured ~20% faster than full blocks for `cat | zog`.
const STREAM_BLOCK_SIZE = 128 * 1024;
const VECTOR_LEN = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(VECTOR_LEN, u8);
const BoolV = @Vector(VECTOR_LEN, bool);
const Mask = std.meta.Int(.unsigned, VECTOR_LEN);
const QUOTE_VEC: V = @splat('"');
const NL_VEC: V = @splat('\n');
const BACKSLASH_VEC: V = @splat('\\');
const U_VEC: V = @splat('u');
const SLASH_VEC: V = @splat('/');
const FALSE_VEC: BoolV = @splat(false);
const TRUE_VEC: BoolV = @splat(true);

const TypeForced = enum { none, string, numeric };

/// A query value, in the forms the comparisons need.
const Literal = struct {
    /// JSON-escaped and quoted, to compare with a string's raw text.
    quoted: []const u8,
    /// As typed: compared with decoded strings, literals and the text of numbers.
    text: []const u8,
    num: ?f64,
    int: ?i64,
};

const CompiledCondition = struct {
    /// Finds the last key of the path, at any depth.
    finder: KeyFinder,
    /// Slot of the key path in the exact parser.
    slot: u32,
    val: Literal,
    op: main.Operator,
    type_forced: TypeForced,
    negated: bool,
    in_vals: []const Literal,
};

const CompiledGroup = struct { conditions: []CompiledCondition };

const CompiledPluck = struct {
    finder: KeyFinder,
    slot: u32,
    ptype: main.PluckType,
    original_str: []const u8,
    /// Index of an earlier pluck with the same key, whose extracted value can be reused.
    same_as: ?usize,
};

const CompiledPlan = struct {
    groups: []CompiledGroup,
    /// One condition per group that a matching line must pass, so whole blocks can be
    /// searched for anchor keys instead of evaluating every line. Empty when some group
    /// has no usable anchor.
    anchors: []const *const CompiledCondition,
    /// The distinct anchor keys, searched for together in one pass.
    anchor_finder: MultiFinder,
    /// Index into `anchor_finder.finders` of each anchor's key.
    anchor_keys: []const usize,
    pluck: []CompiledPluck,
    has_aggregations: bool,
    /// Lines the byte-level search can't rule out are validated and evaluated by parsing.
    /// Off with --fast, which evaluates on the bytes alone.
    exact: bool,
    /// Exact mode only: parse every line instead of prefiltering. For testing the prefilter.
    prefilter: bool,
    trie: json.PathTrie,
    hazards: Hazards,
    format: main.OutputFormat,
    limit: ?usize,
    count_only: bool,
    header: bool,
};

const AggState = union(enum) {
    raw: void,
    count: usize,
    sum: f64,
    min: f64,
    max: f64,
    avg: struct { sum: f64, count: usize },
};

const Value = struct {
    /// String contents without the surrounding quotes (still JSON-escaped), or the literal,
    /// object or array text.
    raw: []const u8,
    is_string: bool,
};

const Hit = struct { key_pos: usize, val_pos: usize };

inline fn load(data: []const u8, i: usize) V {
    return data[i..][0..VECTOR_LEN].*;
}

inline fn vand(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, b, FALSE_VEC);
}

inline fn vor(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, TRUE_VEC, b);
}

/// Finds keys: a quoted key followed by ':'. Requiring the colon means a value that
/// happens to equal the key is not mistaken for it. Candidates are filtered with SIMD on
/// four bytes (both quotes plus the first and last key byte) before a full compare.
const KeyFinder = struct {
    key: []const u8,
    first: V,
    last: V,

    fn init(key_quoted: []const u8) KeyFinder {
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

    fn next(self: *const KeyFinder, hay: []const u8, start: usize) ?Hit {
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
const Hazards = struct {
    ascii: std.StaticBitSet(128) = .initEmpty(),
    non_ascii: bool = false,

    fn add(self: *Hazards, text: []const u8) void {
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

    fn inLine(self: *const Hazards, line: []const u8) bool {
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, line, i, '\\')) |pos| {
            if (self.at(line, pos)) return true;
            i = pos + 2;
        }
        return false;
    }
};

/// A quoted string to search for: a key, or the string value of the key `value_of`.
const Needle = struct { finder: KeyFinder, value_of: ?[]const u8 = null };

/// Whether the target has a 16-entry byte table lookup (NEON tbl, x86 pshufb) at the
/// native vector width, which Teddy needs. It is called as an LLVM intrinsic, which Zig's
/// own backends (the default for x86_64 debug builds) don't provide.
const has_shuffle = builtin.zig_backend == .stage2_llvm and switch (builtin.cpu.arch) {
    .aarch64 => VECTOR_LEN == 16,
    .x86_64 => switch (VECTOR_LEN) {
        16 => builtin.cpu.has(.x86, .ssse3),
        32 => builtin.cpu.has(.x86, .avx2),
        64 => builtin.cpu.has(.x86, .avx512bw),
        else => false,
    },
    else => false,
};

extern fn @"llvm.aarch64.neon.tbl1"(V, V) V;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(V, V) V;
extern fn @"llvm.x86.avx2.pshuf.b"(V, V) V;
extern fn @"llvm.x86.avx512.pshuf.b.512"(V, V) V;

/// `table[idx]` per byte, for indices below 16. On x86 the table repeats per 128-bit lane.
inline fn lookup16(table: V, idx: V) V {
    if (builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(table, idx);
    return switch (VECTOR_LEN) {
        16 => @"llvm.x86.ssse3.pshuf.b.128"(table, idx),
        32 => @"llvm.x86.avx2.pshuf.b"(table, idx),
        64 => @"llvm.x86.avx512.pshuf.b.512"(table, idx),
        else => unreachable,
    };
}

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
const MultiFinder = struct {
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
    const hazard_key = std.math.maxInt(usize);

    /// How candidates are found: comparing against each needle's bytes, with the needle
    /// count known at compile time (so the key vectors stay in registers) or looped over at
    /// runtime, or with Teddy.
    const Mode = union(enum) { unrolled: usize, looped, teddy };

    /// Measured on GH Archive: below this, testing each needle is faster than Teddy.
    const teddy_min_needles = 4;

    fn init(allocator: std.mem.Allocator, needles: []const Needle) !MultiFinder {
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

    fn next(self: *const MultiFinder, hay: []const u8, start: usize) ?MultiHit {
        return self.find(false, hay, start);
    }

    /// Like `next`, but also stops at escapes in `hazards`.
    fn nextOrHazard(self: *const MultiFinder, hay: []const u8, start: usize) ?MultiHit {
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
noinline fn findNewline(data: []const u8, start: usize) usize {
    var i = start;
    while (i + VECTOR_LEN <= data.len) : (i += VECTOR_LEN) {
        const m = load(data, i) == NL_VEC;
        if (@reduce(.Or, m)) return i + @ctz(@as(Mask, @bitCast(m)));
    }
    while (i < data.len and data[i] != '\n') i += 1;
    return i;
}

/// Index of the last '\n' in data[lo..hi].
fn lastNewline(data: []const u8, lo: usize, hi: usize) ?usize {
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

const TermMask = blk: {
    var mask = [_]bool{false} ** 256;
    for (",}] \t\r\n") |c| mask[c] = true;
    break :blk mask;
};

inline fn isPrimitiveTerminator(c: u8) bool {
    return TermMask[c];
}

/// Parses a JSON integer. Up to 18 digits can't overflow, so they take an unchecked fast
/// path; longer inputs use a checked parse and return null when out of range.
inline fn parseFastInt(s: []const u8) ?i64 {
    const neg = s.len > 0 and s[0] == '-';
    const digits = if (neg) s[1..] else s;
    if (digits.len == 0) return null;
    if (digits.len > 18) {
        for (digits) |c| if (c < '0' or c > '9') return null;
        return std.fmt.parseInt(i64, s, 10) catch null;
    }
    var res: i64 = 0;
    for (digits) |c| {
        const digit = c -% '0';
        if (digit > 9) return null;
        res = res * 10 + @as(i64, digit);
    }
    return if (neg) -res else res;
}

/// Parses a JSON number. Rejects forms that std.fmt.parseFloat accepts but JSON doesn't
/// (inf, nan, hex), so strings like "nan" or "Infinity" aren't treated as numbers.
fn parseNumber(s: []const u8) ?f64 {
    if (parseFastInt(s)) |n| return @floatFromInt(n);
    const start: usize = if (s.len > 0 and s[0] == '-') 1 else 0;
    if (start >= s.len or s[start] < '0' or s[start] > '9') return null;
    for (s) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    return std.fmt.parseFloat(f64, s) catch null;
}

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
}

fn jsonEscapeAlloc(allocator: std.mem.Allocator, s: []const u8, quoted: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    if (quoted) try out.writer.writeByte('"');
    try writeJsonEscaped(&out.writer, s);
    if (quoted) try out.writer.writeByte('"');
    return out.toOwnedSlice();
}

/// Splits a key into the path of object keys it names: `a.b` is key `b` inside `a`. `\.`
/// is a literal dot and `\\` a backslash.
fn splitPath(allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var seg: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < key.len) : (i += 1) {
        const c = key[i];
        if (c == '\\' and i + 1 < key.len and (key[i + 1] == '.' or key[i + 1] == '\\')) {
            i += 1;
            try seg.append(allocator, key[i]);
        } else if (c == '.') {
            if (seg.items.len == 0) return error.InvalidKey;
            try segs.append(allocator, try seg.toOwnedSlice(allocator));
        } else try seg.append(allocator, c);
    }
    if (seg.items.len == 0) return error.InvalidKey;
    try segs.append(allocator, try seg.toOwnedSlice(allocator));
    return segs.toOwnedSlice(allocator);
}

fn compileLiteral(allocator: std.mem.Allocator, text: []const u8) !Literal {
    return .{
        .quoted = try jsonEscapeAlloc(allocator, text, true),
        .text = try allocator.dupe(u8, text),
        .num = parseNumber(text),
        .int = parseFastInt(text),
    };
}

fn compilePlan(allocator: std.mem.Allocator, config: main.Config) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, config.groups.len);
    // Every condition's path, then every pluck's, for the exact parser.
    var paths: std.ArrayListUnmanaged([]const []const u8) = .empty;
    var hazards: Hazards = .{};

    for (config.groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            var actual_val = c.val;
            var type_forced: TypeForced = .none;
            if (std.mem.startsWith(u8, actual_val, "s:")) {
                actual_val = actual_val[2..];
                type_forced = .string;
            } else if (std.mem.startsWith(u8, actual_val, "n:") or std.mem.startsWith(u8, actual_val, "b:")) {
                actual_val = actual_val[2..];
                type_forced = .numeric;
            }

            var in_vals: std.ArrayListUnmanaged(Literal) = .empty;
            if (c.op == .in_op) {
                var it = std.mem.splitScalar(u8, actual_val, ',');
                while (it.next()) |v| {
                    if (v.len > 0) try in_vals.append(allocator, try compileLiteral(allocator, v));
                }
            }

            const val = try compileLiteral(allocator, actual_val);
            switch (c.op) {
                .gt, .lt, .gte, .lte => if (val.num == null) return error.NonNumericComparison,
                else => {},
            }

            const path = try splitPath(allocator, c.key);
            try paths.append(allocator, path);
            // The prefilter searches for the keys of positive conditions.
            if (!c.negated) hazards.add(path[path.len - 1]);
            comp_conds[j] = .{
                .finder = .init(try jsonEscapeAlloc(allocator, path[path.len - 1], true)),
                .slot = undefined,
                .val = val,
                .op = c.op,
                .type_forced = type_forced,
                .negated = c.negated,
                .in_vals = try in_vals.toOwnedSlice(allocator),
            };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }

    // A match satisfies some group, and every operator requires its key to be present, so
    // a line can only match if one group's non-negated condition passes on it. A group of
    // only negated conditions can match any line, which rules out anchoring.
    var anchors = try allocator.alloc(*const CompiledCondition, comp_groups.len);
    for (comp_groups, 0..) |*g, gi| {
        var best: ?*const CompiledCondition = null;
        for (g.conditions) |*c| {
            if (!c.negated and (best == null or anchorScore(c) > anchorScore(best.?))) best = c;
        }
        anchors[gi] = best orelse {
            anchors = &.{};
            break;
        };
    }
    var needles = std.array_list.Managed(Needle).init(allocator);
    const anchor_keys = try allocator.alloc(usize, anchors.len);
    for (anchors, anchor_keys) |a, *ki| {
        const needle: Needle = if (searchesValue(a)) blk: {
            hazards.add(a.val.text);
            break :blk .{ .finder = .init(a.val.quoted), .value_of = a.finder.key };
        } else .{ .finder = a.finder };
        ki.* = for (needles.items, 0..) |n, j| {
            if (std.mem.eql(u8, n.finder.key, needle.finder.key) and
                std.mem.eql(u8, n.value_of orelse "", needle.value_of orelse "") and
                (n.value_of == null) == (needle.value_of == null)) break j;
        } else blk: {
            try needles.append(needle);
            break :blk needles.items.len - 1;
        };
    }

    var pks = try allocator.alloc(CompiledPluck, config.pluck.len);
    var has_aggs = false;
    for (config.pluck, 0..) |p, i| {
        const path = try splitPath(allocator, p.key);
        try paths.append(allocator, path);
        const key_quoted = try jsonEscapeAlloc(allocator, path[path.len - 1], true);
        var same_as: ?usize = null;
        for (pks[0..i], 0..) |prev, j| {
            if (std.mem.eql(u8, prev.finder.key, key_quoted)) {
                same_as = j;
                break;
            }
        }
        pks[i] = .{
            .finder = .init(key_quoted),
            .slot = undefined,
            .ptype = p.ptype,
            .original_str = p.original_str,
            .same_as = same_as,
        };
        if (p.ptype != .raw) has_aggs = true;
    }

    const path_slots = try allocator.alloc(u32, paths.items.len);
    const trie = try json.PathTrie.init(allocator, paths.items, path_slots);
    var next_path: usize = 0;
    for (comp_groups) |g| {
        for (g.conditions) |*c| {
            c.slot = path_slots[next_path];
            next_path += 1;
        }
    }
    for (pks) |*p| {
        p.slot = path_slots[next_path];
        next_path += 1;
    }

    var anchor_finder: MultiFinder = try .init(allocator, needles.items);
    anchor_finder.hazards = hazards;
    return CompiledPlan{
        .groups = comp_groups,
        .anchors = anchors,
        .anchor_finder = anchor_finder,
        .anchor_keys = anchor_keys,
        .pluck = pks,
        .has_aggregations = has_aggs,
        .exact = !config.fast,
        .prefilter = config.prefilter,
        .trie = trie,
        .hazards = hazards,
        .format = config.format,
        .limit = config.limit,
        .count_only = config.count_only,
        .header = config.header,
    };
}

/// Whether an anchor is found by searching for its value rather than its key. A string
/// `eq` value is usually far rarer than its key (`"GollumEvent"` vs `"type"`). Values that
/// could also match a number or literal are excluded.
fn searchesValue(c: *const CompiledCondition) bool {
    if (c.op != .eq or c.type_forced == .numeric or c.val.quoted.len < 3) return false;
    if (c.type_forced == .string) return true;
    const v = c.val.text;
    return c.val.num == null and !std.mem.eql(u8, v, "true") and
        !std.mem.eql(u8, v, "false") and !std.mem.eql(u8, v, "null");
}

/// Prefers value anchors, then the longest needle: it yields the fewest SIMD candidates.
fn anchorScore(c: *const CompiledCondition) usize {
    return if (searchesValue(c)) 1000 + c.val.quoted.len else c.finder.key.len;
}

inline fn primitiveEquals(vs: []const u8, literal: []const u8) bool {
    if (!std.mem.startsWith(u8, vs, literal)) return false;
    return literal.len == vs.len or isPrimitiveTerminator(vs[literal.len]);
}

inline fn compare(comptime T: type, a: T, b: T, op: main.Operator) bool {
    return switch (op) {
        .gt => a > b,
        .lt => a < b,
        .gte => a >= b,
        .lte => a <= b,
        else => unreachable,
    };
}

/// Holds decoded strings, reused across values.
const Scratch = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn decode(self: *Scratch, raw: []const u8) ![]const u8 {
        self.buf.clearRetainingCapacity();
        try json.decodeInto(&self.buf, self.gpa, raw);
        return self.buf.items;
    }
};

const StrContents = struct { raw: []const u8, escaped: bool };

/// The raw contents of the string whose opening quote is at `vs[0]`. Stops at a newline.
fn stringContents(vs: []const u8) StrContents {
    var i: usize = 1;
    var escaped = false;
    while (true) {
        i = findStringSpecial(vs, i);
        if (i >= vs.len or vs[i] != '\\') return .{ .raw = vs[1..i], .escaped = escaped };
        escaped = true;
        i = @min(i + 2, vs.len);
    }
}

fn stringText(s: StrContents, sc: *Scratch) ![]const u8 {
    return if (s.escaped) sc.decode(s.raw) else s.raw;
}

/// The text of the number or literal at the start of `vs`.
fn primitiveToken(vs: []const u8) []const u8 {
    var i: usize = 0;
    while (i < vs.len and !isPrimitiveTerminator(vs[i])) i += 1;
    return vs[0..i];
}

fn numEquals(text: []const u8, lit: *const Literal) bool {
    if (lit.int) |target| {
        if (parseFastInt(text)) |n| return n == target;
    }
    const target = lit.num orelse return false;
    return (parseNumber(text) orelse return false) == target;
}

/// `eq`: a string equals the query text, a literal has the same text, and when the query is
/// a number, numbers and numeric strings equal it by value.
fn eqMatch(vs: []const u8, tf: TypeForced, lit: *const Literal, sc: *Scratch) !bool {
    if (vs[0] == '"') {
        if (tf == .numeric) return false;
        if (std.mem.startsWith(u8, vs, lit.quoted)) return true;
        const s = stringContents(vs);
        const numeric = tf == .none and lit.num != null;
        if (!s.escaped and !numeric) return false;
        const text = try stringText(s, sc);
        if (s.escaped and std.mem.eql(u8, text, lit.text)) return true;
        return numeric and numEquals(text, lit);
    }
    if (tf == .string or vs[0] == '{' or vs[0] == '[') return false;
    return primitiveEquals(vs, lit.text) or numEquals(primitiveToken(vs), lit);
}

/// Whether the value starting at `vs` satisfies `cond`; `vs` may run on past the value.
/// This one test serves both layers: the byte-level search applies it to every occurrence
/// of the key, the exact layer to the value at the key's path. That value is one of the
/// occurrences, so a line the exact layer accepts is never ruled out by the search.
fn valueMatches(vs: []const u8, cond: *const CompiledCondition, sc: *Scratch) !bool {
    if (vs.len == 0) return false;
    const is_string = vs[0] == '"';
    const is_container = vs[0] == '{' or vs[0] == '[';
    const type_ok = switch (cond.type_forced) {
        .none => true,
        .string => is_string,
        .numeric => !is_string,
    };
    switch (cond.op) {
        .exists => return true,
        .eq => return eqMatch(vs, cond.type_forced, &cond.val, sc),
        .neq => return !try eqMatch(vs, cond.type_forced, &cond.val, sc),
        .in_op => {
            for (cond.in_vals) |*v| {
                if (try eqMatch(vs, cond.type_forced, v, sc)) return true;
            }
            return false;
        },
        .has => {
            if (!type_ok or is_container) return false;
            const text = if (is_string) try stringText(stringContents(vs), sc) else primitiveToken(vs);
            return contains(text, cond.val.text);
        },
        .gt, .lt, .gte, .lte => {
            if (!type_ok or is_container) return false;
            const text = if (is_string) try stringText(stringContents(vs), sc) else primitiveToken(vs);
            if (cond.val.int) |target| {
                if (parseFastInt(text)) |n| return compare(i64, n, target, cond.op);
            }
            const n = parseNumber(text) orelse return false;
            return compare(f64, n, cond.val.num.?, cond.op);
        },
    }
}

/// Next occurrence of the condition's key at or after `start` whose value satisfies it.
fn nextPassing(cond: *const CompiledCondition, data: []const u8, start: usize, sc: *Scratch) !?Hit {
    var pos = start;
    while (cond.finder.next(data, pos)) |hit| {
        if (cond.op == .exists or try valueMatches(data[hit.val_pos..], cond, sc)) return hit;
        pos = hit.key_pos + 1;
    }
    return null;
}

fn lineMatches(line: []const u8, cond: *const CompiledCondition, sc: *Scratch) !bool {
    return try nextPassing(cond, line, 0, sc) != null;
}

/// --fast: evaluates the plan on the bytes of the line, without parsing it.
fn evaluatePlan(line: []const u8, plan: *const CompiledPlan, sc: *Scratch) !bool {
    if (plan.groups.len == 0) return true;
    if (line.len < 2) return false;

    for (plan.groups) |*group| {
        for (group.conditions) |*cond| {
            if (try lineMatches(line, cond, sc) == cond.negated) break;
        } else return true;
    }
    return false;
}

/// Index of the first '"', '\\' or '\n' at or after `start`, or `s.len` if there is none.
fn findStringSpecial(s: []const u8, start: usize) usize {
    const bs: V = @splat('\\');
    var i = start;
    while (i + VECTOR_LEN <= s.len) : (i += VECTOR_LEN) {
        const c = load(s, i);
        const m = vor(vor(c == QUOTE_VEC, c == bs), c == NL_VEC);
        if (@reduce(.Or, m)) return i + @ctz(@as(Mask, @bitCast(m)));
    }
    while (i < s.len and s[i] != '"' and s[i] != '\\' and s[i] != '\n') i += 1;
    return i;
}

/// Substring search for the short needles of `has`. Not std.mem.find: it builds a 2KB
/// Boyer-Moore table per call for haystacks of 52+ bytes.
fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, hay, i, needle[0])) |pos| {
        if (pos + needle.len > hay.len) return false;
        if (std.mem.eql(u8, hay[pos..][0..needle.len], needle)) return true;
        i = pos + 1;
    }
    return false;
}

/// Extracts the value starting at `vs`. Strings honour escapes, objects and arrays are
/// bracket-matched; nothing extends past a newline.
fn extractValue(vs: []const u8) ?Value {
    if (vs.len == 0) return null;
    switch (vs[0]) {
        '"' => {
            var i: usize = 1;
            while (true) {
                i = findStringSpecial(vs, i);
                if (i >= vs.len or vs[i] == '\n') return .{ .raw = vs[1..@min(i, vs.len)], .is_string = true };
                if (vs[i] == '"') return .{ .raw = vs[1..i], .is_string = true };
                i += 2; // backslash: skip the escaped character
            }
        },
        '{', '[' => {
            var depth: usize = 0;
            var in_str = false;
            var i: usize = 0;
            while (i < vs.len) : (i += 1) {
                const c = vs[i];
                if (c == '\n') break;
                if (in_str) {
                    if (c == '\\') i += 1 else if (c == '"') in_str = false;
                    continue;
                }
                switch (c) {
                    '"' => in_str = true,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return .{ .raw = vs[0 .. i + 1], .is_string = false };
                    },
                    else => {},
                }
            }
            return .{ .raw = vs[0..@min(i, vs.len)], .is_string = false };
        },
        else => {
            var i: usize = 0;
            while (i < vs.len and !isPrimitiveTerminator(vs[i])) : (i += 1) {}
            if (i == 0) return null;
            return .{ .raw = vs[0..i], .is_string = false };
        },
    }
}

fn extractField(line: []const u8, finder: *const KeyFinder) ?Value {
    const hit = finder.next(line, 0) orelse return null;
    return extractValue(line[hit.val_pos..]);
}

fn writeCsvByte(w: *std.Io.Writer, c: u8) !void {
    if (c == '"') try w.writeAll("\"\"") else try w.writeByte(c);
}

fn parseHex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    return std.fmt.parseInt(u16, s[0..4], 16) catch null;
}

/// Writes the contents of a JSON string with escapes decoded, doubling quotes for CSV.
fn writeCsvUnescaped(w: *std.Io.Writer, raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '\\' or i + 1 == raw.len) {
            try writeCsvByte(w, c);
            i += 1;
            continue;
        }
        const e = raw[i + 1];
        i += 2;
        switch (e) {
            'n' => try w.writeByte('\n'),
            't' => try w.writeByte('\t'),
            'r' => try w.writeByte('\r'),
            'b' => try w.writeByte(0x08),
            'f' => try w.writeByte(0x0c),
            'u' => {
                const unit = parseHex4(raw[i..]) orelse {
                    try w.writeAll("\\u");
                    continue;
                };
                i += 4;
                var cp: u21 = unit;
                if (unit >= 0xd800 and unit <= 0xdbff and i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                    if (parseHex4(raw[i + 2 ..])) |low| {
                        if (low >= 0xdc00 and low <= 0xdfff) {
                            cp = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                            i += 6;
                        }
                    }
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8) catch {
                    try w.writeAll("\u{fffd}");
                    continue;
                };
                try w.writeAll(utf8[0..n]);
            },
            else => try writeCsvByte(w, e),
        }
    }
}

fn writeCsvField(w: *std.Io.Writer, v: Value) !void {
    try w.writeByte('"');
    if (v.is_string) {
        try writeCsvUnescaped(w, v.raw);
    } else {
        for (v.raw) |c| try writeCsvByte(w, c);
    }
    try w.writeByte('"');
}

fn writeJsonKey(w: *std.Io.Writer, name: []const u8) !void {
    try w.writeByte('"');
    try writeJsonEscaped(w, name);
    try w.writeAll("\": ");
}

fn printFormatted(results: []const ?Value, plucks: []const CompiledPluck, format: main.OutputFormat, writer: *std.Io.Writer) !void {
    switch (format) {
        .json => {
            try writer.writeByte('{');
            for (results, plucks, 0..) |res, pk, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeJsonKey(writer, pk.original_str);
                if (res) |v| {
                    if (v.is_string) {
                        try writer.writeByte('"');
                        try writer.writeAll(v.raw);
                        try writer.writeByte('"');
                    } else {
                        try writer.writeAll(v.raw);
                    }
                } else {
                    try writer.writeAll("null");
                }
            }
            try writer.writeAll("}\n");
        },
        .csv => {
            for (results, 0..) |res, i| {
                if (i > 0) try writer.writeByte(',');
                if (res) |v| try writeCsvField(writer, v);
            }
            try writer.writeByte('\n');
        },
        .tsv => {
            for (results, 0..) |res, i| {
                if (i > 0) try writer.writeByte('\t');
                if (res) |v| try writer.writeAll(v.raw);
            }
            try writer.writeByte('\n');
        },
    }
}

inline fn formatAggValue(state: AggState, comptime with_nulls: bool, writer: *std.Io.Writer) !void {
    switch (state) {
        .raw => if (with_nulls) try writer.writeAll("null"),
        .count => |c| try writer.print("{d}", .{c}),
        .sum => |s| try writer.print("{d:.4}", .{s}),
        .min => |m| if (m == std.math.inf(f64)) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{m}),
        .max => |m| if (m == -std.math.inf(f64)) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{m}),
        .avg => |a| if (a.count == 0) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{a.sum / @as(f64, @floatFromInt(a.count))}),
    }
}

fn printAggregations(agg_states: []const AggState, plucks: []const CompiledPluck, format: main.OutputFormat, writer: *std.Io.Writer) !void {
    if (format == .json) {
        try writer.writeAll("{");
        for (agg_states, 0..) |state, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeJsonKey(writer, plucks[i].original_str);
            try formatAggValue(state, true, writer);
        }
        try writer.writeAll("}\n");
    } else {
        const sep: u8 = if (format == .csv) ',' else '\t';
        for (agg_states, 0..) |state, i| {
            try formatAggValue(state, false, writer);
            if (i < agg_states.len - 1) try writer.writeByte(sep);
        }
        try writer.writeByte('\n');
    }
}

fn printHeader(plan: *const CompiledPlan, writer: *std.Io.Writer) !void {
    // JSON output carries field names in every object, so a header line would only corrupt it.
    if (!plan.header or plan.pluck.len == 0 or plan.count_only or plan.format == .json) return;
    for (plan.pluck, 0..) |p, idx| {
        if (plan.format == .csv) {
            if (idx > 0) try writer.writeByte(',');
            if (std.mem.findAny(u8, p.original_str, ",\"\n") != null) {
                try writeCsvField(writer, .{ .raw = p.original_str, .is_string = false });
            } else {
                try writer.writeAll(p.original_str);
            }
        } else {
            if (idx > 0) try writer.writeByte('\t');
            try writer.writeAll(p.original_str);
        }
    }
    try writer.writeByte('\n');
}

fn accumulate(state: *AggState, v: Value, sc: *Scratch) !void {
    if (!v.is_string and std.mem.eql(u8, v.raw, "null")) return;
    switch (state.*) {
        .raw => {},
        .count => |*c| c.* += 1,
        .sum, .min, .max, .avg => {
            const text = if (v.is_string) try stringText(.{ .raw = v.raw, .escaped = std.mem.findScalar(u8, v.raw, '\\') != null }, sc) else v.raw;
            const f = parseNumber(text) orelse return;
            switch (state.*) {
                .sum => |*s| s.* += f,
                .min => |*m| m.* = @min(m.*, f),
                .max => |*m| m.* = @max(m.*, f),
                .avg => |*a| {
                    a.sum += f;
                    a.count += 1;
                },
                .raw, .count => unreachable,
            }
        },
    }
}

/// The value in an exact-parser slot, in the form `extractValue` gives.
fn slotValue(raw: ?[]const u8) ?Value {
    const r = raw orelse return null;
    if (r[0] == '"') return .{ .raw = r[1 .. r.len - 1], .is_string = true };
    return .{ .raw = r, .is_string = false };
}

const Search = struct {
    plan: *const CompiledPlan,
    agg_states: []AggState,
    writer: *std.Io.Writer,
    /// Per anchor: whether it passed at the key occurrence being evaluated.
    passed: []bool,
    scratch: Scratch,
    /// The exact layer. After a successful `exactLineMatches`, its slots hold the line's values.
    parser: *json.Parser,
    match_count: usize = 0,

    /// Records a matching line. Returns true once the match limit is reached.
    fn emit(self: *Search, line_raw: []const u8) !bool {
        self.match_count += 1;
        const reached = if (self.plan.limit) |limit| self.match_count >= limit else false;
        const plan = self.plan;
        if (plan.count_only) return reached;
        const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r') line_raw[0 .. line_raw.len - 1] else line_raw;
        if (plan.pluck.len == 0) {
            try self.writer.writeAll(line);
            try self.writer.writeByte('\n');
            return reached;
        }

        var results: [main.MAX_PLUCK_FIELDS]?Value = undefined;
        for (plan.pluck, 0..) |*pk, i| {
            results[i] = if (plan.exact)
                slotValue(self.parser.slots[pk.slot])
            else if (pk.same_as) |j| results[j] else extractField(line, &pk.finder);
        }

        if (plan.has_aggregations) {
            for (results[0..plan.pluck.len], self.agg_states) |res, *state| {
                if (res) |v| try accumulate(state, v, &self.scratch);
            }
        } else {
            try printFormatted(results[0..plan.pluck.len], plan.pluck, plan.format, self.writer);
        }
        return reached;
    }

    /// Processes a block of lines. Every block ends with a newline except possibly the last.
    /// Returns true once the match limit is reached.
    fn scanBlock(self: *Search, data: []const u8) !bool {
        const plan = self.plan;
        if (plan.exact) {
            if (plan.anchors.len > 0 and plan.prefilter) return self.scanAnchored(true, data);
            return self.scanLines(true, data);
        }
        if (plan.anchors.len > 0) return self.scanAnchored(false, data);
        return self.scanLines(false, data);
    }

    /// Searches the whole block for each group's anchor and only looks at lines where one
    /// passes, so other lines are never split out or evaluated. The anchor streams are
    /// merged by position to keep matches in input order.
    ///
    /// In exact mode the search also stops at escapes that could hide an anchor, and sends
    /// those lines to the parser. Lines with a passing anchor go through a byte-level check
    /// of the other conditions first, which only rules a line out when it provably can't
    /// match.
    fn scanAnchored(self: *Search, comptime exact: bool, data: []const u8) !bool {
        const plan = self.plan;
        var sol: usize = 0; // start of the first line not yet evaluated
        var pos: usize = 0;
        while (if (exact) plan.anchor_finder.nextOrHazard(data, pos) else plan.anchor_finder.next(data, pos)) |mh| {
            const hazard = exact and mh.key == MultiFinder.hazard_key;
            var any = hazard;
            if (!hazard) {
                for (plan.anchors, plan.anchor_keys, self.passed) |a, ki, *p| {
                    p.* = ki == mh.key and (a.op == .exists or try valueMatches(data[mh.hit.val_pos..], a, &self.scratch));
                    any = any or p.*;
                }
            }
            if (!any) {
                pos = mh.pos + 1;
                continue;
            }
            const ls = if (lastNewline(data, sol, mh.hit.key_pos)) |nl| nl + 1 else sol;
            const le = std.mem.findScalarPos(u8, data, mh.hit.key_pos, '\n') orelse data.len;
            const line = data[ls..le];
            const matches = if (exact)
                (hazard or plan.hazards.inLine(line) or try self.anchoredLineMatches(true, line, mh.hit.key_pos - ls)) and
                    try self.exactLineMatches(line)
            else
                try self.anchoredLineMatches(false, line, mh.hit.key_pos - ls);
            if (matches) {
                if (try self.emit(line)) return true;
            }
            sol = @min(le + 1, data.len);
            pos = sol;
        }
        return false;
    }

    /// Evaluates a line whose first passing anchor occurrence has its key at `off`. Groups
    /// whose anchor passed there only need their other conditions checked. Every anchor
    /// failed at all earlier occurrences, so the others only need the rest of the line searched.
    ///
    /// With `prefilter`, negated conditions are skipped: the bytes can show that a key is
    /// absent, not that the value at its path fails. The line must then be free of hazards.
    fn anchoredLineMatches(self: *Search, comptime prefilter: bool, line: []const u8, off: usize) !bool {
        const plan = self.plan;
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, p| {
            if (p and try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, p| {
            if (p) continue;
            if (try nextPassing(anchor, line, off, &self.scratch) == null) continue;
            if (try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        return false;
    }

    fn otherConditionsMatch(self: *Search, comptime prefilter: bool, line: []const u8, group: *const CompiledGroup, anchor: *const CompiledCondition) !bool {
        for (group.conditions) |*cond| {
            if (cond == anchor or (prefilter and cond.negated)) continue;
            if (try lineMatches(line, cond, &self.scratch) == cond.negated) return false;
        }
        return true;
    }

    /// Parses the line and evaluates the plan on the values at the query's paths. Invalid
    /// lines never match.
    fn exactLineMatches(self: *Search, line: []const u8) !bool {
        self.parser.parse(line) catch return false;
        const slots = self.parser.slots;
        if (self.plan.groups.len == 0) return true;
        for (self.plan.groups) |*group| {
            for (group.conditions) |*cond| {
                const pass = if (slots[cond.slot]) |vs| try valueMatches(vs, cond, &self.scratch) else false;
                if (pass == cond.negated) break;
            } else return true;
        }
        return false;
    }

    fn scanLines(self: *Search, comptime exact: bool, data: []const u8) !bool {
        var sol: usize = 0;
        while (sol < data.len) {
            const nl = findNewline(data, sol);
            const line = data[sol..nl];
            const matches = if (exact) try self.exactLineMatches(line) else try evaluatePlan(line, self.plan, &self.scratch);
            if (matches) {
                if (try self.emit(line)) return true;
            }
            sol = nl + 1;
        }
        return false;
    }
};

const Buffer = struct { data: []u8, len: usize = 0, eof: bool = false };

const ReaderCtx = struct {
    file: std.Io.File,
    io: std.Io,
    /// Input is a pipe or terminal: hand data over as soon as nothing more is immediately
    /// readable instead of waiting for a full block.
    streaming: bool,
    bufs: [2]Buffer,
    stop: std.atomic.Value(bool) = .init(false),
    read_err: ?anyerror = null,
    fill_sem: std.Io.Semaphore = .{ .permits = 0 },
    read_sem: std.Io.Semaphore = .{ .permits = 2 },
};

fn dataReady(file: std.Io.File) bool {
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&fds, 0) catch return false) > 0;
}

/// Reads into `buf` until it is full, or for streaming input until a small block is
/// gathered or nothing more is immediately readable (so `tail -f` matches show up right
/// away). Always reads at least once. Returns true at end of input or on a read error.
fn fillBuffer(ctx: *ReaderCtx, buf: *Buffer, total: *usize) bool {
    while (total.* < buf.data.len) {
        const n = ctx.file.readStreaming(ctx.io, &.{buf.data[total.*..]}) catch |err| {
            if (err != error.EndOfStream) ctx.read_err = err;
            return true;
        };
        if (n == 0) return true;
        total.* += n;
        if (ctx.streaming and (total.* >= STREAM_BLOCK_SIZE or !dataReady(ctx.file))) return false;
    }
    return false;
}

fn growBuffer(buf: *Buffer, new_len: usize) !void {
    buf.data = try std.heap.page_allocator.realloc(buf.data, new_len);
}

fn readerThread(ctx: *ReaderCtx) void {
    const io = ctx.io;
    var idx: usize = 0;
    // Partial last line of the previously filled buffer. It sits past that buffer's `len`,
    // which the consumer never reads, so it can be copied straight into the next buffer.
    var carry: []const u8 = &.{};

    while (true) {
        ctx.read_sem.wait(io) catch return;
        if (ctx.stop.load(.acquire)) return;
        const buf = &ctx.bufs[idx];

        if (carry.len + BLOCK_SIZE / 2 > buf.data.len) {
            growBuffer(buf, carry.len + BLOCK_SIZE) catch |err| {
                ctx.read_err = err;
                buf.len = 0;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            };
        }
        @memcpy(buf.data[0..carry.len], carry);
        var total = carry.len;
        var scanned = carry.len; // the carried bytes contain no newline

        while (true) {
            if (fillBuffer(ctx, buf, &total)) {
                buf.len = total;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            }
            if (lastNewline(buf.data, scanned, total)) |nl| {
                buf.len = nl + 1;
                carry = buf.data[nl + 1 .. total];
                break;
            }
            // No complete line yet: keep reading, growing the buffer if a line outgrew it.
            scanned = total;
            if (total == buf.data.len) {
                growBuffer(buf, buf.data.len * 2) catch |err| {
                    ctx.read_err = err;
                    buf.len = total;
                    buf.eof = true;
                    ctx.fill_sem.post(io);
                    return;
                };
            }
        }
        ctx.fill_sem.post(io);
        idx = 1 - idx;
    }
}

/// Returns true when all input was consumed, false when the match limit stopped it early.
fn consume(search: *Search, ctx: *ReaderCtx, io: std.Io) !bool {
    var idx: usize = 0;
    while (true) {
        try ctx.fill_sem.wait(io);
        const buf = &ctx.bufs[idx];
        const limit_reached = try search.scanBlock(buf.data[0..buf.len]);
        // Flush per block so streaming input (`tail -f`) produces output as it arrives.
        try search.writer.flush();
        if (limit_reached) return false;
        if (buf.eof) {
            if (ctx.read_err) |err| return err;
            return true;
        }
        ctx.read_sem.post(io);
        idx = 1 - idx;
    }
}

fn runSearch(search: *Search, file: std.Io.File, io: std.Io) !void {
    // When we stop early the reader may be blocked in a read that never returns (e.g. on
    // `tail -f`), so it is detached rather than joined. Its context and buffers must then
    // outlive this function, so they come from page_allocator and are freed only after a join.
    const pa = std.heap.page_allocator;
    const ctx = try pa.create(ReaderCtx);
    ctx.* = .{
        .file = file,
        .io = io,
        .streaming = if (file.stat(io)) |st| st.kind != .file else |_| true,
        .bufs = .{ .{ .data = try pa.alloc(u8, BLOCK_SIZE) }, .{ .data = try pa.alloc(u8, BLOCK_SIZE) } },
    };
    const thread = try std.Thread.spawn(.{}, readerThread, .{ctx});

    const finished = consume(search, ctx, io) catch |err| {
        abandonReader(ctx, thread, io);
        return err;
    };
    if (!finished) return abandonReader(ctx, thread, io);

    thread.join();
    pa.free(ctx.bufs[0].data);
    pa.free(ctx.bufs[1].data);
    pa.destroy(ctx);
}

fn abandonReader(ctx: *ReaderCtx, thread: std.Thread, io: std.Io) void {
    ctx.stop.store(true, .release);
    ctx.read_sem.post(io);
    thread.detach();
}

pub fn searchFile(allocator: std.mem.Allocator, config: main.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    const file = try std.Io.Dir.cwd().openFile(io, config.file_path.?, .{});
    defer file.close(io);
    return try searchFileInternal(allocator, file, config, writer, io);
}

pub fn searchStream(allocator: std.mem.Allocator, config: main.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    return try searchFileInternal(allocator, std.Io.File.stdin(), config, writer, io);
}

fn searchFileInternal(allocator: std.mem.Allocator, file: std.Io.File, config: main.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compilePlan(arena.allocator(), config);

    var agg_states = try arena.allocator().alloc(AggState, plan.pluck.len);
    for (plan.pluck, 0..) |p, i| {
        agg_states[i] = switch (p.ptype) {
            .raw => .raw,
            .count => .{ .count = 0 },
            .sum => .{ .sum = 0.0 },
            .min => .{ .min = std.math.inf(f64) },
            .max => .{ .max = -std.math.inf(f64) },
            .avg => .{ .avg = .{ .sum = 0.0, .count = 0 } },
        };
    }

    try printHeader(&plan, writer);

    const parser = try arena.allocator().create(json.Parser);
    parser.* = .{ .trie = &plan.trie, .slots = try arena.allocator().alloc(?[]const u8, plan.trie.slot_count) };
    var search: Search = .{
        .plan = &plan,
        .agg_states = agg_states,
        .writer = writer,
        .passed = try arena.allocator().alloc(bool, plan.anchors.len),
        .scratch = .{ .gpa = arena.allocator() },
        .parser = parser,
    };
    const limit_zero = if (plan.limit) |limit| limit == 0 else false;
    if (!limit_zero) try runSearch(&search, file, io);

    if (plan.count_only) {
        try writer.print("{d}\n", .{search.match_count});
    } else if (plan.has_aggregations) {
        try printAggregations(agg_states, plan.pluck, plan.format, writer);
    }
    return search.match_count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = json;
}

/// Runs a query on `input`, returning its output (allocated in `a`).
fn runTestQuery(a: std.mem.Allocator, input: []const u8, config: main.Config) ![]const u8 {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = input });
    const file = try tmp.dir.openFile(io, "in.jsonl", .{});
    defer file.close(io);

    var out: std.Io.Writer.Allocating = .init(a);
    _ = try searchFileInternal(a, file, config, &out.writer, io);
    return out.written();
}

fn expectQuery(input: []const u8, args: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try main.parseArgs(a, args)).run;
    try testing.expectEqualStrings(expected, try runTestQuery(a, input, config));
    if (!config.fast) {
        // The prefilter never changes the result.
        var unfiltered = config;
        unfiltered.prefilter = false;
        try testing.expectEqualStrings(expected, try runTestQuery(a, input, unfiltered));
    }
}

const demo =
    \\{"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
    \\{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
    \\{"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
    \\{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
    \\{"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
    \\
;

test "README examples" {
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30", "AND", "tier", "gt", "2" }, "Charlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "tier", "eq", "5" }, "Alice\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "NOT", "age", "eq", "30" }, "Alice\nDave\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "age", "eq", "30", "AND", "balance", "lt", "0" }, "Alice\nBob\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "name", "has", "li" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "in", "1,3,5" }, "Alice\nCharlie\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "Bob\t2\nCharlie\t3\nEve\t5\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "s:100" }, "Eve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "n:100" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "active", "eq", "b:true" }, "Alice\nCharlie\nDave\n");
    try expectQuery(demo, &.{ "--count", "tier", "gte", "2" }, "4\n");
    try expectQuery(demo, &.{ "SELECT", "min:age,max:age", "WHERE", "active", "eq", "true" }, "25.0000\t45.0000\n");
    try expectQuery(demo, &.{ "--format", "json", "SELECT", "count:name,sum:balance", "WHERE", "tier", "gte", "2" }, "{\"count:name\": 4, \"sum:balance\": 5049.7400}\n");
    try expectQuery(demo, &.{ "--limit", "2", "SELECT", "name", "WHERE", "active", "eq", "true" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "--header", "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "name\ttier\nBob\t2\nCharlie\t3\nEve\t5\n");
}

test "json output keeps string values quoted" {
    try expectQuery(
        "{\"name\":\"nancy\",\"id\":\"42\",\"n\":7,\"t\":true,\"o\":{\"a\":[1, 2]}}\n",
        &.{ "--format", "json", "SELECT", "name,id,n,t,o,missing" },
        "{\"name\": \"nancy\", \"id\": \"42\", \"n\": 7, \"t\": true, \"o\": {\"a\":[1, 2]}, \"missing\": null}\n",
    );
}

test "json output skips header and escapes keys" {
    try expectQuery("{\"a\":1}\n", &.{ "--header", "--format", "json", "SELECT", "a" }, "{\"a\": 1}\n");
}

test "keys are only matched in key position" {
    // A value equal to the key name is not the key.
    try expectQuery("{\"msg\":\"error\"}\n", &.{ "--count", "error", "exists" }, "0\n");
    try expectQuery("{\"tag\":\"level\",\"level\":\"debug\"}\n", &.{ "--count", "level", "neq", "debug" }, "0\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name" }, "Bob\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name,a" }, "Bob\tname\n");
    // Escaped quotes inside a string don't start a key.
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\",\"k\":2}\n", &.{ "SELECT", "k" }, "2\n");
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\"}\n", &.{ "--count", "k", "exists" }, "0\n");
    // Whitespace around the colon is fine.
    try expectQuery("{\"k\" :  5}\n", &.{ "SELECT", "k", "WHERE", "k", "eq", "5" }, "5\n");
}

test "string eq is found by its value" {
    const lines =
        \\{"type": "Push", "n": 1}
        \\{"other":"Push","type":"Fork"}
        \\{"type":["Push"]}
        \\{"m":"\"type\":\"Push\"","type":"x"}
        \\{"Push":"type"}
        \\{"a":{"type" : "Push"}}
        \\
    ;
    try expectQuery(lines, &.{ "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "2\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "AND", "n", "eq", "1" }, "1\n");
    try expectQuery(lines, &.{ "--count", "a.type", "eq", "Push" }, "1\n");
    // --fast also finds the nested key.
    try expectQuery(lines, &.{ "--fast", "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n\n");
    try expectQuery(lines, &.{ "--fast", "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "3\n");
    try expectQuery("{\"type\"\t:\t\"Push\"}\n", &.{ "--count", "type", "eq", "Push" }, "1\n");
    // A value that could be a bare literal is still matched as one.
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "12" }, "2\n");
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "true", "OR", "v", "eq", "12" }, "3\n");
}

test "OR over several distinct keys" {
    const keys = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff" };
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(testing.allocator);
    var expected3: usize = 0;
    var expected5: usize = 0;
    for (0..3000) |i| {
        // Varying padding puts the needles at every offset relative to the SIMD chunks.
        try lines.print(testing.allocator, "{{\"pad\":\"{s}\",\"{s}\":\"v{d}\"}}\n", .{ ("x" ** 40)[0 .. i % 37], keys[i % 6], i % 4 });
        const k = i % 6;
        if (k == 0 or k == 1 or (k == 2 and i % 4 == 1)) expected3 += 1;
        if (k < 4 or (k == 4 and i % 4 == 2)) expected5 += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(lines.items, &.{ "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "eq", "v1" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected3}));
    // Five needles take the Teddy path where the target supports it.
    try expectQuery(lines.items, &.{
        "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "exists", "OR", "dddd", "exists", "OR", "eeeee", "eq", "v2",
    }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected5}));
}

test "multi-field select survives escaped quotes in arrays" {
    try expectQuery("{\"arr\":[\"a\\\"b\",\"c\"],\"x\":1,\"y\":\"z\"}\n", &.{ "SELECT", "x,y" }, "1\tz\n");
}

test "integers beyond i64 compare correctly" {
    try expectQuery("{\"id\":18446744073709551615}\n{\"id\":-1}\n", &.{ "--count", "id", "gt", "0" }, "1\n");
    try expectQuery("{\"id\":9223372036854775807}\n", &.{ "--count", "id", "gte", "9223372036854775807" }, "1\n");
}

test "non-numbers are not treated as numbers" {
    try expectQuery("{\"v\":\"nan\"}\n{\"v\":\"inf\"}\n{\"v\":\"0x10\"}\n{\"v\":3}\n", &.{ "SELECT", "sum:v,count:v" }, "3.0000\t4\n");
    try expectQuery("{\"v\":\"inf\"}\n", &.{ "--count", "v", "gt", "0" }, "0\n");
}

test "limit 0 outputs nothing" {
    try expectQuery("{\"a\":1}\n{\"a\":2}\n", &.{ "--limit", "0", "a", "exists" }, "");
    try expectQuery("{\"a\":1}\n", &.{ "--limit", "0", "--count", "a", "exists" }, "0\n");
}

test "nested objects and arrays are extracted whole" {
    try expectQuery("{\"a\": {\"b\": [1, \"]\"]}, \"c\": 2}\n", &.{ "SELECT", "a,c" }, "{\"b\": [1, \"]\"]}\t2\n");
}

test "count skips nulls" {
    try expectQuery("{\"x\":null}\n{\"x\":1}\n{\"y\":1}\n", &.{ "SELECT", "count:x" }, "1\n");
}

test "csv escapes quotes and decodes JSON escapes" {
    try expectQuery(
        "{\"s\":\"say \\\"hi\\\"\\n\\u00e9\\ud83d\\ude00\",\"n\":5}\n",
        &.{ "--format", "csv", "SELECT", "s,n,missing" },
        "\"say \"\"hi\"\"\n\u{e9}\u{1f600}\",\"5\",\n",
    );
}

test "query values are JSON-escaped before matching" {
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "eq", "a\"b" }, "1\n");
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "has", "\"" }, "1\n");
}

test "has respects type prefixes" {
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "s:2" }, "1\n");
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "n:2" }, "1\n");
}

test "last line without trailing newline is processed" {
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "--count", "a", "exists" }, "2\n");
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "SELECT", "a", "WHERE", "NOT", "b", "exists" }, "1\n2\n");
    try expectQuery("{\"a\":1}\r\n{\"a\":2}\r\n", &.{ "a", "eq", "2" }, "{\"a\":2}\n");
}

test "lines longer than a block are handled" {
    const a = testing.allocator;
    const big = try a.alloc(u8, BLOCK_SIZE + BLOCK_SIZE / 2);
    defer a.free(big);
    @memset(big, 'x');
    const input = try std.mem.concat(a, u8, &.{ "{\"a\":0}\n{\"pad\":\"", big, "\",\"a\":1}\n{\"a\":2}\n{\"a\":3}" });
    defer a.free(input);
    try expectQuery(input, &.{ "--count", "a", "exists" }, "4\n");
    try expectQuery(input, &.{ "SELECT", "a", "WHERE", "a", "gte", "1" }, "1\n2\n3\n");
}

test "many blocks with multi-condition and OR plans" {
    const a = testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(a);
    var expected_and: usize = 0;
    var expected_or: usize = 0;
    var i: usize = 0;
    while (list.items.len < 2 * BLOCK_SIZE + 12345) : (i += 1) {
        const lvl = if (i % 7 == 0) "error" else "info";
        const status = 200 + (i % 5) * 100;
        try list.print(a, "{{\"i\":{d},\"level\":\"{s}\",\"status\":{d},\"msg\":\"some text {d}\"}}\n", .{ i, lvl, status, i });
        if (i % 7 == 0 and status >= 500) expected_and += 1;
        if (i % 7 == 0 or status == 300) expected_or += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "AND", "status", "gte", "500" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_and}));
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "OR", "status", "eq", "300" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_or}));
}

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

test "parseFastInt" {
    try testing.expectEqual(@as(?i64, -42), parseFastInt("-42"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("-"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("1.5"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseFastInt("9223372036854775807"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("9223372036854775808"));
}

test "exact: keys are top-level and paths walk into objects" {
    const line = "{\"id\": 5, \"meta\": {\"id\": 10, \"user\": {\"name\": \"x\"}}}\n";
    try expectQuery(line, &.{ "--count", "id", "eq", "10" }, "0\n");
    try expectQuery(line, &.{ "--count", "meta.id", "eq", "10" }, "1\n");
    try expectQuery(line, &.{ "SELECT", "id,meta.user.name,meta.user,nope.x" }, "5\tx\t{\"name\": \"x\"}\t\n");
    try expectQuery("{\"a.b\":1,\"a\":{\"b\":2}}\n", &.{ "SELECT", "a\\.b,a.b" }, "1\t2\n");
    // A path through a non-object is absent.
    try expectQuery("{\"a\":[{\"b\":1}]}\n", &.{ "--count", "a.b", "exists" }, "0\n");
    try expectQuery(line, &.{ "--fast", "--count", "id", "eq", "10" }, "1\n");
}

test "exact: NOT sees only the value at the path" {
    // The nested "a" must not make `NOT a eq 1` fail.
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "a", "eq", "2", "AND", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"b\":1}\n", &.{ "--count", "NOT", "a", "exists" }, "1\n");
}

test "exact: escapes are decoded" {
    const lines =
        \\{"\u006cevel": "error"}
        \\{"level": "\u0065rror"}
        \\{"level": "err\/or"}
        \\{"msg": "caf\u00e9 \ud83d\ude00", "path": "a\/b"}
        \\{"level": "error"}
        \\
    ;
    try expectQuery(lines, &.{ "--count", "level", "eq", "error" }, "3\n");
    try expectQuery(lines, &.{ "--count", "level", "eq", "err/or" }, "1\n");
    try expectQuery(lines, &.{ "--count", "msg", "has", "caf\u{e9} \u{1f600}" }, "1\n");
    try expectQuery(lines, &.{ "--count", "path", "eq", "a/b" }, "1\n");
    try expectQuery(lines, &.{ "--count", "level", "in", "x,error" }, "3\n");
    // Many anchors take the Teddy path, which must stop at escapes too.
    try expectQuery(lines, &.{ "--count", "level", "eq", "error", "OR", "p1", "exists", "OR", "p2", "exists", "OR", "p3", "exists", "OR", "p4", "exists" }, "3\n");
}

test "exact: numbers compare by value" {
    const lines = "{\"v\":90}\n{\"v\":90.0}\n{\"v\":9e1}\n{\"v\":\"90\"}\n{\"v\":\"90.0\"}\n{\"v\":900}\n{\"v\":-0}\n";
    try expectQuery(lines, &.{ "--count", "v", "eq", "90" }, "5\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "n:90.0" }, "3\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "s:90" }, "1\n");
    try expectQuery(lines, &.{ "--count", "v", "in", "0,9e1" }, "6\n");
    try expectQuery(lines, &.{ "--count", "v", "neq", "90" }, "2\n");
}

test "exact: duplicate keys, last wins" {
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "--count", "a", "eq", "1" }, "0\n");
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "SELECT", "a" }, "2\n");
    try expectQuery("{\"a\":{\"b\":1},\"a\":3}\n", &.{ "--count", "a.b", "exists" }, "0\n");
}

test "exact: invalid lines are skipped" {
    const lines = "{\"a\":1}\n{\"a\":1,}\n{\"a\":01}\n\n{\"a\":\"\xff\"}\n{\"a\":1} x\n[1]\n";
    try expectQuery(lines, &.{ "--count", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{ "--count", "NOT", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{"--count"}, "2\n");
}

test "exact: any JSON whitespace around colons" {
    try expectQuery("{\"a\"\r:\r1}\n", &.{ "--count", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"t\" :\r\"x\"}\n", &.{ "--count", "t", "eq", "x" }, "1\n");
}

/// Writes random JSONL that exercises everything the byte search must see through:
/// escaped spellings of key and value characters, nesting, repeated keys, unusual
/// whitespace, numbers spelled several ways, and some invalid lines.
const FuzzGen = struct {
    rand: std.Random,
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,

    const keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a.b", "p1", "q\"" };
    const strings = [_][]const u8{ "x", "ab", "Push", "1", "90", "90.0", "true", "a/b", "\u{e9}t\u{e9}", "q\"t", "", "-0", "\u{1f600}", "line\nbreak" };
    const numbers = [_][]const u8{ "1", "1.0", "1e0", "90", "9E1", "-0", "0", "12.5", "100", "1E2", "-3" };

    fn print(g: *FuzzGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.a, fmt, args);
    }

    fn chance(g: *FuzzGen, n: u32) bool {
        return g.rand.uintLessThan(u32, n) == 0;
    }

    fn ws(g: *FuzzGen) !void {
        try g.out.appendSlice(g.a, switch (g.rand.uintLessThan(u32, 8)) {
            0 => " ",
            1 => "\t",
            2 => "\r",
            3 => "  ",
            else => "",
        });
    }

    fn hex(g: *FuzzGen, unit: u21) !void {
        if (g.rand.boolean()) try g.print("\\u{x:0>4}", .{unit}) else try g.print("\\u{X:0>4}", .{unit});
    }

    /// A string, with characters randomly written as escapes.
    fn string(g: *FuzzGen, s: []const u8) !void {
        try g.out.append(g.a, '"');
        var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| {
            if (g.chance(5)) {
                if (cp >= 0x10000) {
                    const v = cp - 0x10000;
                    try g.hex(@intCast(0xd800 + (v >> 10)));
                    try g.hex(@intCast(0xdc00 + (v & 0x3ff)));
                } else try g.hex(cp);
            } else switch (cp) {
                '"' => try g.print("\\\"", .{}),
                '\\' => try g.print("\\\\", .{}),
                '\n' => try g.print("\\n", .{}),
                '/' => try g.print("{s}", .{if (g.rand.boolean()) "\\/" else "/"}),
                else => try g.print("{u}", .{cp}),
            }
        }
        try g.out.append(g.a, '"');
    }

    fn value(g: *FuzzGen, depth: u32) error{ OutOfMemory, WriteFailed }!void {
        switch (g.rand.uintLessThan(u32, if (depth < 3) 9 else 6)) {
            0, 1 => try g.string(strings[g.rand.uintLessThan(usize, strings.len)]),
            2, 3 => try g.print("{s}", .{numbers[g.rand.uintLessThan(usize, numbers.len)]}),
            4 => try g.print("{s}", .{([_][]const u8{ "true", "false", "null" })[g.rand.uintLessThan(usize, 3)]}),
            5 => try g.print("{d}", .{g.rand.intRangeAtMost(i32, -200, 200)}),
            6, 7 => try g.object(depth + 1),
            else => {
                try g.out.append(g.a, '[');
                const n = g.rand.uintLessThan(u32, 3);
                for (0..n) |i| {
                    if (i > 0) try g.out.append(g.a, ',');
                    try g.ws();
                    try g.value(depth + 1);
                }
                try g.out.append(g.a, ']');
            },
        }
    }

    fn object(g: *FuzzGen, depth: u32) !void {
        try g.out.append(g.a, '{');
        const n = g.rand.uintLessThan(u32, 5);
        for (0..n) |i| {
            if (i > 0) try g.out.append(g.a, ',');
            try g.ws();
            try g.string(keys[g.rand.uintLessThan(usize, keys.len)]);
            try g.ws();
            try g.out.append(g.a, ':');
            try g.ws();
            try g.value(depth);
        }
        // Padding moves the needles around relative to the SIMD chunks.
        if (g.chance(2)) try g.print(",\"pad\":\"{s}\"", .{("." ** 40)[0..g.rand.uintLessThan(usize, 40)]});
        try g.out.append(g.a, '}');
    }

    fn line(g: *FuzzGen) !void {
        const start = g.out.items.len;
        if (g.chance(20)) try g.value(2) else try g.object(0);
        if (g.chance(20)) g.out.items.len = start + g.rand.uintLessThan(usize, g.out.items.len - start + 1);
        if (g.chance(10)) try g.out.append(g.a, '\r');
        try g.out.append(g.a, '\n');
    }
};

test "differential: the prefilter never drops a line the parser accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x2e60);
    const rand = prng.random();

    const query_keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a\\.b", "a.b", "a.ab", "b.a", "p1", "q\"", "nope" };
    const query_vals = FuzzGen.strings ++ FuzzGen.numbers ++ [_][]const u8{ "false", "null", "t", "/", "\u{e9}" };
    const ops = [_][]const u8{ "eq", "eq", "neq", "has", "in", "exists", "gt", "lte" };

    for (0..20) |_| {
        var gen: FuzzGen = .{ .rand = rand, .a = a };
        for (0..300) |_| try gen.line();

        for (0..40) |_| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            const groups = 1 + rand.uintLessThan(u32, if (rand.boolean()) 2 else 6);
            for (0..groups) |gi| {
                if (gi > 0) try args.append(a, "OR");
                const conds = 1 + rand.uintLessThan(u32, 2);
                for (0..conds) |ci| {
                    if (ci > 0) try args.append(a, "AND");
                    if (rand.uintLessThan(u32, 4) == 0) try args.append(a, "NOT");
                    try args.append(a, query_keys[rand.uintLessThan(usize, query_keys.len)]);
                    const op = ops[rand.uintLessThan(usize, ops.len)];
                    try args.append(a, op);
                    if (std.mem.eql(u8, op, "exists")) continue;
                    const pool: []const []const u8 = if (op[0] == 'g' or op[0] == 'l') &FuzzGen.numbers else &query_vals;
                    var v = pool[rand.uintLessThan(usize, pool.len)];
                    if (std.mem.eql(u8, op, "in")) v = try std.mem.concat(a, u8, &.{ v, ",", pool[rand.uintLessThan(usize, pool.len)] });
                    v = try std.mem.concat(a, u8, &.{ ([_][]const u8{ "", "", "s:", "n:" })[rand.uintLessThan(usize, 4)], v });
                    try args.append(a, v);
                }
            }
            if (rand.boolean()) try args.insertSlice(a, 0, &.{ "SELECT", "a,a.b,p1" });

            const config = (try main.parseArgs(a, args.items)).run;
            const got = try runTestQuery(a, gen.out.items, config);
            var unfiltered = config;
            unfiltered.prefilter = false;
            const want = try runTestQuery(a, gen.out.items, unfiltered);
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("query:", .{});
                for (args.items) |t| std.debug.print(" '{s}'", .{t});
                std.debug.print("\nwant:\n{s}\ngot:\n{s}\n", .{ want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}
