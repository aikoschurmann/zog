//! Reading JSON values out of raw line bytes: numbers, strings and whole values.
const std = @import("std");
const json = @import("json.zig");
const simd = @import("simd.zig");

const VECTOR_LEN = simd.VECTOR_LEN;
const V = simd.V;
const Mask = simd.Mask;
const QUOTE_VEC = simd.QUOTE_VEC;
const NL_VEC = simd.NL_VEC;
const load = simd.load;
const vor = simd.vor;
const KeyFinder = @import("finder.zig").KeyFinder;

pub const Value = struct {
    /// String contents without the surrounding quotes (still JSON-escaped), or the literal,
    /// object or array text.
    raw: []const u8,
    is_string: bool,
};

const TermMask = blk: {
    var mask = [_]bool{false} ** 256;
    for (",}] \t\r\n") |c| mask[c] = true;
    break :blk mask;
};

pub inline fn isPrimitiveTerminator(c: u8) bool {
    return TermMask[c];
}

/// Parses a JSON integer. Up to 18 digits can't overflow, so they take an unchecked fast
/// path; longer inputs use a checked parse and return null when out of range.
pub inline fn parseFastInt(s: []const u8) ?i64 {
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
pub fn parseNumber(s: []const u8) ?f64 {
    if (parseFastInt(s)) |n| return @floatFromInt(n);
    const start: usize = if (s.len > 0 and s[0] == '-') 1 else 0;
    if (start >= s.len or s[start] < '0' or s[start] > '9') return null;
    for (s) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Holds decoded strings, reused across values.
pub const Scratch = struct {
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
pub fn stringContents(vs: []const u8) StrContents {
    var i: usize = 1;
    var escaped = false;
    while (true) {
        i = findStringSpecial(vs, i);
        if (i >= vs.len or vs[i] != '\\') return .{ .raw = vs[1..i], .escaped = escaped };
        escaped = true;
        i = @min(i + 2, vs.len);
    }
}

pub fn stringText(s: StrContents, sc: *Scratch) ![]const u8 {
    return if (s.escaped) sc.decode(s.raw) else s.raw;
}

/// The text of the number or literal at the start of `vs`.
pub fn primitiveToken(vs: []const u8) []const u8 {
    var i: usize = 0;
    while (i < vs.len and !isPrimitiveTerminator(vs[i])) i += 1;
    return vs[0..i];
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

pub fn extractField(line: []const u8, finder: *const KeyFinder) ?Value {
    const hit = finder.next(line, 0) orelse return null;
    return extractValue(line[hit.val_pos..]);
}

/// The value in an exact-parser slot, in the form `extractValue` gives.
pub fn slotValue(raw: ?[]const u8) ?Value {
    const r = raw orelse return null;
    if (r[0] == '"') return .{ .raw = r[1 .. r.len - 1], .is_string = true };
    return .{ .raw = r, .is_string = false };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseFastInt" {
    try testing.expectEqual(@as(?i64, -42), parseFastInt("-42"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("-"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("1.5"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseFastInt("9223372036854775807"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("9223372036854775808"));
}
