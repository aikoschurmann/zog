const std = @import("std");
const main = @import("main.zig");
const builtin = @import("builtin");

const BLOCK_SIZE = 8 * 1024 * 1024;
const VECTOR_LEN = 32;
const V = @Vector(VECTOR_LEN, u8);

const TypeForced = enum { none, string, numeric };

const CompiledCondition = struct {
    key_quoted: []const u8,
    val_quoted: []const u8,
    val_unquoted: []const u8,
    val_f64: ?f64,
    op: main.Operator,
    type_forced: TypeForced,
};

const CompiledGroup = struct { conditions: []CompiledCondition };

const CompiledPlan = struct {
    groups: []CompiledGroup,
    pluck_keys: [][]const u8,
    unique_first_chars: []u8,
    char_vectors: []V, 
};

const Buffer = struct { 
    data: []u8, 
    len: usize = 0 
};

const ReaderCtx = struct {
    file: std.fs.File,
    bufs: [2]Buffer,
    current_idx: usize = 0,
    done: std.atomic.Value(bool),
    fill_sem: *std.Thread.Semaphore,
    read_sem: *std.Thread.Semaphore,
};

fn isPrimitive(val: []const u8) bool {
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "null")) return true;
    _ = std.fmt.parseFloat(f64, val) catch return false;
    return true;
}

fn compilePlan(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: [][]const u8) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, groups.len);
    var unique_list = std.ArrayList(u8).init(allocator);
    var seen_chars = [_]bool{false} ** 256;

    for (groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            const key_q = try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.key});
            if (!seen_chars[key_q[1]]) { seen_chars[key_q[1]] = true; try unique_list.append(key_q[1]); }

            var actual_val = c.val;
            var type_forced: TypeForced = .none;
            if (std.mem.startsWith(u8, actual_val, "s:")) { actual_val = actual_val[2..]; type_forced = .string; }
            else if (std.mem.startsWith(u8, actual_val, "n:") or std.mem.startsWith(u8, actual_val, "b:")) { actual_val = actual_val[2..]; type_forced = .numeric; }

            comp_conds[j] = .{
                .key_quoted = key_q,
                .val_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{actual_val}),
                .val_unquoted = try allocator.dupe(u8, actual_val),
                .val_f64 = std.fmt.parseFloat(f64, actual_val) catch null,
                .op = c.op,
                .type_forced = type_forced,
            };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }

    const ufc = try unique_list.toOwnedSlice();
    var cvs = try allocator.alloc(V, ufc.len);
    for (ufc, 0..) |char, i| cvs[i] = @splat(char);

    var pks = try allocator.alloc([]const u8, pluck.len);
    for (pluck, 0..) |p, i| pks[i] = try std.fmt.allocPrint(allocator, "\"{s}\"", .{p});

    return CompiledPlan{ .groups = comp_groups, .pluck_keys = pks, .unique_first_chars = ufc, .char_vectors = cvs };
}

// Replace the evaluateValue function in src/scanner.zig with this:

inline fn evaluateValue(rest_si: []const u8, cond: CompiledCondition) bool {
    const is_json_string = rest_si.len > 0 and rest_si[0] == '"';

    if (cond.op == .eq or cond.op == .neq) {
        var is_match = false;
        
        // Optimized EQ: Check the most likely type first based on the query
        if (is_json_string) {
            // JSON is a string: only check if we aren't forced to numeric
            if (cond.type_forced != .numeric) {
                if (std.mem.startsWith(u8, rest_si, cond.val_quoted)) is_match = true;
            }
        } else {
            // JSON is a primitive: only check if we aren't forced to string
            if (cond.type_forced != .string) {
                if (std.mem.startsWith(u8, rest_si, cond.val_unquoted)) {
                    const me = cond.val_unquoted.len;
                    if (me == rest_si.len or std.mem.indexOfScalar(u8, ",}] \t\r\n", rest_si[me]) != null) is_match = true;
                }
            }
        }
        return if (cond.op == .eq) is_match else !is_match;
    } 

    // HAS and Math remain unchanged as they already isolate the value
    if (cond.op == .has) {
        if (extractValueFromRest(rest_si)) |extracted| return std.mem.indexOf(u8, extracted, cond.val_unquoted) != null;
        return false;
    }

    if (cond.val_f64) |target| {
        if (cond.type_forced == .string and !is_json_string) return false;
        if (cond.type_forced == .numeric and is_json_string) return false;
        if (extractValueFromRest(rest_si)) |extracted| {
            if (std.fmt.parseFloat(f64, extracted)) |parsed| {
                return switch (cond.op) { 
                    .gt => parsed > target, 
                    .lt => parsed < target, 
                    .gte => parsed >= target, 
                    .lte => parsed <= target, 
                    else => false 
                };
            } else |_| {}
        }
    }
    return false;
}

inline fn checkSimdChunk(line: []const u8, cond: CompiledCondition, quote_vec: V, first_char_vec: V, i: usize) bool {
    const chunk: V = line[i..][0..VECTOR_LEN].*;
    const next_chunk: V = line[i + 1..][0..VECTOR_LEN].*;
    const matches_mask = @as(u32, @bitCast(chunk == quote_vec)) & @as(u32, @bitCast(next_chunk == first_char_vec));

    if (matches_mask != 0) {
        var mask = matches_mask;
        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const pos = i + bit_pos;
            if (std.mem.startsWith(u8, line[pos..], cond.key_quoted)) {
                const rest = line[pos + cond.key_quoted.len..];
                if (std.mem.indexOfNone(u8, rest, " \t:")) |si| {
                    if (evaluateValue(rest[si..], cond)) return true;
                }
            }
            mask &= mask - 1;
        }
    }
    return false;
}

fn lineMatches(line: []const u8, cond: CompiledCondition) bool {
    if (line.len < 2) return false;
    if (line.len < VECTOR_LEN + 1) {
        var j: usize = 0;
        while (j + cond.key_quoted.len <= line.len) : (j += 1) {
            if (line[j] == '"' and line[j+1] == cond.key_quoted[1]) {
                if (std.mem.startsWith(u8, line[j..], cond.key_quoted)) {
                    const rest = line[j + cond.key_quoted.len..];
                    if (std.mem.indexOfNone(u8, rest, " \t:")) |si| { if (evaluateValue(rest[si..], cond)) return true; }
                }
            }
        }
        return false;
    }

    const qv: V = @splat('"');
    const fcv: V = @splat(cond.key_quoted[1]);
    var i: usize = 0;
    while (i + VECTOR_LEN + 1 <= line.len) {
        if (checkSimdChunk(line, cond, qv, fcv, i)) return true;
        i += VECTOR_LEN;
    }
    const tail_i = line.len - VECTOR_LEN - 1;
    return checkSimdChunk(line, cond, qv, fcv, tail_i);
}

inline fn evaluatePlan(line: []const u8, plan: CompiledPlan) bool {
    if (plan.groups.len == 0) return true;
    if (line.len < 2) return false;
    var might_match = false;
    const qv: V = @splat('"');

    if (line.len >= VECTOR_LEN + 1) {
        var i: usize = 0;
        while (i + VECTOR_LEN + 1 <= line.len) {
            const chunk: V = line[i..][0..VECTOR_LEN].*;
            const next_chunk: V = line[i + 1..][0..VECTOR_LEN].*;
            const qm = @as(u32, @bitCast(chunk == qv));
            for (plan.char_vectors) |cv| {
                if (qm & @as(u32, @bitCast(next_chunk == cv)) != 0) { might_match = true; break; }
            }
            if (might_match) break;
            i += VECTOR_LEN;
        }
        if (!might_match) {
            const tail_i = line.len - VECTOR_LEN - 1;
            const qm = @as(u32, @bitCast(line[tail_i..][0..VECTOR_LEN].* == qv));
            for (plan.char_vectors) |cv| {
                if (qm & @as(u32, @bitCast(line[tail_i + 1..][0..VECTOR_LEN].* == cv)) != 0) { might_match = true; break; }
            }
        }
    } else {
        for (plan.unique_first_chars) |char| { if (std.mem.indexOfScalar(u8, line, char) != null) { might_match = true; break; } }
    }

    if (might_match) {
        for (plan.groups) |group| {
            var gm = true;
            for (group.conditions) |cond| { if (!lineMatches(line, cond)) { gm = false; break; } }
            if (gm) return true;
        }
    }
    return false;
}

inline fn extractValueFromRest(vs: []const u8) ?[]const u8 {
    if (vs.len == 0) return null;
    if (vs[0] == '"') {
        var i: usize = 1;
        while (i < vs.len) : (i += 1) {
            if (vs[i] == '"') {
                var bc: usize = 0;
                var j = i;
                while (j > 1) { j -= 1; if (vs[j] == '\\') bc += 1 else break; }
                if (bc % 2 == 0) return vs[1..i];
            }
        }
    } else if (std.mem.indexOfAny(u8, vs, ",}] \t\r\n")) |ei| return vs[0..ei];
    return vs;
}

fn extractValue(line: []const u8, pk_quoted: []const u8) ?[]const u8 {
    var search = line;
    while (std.mem.indexOf(u8, search, pk_quoted)) |kp| {
        const rest = search[kp + pk_quoted.len..];
        if (std.mem.indexOfNone(u8, rest, " \t:")) |si| { if (extractValueFromRest(rest[si..])) |val| return val; }
        search = rest;
    }
    return null;
}

fn handleMatch(line: []const u8, pluck_keys: [][]const u8, writer: anytype) !void {
    if (pluck_keys.len > 0) {
        for (pluck_keys, 0..) |pk, i| {
            if (extractValue(line, pk)) |val| try writer.print("{s}", .{val});
            if (i < pluck_keys.len - 1) try writer.print("\t", .{});
        }
        try writer.print("\n", .{});
    } else try writer.print("{s}\n", .{line});
}

fn readerThread(ctx: *ReaderCtx) void {
    var leftover_count: usize = 0;
    var leftover_buf = std.heap.page_allocator.alloc(u8, 2 * BLOCK_SIZE) catch return;
    defer std.heap.page_allocator.free(leftover_buf);

    while (true) {
        ctx.read_sem.wait();
        const buf = &ctx.bufs[ctx.current_idx];
        if (leftover_count > 0) @memcpy(buf.data[0..leftover_count], leftover_buf[0..leftover_count]);
        const rc = ctx.file.read(buf.data[leftover_count..]) catch 0;
        if (rc == 0) { buf.len = leftover_count; ctx.done.store(true, .release); ctx.fill_sem.post(); break; }
        const total = leftover_count + rc;
        if (std.mem.lastIndexOfScalar(u8, buf.data[0..total], '\n')) |idx| {
            const boundary = idx + 1;
            leftover_count = total - boundary;
            if (leftover_count > 0) @memcpy(leftover_buf[0..leftover_count], buf.data[boundary..total]);
            buf.len = boundary;
        } else { leftover_count = total; @memcpy(leftover_buf[0..leftover_count], buf.data[0..total]); buf.len = 0; }
        ctx.current_idx = 1 - ctx.current_idx;
        ctx.fill_sem.post();
    }
}

pub fn searchFile(allocator: std.mem.Allocator, path: []const u8, groups: []const main.ConditionGroup, pluck: [][]const u8, writer: anytype) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    try searchFileInternal(allocator, file, groups, pluck, writer);
}

pub fn searchStream(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: [][]const u8, writer: anytype) !void {
    try searchFileInternal(allocator, std.io.getStdIn(), groups, pluck, writer);
}

fn searchFileInternal(allocator: std.mem.Allocator, file: std.fs.File, groups: []const main.ConditionGroup, pluck: [][]const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compilePlan(arena.allocator(), groups, pluck);

    var fill_sem = std.Thread.Semaphore{ .permits = 0 };
    var read_sem = std.Thread.Semaphore{ .permits = 2 };

    var ctx = ReaderCtx{ .file = file, .bufs = .{ .{ .data = try allocator.alloc(u8, BLOCK_SIZE) }, .{ .data = try allocator.alloc(u8, BLOCK_SIZE) } }, .done = std.atomic.Value(bool).init(false), .fill_sem = &fill_sem, .read_sem = &read_sem };
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
        const nlv: V = @splat('\n');
        
        while (i + VECTOR_LEN <= data.len) : (i += VECTOR_LEN) {
            const mask = @as(u32, @bitCast(data[i..][0..VECTOR_LEN].* == nlv));
            if (mask != 0) {
                var iter = mask;
                while (iter != 0) {
                    const nl_pos = @ctz(iter);
                    const line = data[sol .. i + nl_pos];
                    if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_keys, writer);
                    sol = i + nl_pos + 1;
                    iter &= iter - 1;
                }
            }
        }
        while (sol < data.len) {
            if (std.mem.indexOfScalar(u8, data[sol..], '\n')) |nl_pos| {
                const line = data[sol .. sol + nl_pos];
                if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_keys, writer);
                sol += nl_pos + 1;
            } else break;
        }
        if (ctx.done.load(.acquire) and sol < data.len) {
            const line = std.mem.trimRight(u8, data[sol..], "\r\n");
            if (line.len > 0 and evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_keys, writer);
            sol = data.len;
        }
        consume_idx = 1 - consume_idx;
        read_sem.post();
        if (ctx.done.load(.acquire) and fill_sem.permits == 0) break;
    }
    thread.join();
}