//! SIMD UTF-8 validation.
const std = @import("std");
const builtin = @import("builtin");

const V16 = @Vector(16, u8);

/// The NEON and SSSE3 instructions below are called as LLVM intrinsics, which Zig's own
/// backends (the default for x86_64 debug builds) don't provide.
const llvm = builtin.zig_backend == .stage2_llvm;
const has_shuffle = llvm and switch (builtin.cpu.arch) {
    .aarch64 => true,
    .x86_64 => builtin.cpu.has(.x86, .ssse3),
    else => false,
};

extern fn @"llvm.aarch64.neon.tbl1"(V16, V16) V16;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(V16, V16) V16;

/// `table[idx]` per byte, for indices below 16.
inline fn lookup16(table: V16, idx: V16) V16 {
    if (builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(table, idx);
    return @"llvm.x86.ssse3.pshuf.b.128"(table, idx);
}

/// The last `k` bytes of `prev` followed by the first 16 - `k` of `cur`.
inline fn shiftIn(prev: V16, cur: V16, comptime k: comptime_int) V16 {
    const mask = comptime blk: {
        var m: @Vector(16, i32) = undefined;
        for (0..16) |j| m[j] = if (j < k) 16 - k + j else ~@as(i32, j - k);
        break :blk m;
    };
    return @shuffle(u8, prev, cur, mask);
}

/// Whether `s` is valid UTF-8, with the lookup algorithm of simdjson (Keiser and Lemire,
/// "Validating UTF-8 In Less Than One Instruction Per Byte"). Three table lookups on the
/// nibbles of each byte and the byte before it flag every error that two adjacent bytes
/// show: a missing or stray continuation byte, an overlong form, a surrogate or a code
/// point above U+10FFFF. What remains is a continuation byte that a lead two or three bytes
/// back requires, which a saturating subtraction finds.
pub fn validUtf8(s: []const u8) bool {
    if (!has_shuffle) return std.unicode.utf8ValidateSlice(s);
    var prev: V16 = @splat(0);
    var err: V16 = @splat(0);
    var i: usize = 0;
    while (i + 16 <= s.len) : (i += 16) {
        const cur: V16 = s[i..][0..16].*;
        err |= utf8Errors(prev, cur);
        prev = cur;
    }
    // At least one zero pads the last block, which ends any sequence cut off at the end.
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0 .. s.len - i], s[i..]);
    err |= utf8Errors(prev, buf);
    return @reduce(.Max, err) == 0;
}

fn utf8Errors(prev: V16, cur: V16) V16 {
    const too_short = 1 << 0; // a lead byte or ASCII followed by a lead byte or ASCII
    const too_long = 1 << 1; // ASCII followed by a continuation byte
    const overlong_3 = 1 << 2;
    const too_large = 1 << 3;
    const surrogate = 1 << 4;
    const overlong_2 = 1 << 5;
    const too_large_1000 = 1 << 6;
    const overlong_4 = 1 << 6;
    const two_conts = 1 << 7; // a continuation byte followed by one, unless a lead requires it
    const carry = too_short | too_long | two_conts;

    const prev1 = shiftIn(prev, cur, 1);
    const byte_1_high = lookup16(.{
        too_long,               too_long,  too_long,                           too_long,
        too_long,               too_long,  too_long,                           too_long,
        two_conts,              two_conts, two_conts,                          two_conts,
        too_short | overlong_2, too_short, too_short | overlong_3 | surrogate, too_short | too_large | too_large_1000 | overlong_4,
    }, prev1 >> @splat(4));
    const byte_1_low = lookup16(.{
        carry | overlong_3 | overlong_2 | overlong_4, carry | overlong_2,
        carry,                                        carry,
        carry | too_large,                            carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,           carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,           carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,           carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,           carry | too_large | too_large_1000 | surrogate,
        carry | too_large | too_large_1000,           carry | too_large | too_large_1000,
    }, prev1 & @as(V16, @splat(0x0f)));
    const byte_2_high = lookup16(.{
        too_short,                                                                    too_short,
        too_short,                                                                    too_short,
        too_short,                                                                    too_short,
        too_short,                                                                    too_short,
        too_long | overlong_2 | two_conts | overlong_3 | too_large_1000 | overlong_4, too_long | overlong_2 | two_conts | overlong_3 | too_large,
        too_long | overlong_2 | two_conts | surrogate | too_large,                    too_long | overlong_2 | two_conts | surrogate | too_large,
        too_short,                                                                    too_short,
        too_short,                                                                    too_short,
    }, cur >> @splat(4));
    const special = byte_1_high & byte_1_low & byte_2_high;

    // Only bytes 111_____ two back and 1111____ three back require a continuation byte here.
    const third = shiftIn(prev, cur, 2) -| @as(V16, @splat(0xe0 - 0x80));
    const fourth = shiftIn(prev, cur, 3) -| @as(V16, @splat(0xf0 - 0x80));
    return ((third | fourth) & @as(V16, @splat(0x80))) ^ special;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "differential: validUtf8 agrees with std" {
    var prng = std.Random.DefaultPrng.init(0x7f8);
    const rand = prng.random();
    const pieces = [_][]const u8{
        "a",                "\x7f",         "\xc2\x80",         "\xdf\xbf",         "\xe0\xa0\x80", "\xed\x9f\xbf",
        "\xee\x80\x80",     "\xef\xbf\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf", "\x80",         "\xbf",
        "\xc0\x80",         "\xc1\xbf",     "\xe0\x80\x80",     "\xed\xa0\x80",     "\xf0\x80\x80", "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80", "\xff",         "\xc3",             "\xe2\x82",         "\xf0\x9f\x98",
    };
    var buf: [200]u8 = undefined;
    for (0..100_000) |_| {
        var n: usize = 0;
        const count = rand.uintLessThan(usize, 40);
        for (0..count) |_| {
            const piece = pieces[rand.uintLessThan(usize, pieces.len)];
            if (n + piece.len > buf.len) break;
            @memcpy(buf[n..][0..piece.len], piece);
            n += piece.len;
        }
        const s = buf[0..n];
        if (validUtf8(s) != std.unicode.utf8ValidateSlice(s)) {
            std.debug.print("bytes: {x}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}
