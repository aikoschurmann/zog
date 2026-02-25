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
    val_i64: ?i64,
    op: main.Operator,
    type_forced: TypeForced,
};

const CompiledGroup = struct { conditions: []CompiledCondition };

const CompiledPluck = struct {
    key_quoted: []const u8,
    ptype: main.PluckType,
    original_str: []const u8,
};

const CompiledPlan = struct {
    groups: []CompiledGroup,
    pluck: []CompiledPluck,
    unique_first_chars: []u8,
    char_vectors: []V, 
    has_aggregations: bool,
    format: main.OutputFormat,
};

const AggState = union(enum) {
    raw: void,
    count: usize,
    sum: f64,
    min: f64,
    max: f64,
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

inline fn isFastPrimitive(val: []const u8) bool {
    if (val.len == 0) return false;
    const c = val[0];
    // If it starts with a number, minus, 't' (true), 'f' (false), or 'n' (null), it's primitive.
    return (c >= '0' and c <= '9') or c == '-' or c == 't' or c == 'f' or c == 'n';
}

inline fn isPrimitiveTerminator(c: u8) bool {
    return TermMask[c];
}

inline fn parseFastInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var sign: i64 = 1;
    var i: usize = 0;
    if (s[0] == '-') {
        sign = -1;
        i += 1;
    }
    if (i == s.len) return null;
    var res: i64 = 0;
    while (i < s.len) : (i += 1) {
        const digit = s[i] -% '0';
        if (digit > 9) return null;
        res = res * 10 + @as(i64, digit);
    }
    return res * sign;
}

fn compilePlan(allocator: std.mem.Allocator, config: main.Config) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, config.groups.len);
    var unique_list = std.ArrayList(u8).init(allocator);
    var seen_chars = [_]bool{false} ** 256;

    for (config.groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            const key_q = try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.key});
            if (!seen_chars[key_q[1]]) { seen_chars[key_q[1]] = true; try unique_list.append(key_q[1]); }

            var actual_val = c.val;
            var type_forced: TypeForced = .none;
            if (std.mem.startsWith(u8, actual_val, "s:")) { actual_val = actual_val[2..]; type_forced = .string;
            } else if (std.mem.startsWith(u8, actual_val, "n:") or std.mem.startsWith(u8, actual_val, "b:")) { actual_val = actual_val[2..];
            type_forced = .numeric; }

            comp_conds[j] = .{
                .key_quoted = key_q,
                .val_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{actual_val}),
                .val_unquoted = try allocator.dupe(u8, actual_val),
                .val_f64 = std.fmt.parseFloat(f64, actual_val) catch null,
                .val_i64 = std.fmt.parseInt(i64, actual_val, 10) catch null,
                .op = c.op,
                .type_forced = type_forced,
            };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }

    const ufc = try unique_list.toOwnedSlice();
    var cvs = try allocator.alloc(V, ufc.len);
    for (ufc, 0..) |char, i| cvs[i] = @splat(char);

    var pks = try allocator.alloc(CompiledPluck, config.pluck.len);
    var has_aggs = false;
    for (config.pluck, 0..) |p, i| {
        pks[i] = .{
            .key_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{p.key}),
            .ptype = p.ptype,
            .original_str = p.original_str,
        };
        if (p.ptype != .raw) has_aggs = true;
    }

    return CompiledPlan{ 
        .groups = comp_groups, 
        .pluck = pks, 
        .unique_first_chars = ufc, 
        .char_vectors = cvs,
        .has_aggregations = has_aggs,
        .format = config.format,
    };
}

inline fn evaluateValue(rest_si: []const u8, cond: CompiledCondition) bool {
    const is_json_string = rest_si.len > 0 and rest_si[0] == '"';

    if (cond.op == .eq or cond.op == .neq) {
        var is_match = false;
        if (is_json_string) {
            if (cond.type_forced != .numeric) {
                if (std.mem.startsWith(u8, rest_si, cond.val_quoted)) is_match = true;
            }
        } else {
            if (cond.type_forced != .string) {
                if (std.mem.startsWith(u8, rest_si, cond.val_unquoted)) {
                    const me = cond.val_unquoted.len;
                    if (me == rest_si.len or isPrimitiveTerminator(rest_si[me])) is_match = true;
                }
            }
        }
        return if (cond.op == .eq) is_match else !is_match;
    } 

    if (cond.op == .has) {
        if (extractValueFromRest(rest_si)) |extracted|
            return std.mem.indexOf(u8, extracted, cond.val_unquoted) != null;
        return false;
    }

    if (cond.val_f64) |target_f64| {
        if (cond.type_forced == .string and !is_json_string) return false;
        if (cond.type_forced == .numeric and is_json_string) return false;
        
        if (extractValueFromRest(rest_si)) |extracted| {
            if (cond.val_i64) |target_i64| {
                if (parseFastInt(extracted)) |parsed_i64| {
                    return switch (cond.op) { 
                        .gt => parsed_i64 > target_i64, 
                        .lt => parsed_i64 < target_i64, 
                        .gte => parsed_i64 >= target_i64, 
                        .lte => parsed_i64 <= target_i64, 
                        else => false 
                    };
                }
            }
            if (std.fmt.parseFloat(f64, extracted)) |parsed_f64| {
                return switch (cond.op) { 
                    .gt => parsed_f64 > target_f64, 
                    .lt => parsed_f64 < target_f64, 
                    .gte => parsed_f64 >= target_f64, 
                    .lte => parsed_f64 <= target_f64, 
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
            if (line.len - pos >= cond.key_quoted.len) {
                if (std.mem.eql(u8, line[pos + 2 .. pos + cond.key_quoted.len], cond.key_quoted[2..])) {
                    const rest = line[pos + cond.key_quoted.len..];
                    var si: usize = 0;
                    while (si < rest.len and (rest[si] == ' ' or rest[si] == '\t' or rest[si] == ':')) : (si += 1) {}
                    if (si < rest.len) {
                        if (evaluateValue(rest[si..], cond)) return true;
                    }
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
                if (std.mem.eql(u8, line[j + 2 .. j + cond.key_quoted.len], cond.key_quoted[2..])) {
                    const rest = line[j + cond.key_quoted.len..];
                    var si: usize = 0;
                    while (si < rest.len and (rest[si] == ' ' or rest[si] == '\t' or rest[si] == ':')) : (si += 1) {}
                    if (si < rest.len) { if (evaluateValue(rest[si..], cond)) return true; }
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

const TermMask = blk: {
    var mask = [_]bool{false} ** 256;
    for (",}] \t\r\n") |c| mask[c] = true;
    break :blk mask;
};

inline fn extractValueFromRest(vs: []const u8) ?[]const u8 {
    if (vs.len == 0) return null;
    if (vs[0] == '"') {
        var i: usize = 1;
        while (i < vs.len) {
            if (std.mem.indexOfScalar(u8, vs[i..], '"')) |next_idx| {
                i += next_idx;
                var bc: usize = 0;
                var j = i;
                while (j > 1) { j -= 1; if (vs[j] == '\\') bc += 1 else break; }
                if (bc % 2 == 0) return vs[1..i];
                i += 1;
            } else {
                break;
            }
        }
    } else {
        var i: usize = 0;
        while (i < vs.len) : (i += 1) {
            if (TermMask[vs[i]]) return vs[0..i];
        }
    }
    return vs;
}

inline fn extractValueSingle(line: []const u8, pk_quoted: []const u8) ?[]const u8 {
    var search = line;
    while (std.mem.indexOf(u8, search, pk_quoted)) |kp| {
        const rest = search[kp + pk_quoted.len..];
        var si: usize = 0;
        while (si < rest.len and (rest[si] == ' ' or rest[si] == '\t' or rest[si] == ':')) : (si += 1) {}
        if (si < rest.len) { 
            if (extractValueFromRest(rest[si..])) |val| return val; 
        }
        search = rest;
    }
    return null;
}

fn printFormatted(results: []const ?[]const u8, plucks: []const CompiledPluck, format: main.OutputFormat, writer: anytype) !void {
    // 8KB Stack buffer to build the line without function call overhead
    var buf: [8192]u8 = undefined;
    var cursor: usize = 0;

    // Helper to safely write bytes to the scratch buffer
    const Flush = struct {
        inline fn check(c: *usize, req: usize, b: []u8, w: anytype) !void {
            if (c.* + req > b.len) {
                try w.writeAll(b[0..c.*]);
                c.* = 0;
            }
        }
        inline fn append(c: *usize, b: []u8, val: []const u8, w: anytype) !void {
            if (val.len >= b.len) {
                try w.writeAll(b[0..c.*]);
                c.* = 0;
                try w.writeAll(val);
            } else {
                try check(c, val.len, b, w);
                @memcpy(b[c.* .. c.* + val.len], val);
                c.* += val.len;
            }
        }
    };

    if (format == .json) {
        buf[cursor] = '{'; cursor += 1;
        var first = true;
        for (results, 0..) |res, i| {
            if (res) |val| {
                if (!first) {
                    try Flush.check(&cursor, 2, &buf, writer);
                    buf[cursor] = ','; buf[cursor+1] = ' '; cursor += 2;
                }
                first = false;
                
                try Flush.check(&cursor, 1, &buf, writer);
                buf[cursor] = '"'; cursor += 1;
                
                const key = plucks[i].original_str;
                try Flush.append(&cursor, &buf, key, writer);
                
                try Flush.check(&cursor, 3, &buf, writer);
                buf[cursor] = '"'; buf[cursor+1] = ':'; buf[cursor+2] = ' '; cursor += 3;
                
                if (isFastPrimitive(val)) {
                    try Flush.append(&cursor, &buf, val, writer);
                } else {
                    try Flush.check(&cursor, 1, &buf, writer);
                    buf[cursor] = '"'; cursor += 1;
                    
                    try Flush.append(&cursor, &buf, val, writer);
                    
                    try Flush.check(&cursor, 1, &buf, writer);
                    buf[cursor] = '"'; cursor += 1;
                }
            }
        }
        try Flush.check(&cursor, 2, &buf, writer);
        buf[cursor] = '}'; buf[cursor+1] = '\n'; cursor += 2;
        try writer.writeAll(buf[0..cursor]);
        
    } else if (format == .csv) {
        for (results, 0..) |res, i| {
            if (res) |val| {
                try Flush.check(&cursor, 1, &buf, writer);
                buf[cursor] = '"'; cursor += 1;
                
                try Flush.append(&cursor, &buf, val, writer);
                
                try Flush.check(&cursor, 1, &buf, writer);
                buf[cursor] = '"'; cursor += 1;
            }
            if (i < results.len - 1) {
                try Flush.check(&cursor, 1, &buf, writer);
                buf[cursor] = ','; cursor += 1;
            }
        }
        try Flush.check(&cursor, 1, &buf, writer);
        buf[cursor] = '\n'; cursor += 1;
        try writer.writeAll(buf[0..cursor]);
        
    } else {
        for (results, 0..) |res, i| {
            if (res) |val| {
                try Flush.append(&cursor, &buf, val, writer);
            }
            if (i < results.len - 1) {
                try Flush.check(&cursor, 1, &buf, writer);
                buf[cursor] = '\t'; cursor += 1;
            }
        }
        try Flush.check(&cursor, 1, &buf, writer);
        buf[cursor] = '\n'; cursor += 1;
        try writer.writeAll(buf[0..cursor]);
    }
}

fn printAggregations(agg_states: []const AggState, plucks: []const CompiledPluck, format: main.OutputFormat, writer: anytype) !void {
    if (format == .json) {
        try writer.print("{{", .{});
        for (agg_states, 0..) |state, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("\"{s}\": ", .{plucks[i].original_str});
            switch (state) {
                .raw => try writer.print("null", .{}),
                .count => |c| try writer.print("{d}", .{c}),
                .sum => |s| try writer.print("{d:.4}", .{s}),
                .min => |m| if (m == std.math.inf(f64)) try writer.print("null", .{}) else try writer.print("{d:.4}", .{m}),
                .max => |m| if (m == -std.math.inf(f64)) try writer.print("null", .{}) else try writer.print("{d:.4}", .{m}),
            }
        }
        try writer.print("}}\n", .{});
    } else if (format == .csv) {
        for (agg_states, 0..) |state, i| {
            switch (state) {
                .raw => {},
                .count => |c| try writer.print("{d}", .{c}),
                .sum => |s| try writer.print("{d:.4}", .{s}),
                .min => |m| if (m == std.math.inf(f64)) {} else try writer.print("{d:.4}", .{m}),
                .max => |m| if (m == -std.math.inf(f64)) {} else try writer.print("{d:.4}", .{m}),
            }
            if (i < agg_states.len - 1) try writer.print(",", .{});
        }
        try writer.print("\n", .{});
    } else {
        for (agg_states, 0..) |state, i| {
            switch (state) {
                .raw => {},
                .count => |c| try writer.print("{d}", .{c}),
                .sum => |s| try writer.print("{d:.4}", .{s}),
                .min => |m| if (m == std.math.inf(f64)) {} else try writer.print("{d:.4}", .{m}),
                .max => |m| if (m == -std.math.inf(f64)) {} else try writer.print("{d:.4}", .{m}),
            }
            if (i < agg_states.len - 1) try writer.print("\t", .{});
        }
        try writer.print("\n", .{});
    }
}

fn handleMatch(line: []const u8, plan: CompiledPlan, agg_states: []AggState, writer: anytype) !void {
    const pluck_keys = plan.pluck;
    if (pluck_keys.len == 0) {
        try writer.print("{s}\n", .{line});
        return;
    }

    var results: [256]?[]const u8 = undefined;
    const max_keys = @min(pluck_keys.len, 256);
    @memset(results[0..max_keys], null);
    
    if (pluck_keys.len == 1) {
        if (extractValueSingle(line, pluck_keys[0].key_quoted)) |val| {
            results[0] = val;
        }
    } else {
        var found_count: usize = 0;
        var search = line;
        while (search.len > 0 and found_count < max_keys) {
            const quote_idx = std.mem.indexOfScalar(u8, search, '"') orelse break;
            search = search[quote_idx..]; 
            
            const end_quote_idx = std.mem.indexOfScalar(u8, search[1..], '"');
            if (end_quote_idx == null) break;
            
            const full_key = search[0 .. end_quote_idx.? + 2];
            search = search[end_quote_idx.? + 2 ..];
            
            if (std.mem.indexOfNone(u8, search, " \t")) |colon_pos|
            {
                if (search[colon_pos] == ':') {
                    const rest = search[colon_pos + 1 ..];
                    if (std.mem.indexOfNone(u8, rest, " \t")) |val_start| {
                        if (extractValueFromRest(rest[val_start..])) |val|
                        {
                            // FIX: Assign the extracted value to ALL pluck keys that want it!
                            for (pluck_keys[0..max_keys], 0..) |pk, i| {
                                if (results[i] == null and std.mem.eql(u8, full_key, pk.key_quoted)) {
                                    results[i] = val;
                                    found_count += 1;
                                }
                            }

                            if (rest[val_start] == '"') {
                                search = rest[val_start + val.len + 2 ..]; 
                            } else {
                                search = rest[val_start + val.len ..];
                            }
                            continue;
                        }
                    }
                }
            }
        }
    }

    if (plan.has_aggregations) {
        for (0..max_keys) |i| {
            if (results[i]) |val| {
                switch (pluck_keys[i].ptype) {
                    .raw => {},
                    .count => agg_states[i].count += 1,
                    .sum => { if (std.fmt.parseFloat(f64, val)) |f| agg_states[i].sum += f else |_| {} },
                    .min => { if (std.fmt.parseFloat(f64, val)) |f| agg_states[i].min = @min(agg_states[i].min, f) else |_| {} },
                    .max => { if (std.fmt.parseFloat(f64, val)) |f| agg_states[i].max = @max(agg_states[i].max, f) else |_| {} },
                }
            }
        }
    } else {
        try printFormatted(results[0..max_keys], pluck_keys[0..max_keys], plan.format, writer);
    }
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

pub fn searchFile(allocator: std.mem.Allocator, config: main.Config, writer: anytype) !void {
    const file = try std.fs.cwd().openFile(config.file_path.?, .{});
    defer file.close();
    try searchFileInternal(allocator, file, config, writer);
}

pub fn searchStream(allocator: std.mem.Allocator, config: main.Config, writer: anytype) !void {
    try searchFileInternal(allocator, std.io.getStdIn(), config, writer);
}

fn searchFileInternal(allocator: std.mem.Allocator, file: std.fs.File, config: main.Config, writer: anytype) !void {
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
        };
    }

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
                    if (evaluatePlan(line, plan)) try handleMatch(line, plan, agg_states, writer);
                    sol = i + nl_pos + 1;
                    iter &= iter - 1;
                }
            }
        }
        while (sol < data.len) {
            if (std.mem.indexOfScalar(u8, data[sol..], '\n')) |nl_pos| {
                const line = data[sol .. sol + nl_pos];
                if (evaluatePlan(line, plan)) try handleMatch(line, plan, agg_states, writer);
                sol += nl_pos + 1;
            } else break;
        }
        if (ctx.done.load(.acquire) and sol < data.len) {
            const line = std.mem.trimRight(u8, data[sol..], "\r\n");
            if (line.len > 0 and evaluatePlan(line, plan)) try handleMatch(line, plan, agg_states, writer);
            sol = data.len;
        }
        consume_idx = 1 - consume_idx;
        read_sem.post();
        if (ctx.done.load(.acquire) and fill_sem.permits == 0) break;
    }
    thread.join();

    if (plan.has_aggregations) {
        try printAggregations(agg_states, plan.pluck, plan.format, writer);
    }
}