const std = @import("std");
const main = @import("main.zig");

// ==========================================
// QUERY COMPILER & EVALUATOR
// ==========================================

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
};

// Helper to detect JSON primitives (numbers, booleans, null)
fn isPrimitive(val: []const u8) bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return true;
    if (std.mem.eql(u8, val, "null")) return true;
    
    // If it parses as a float, treat it as a raw number
    _ = std.fmt.parseFloat(f64, val) catch return false;
    return true;
}

fn compilePlan(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: ?[]const u8) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, groups.len);
    for (groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            const key_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.key});
            
            // 1. Explicitly quoted by user (e.g., '"99"') -> Leave it alone
            // 2. Auto-detected primitive (e.g., 99 or true) -> Leave it alone
            // 3. Normal string (e.g., critical) -> Wrap it in quotes
            const val_quoted = if (c.val.len >= 2 and c.val[0] == '"' and c.val[c.val.len - 1] == '"')
                try std.fmt.allocPrint(allocator, "{s}", .{c.val})
            else if (isPrimitive(c.val))
                try std.fmt.allocPrint(allocator, "{s}", .{c.val})
            else
                try std.fmt.allocPrint(allocator, "\"{s}\"", .{c.val});

            comp_conds[j] = .{
                .key_quoted = key_quoted,
                .val_quoted = val_quoted,
            };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }
    var pluck_quoted: ?[]const u8 = null;
    if (pluck) |p| pluck_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{p});
    return CompiledPlan{ .groups = comp_groups, .pluck_quoted = pluck_quoted };
}

inline fn evaluatePlan(line: []const u8, plan: CompiledPlan) bool {
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
    return false;
}

// ==========================================
// SIMD SCANNER (NEON/AVX2)
// ==========================================
fn lineMatches(line: []const u8, key_quoted: []const u8, val_quoted: []const u8) bool {
    const vector_len = 32;
    const V = @Vector(vector_len, u8);
    const first_char_vec: V = @splat(key_quoted[0]);
    
    var i: usize = 0;
    while (i + vector_len <= line.len) {
        const chunk: V = line[i..][0..vector_len].*;
        const matches = chunk == first_char_vec;

        if (@reduce(.Or, matches)) {
            var mask = @as(u32, @bitCast(matches));
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const pos = i + bit_pos;
                if (std.mem.startsWith(u8, line[pos..], key_quoted)) {
                    const rest = line[pos + key_quoted.len..];
                    if (std.mem.indexOfNone(u8, rest, " \t:")) |start_idx| {
                        
                        // --- BOUNDARY CHECK ---
                        if (std.mem.startsWith(u8, rest[start_idx..], val_quoted)) {
                            const match_end = start_idx + val_quoted.len;
                            // If it's a string (ends in quote), the exact match is perfect.
                            if (val_quoted[val_quoted.len - 1] == '"') {
                                return true;
                            } 
                            // If it's a primitive (number/bool), check the boundary char
                            else if (match_end < rest.len) {
                                const next_c = rest[match_end];
                                // Valid JSON boundaries after a primitive
                                if (next_c == ',' or next_c == '}' or next_c == ']' or next_c == ' ' or next_c == '\t' or next_c == '\r' or next_c == '\n') {
                                    return true;
                                }
                            } else {
                                // Hit the end of the line
                                return true;
                            }
                        }
                    }
                }
                mask &= mask - 1;
            }
        }
        i += vector_len;
    }

    var tail = line[i..];
    while (std.mem.indexOf(u8, tail, key_quoted)) |key_pos| {
        const rest = tail[key_pos + key_quoted.len..];
        if (std.mem.indexOfNone(u8, rest, " \t:")) |start_idx| {
            
            // --- BOUNDARY CHECK (TAIL) ---
            if (std.mem.startsWith(u8, rest[start_idx..], val_quoted)) {
                const match_end = start_idx + val_quoted.len;
                if (val_quoted[val_quoted.len - 1] == '"') {
                    return true;
                } else if (match_end < rest.len) {
                    const next_c = rest[match_end];
                    if (next_c == ',' or next_c == '}' or next_c == ']' or next_c == ' ' or next_c == '\t' or next_c == '\r' or next_c == '\n') {
                        return true;
                    }
                } else {
                    return true;
                }
            }
        }
        tail = rest;
    }
    return false;
}

fn extractValue(line: []const u8, pluck_key_quoted: []const u8) ?[]const u8 {
    var search_slice = line;
    while (std.mem.indexOf(u8, search_slice, pluck_key_quoted)) |key_pos| {
        const rest = search_slice[key_pos + pluck_key_quoted.len ..];
        const start_idx = std.mem.indexOfNone(u8, rest, " \t:") orelse return null;
        const val_start = rest[start_idx..];
        if (val_start.len == 0) return null;

        if (val_start[0] == '"') {
            const content_start = 1;
            var i: usize = content_start;
            while (i < val_start.len) : (i += 1) {
                if (val_start[i] == '"') {
                    var backslash_count: usize = 0;
                    var j = i;
                    while (j > content_start) {
                        j -= 1;
                        if (val_start[j] == '\\') {
                            backslash_count += 1;
                        } else break;
                    }
                    if (backslash_count % 2 == 0) return val_start[content_start..i];
                }
            }
        } else {
            var i: usize = 0;
            while (i < val_start.len) : (i += 1) {
                const c = val_start[i];
                if (c == ',' or c == '}' or c == ' ' or c == '\r' or c == '\n') return val_start[0..i];
            }
            return val_start;
        }
        search_slice = rest;
    }
    return null;
}

fn handleMatch(line: []const u8, pluck_key_quoted: ?[]const u8, writer: anytype) !void {
    if (pluck_key_quoted) |pk| {
        if (extractValue(line, pk)) |val| {
            try writer.print("{s}\n", .{val});
        }
    } else {
        try writer.print("{s}\n", .{line});
    }
}

// ==========================================
// STABLE PRODUCER-CONSUMER
// ==========================================

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

fn readerThread(ctx: *ReaderCtx) void {
    var leftover_count: usize = 0;
    var leftover_buf: [2 * 1024 * 1024]u8 = undefined;

    while (true) {
        ctx.read_sem.wait();
        const buf = &ctx.bufs[ctx.current_idx];
        
        // 1. Copy over leftover from previous read
        if (leftover_count > 0) {
            @memcpy(buf.data[0..leftover_count], leftover_buf[0..leftover_count]);
        }

        // 2. Read new data
        const read_count = ctx.file.read(buf.data[leftover_count..]) catch 0;
        
        if (read_count == 0) {
            buf.len = leftover_count;
            ctx.done.store(true, .release);
            ctx.fill_sem.post();
            break;
        }

        const total_in_buf = leftover_count + read_count;
        
        // 3. Find line boundary and save leftover for next round
        if (std.mem.lastIndexOfScalar(u8, buf.data[0..total_in_buf], '\n')) |idx| {
            const boundary = idx + 1;
            const new_leftover = total_in_buf - boundary;
            if (new_leftover > 0) {
                @memcpy(leftover_buf[0..new_leftover], buf.data[boundary..total_in_buf]);
            }
            leftover_count = new_leftover;
            buf.len = boundary;
        } else {
            // Buffer didn't contain a newline (extremely long line)
            buf.len = total_in_buf;
            leftover_count = 0;
        }

        ctx.current_idx = 1 - ctx.current_idx;
        ctx.fill_sem.post();
    }
}
pub fn searchFile(allocator: std.mem.Allocator, file_path: []const u8, groups: []const main.ConditionGroup, pluck: ?[]const u8, writer: anytype) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compilePlan(arena.allocator(), groups, pluck);

    var fill_sem = std.Thread.Semaphore{ .permits = 0 };
    var read_sem = std.Thread.Semaphore{ .permits = 2 };

    const buf_size = 8 * 1024 * 1024;
    var ctx = ReaderCtx{
        .file = file,
        .bufs = .{
            .{ .data = try allocator.alloc(u8, buf_size) },
            .{ .data = try allocator.alloc(u8, buf_size) },
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
        
        // Break condition
        if (buf.len == 0 and ctx.done.load(.acquire)) break;

        const data = buf.data[0..buf.len];
        var start_of_line: usize = 0;
        var i: usize = 0;
        const vector_len = 32;
        const V = @Vector(vector_len, u8);
        const nl_vec: V = @splat('\n');

        while (i + vector_len <= data.len) : (i += vector_len) {
            const chunk: V = data[i..][0..vector_len].*;
            const mask = @as(u32, @bitCast(chunk == nl_vec));
            if (mask != 0) {
                var iter_mask = mask;
                while (iter_mask != 0) {
                    const nl_pos = @ctz(iter_mask);
                    const abs_nl = i + nl_pos;
                    const line = data[start_of_line..abs_nl];
                    if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_quoted, writer);
                    start_of_line = abs_nl + 1;
                    iter_mask &= iter_mask - 1;
                }
            }
        }

        // Catch the remainder of the buffer that wasn't reached by the SIMD step
        // (This happens if the buffer size isn't a multiple of 32)
        while (start_of_line < data.len) {
            if (std.mem.indexOfScalar(u8, data[start_of_line..], '\n')) |nl_pos| {
                const abs_nl = start_of_line + nl_pos;
                const line = data[start_of_line..abs_nl];
                if (evaluatePlan(line, plan)) try handleMatch(line, plan.pluck_quoted, writer);
                start_of_line = abs_nl + 1;
            } else break;
        }

        consume_idx = 1 - consume_idx;
        read_sem.post();
        if (ctx.done.load(.acquire) and fill_sem.permits == 0) break;
    }
    thread.join();

    // If the file didn't end with a newline, there is still data in the 'next' buffer
    // that the reader thread moved to the start but then hit EOF.
    const final_buf = &ctx.bufs[ctx.current_idx];
    if (final_buf.len > 0) {
        // Trim any trailing garbage and process the very last line
        const line = std.mem.trimRight(u8, final_buf.data[0..final_buf.len], "\r\n");
        if (line.len > 0 and evaluatePlan(line, plan)) {
            try handleMatch(line, plan.pluck_quoted, writer);
        }
    }
}

pub fn searchStream(allocator: std.mem.Allocator, groups: []const main.ConditionGroup, pluck: ?[]const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compilePlan(arena.allocator(), groups, pluck);

    const buffer_size = 1024 * 1024;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);
    
    var bytes_in_buffer: usize = 0;
    const stdin = std.io.getStdIn().reader();

    const vector_len = 32;
    const V = @Vector(vector_len, u8);
    const nl_vec: V = @splat('\n');

    while (true) {
        const read_count = try stdin.read(buffer[bytes_in_buffer..]);
        if (read_count == 0 and bytes_in_buffer == 0) break;
        const total_data = bytes_in_buffer + read_count;
        var start_of_line: usize = 0;
        var i: usize = 0;

        while (i + vector_len <= total_data) : (i += vector_len) {
            const chunk: V = buffer[i..][0..vector_len].*;
            const mask = @as(u32, @bitCast(chunk == nl_vec));
            if (mask != 0) {
                var iter_mask = mask;
                while (iter_mask != 0) {
                    const nl_pos = @ctz(iter_mask);
                    const abs_nl = i + nl_pos;
                    if (evaluatePlan(buffer[start_of_line..abs_nl], plan)) {
                        try handleMatch(buffer[start_of_line..abs_nl], plan.pluck_quoted, writer);
                    }
                    start_of_line = abs_nl + 1;
                    iter_mask &= iter_mask - 1;
                }
            }
        }

        if (start_of_line < total_data) {
            bytes_in_buffer = total_data - start_of_line;
            std.mem.copyForwards(u8, buffer[0..bytes_in_buffer], buffer[start_of_line..total_data]);
        } else bytes_in_buffer = 0;
        if (read_count == 0) break;
    }
}
// ==========================================
// TEST SUITE
// ==========================================

const testing = std.testing;

// Helper to compile a single key-val condition and test a JSON line against it
fn expectMatch(line: []const u8, key: []const u8, val: []const u8, expected: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 1. Create a mutable array of conditions
    var conds = [_]main.Condition{.{ .key = key, .val = val }};
    
    // 2. Create a mutable array of groups pointing to our conditions
    var groups = [_]main.ConditionGroup{.{ .conditions = &conds }};
    
    // 3. Compile the plan
    const plan = try compilePlan(arena.allocator(), &groups, null);
    
    const result = evaluatePlan(line, plan);
    if (result != expected) {
        std.debug.print("\nFAIL:\n  Line: {s}\n  Key: {s}\n  Val: {s}\n  Expected: {}\n  Got: {}\n", .{line, key, val, expected, result});
    }
    try testing.expectEqual(expected, result);
}

// Helper to test pluck extraction
fn expectPluck(line: []const u8, pluck_key: []const u8, expected: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const pk_quoted = try std.fmt.allocPrint(arena.allocator(), "\"{s}\"", .{pluck_key});
    const result = extractValue(line, pk_quoted);
    
    if (expected) |exp| {
        try testing.expect(result != null);
        try testing.expectEqualStrings(exp, result.?);
    } else {
        try testing.expect(result == null);
    }
}

test "Scanner: Standard String Matching" {
    // Exact matches
    try expectMatch("{\"level\": \"error\"}", "level", "error", true);
    try expectMatch("{\"service\": \"auth-api\", \"level\": \"error\"}", "service", "auth-api", true);
    
    // Substring trap: value shouldn't match if it's just a prefix in the JSON
    try expectMatch("{\"level\": \"error\"}", "level", "err", false);
    
    // Key substring trap: make sure key isn't a substring match
    try expectMatch("{\"sublevel\": \"error\"}", "level", "error", false);
}

test "Scanner: Number Primitives & Boundaries" {
    // Exact integer matches
    try expectMatch("{\"load\": 99}", "load", "99", true);
    try expectMatch("{\"load\": -42}", "load", "-42", true);
    try expectMatch("{\"load\": 0}", "load", "0", true);

    // Exact float matches
    try expectMatch("{\"load\": 99.0}", "load", "99.0", true);
    try expectMatch("{\"load\": 99.55}", "load", "99.55", true);

    // Decimal boundary traps (Should FAIL)
    try expectMatch("{\"load\": 99.0}", "load", "99", false);
    try expectMatch("{\"load\": 99.5}", "load", "99", false);
    
    // Adjacent number traps (Should FAIL)
    try expectMatch("{\"load\": 995}", "load", "99", false);
    try expectMatch("{\"load\": 199}", "load", "99", false);

    // Valid JSON boundaries for primitives
    try expectMatch("{\"load\": 99}", "load", "99", true); 
    try expectMatch("{\"load\": 99, \"other\": 1}", "load", "99", true); 
    try expectMatch("[{\"load\": 99}]", "load", "99", true); 
    try expectMatch("{\"load\": 99 \n}", "load", "99", true); 
}

test "Scanner: Boolean and Null Primitives" {
    // Exact matches
    try expectMatch("{\"active\": true}", "active", "true", true);
    try expectMatch("{\"active\": false}", "active", "false", true);
    try expectMatch("{\"user\": null}", "user", "null", true);

    // Substring trap (Should FAIL)
    try expectMatch("{\"active\": trueFalse}", "active", "true", false);
    try expectMatch("{\"active\": true123}", "active", "true", false);
}

test "Scanner: Explicit Quoting (Overrides)" {
    // User searches for the STRING "99" (passed as '"99"' from shell)
    try expectMatch("{\"load\": \"99\"}", "load", "\"99\"", true);
    try expectMatch("{\"load\": 99}", "load", "\"99\"", false); // It's a number in JSON

    // User searches for the STRING "true" (passed as '"true"' from shell)
    try expectMatch("{\"active\": \"true\"}", "active", "\"true\"", true);
    try expectMatch("{\"active\": true}", "active", "\"true\"", false); // It's a bool in JSON
}

test "Scanner: Whitespace and Formatting Resilience" {
    // Spacing between key, colon, and value
    try expectMatch("{\"load\" : 99}", "load", "99", true);
    try expectMatch("{\"load\":  99}", "load", "99", true);
    try expectMatch("{\"load\"   :   99}", "load", "99", true);
    try expectMatch("{\"level\" : \"error\"}", "level", "error", true);

    // Value followed by weird whitespace
    try expectMatch("{\"load\": 99 \t, \"x\": 1}", "load", "99", true);
}

test "Scanner: Data Plucking (extractValue)" {
    // Pluck basic strings
    try expectPluck("{\"msg\": \"hello\"}", "msg", "hello");
    try expectPluck("{\"msg\": \"hello world\", \"id\": 1}", "msg", "hello world");
    
    // Pluck primitives
    try expectPluck("{\"load\": 99.5, \"id\": 1}", "load", "99.5");
    try expectPluck("{\"active\": true, \"id\": 1}", "active", "true");
    try expectPluck("{\"user\": null}", "user", "null");

    // Pluck with weird spacing/boundaries
    try expectPluck("{\"load\": 99}", "load", "99");
    try expectPluck("{\"load\": 99\n}", "load", "99");

    // Pluck with escaped quotes inside the string
    try expectPluck("{\"msg\": \"he \\\"said\\\" hi\"}", "msg", "he \\\"said\\\" hi");
    
    // Missing keys
    try expectPluck("{\"level\": \"info\"}", "msg", null);
}