const std = @import("std");
const main = @import("main.zig");
const builtin = @import("builtin");

// ==========================================
// STRUCTURES & CONSTANTS
// ==========================================

const BLOCK_SIZE = 8 * 1024 * 1024; // 8MB processing blocks
const VECTOR_LEN = 32;
const V = @Vector(VECTOR_LEN, u8);

const CompiledCondition = struct {
    key_quoted: []const u8,
    val_quoted: []const u8,
};

const CompiledGroup = struct {
    conditions: []CompiledCondition,
};

const CompiledPlan = struct {
    groups: []CompiledGroup,
    pluck_quoted: ?[]const u8,
    unique_first_chars: []u8,
    char_vectors: []V, 
};

const Buffer = struct {
    data: []u8,
    len: usize = 0,
};

const ReaderCtx = struct {
    file: std.fs.File,
    bufs: [2]Buffer,
    current_idx: usize = 0,
    done: std.atomic.Value(bool),
    fill_sem: *std.Thread.Semaphore,
    read_sem: *std.Thread.Semaphore,
};

// ==========================================
// QUERY COMPILER
// ==========================================

fn isPrimitive(val: []const u8) bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return true;
    if (std.mem.eql(u8, val, "null")) return true;
    _ = std.fmt.parseFloat(f64, val) catch return false;
    return true;
}

fn compilePlan(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: ?[]const u8) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, groups.len);
    var seen_chars = [_]bool{false} ** 256;
    var unique_list = std.ArrayList(u8).init(allocator);
    defer unique_list.deinit();

    for (groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            const key_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.key});

            if (!seen_chars[key_quoted[1]]) {
                seen_chars[key_quoted[1]] = true;
                try unique_list.append(key_quoted[1]);
            }

            const val_quoted = if (c.val.len >= 2 and c.val[0] == '"' and c.val[c.val.len - 1] == '"')
                try std.fmt.allocPrint(allocator, "{s}", .{c.val})
            else if (isPrimitive(c.val))
                try std.fmt.allocPrint(allocator, "{s}", .{c.val})
            else
                try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.val});

            comp_conds[j] = .{ .key_quoted = key_quoted, .val_quoted = val_quoted };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }

    const unique_first_chars = try unique_list.toOwnedSlice();
    var char_vectors = try allocator.alloc(V, unique_first_chars.len);
    for (unique_first_chars, 0..) |char, i| char_vectors[i] = @splat(char);

    var pluck_quoted: ?[]const u8 = null;
    if (pluck) |p| pluck_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{p});

    return CompiledPlan{
        .groups = comp_groups,
        .pluck_quoted = pluck_quoted,
        .unique_first_chars = unique_first_chars,
        .char_vectors = char_vectors,
    };
}

// ==========================================
// REFINED SIMD EVALUATOR (Teddy-lite)
// ==========================================

inline fn evaluatePlan(line: []const u8, plan: CompiledPlan) bool {
    if (line.len < 2) return false;
    var might_match = false;
    const quote_vec: V = @splat('"');

    if (line.len >= VECTOR_LEN + 1) {
        var i: usize = 0;
        // Primary Fast Path
        while (i + VECTOR_LEN + 1 <= line.len) {
            const chunk: V = line[i..][0..VECTOR_LEN].*;
            const next_chunk: V = line[i + 1..][0..VECTOR_LEN].*;
            
            const quote_mask = @as(u32, @bitCast(chunk == quote_vec));
            for (plan.char_vectors) |cv| {
                const char_mask = @as(u32, @bitCast(next_chunk == cv));
                if (quote_mask & char_mask != 0) {
                    might_match = true;
                    break;
                }
            }
            if (might_match) break;
            i += VECTOR_LEN;
        }

        // SIMD Overlapping Tail Check 
        if (!might_match and i < line.len) {
            const tail_i = line.len - VECTOR_LEN - 1;
            const chunk: V = line[tail_i..][0..VECTOR_LEN].*;
            const next_chunk: V = line[tail_i + 1..][0..VECTOR_LEN].*;
            
            const quote_mask = @as(u32, @bitCast(chunk == quote_vec));
            for (plan.char_vectors) |cv| {
                const char_mask = @as(u32, @bitCast(next_chunk == cv));
                if (quote_mask & char_mask != 0) {
                    might_match = true;
                    break;
                }
            }
        }
    } else {
        // ONLY execute scalar scan for lines that are too short to fit in SIMD (< 33 bytes)
        for (plan.unique_first_chars) |char| {
            if (std.mem.indexOfScalar(u8, line, char) != null) {
                might_match = true;
                break;
            }
        }
    }

    if (might_match) {
        for (plan.groups) |group| {
            var group_matched = true;
            for (group.conditions) |cond| {
                if (!lineMatches(line, cond.key_quoted, cond.val_quoted)) {
                    group_matched = false;
                    break;
                }
            }
            if (group_matched) return true;
        }
    }
    return false;
}

// Inlined SIMD processing block to guarantee optimization and reuse on the tail
inline fn checkSimdChunk(line: []const u8, key_quoted: []const u8, val_quoted: []const u8, quote_vec: V, first_char_vec: V, i: usize) bool {
    const chunk: V = line[i..][0..VECTOR_LEN].*;
    const next_chunk: V = line[i + 1..][0..VECTOR_LEN].*;
    
    const matches_mask = @as(u32, @bitCast(chunk == quote_vec)) & @as(u32, @bitCast(next_chunk == first_char_vec));

    if (matches_mask != 0) {
        var mask = matches_mask;
        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const pos = i + bit_pos;

            if (std.mem.startsWith(u8, line[pos..], key_quoted)) {
                const rest = line[pos + key_quoted.len..];
                if (std.mem.indexOfNone(u8, rest, " \t:")) |si| {
                    if (std.mem.startsWith(u8, rest[si..], val_quoted)) {
                        const me = si + val_quoted.len;
                        if (val_quoted[val_quoted.len - 1] == '"') return true;
                        if (me < rest.len) {
                            const next_c = rest[me];
                            if (std.mem.indexOfScalar(u8, ",}] \t\r\n", next_c) != null) return true;
                        } else return true;
                    }
                }
            }
            mask &= mask - 1;
        }
    }
    return false;
}

fn lineMatches(line: []const u8, key_quoted: []const u8, val_quoted: []const u8) bool {
    if (line.len < 2) return false;
    
    // Tight inline scalar fallback strictly for lines too short for SIMD (< 33 bytes)
    if (line.len < VECTOR_LEN + 1) {
        var j: usize = 0;
        while (j + key_quoted.len <= line.len) : (j += 1) {
            if (line[j] == '"' and line[j+1] == key_quoted[1]) {
                if (std.mem.startsWith(u8, line[j..], key_quoted)) {
                    const rest = line[j + key_quoted.len..];
                    if (std.mem.indexOfNone(u8, rest, " \t:")) |si| {
                        if (std.mem.startsWith(u8, rest[si..], val_quoted)) {
                            const me = si + val_quoted.len;
                            if (val_quoted[val_quoted.len - 1] == '"') return true;
                            if (me < rest.len) {
                                const next_c = rest[me];
                                if (std.mem.indexOfScalar(u8, ",}] \t\r\n", next_c) != null) return true;
                            } else return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    const quote_vec: V = @splat('"');
    const first_char_vec: V = @splat(key_quoted[1]);
    var i: usize = 0;
    
    // Primary Fast Path
    while (i + VECTOR_LEN + 1 <= line.len) {
        if (checkSimdChunk(line, key_quoted, val_quoted, quote_vec, first_char_vec, i)) return true;
        i += VECTOR_LEN;
    }

    // High-Performance Overlapping SIMD Tail Check
    if (i < line.len) {
        const tail_i = line.len - VECTOR_LEN - 1;
        if (checkSimdChunk(line, key_quoted, val_quoted, quote_vec, first_char_vec, tail_i)) return true;
    }

    return false;
}

fn extractValue(line: []const u8, pk_quoted: []const u8) ?[]const u8 {
    var search = line;
    while (std.mem.indexOf(u8, search, pk_quoted)) |kp| {
        const rest = search[kp + pk_quoted.len..];
        const si = std.mem.indexOfNone(u8, rest, " \t:") orelse return null;
        const vs = rest[si..];
        if (vs.len == 0) return null;
        if (vs[0] == '"') {
            var i: usize = 1;
            while (i < vs.len) : (i += 1) {
                if (vs[i] == '"') {
                    var bc: usize = 0;
                    var j = i;
                    while (j > 1) {
                        j -= 1;
                        if (vs[j] == '\\') bc += 1 else break;
                    }
                    if (bc % 2 == 0) return vs[1..i];
                }
            }
        } else {
            if (std.mem.indexOfAny(u8, vs, ",}] \r\n")) |ei| return vs[0..ei];
            return vs;
        }
        search = rest;
    }
    
    return null;
}

fn handleMatch(line: []const u8, pk_quoted: ?[]const u8, writer: anytype) !void {
    if (pk_quoted) |pk| {
        if (extractValue(line, pk)) |val| try writer.print("{s}\n", .{val});
    } else try writer.print("{s}\n", .{line});
}

// ==========================================
// REUSABLE PRODUCER-CONSUMER ENGINE
// ==========================================

fn readerThread(ctx: *ReaderCtx) void {
    var leftover_count: usize = 0;
    var leftover_buf = std.heap.page_allocator.alloc(u8, 2 * BLOCK_SIZE) catch return;
    defer std.heap.page_allocator.free(leftover_buf);

    while (true) {
        ctx.read_sem.wait();
        const buf = &ctx.bufs[ctx.current_idx];
        if (leftover_count > 0) @memcpy(buf.data[0..leftover_count], leftover_buf[0..leftover_count]);
        const read_count = ctx.file.read(buf.data[leftover_count..]) catch 0;
        
        if (read_count == 0) {
            buf.len = leftover_count;
            ctx.done.store(true, .release);
            ctx.fill_sem.post();
            break;
        }

        const total = leftover_count + read_count;
        if (std.mem.lastIndexOfScalar(u8, buf.data[0..total], '\n')) |idx| {
            const boundary = idx + 1;
            leftover_count = total - boundary;
            if (leftover_count > 0) @memcpy(leftover_buf[0..leftover_count], buf.data[boundary..total]);
            buf.len = boundary;
        } else {
            leftover_count = total;
            @memcpy(leftover_buf[0..leftover_count], buf.data[0..total]);
            buf.len = 0; 
        }

        ctx.current_idx = 1 - ctx.current_idx;
        ctx.fill_sem.post();
    }
}

pub fn searchFile(allocator: std.mem.Allocator, path: []const u8, groups: []const main.ConditionGroup, pluck: ?[]const u8, writer: anytype) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    if (builtin.os.tag == .macos) _ = std.posix.system.fcntl(file.handle, 48, @as(i32, 1));
    if (builtin.os.tag == .linux) _ = std.posix.system.posix_fadvise(file.handle, 0, 0, 2);
    
    try searchFileInternal(allocator, file, groups, pluck, writer);
}

pub fn searchStream(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: ?[]const u8, writer: anytype) !void {
    const stdin = std.io.getStdIn();
    try searchFileInternal(allocator, stdin, groups, pluck, writer);
}

fn searchFileInternal(allocator: std.mem.Allocator, file: std.fs.File, groups: []const main.ConditionGroup, pluck: ?[]const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compilePlan(arena.allocator(), groups, pluck);

    var fill_sem = std.Thread.Semaphore{ .permits = 0 };
    var read_sem = std.Thread.Semaphore{ .permits = 2 };

    var ctx = ReaderCtx{
        .file = file,
        .bufs = .{
            .{ .data = try allocator.alloc(u8, BLOCK_SIZE) },
            .{ .data = try allocator.alloc(u8, BLOCK_SIZE) },
        },
        .done = std.atomic.Value(bool).init(false),
        .fill_sem = &fill_sem,
        .read_sem = &read_sem,
    };
    defer allocator.free(ctx.bufs[0].data);
    defer allocator.free(ctx.bufs[1].data);
    
    const thread = try std.Thread.spawn(.{}, readerThread, .{&ctx});
    var consume_idx: usize = 0;
    
    while (true) {
        fill_sem.wait();
        const buf = &ctx.bufs[consume_idx];
        if (buf.len == 0 and ctx.done.load(.acquire)) break;

        const data = buf.data[0..buf.len];
        var sol: usize = 0;
        var i: usize = 0;
        const nl_vec: V = @splat('\n');
        
        while (i + VECTOR_LEN <= data.len) : (i += VECTOR_LEN) {
            const mask = @as(u32, @bitCast(data[i..][0..VECTOR_LEN].* == nl_vec));
            if (mask != 0) {
                var iter = mask;
                while (iter != 0) {
                    const nl_pos = @ctz(iter);
                    const line = data[sol .. i + nl_pos];
                    if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_quoted, writer);
                    sol = i + nl_pos + 1;
                    iter &= iter - 1;
                }
            }
        }

        while (sol < data.len) {
            if (std.mem.indexOfScalar(u8, data[sol..], '\n')) |nl_pos| {
                const line = data[sol .. sol + nl_pos];
                if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_quoted, writer);
                sol += nl_pos + 1;
            } else break;
        }

        if (ctx.done.load(.acquire) and sol < data.len) {
            const line = std.mem.trimRight(u8, data[sol..], "\r\n");
            if (line.len > 0 and evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_quoted, writer);
            sol = data.len;
        }

        consume_idx = 1 - consume_idx;
        read_sem.post();
        if (ctx.done.load(.acquire) and fill_sem.permits == 0) break;
    }
    thread.join();
}