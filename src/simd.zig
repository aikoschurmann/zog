//! Vector types and helpers shared by the byte-level search.
const std = @import("std");
const builtin = @import("builtin");

/// Bytes per vector: the width the compiler suggests for `u8`, or 16 when it suggests none.
pub const vector_len = std.simd.suggestVectorLength(u8) orelse 16;

pub const V = @Vector(vector_len, u8);
pub const BoolV = @Vector(vector_len, bool);
/// One bit per lane, for `@bitCast` of a bool vector into an integer.
pub const Mask = std.meta.Int(.unsigned, vector_len);
pub const quote_vec: V = @splat('"');
pub const nl_vec: V = @splat('\n');
pub const backslash_vec: V = @splat('\\');
pub const u_vec: V = @splat('u');
pub const slash_vec: V = @splat('/');
pub const false_vec: BoolV = @splat(false);
pub const true_vec: BoolV = @splat(true);

/// The `vector_len` bytes at `i`; the caller guarantees they are in bounds.
pub inline fn load(data: []const u8, i: usize) V {
    return data[i..][0..vector_len].*;
}

/// Lane-wise AND of two bool vectors.
pub inline fn vand(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, b, false_vec);
}

/// Lane-wise OR of two bool vectors.
pub inline fn vor(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, true_vec, b);
}

/// Whether the target has a 16-entry byte table lookup (NEON tbl, x86 pshufb) at the
/// native vector width, which Teddy needs. It is called as an LLVM intrinsic, which Zig's
/// own backends (the default for x86_64 debug builds) don't provide. `lookup16` must only be
/// called when this is true.
pub const has_shuffle = builtin.zig_backend == .stage2_llvm and switch (builtin.cpu.arch) {
    .aarch64 => vector_len == 16,
    .x86_64 => switch (vector_len) {
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
/// The width switch covers the same widths that `has_shuffle` accepts, so no other width
/// reaches the `unreachable`.
pub inline fn lookup16(table: V, idx: V) V {
    if (builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(table, idx);
    return switch (vector_len) {
        16 => @"llvm.x86.ssse3.pshuf.b.128"(table, idx),
        32 => @"llvm.x86.avx2.pshuf.b"(table, idx),
        64 => @"llvm.x86.avx512.pshuf.b.512"(table, idx),
        else => unreachable,
    };
}
