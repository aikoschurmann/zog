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

/// The 16 bytes that come `k` positions before `cur`'s bytes: the last `k` bytes of `prev`
/// followed by the first 16 - `k` of `cur`. So lane `j` of the result holds the byte `k` places
/// before `cur[j]`. `@shuffle` reads a non-negative index from its first vector and a negative
/// index `~i` from its second, so `prev` is indexed directly and `cur` through `~`.
inline fn shiftIn(prev: V16, cur: V16, comptime k: comptime_int) V16 {
    // Lanes below `k` take `prev[16 - k + lane]`, the rest take `cur[lane - k]`.
    const indices = comptime blk: {
        var result: @Vector(16, i32) = undefined;
        for (0..16) |lane| {
            result[lane] = if (lane < k) 16 - k + lane else ~@as(i32, lane - k);
        }
        break :blk result;
    };
    return @shuffle(u8, prev, cur, indices);
}

/// Whether `s` is valid UTF-8, with the lookup algorithm of simdjson (Keiser and Lemire,
/// "Validating UTF-8 In Less Than One Instruction Per Byte"). Three table lookups on the
/// nibbles of each byte and the byte before it flag every error that two adjacent bytes
/// show: a missing or stray continuation byte, an overlong form, a surrogate or a code
/// point above U+10FFFF. What remains is a continuation byte that a lead two or three bytes
/// back requires, which a saturating subtraction finds.
pub fn validUtf8(s: []const u8) bool {
    // Targets without the byte-shuffle intrinsics use the standard library's scalar validator.
    if (!has_shuffle) return std.unicode.utf8ValidateSlice(s);
    var prev: V16 = @splat(0);
    var err: V16 = @splat(0);
    var i: usize = 0;
    while (i + 16 <= s.len) : (i += 16) {
        const cur: V16 = s[i..][0..16].*;
        err |= utf8Errors(prev, cur);
        prev = cur;
    }
    // The last block is zero-padded past the end of `s`, and it is always checked, even when
    // `s.len` is a multiple of 16 and the pad is all zeros. Zero is ASCII, so a sequence cut off
    // by the end of `s` meets an ASCII byte where it needs a continuation, and that is flagged.
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0 .. s.len - i], s[i..]);
    err |= utf8Errors(prev, buf);
    return @reduce(.Max, err) == 0;
}

/// The error kinds at each byte of `cur`, given the bytes before it in `prev`. A lane is zero
/// where the byte is valid, given the three bytes before it.
fn utf8Errors(prev: V16, cur: V16) V16 {
    const too_short = 1 << 0; // a lead byte or ASCII followed by a lead byte or ASCII
    const too_long = 1 << 1; // ASCII followed by a continuation byte
    const overlong_3 = 1 << 2;
    const too_large = 1 << 3;
    const surrogate = 1 << 4;
    const overlong_2 = 1 << 5;
    // `too_large_1000` (leads 0xF5 and up) and `overlong_4` (0xF0 then 0x80..0x8F) share bit 6.
    // The lookups never allow both for one pair: `overlong_4` needs the previous byte's low
    // nibble to be 0, and `too_large_1000` needs it to be nonzero.
    const too_large_1000 = 1 << 6;
    const overlong_4 = 1 << 6;
    const two_conts = 1 << 7; // a continuation byte followed by one, unless a lead requires it
    // The kinds that the continuation pattern alone causes. The lookups add the overlong and
    // too-large kinds on top of these.
    const carry = too_short | too_long | two_conts;

    // Each lookup maps one nibble to the error kinds that nibble allows. ANDing the three keeps
    // only the kinds that every lookup allows for this pair, so `special` holds only real errors.
    // The lookups are, in order: the previous byte's high nibble, its low nibble, and the
    // current byte's high nibble.
    const prev1 = shiftIn(prev, cur, 1);
    // Previous byte's high nibble. ASCII is `too_long` before a continuation, a continuation
    // (0x8-0xB) is `two_conts`, and a lead (0xC-0xF) is `too_short` unless a continuation follows.
    const byte_1_high = lookup16(.{
        too_long,               too_long,  too_long,                           too_long,
        too_long,               too_long,  too_long,                           too_long,
        two_conts,              two_conts, two_conts,                          two_conts,
        too_short | overlong_2, too_short, too_short | overlong_3 | surrogate, too_short | too_large | too_large_1000 | overlong_4,
    }, prev1 >> @splat(4));
    // Previous byte's low nibble, which tells the overlong and too-large leads apart: C0 and C1
    // are overlong_2, E0 overlong_3, ED a surrogate, F0 overlong_4, F4 too_large, and F5 and up
    // too_large_1000.
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
    // Current byte's high nibble. 0x8-0xB are continuations, which can complete an overlong, a
    // surrogate or a too-large sequence depending on the lead before them. Other rows are not
    // continuations, so the only kind they allow is `too_short`.
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

    // Bit 7 of `special` is set where the previous and the current byte are both continuations.
    // A lead needs a continuation at this byte when the byte two back is a 3-byte lead (0xE0 and
    // up) or the byte three back is a 4-byte lead (0xF0 and up). Subtracting 0x60 or 0x70 with
    // saturation leaves bit 7 set exactly for those leads, so `third | fourth` marks the bytes
    // that need a continuation. The XOR keeps bit 7 where the two disagree: a required
    // continuation that the previous byte doesn't set up, or a continuation after a continuation
    // that no lead asked for.
    const third = shiftIn(prev, cur, 2) -| @as(V16, @splat(0xe0 - 0x80));
    const fourth = shiftIn(prev, cur, 3) -| @as(V16, @splat(0xf0 - 0x80));
    return ((third | fourth) & @as(V16, @splat(0x80))) ^ special;
}

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
