//! The byte-level search: finds quoted keys and values in raw JSONL without parsing it.
const std = @import("std");
const json = @import("json.zig");
const simd = @import("simd.zig");

const vector_len = simd.vector_len;
const V = simd.V;
const Mask = simd.Mask;
const quote_vec = simd.quote_vec;
const load = simd.load;
const vand = simd.vand;
const vor = simd.vor;

/// Where a key starts (its opening quote) and where its value starts.
pub const Hit = struct { key_pos: usize, val_pos: usize };

/// Finds keys: a quoted key followed by ':'. Requiring the colon means a value that
/// happens to equal the key is not mistaken for it. Candidates are filtered with SIMD on
/// four bytes (both quotes plus the first and last key byte) before a full compare.
pub const KeyFinder = struct {
    key: []const u8,
    first: V,
    last: V,

    /// `key_quoted` is the JSON-escaped key with its quotes, e.g. `"level"`.
    pub fn init(key_quoted: []const u8) KeyFinder {
        return .{
            .key = key_quoted,
            .first = @splat(key_quoted[1]),
            .last = @splat(key_quoted[key_quoted.len - 2]),
        };
    }

    /// Candidate test without the opening-quote check. `after_quote` holds the bytes one past
    /// each position, which the caller has already loaded.
    inline fn withoutOpeningQuote(
        self: *const KeyFinder,
        after_quote: V,
        hay: []const u8,
        i: usize,
    ) simd.BoolV {
        const key_len = self.key.len;

        return vand(
            vand(after_quote == self.first, load(hay, i + key_len - 2) == self.last),
            load(hay, i + key_len - 1) == quote_vec,
        );
    }

    /// Lane `p` of the result is set when a candidate key starts at `i + p`.
    inline fn candidates(self: *const KeyFinder, hay: []const u8, i: usize) Mask {
        const key_len = self.key.len;

        // Four byte tests, each one vector compare: the opening quote, the first key byte,
        // the last key byte and the closing quote. Only positions passing all four are
        // candidates, so the full compare in `verify` runs rarely.
        const matches = vand(
            vand(load(hay, i) == quote_vec, load(hay, i + 1) == self.first),
            vand(load(hay, i + key_len - 2) == self.last, load(hay, i + key_len - 1) == quote_vec),
        );

        // Candidates are rare; on NEON an any-test is one instruction, a bitmask several.
        if (!@reduce(.Or, matches)) return 0;
        return @bitCast(matches);
    }

    pub fn next(self: *const KeyFinder, hay: []const u8, start: usize) ?Hit {
        const key_len = self.key.len;
        var i = start;

        // A chunk at `i` reads up to `key_len - 1 + vector_len` bytes past `i`. Vector chunks
        // are only used while those reads stay inside `hay`.
        if (start + key_len - 1 + vector_len <= hay.len) {
            // The last chunk start whose reads still fit in `hay`.
            const last_chunk = hay.len - (key_len - 1) - vector_len;

            while (true) {
                var candidate_bits = self.candidates(hay, i);
                while (candidate_bits != 0) : (candidate_bits &= candidate_bits - 1) {
                    const pos = i + @ctz(candidate_bits);
                    if (self.verify(hay, pos)) |val_pos| {
                        return .{ .key_pos = pos, .val_pos = val_pos };
                    }
                }

                if (i == last_chunk) return null;
                i += vector_len;

                if (i > last_chunk) {
                    // The next chunk would read past the end, so one more chunk is searched,
                    // aligned to `last_chunk`. Its first `i - last_chunk` lanes were already
                    // searched by the previous chunk, so those bits are shifted out.
                    var unsearched = self.candidates(hay, last_chunk) >> @intCast(i - last_chunk);
                    while (unsearched != 0) : (unsearched &= unsearched - 1) {
                        const pos = i + @ctz(unsearched);
                        if (self.verify(hay, pos)) |val_pos| {
                            return .{ .key_pos = pos, .val_pos = val_pos };
                        }
                    }
                    return null;
                }
            }
        }

        // Haystack shorter than one chunk. Not std.mem.findPos: it builds a 2KB Boyer-Moore
        // table per call for haystacks of 52+ bytes.
        while (std.mem.findScalarPos(u8, hay, i, '"')) |pos| {
            if (pos + key_len > hay.len) break;
            if (self.verify(hay, pos)) |val_pos| {
                return .{ .key_pos = pos, .val_pos = val_pos };
            }
            i = pos + 1;
        }
        return null;
    }

    /// Returns the start of the value if the key at `pos` is a real key.
    inline fn verify(self: *const KeyFinder, hay: []const u8, pos: usize) ?usize {
        const key_len = self.key.len;

        if (!std.mem.eql(u8, hay[pos..][0..key_len], self.key)) return null;

        // An opening quote preceded by an odd number of backslashes is escaped text inside a string.
        if (isEscaped(hay, pos)) return null;

        // A key is followed by optional whitespace, a colon, and optional whitespace.
        const colon = skipSpaceForward(hay, pos + key_len);
        if (colon == hay.len or hay[colon] != ':') return null;
        return skipSpaceForward(hay, colon + 1);
    }
};

/// JSON whitespace, minus the newline that ends a line.
inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// Whether the quote at `pos` is escaped, i.e. preceded by an odd number of backslashes.
inline fn isEscaped(hay: []const u8, pos: usize) bool {
    var run_start = pos;
    while (run_start > 0 and hay[run_start - 1] == '\\') run_start -= 1;
    return (pos - run_start) % 2 == 1;
}

/// The first position at or after `pos` that is not whitespace.
inline fn skipSpaceForward(hay: []const u8, pos: usize) usize {
    var end = pos;
    while (end < hay.len and isSpace(hay[end])) end += 1;
    return end;
}

/// The position just after the last non-whitespace byte before `pos`.
inline fn skipSpaceBackward(hay: []const u8, pos: usize) usize {
    var start = pos;
    while (start > 0 and isSpace(hay[start - 1])) start -= 1;
    return start;
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
        for (text) |byte| {
            if (byte < 0x80) {
                self.ascii.set(byte);
            } else {
                self.non_ascii = true;
            }
        }
    }

    /// Whether the backslash at `pos` starts an escape for a needle character. Backslash
    /// parity isn't checked, so an escaped backslash can be reported too, which only costs
    /// a parse.
    fn startsHazard(self: *const Hazards, hay: []const u8, pos: usize) bool {
        if (pos + 1 >= hay.len) return false;

        switch (hay[pos + 1]) {
            '/' => return self.ascii.isSet('/'),
            'u' => {
                // Twelve bytes cover a surrogate pair, two `\uXXXX` escapes.
                const escape = hay[pos..@min(pos + 12, hay.len)];
                var cursor: usize = 0;
                var decoded: [4]u8 = undefined;
                const unit = json.nextUnit(escape, &cursor, &decoded);

                if (cursor == 2) return false; // not followed by 4 hex digits
                if (unit.len == 1 and unit[0] < 0x80) return self.ascii.isSet(unit[0]);
                return self.non_ascii;
            },
            else => return false,
        }
    }

    /// Whether `line` has an escape that could hide a needle.
    pub fn inLine(self: *const Hazards, line: []const u8) bool {
        var search_from: usize = 0;
        while (std.mem.findScalarPos(u8, line, search_from, '\\')) |pos| {
            if (self.startsHazard(line, pos)) return true;

            // Jump past the escaped character, so a backslash that is itself escaped is not
            // read as the start of another escape.
            search_from = pos + 2;
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
    low_lookup: [teddy_bytes]V,
    high_lookup: [teddy_bytes]V,

    /// Fingerprinted bytes after the opening quote.
    const teddy_bytes = 3;
    const low_nibble: V = @splat(0x0f);

    fn init(finders: []const KeyFinder) Teddy {
        // Bit b of low[offset][x] is set when some needle in bucket b may have low nibble x at
        // `offset` bytes after the quote. high[offset][x] does the same for the high nibble.
        var low = [_][16]u8{[_]u8{0} ** 16} ** teddy_bytes;
        var high = low;

        for (finders, 0..) |finder, needle_index| {
            const bit = bucketBit(needle_index);
            for (0..teddy_bytes) |offset| {
                if (offset + 1 < finder.key.len) {
                    const byte = finder.key[offset + 1];
                    low[offset][byte & 0x0f] |= bit;
                    high[offset][byte >> 4] |= bit;
                } else {
                    // The needle is shorter: any byte is allowed here.
                    for (&low[offset], &high[offset]) |*low_entry, *high_entry| {
                        low_entry.* |= bit;
                        high_entry.* |= bit;
                    }
                }
            }
        }

        var self: Teddy = undefined;
        for (0..teddy_bytes) |offset| {
            // The vector shuffle looks up within each 128-bit lane, so the 16-entry table is
            // repeated across the whole vector.
            var low_vec: [vector_len]u8 = undefined;
            var high_vec: [vector_len]u8 = undefined;
            for (&low_vec, &high_vec, 0..) |*low_lane, *high_lane, lane| {
                low_lane.* = low[offset][lane % 16];
                high_lane.* = high[offset][lane % 16];
            }
            self.low_lookup[offset] = low_vec;
            self.high_lookup[offset] = high_vec;
        }
        return self;
    }

    /// Needles are assigned to buckets round-robin, so each bucket is one bit of a byte.
    fn bucketBit(needle_index: usize) u8 {
        return @as(u8, 1) << @intCast(needle_index % 8);
    }

    /// Per position, the buckets with a needle that may start there. Reads two chunks.
    inline fn buckets(self: *const Teddy, hay: []const u8, i: usize) V {
        // The shifted views are built from two loads: given loads at i+1, i+2 and i+3, LLVM
        // merged them into byte-by-byte inserts and the scan ran ~50% slower.
        const this_chunk = load(hay, i);
        const next_chunk = load(hay, i + vector_len);

        var candidate_buckets: V = @splat(0xff);
        inline for (0..teddy_bytes) |offset| {
            // Lane `p` now holds the byte `offset + 1` after position `i + p`.
            const shifted = @shuffle(u8, this_chunk, next_chunk, shiftMask(offset + 1));

            // Each nibble lookup gives the buckets that allow that nibble. ANDing both leaves
            // the buckets that allow the whole byte. The tables are a superset of the needles,
            // so a bucket can still be a false positive; `verify` filters those out.
            candidate_buckets &= simd.lookup16(self.low_lookup[offset], shifted & low_nibble) &
                simd.lookup16(self.high_lookup[offset], shifted >> @splat(4));
        }

        // A needle can only start at an opening quote.
        return @select(u8, this_chunk == quote_vec, candidate_buckets, @as(V, @splat(0)));
    }

    /// Shuffle mask selecting bytes `shift..shift + vector_len` of two concatenated chunks.
    fn shiftMask(shift: usize) @Vector(vector_len, i32) {
        var indices: [vector_len]i32 = undefined;

        // Non-negative indices pick from the first chunk, `~i` from the second.
        for (&indices, 0..) |*entry, lane| {
            if (lane + shift < vector_len) {
                entry.* = @intCast(lane + shift);
            } else {
                entry.* = ~@as(i32, @intCast(lane + shift - vector_len));
            }
        }
        return indices;
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

    /// Builds the Teddy tables too when there are enough needles for it to pay off.
    pub fn init(allocator: std.mem.Allocator, needles: []const Needle) !MultiFinder {
        const finders = try allocator.alloc(KeyFinder, needles.len);
        const value_of = try allocator.alloc(?[]const u8, needles.len);

        var max_len: usize = 0;
        for (needles, finders, value_of) |needle, *finder, *owner| {
            finder.* = needle.finder;
            owner.* = needle.value_of;
            max_len = @max(max_len, needle.finder.key.len);
        }

        const use_teddy = simd.has_shuffle and needles.len >= teddy_min_needles;
        return .{
            .finders = finders,
            .value_of = value_of,
            .max_len = max_len,
            .teddy = if (use_teddy) .init(finders) else null,
        };
    }

    /// Bytes past a chunk's start that `mask` reads, beyond the chunk itself. Teddy reads a
    /// second chunk; the other modes read as far as the longest needle needs.
    inline fn reach(self: *const MultiFinder, comptime mode: Mode) usize {
        return if (mode == .teddy) vector_len else self.max_len - 1;
    }

    /// Per position, the buckets of needles that may start there (any nonzero value when
    /// buckets aren't tracked). With `with_hazards`, also `\u` and `\/` positions, as 0xff.
    inline fn mask(
        self: *const MultiFinder,
        comptime mode: Mode,
        comptime with_hazards: bool,
        hay: []const u8,
        i: usize,
    ) V {
        const next_byte = load(hay, i + 1);

        // A backslash at `i` followed by `u` or `/`. Such a position might be an escape for a
        // needle character, so it is always reported.
        const hazard = if (with_hazards)
            vand(load(hay, i) == simd.backslash_vec, vor(next_byte == simd.u_vec, next_byte == simd.slash_vec))
        else
            simd.false_vec;

        if (mode == .teddy) {
            const bucket_bits = self.teddy.?.buckets(hay, i);
            if (with_hazards) return @select(u8, hazard, @as(V, @splat(0xff)), bucket_bits);
            return bucket_bits;
        }

        // The needles' tests are ORed together. The quote test at `i` is shared by all of
        // them, so it is applied once after the loop.
        var matches = simd.false_vec;
        switch (mode) {
            .unrolled => |count| inline for (self.finders[0..count]) |*finder| {
                matches = vor(matches, finder.withoutOpeningQuote(next_byte, hay, i));
            },
            .looped => for (self.finders) |*finder| {
                matches = vor(matches, finder.withoutOpeningQuote(next_byte, hay, i));
            },
            .teddy => unreachable,
        }

        const is_candidate = vand(matches, load(hay, i) == quote_vec);
        return @select(u8, vor(is_candidate, hazard), @as(V, @splat(0xff)), @as(V, @splat(0)));
    }

    /// Whether any lane of `masks` is nonzero.
    inline fn anyCandidate(masks: V) bool {
        return @reduce(.Or, masks != @as(V, @splat(0)));
    }

    /// `bits` has bit `p` set for each candidate position `p` of a chunk, and `buckets` holds
    /// the bucket mask of each position.
    const Candidates = struct { bits: Mask, buckets: [vector_len]u8 };

    inline fn candidates(
        self: *const MultiFinder,
        comptime mode: Mode,
        comptime with_hazards: bool,
        hay: []const u8,
        i: usize,
    ) Candidates {
        const masks = self.mask(mode, with_hazards, hay, i);
        if (!anyCandidate(masks)) {
            return .{ .bits = 0, .buckets = undefined };
        }

        return .{
            .bits = @bitCast(masks != @as(V, @splat(0))),
            .buckets = masks,
        };
    }

    /// Checks the needles at `pos`. For a Teddy candidate, only the needles in `allowed_buckets`
    /// can start there, so the others are skipped.
    inline fn verify(
        self: *const MultiFinder,
        comptime mode: Mode,
        comptime with_hazards: bool,
        hay: []const u8,
        pos: usize,
        allowed_buckets: u8,
    ) ?MultiHit {
        // A hazard reports the backslash itself. The caller decides whether to parse the line.
        if (with_hazards and hay[pos] == '\\') {
            if (!self.hazards.startsHazard(hay, pos)) return null;

            return .{
                .hit = .{ .key_pos = pos, .val_pos = pos },
                .key = hazard_key,
                .pos = pos,
            };
        }

        for (self.finders, self.value_of, 0..) |*finder, owner, needle_index| {
            if (mode == .teddy and Teddy.bucketBit(needle_index) & allowed_buckets == 0) continue;
            if (pos + finder.key.len > hay.len) continue;

            if (owner) |owner_key| {
                // A value needle matches the value's bytes here, and then the key before them
                // must be `owner_key`.
                if (!std.mem.eql(u8, hay[pos..][0..finder.key.len], finder.key)) continue;
                const key_pos = keyBefore(hay, pos, owner_key) orelse continue;

                return .{
                    .hit = .{ .key_pos = key_pos, .val_pos = pos },
                    .key = needle_index,
                    .pos = pos,
                };
            }

            // A key needle: `KeyFinder.verify` checks the key and the colon after it.
            if (finder.verify(hay, pos)) |val_pos| {
                return .{
                    .hit = .{ .key_pos = pos, .val_pos = val_pos },
                    .key = needle_index,
                    .pos = pos,
                };
            }
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

    fn find(self: *const MultiFinder, comptime with_hazards: bool, hay: []const u8, start: usize) ?MultiHit {
        // With Teddy, one scan covers all needles.
        if (simd.has_shuffle and self.teddy != null) {
            return self.nextN(.teddy, with_hazards, hay, start);
        }

        return switch (self.finders.len) {
            // A single plain key has its own search loop. Hazards and value needles need the
            // general loop, which knows how to report them.
            1 => if (with_hazards or self.value_of[0] != null)
                self.nextN(.{ .unrolled = 1 }, with_hazards, hay, start)
            else if (self.finders[0].next(hay, start)) |hit|
                .{ .hit = hit, .key = 0, .pos = hit.key_pos }
            else
                null,

            // The needle count is known at compile time, so the loop over needles is unrolled
            // and each needle's vectors can stay in registers.
            inline 2...8 => |n| self.nextN(.{ .unrolled = n }, with_hazards, hay, start),
            else => self.nextN(.looped, with_hazards, hay, start),
        };
    }

    /// Verifies the candidates of the chunk at `base`, from position `base + skip` on.
    inline fn verifyChunk(
        self: *const MultiFinder,
        comptime mode: Mode,
        comptime with_hazards: bool,
        hay: []const u8,
        base: usize,
        skip: usize,
    ) ?MultiHit {
        const found = self.candidates(mode, with_hazards, hay, base);

        // Shifting drops the lanes before `skip`, which an earlier chunk already checked.
        var bits = found.bits >> @intCast(skip);
        while (bits != 0) : (bits &= bits - 1) {
            const offset = skip + @ctz(bits);
            if (self.verify(mode, with_hazards, hay, base + offset, found.buckets[offset])) |hit| {
                return hit;
            }
        }
        return null;
    }

    /// The search loop: vector chunks while they fit, then a scalar tail.
    fn nextN(
        self: *const MultiFinder,
        comptime mode: Mode,
        comptime with_hazards: bool,
        hay: []const u8,
        start: usize,
    ) ?MultiHit {
        const chunk_reach = self.reach(mode);
        var i = start;

        // A chunk at `i` reads `chunk_reach` bytes past its own end, so vector chunks are used
        // only while those reads stay inside `hay`.
        if (start + chunk_reach + vector_len <= hay.len) {
            // The last chunk start whose reads still fit in `hay`. The chunk aligned to `end`
            // is the one that covers the final bytes.
            const last_chunk = hay.len - chunk_reach - vector_len;
            const end = last_chunk + vector_len;

            while (true) {
                // Skip two chunks per branch while there are no candidates.
                while (i + vector_len <= last_chunk) : (i += 2 * vector_len) {
                    const pair = self.mask(mode, with_hazards, hay, i) |
                        self.mask(mode, with_hazards, hay, i + vector_len);
                    if (anyCandidate(pair)) break;
                }

                // Verify the two chunks the skip stopped at, then go back to skipping rather than
                // going chunk by chunk until a real hit. Past `last_chunk`, the chunk aligned to
                // the end is used instead, skipping the positions already seen.
                const stop = @min(i + 2 * vector_len, end);
                while (i < stop) : (i += vector_len) {
                    const base = @min(i, last_chunk);
                    if (self.verifyChunk(mode, with_hazards, hay, base, i - base)) |hit| return hit;
                }

                if (i >= end) break;
            }

            // Positions from `end` on are the last `chunk_reach` bytes, which no chunk covered.
            i = end;
        }

        // Scalar scan for the rest. Only quotes can start a needle, and with hazards a
        // backslash can start one too.
        while (if (with_hazards) std.mem.findAnyPos(u8, hay, i, "\"\\") else std.mem.findScalarPos(u8, hay, i, '"')) |pos| {
            if (self.verify(.looped, with_hazards, hay, pos, 0xff)) |hit| return hit;
            i = pos + 1;
        }
        return null;
    }
};

/// If the string value at `value_pos` belongs to `key` (`"key": "value"`), returns the
/// position of the key's opening quote.
fn keyBefore(hay: []const u8, value_pos: usize, key: []const u8) ?usize {
    // Walk backwards over `<space>:<space>` to the end of the key.
    const colon_end = skipSpaceBackward(hay, value_pos);
    if (colon_end == 0 or hay[colon_end - 1] != ':') return null;
    const key_end = skipSpaceBackward(hay, colon_end - 1);

    if (key_end < key.len) return null;
    const key_pos = key_end - key.len;
    if (!std.mem.eql(u8, hay[key_pos..key_end], key)) return null;

    // `\"key":` inside a string is text, not a key.
    if (isEscaped(hay, key_pos)) return null;
    return key_pos;
}

/// Index of the first '\n' at or after `start`, or `data.len`. Kept out of line so the
/// loop is register-only: inlined into the per-line scan, LLVM spilled the index to the stack.
pub noinline fn findNewline(data: []const u8, start: usize) usize {
    var i = start;
    while (i + vector_len <= data.len) : (i += vector_len) {
        const is_newline = load(data, i) == simd.nl_vec;
        if (@reduce(.Or, is_newline)) {
            return i + @ctz(@as(Mask, @bitCast(is_newline)));
        }
    }

    while (i < data.len and data[i] != '\n') i += 1;
    return i;
}

/// Index of the last '\n' in data[lo..hi].
pub fn lastNewline(data: []const u8, lo: usize, hi: usize) ?usize {
    var i = hi;
    while (i >= lo + vector_len) {
        i -= vector_len;
        const is_newline = load(data, i) == simd.nl_vec;
        if (@reduce(.Or, is_newline)) {
            // @clz counts the zero bits above the highest set bit, so the highest set bit
            // (the last newline in this chunk) is at `vector_len - 1 - @clz`.
            const newline_bits: Mask = @bitCast(is_newline);
            return i + (vector_len - 1 - @clz(newline_bits));
        }
    }

    while (i > lo) {
        i -= 1;
        if (data[i] == '\n') return i;
    }
    return null;
}

const testing = std.testing;

test "Teddy finds the same needles as testing each" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x7edd7);
    const random = prng.random();

    // A small alphabet makes prefix collisions, shared buckets and near misses common.
    const alphabet = "abAB\\\":, \xe9";
    for (0..300) |round| {
        const count = 4 + round % 14;
        const needles = try allocator.alloc(Needle, count);
        for (needles) |*needle| {
            const len = 1 + random.uintLessThan(usize, 5);
            const key = try allocator.alloc(u8, len + 2);
            key[0] = '"';
            key[len + 1] = '"';
            for (key[1 .. len + 1]) |*byte| byte.* = "abAB\xe9"[random.uintLessThan(usize, 5)];
            needle.* = .{ .finder = .init(key), .value_of = if (random.boolean()) "\"k\"" else null };
        }

        const teddy: MultiFinder = try .init(allocator, needles);
        if (teddy.teddy == null) return error.SkipZigTest;
        var plain = teddy;
        plain.teddy = null;

        const hay = try allocator.alloc(u8, random.uintLessThan(usize, 400));
        for (hay) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];

        // Plant needles, half of them as `"k": value`, so there are real hits.
        for (0..hay.len / 20) |_| {
            const needle = needles[random.uintLessThan(usize, count)];
            const text = if (needle.value_of != null)
                try std.mem.concat(allocator, u8, &.{ "\"k\": ", needle.finder.key })
            else
                try std.mem.concat(allocator, u8, &.{ needle.finder.key, ":" });
            if (text.len > hay.len) continue;
            @memcpy(hay[random.uintLessThan(usize, hay.len - text.len + 1)..][0..text.len], text);
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

    const single_key = KeyFinder.init("\"k\"");
    try testing.expectEqual(@as(?usize, 5), if (single_key.next("{\"k\":1}", 0)) |h| h.val_pos else null);
}

test "lastNewline" {
    const text = "ab\ncdefghijklmnopqrstuvwxyz0123456789\nxyz";
    try testing.expectEqual(@as(?usize, 37), lastNewline(text, 0, text.len));
    try testing.expectEqual(@as(?usize, 2), lastNewline(text, 0, 37));
    try testing.expectEqual(@as(?usize, null), lastNewline(text, 3, 37));
}
