//! Vector types and helpers shared by the byte-level search.
const std = @import("std");
const builtin = @import("builtin");

pub const VECTOR_LEN = std.simd.suggestVectorLength(u8) orelse 16;

pub const V = @Vector(VECTOR_LEN, u8);
pub const BoolV = @Vector(VECTOR_LEN, bool);
pub const Mask = std.meta.Int(.unsigned, VECTOR_LEN);
pub const QUOTE_VEC: V = @splat('"');
pub const NL_VEC: V = @splat('\n');
pub const BACKSLASH_VEC: V = @splat('\\');
pub const U_VEC: V = @splat('u');
pub const SLASH_VEC: V = @splat('/');
pub const FALSE_VEC: BoolV = @splat(false);
pub const TRUE_VEC: BoolV = @splat(true);

pub inline fn load(data: []const u8, i: usize) V {
    return data[i..][0..VECTOR_LEN].*;
}

pub inline fn vand(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, b, FALSE_VEC);
}

pub inline fn vor(a: BoolV, b: BoolV) BoolV {
    return @select(bool, a, TRUE_VEC, b);
}

/// Whether the target has a 16-entry byte table lookup (NEON tbl, x86 pshufb) at the
/// native vector width, which Teddy needs. It is called as an LLVM intrinsic, which Zig's
/// own backends (the default for x86_64 debug builds) don't provide.
pub const has_shuffle = builtin.zig_backend == .stage2_llvm and switch (builtin.cpu.arch) {
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
pub inline fn lookup16(table: V, idx: V) V {
    if (builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(table, idx);
    return switch (VECTOR_LEN) {
        16 => @"llvm.x86.ssse3.pshuf.b.128"(table, idx),
        32 => @"llvm.x86.avx2.pshuf.b"(table, idx),
        64 => @"llvm.x86.avx512.pshuf.b.512"(table, idx),
        else => unreachable,
    };
}
