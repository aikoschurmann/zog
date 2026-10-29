//! Runs a query over a file or stdin: a reader thread fills blocks while the search scans them.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const json = @import("json.zig");
const finder = @import("finder.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");
const match = @import("match.zig");
const output = @import("output.zig");

const MultiFinder = finder.MultiFinder;
const findNewline = finder.findNewline;
const lastNewline = finder.lastNewline;
const CompiledPlan = compile.CompiledPlan;
const CompiledGroup = compile.CompiledGroup;
const CompiledCondition = compile.CompiledCondition;
const compilePlan = compile.compilePlan;
const Value = values.Value;
const Scratch = values.Scratch;
const extractField = values.extractField;
const slotValue = values.slotValue;
const valueMatches = match.valueMatches;
const nextPassing = match.nextPassing;
const lineMatches = match.lineMatches;
const evaluatePlan = match.evaluatePlan;
const AggState = output.AggState;
const accumulate = output.accumulate;
const printFormatted = output.printFormatted;
const printAggregations = output.printAggregations;
const printHeader = output.printHeader;

const BLOCK_SIZE = 8 * 1024 * 1024;
/// Pipe input is handed over in small blocks: the consumer then scans data the reader just
/// copied while it is still in L2. Measured ~20% faster than full blocks for `cat | zog`.
const STREAM_BLOCK_SIZE = 128 * 1024;

const Search = struct {
    plan: *const CompiledPlan,
    agg_states: []AggState,
    writer: *std.Io.Writer,
    /// Per anchor: whether it passed at the key occurrence being evaluated.
    passed: []bool,
    scratch: Scratch,
    /// The exact layer. After a successful `exactLineMatches`, its slots hold the line's values.
    parser: *json.Parser,
    match_count: usize = 0,

    /// Records a matching line. Returns true once the match limit is reached.
    fn emit(self: *Search, line_raw: []const u8) !bool {
        self.match_count += 1;
        const reached = if (self.plan.limit) |limit| self.match_count >= limit else false;
        const plan = self.plan;
        if (plan.count_only) return reached;
        const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r') line_raw[0 .. line_raw.len - 1] else line_raw;
        if (plan.pluck.len == 0) {
            try self.writer.writeAll(line);
            try self.writer.writeByte('\n');
            return reached;
        }

        var results: [cli.MAX_PLUCK_FIELDS]?Value = undefined;
        for (plan.pluck, 0..) |*pk, i| {
            results[i] = if (plan.exact)
                slotValue(self.parser.slots[pk.slot])
            else if (pk.same_as) |j| results[j] else extractField(line, &pk.finder);
        }

        if (plan.has_aggregations) {
            for (results[0..plan.pluck.len], self.agg_states) |res, *state| {
                if (res) |v| try accumulate(state, v, &self.scratch);
            }
        } else {
            try printFormatted(results[0..plan.pluck.len], plan.pluck, plan.format, self.writer);
        }
        return reached;
    }

    /// Processes a block of lines. Every block ends with a newline except possibly the last.
    /// Returns true once the match limit is reached.
    fn scanBlock(self: *Search, data: []const u8) !bool {
        const plan = self.plan;
        if (plan.exact) {
            if (plan.anchors.len > 0 and plan.prefilter) return self.scanAnchored(true, data);
            return self.scanLines(true, data);
        }
        if (plan.anchors.len > 0) return self.scanAnchored(false, data);
        return self.scanLines(false, data);
    }

    /// Searches the whole block for each group's anchor and only looks at lines where one
    /// passes, so other lines are never split out or evaluated. The anchor streams are
    /// merged by position to keep matches in input order.
    ///
    /// In exact mode the search also stops at escapes that could hide an anchor, and sends
    /// those lines to the parser. Lines with a passing anchor go through a byte-level check
    /// of the other conditions first, which only rules a line out when it provably can't
    /// match.
    fn scanAnchored(self: *Search, comptime exact: bool, data: []const u8) !bool {
        const plan = self.plan;
        var sol: usize = 0; // start of the first line not yet evaluated
        var pos: usize = 0;
        while (if (exact) plan.anchor_finder.nextOrHazard(data, pos) else plan.anchor_finder.next(data, pos)) |mh| {
            const hazard = exact and mh.key == MultiFinder.hazard_key;
            var any = hazard;
            if (!hazard) {
                for (plan.anchors, plan.anchor_keys, self.passed) |a, ki, *p| {
                    p.* = ki == mh.key and (a.op == .exists or try valueMatches(data[mh.hit.val_pos..], a, &self.scratch));
                    any = any or p.*;
                }
            }
            if (!any) {
                pos = mh.pos + 1;
                continue;
            }
            const ls = if (lastNewline(data, sol, mh.hit.key_pos)) |nl| nl + 1 else sol;
            const le = std.mem.findScalarPos(u8, data, mh.hit.key_pos, '\n') orelse data.len;
            const line = data[ls..le];
            const matches = if (exact)
                (hazard or plan.hazards.inLine(line) or try self.anchoredLineMatches(true, line, mh.hit.key_pos - ls)) and
                    try self.exactLineMatches(line)
            else
                try self.anchoredLineMatches(false, line, mh.hit.key_pos - ls);
            if (matches) {
                if (try self.emit(line)) return true;
            }
            sol = @min(le + 1, data.len);
            pos = sol;
        }
        return false;
    }

    /// Evaluates a line whose first passing anchor occurrence has its key at `off`. Groups
    /// whose anchor passed there only need their other conditions checked. Every anchor
    /// failed at all earlier occurrences, so the others only need the rest of the line searched.
    ///
    /// With `prefilter`, negated conditions are skipped: the bytes can show that a key is
    /// absent, not that the value at its path fails. The line must then be free of hazards.
    fn anchoredLineMatches(self: *Search, comptime prefilter: bool, line: []const u8, off: usize) !bool {
        const plan = self.plan;
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, p| {
            if (p and try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, p| {
            if (p) continue;
            if (try nextPassing(anchor, line, off, &self.scratch) == null) continue;
            if (try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        return false;
    }

    fn otherConditionsMatch(self: *Search, comptime prefilter: bool, line: []const u8, group: *const CompiledGroup, anchor: *const CompiledCondition) !bool {
        for (group.conditions) |*cond| {
            if (cond == anchor or (prefilter and cond.negated)) continue;
            if (try lineMatches(line, cond, &self.scratch) == cond.negated) return false;
        }
        return true;
    }

    /// Parses the line and evaluates the plan on the values at the query's paths. Invalid
    /// lines never match.
    fn exactLineMatches(self: *Search, line: []const u8) !bool {
        self.parser.parse(line) catch return false;
        const slots = self.parser.slots;
        if (self.plan.groups.len == 0) return true;
        for (self.plan.groups) |*group| {
            for (group.conditions) |*cond| {
                const pass = if (slots[cond.slot]) |vs| try valueMatches(vs, cond, &self.scratch) else false;
                if (pass == cond.negated) break;
            } else return true;
        }
        return false;
    }

    fn scanLines(self: *Search, comptime exact: bool, data: []const u8) !bool {
        var sol: usize = 0;
        while (sol < data.len) {
            const nl = findNewline(data, sol);
            const line = data[sol..nl];
            const matches = if (exact) try self.exactLineMatches(line) else try evaluatePlan(line, self.plan, &self.scratch);
            if (matches) {
                if (try self.emit(line)) return true;
            }
            sol = nl + 1;
        }
        return false;
    }
};

const Buffer = struct { data: []u8, len: usize = 0, eof: bool = false };

const ReaderCtx = struct {
    file: std.Io.File,
    io: std.Io,
    /// Input is a pipe or terminal: hand data over as soon as nothing more is immediately
    /// readable instead of waiting for a full block.
    streaming: bool,
    bufs: [2]Buffer,
    stop: std.atomic.Value(bool) = .init(false),
    read_err: ?anyerror = null,
    fill_sem: std.Io.Semaphore = .{ .permits = 0 },
    read_sem: std.Io.Semaphore = .{ .permits = 2 },
};

fn dataReady(file: std.Io.File) bool {
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&fds, 0) catch return false) > 0;
}

/// Reads into `buf` until it is full, or for streaming input until a small block is
/// gathered or nothing more is immediately readable (so `tail -f` matches show up right
/// away). Always reads at least once. Returns true at end of input or on a read error.
fn fillBuffer(ctx: *ReaderCtx, buf: *Buffer, total: *usize) bool {
    while (total.* < buf.data.len) {
        const n = ctx.file.readStreaming(ctx.io, &.{buf.data[total.*..]}) catch |err| {
            if (err != error.EndOfStream) ctx.read_err = err;
            return true;
        };
        if (n == 0) return true;
        total.* += n;
        if (ctx.streaming and (total.* >= STREAM_BLOCK_SIZE or !dataReady(ctx.file))) return false;
    }
    return false;
}

fn growBuffer(buf: *Buffer, new_len: usize) !void {
    buf.data = try std.heap.page_allocator.realloc(buf.data, new_len);
}

fn readerThread(ctx: *ReaderCtx) void {
    const io = ctx.io;
    var idx: usize = 0;
    // Partial last line of the previously filled buffer. It sits past that buffer's `len`,
    // which the consumer never reads, so it can be copied straight into the next buffer.
    var carry: []const u8 = &.{};

    while (true) {
        ctx.read_sem.wait(io) catch return;
        if (ctx.stop.load(.acquire)) return;
        const buf = &ctx.bufs[idx];

        if (carry.len + BLOCK_SIZE / 2 > buf.data.len) {
            growBuffer(buf, carry.len + BLOCK_SIZE) catch |err| {
                ctx.read_err = err;
                buf.len = 0;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            };
        }
        @memcpy(buf.data[0..carry.len], carry);
        var total = carry.len;
        var scanned = carry.len; // the carried bytes contain no newline

        while (true) {
            if (fillBuffer(ctx, buf, &total)) {
                buf.len = total;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            }
            if (lastNewline(buf.data, scanned, total)) |nl| {
                buf.len = nl + 1;
                carry = buf.data[nl + 1 .. total];
                break;
            }
            // No complete line yet: keep reading, growing the buffer if a line outgrew it.
            scanned = total;
            if (total == buf.data.len) {
                growBuffer(buf, buf.data.len * 2) catch |err| {
                    ctx.read_err = err;
                    buf.len = total;
                    buf.eof = true;
                    ctx.fill_sem.post(io);
                    return;
                };
            }
        }
        ctx.fill_sem.post(io);
        idx = 1 - idx;
    }
}

/// Returns true when all input was consumed, false when the match limit stopped it early.
fn consume(search: *Search, ctx: *ReaderCtx, io: std.Io) !bool {
    var idx: usize = 0;
    while (true) {
        try ctx.fill_sem.wait(io);
        const buf = &ctx.bufs[idx];
        const limit_reached = try search.scanBlock(buf.data[0..buf.len]);
        // Flush per block so streaming input (`tail -f`) produces output as it arrives.
        try search.writer.flush();
        if (limit_reached) return false;
        if (buf.eof) {
            if (ctx.read_err) |err| return err;
            return true;
        }
        ctx.read_sem.post(io);
        idx = 1 - idx;
    }
}

fn runSearch(search: *Search, file: std.Io.File, io: std.Io) !void {
    // When we stop early the reader may be blocked in a read that never returns (e.g. on
    // `tail -f`), so it is detached rather than joined. Its context and buffers must then
    // outlive this function, so they come from page_allocator and are freed only after a join.
    const pa = std.heap.page_allocator;
    const ctx = try pa.create(ReaderCtx);
    ctx.* = .{
        .file = file,
        .io = io,
        .streaming = if (file.stat(io)) |st| st.kind != .file else |_| true,
        .bufs = .{ .{ .data = try pa.alloc(u8, BLOCK_SIZE) }, .{ .data = try pa.alloc(u8, BLOCK_SIZE) } },
    };
    const thread = try std.Thread.spawn(.{}, readerThread, .{ctx});

    const finished = consume(search, ctx, io) catch |err| {
        abandonReader(ctx, thread, io);
        return err;
    };
    if (!finished) return abandonReader(ctx, thread, io);

    thread.join();
    pa.free(ctx.bufs[0].data);
    pa.free(ctx.bufs[1].data);
    pa.destroy(ctx);
}

fn abandonReader(ctx: *ReaderCtx, thread: std.Thread, io: std.Io) void {
    ctx.stop.store(true, .release);
    ctx.read_sem.post(io);
    thread.detach();
}

pub fn searchFile(allocator: std.mem.Allocator, config: cli.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    const file = try std.Io.Dir.cwd().openFile(io, config.file_path.?, .{});
    defer file.close(io);
    return try searchFileInternal(allocator, file, config, writer, io);
}

pub fn searchStream(allocator: std.mem.Allocator, config: cli.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    return try searchFileInternal(allocator, std.Io.File.stdin(), config, writer, io);
}

fn searchFileInternal(allocator: std.mem.Allocator, file: std.Io.File, config: cli.Config, writer: *std.Io.Writer, io: std.Io) !usize {
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
            .avg => .{ .avg = .{ .sum = 0.0, .count = 0 } },
        };
    }

    try printHeader(&plan, writer);

    const parser = try arena.allocator().create(json.Parser);
    parser.* = .{ .trie = &plan.trie, .slots = try arena.allocator().alloc(?[]const u8, plan.trie.slot_count) };
    var search: Search = .{
        .plan = &plan,
        .agg_states = agg_states,
        .writer = writer,
        .passed = try arena.allocator().alloc(bool, plan.anchors.len),
        .scratch = .{ .gpa = arena.allocator() },
        .parser = parser,
    };
    const limit_zero = if (plan.limit) |limit| limit == 0 else false;
    if (!limit_zero) try runSearch(&search, file, io);

    if (plan.count_only) {
        try writer.print("{d}\n", .{search.match_count});
    } else if (plan.has_aggregations) {
        try printAggregations(agg_states, plan.pluck, plan.format, writer);
    }
    return search.match_count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = json;
    _ = finder;
    _ = values;
}

/// Runs a query on `input`, returning its output (allocated in `a`).
fn runTestQuery(a: std.mem.Allocator, input: []const u8, config: cli.Config) ![]const u8 {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = input });
    const file = try tmp.dir.openFile(io, "in.jsonl", .{});
    defer file.close(io);

    var out: std.Io.Writer.Allocating = .init(a);
    _ = try searchFileInternal(a, file, config, &out.writer, io);
    return out.written();
}

fn expectQuery(input: []const u8, args: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try cli.parseArgs(a, args)).run;
    try testing.expectEqualStrings(expected, try runTestQuery(a, input, config));
    if (!config.fast) {
        // The prefilter never changes the result.
        var unfiltered = config;
        unfiltered.prefilter = false;
        try testing.expectEqualStrings(expected, try runTestQuery(a, input, unfiltered));
    }
}

const demo =
    \\{"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
    \\{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
    \\{"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
    \\{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
    \\{"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
    \\
;

test "README examples" {
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30", "AND", "tier", "gt", "2" }, "Charlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "tier", "eq", "5" }, "Alice\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "NOT", "age", "eq", "30" }, "Alice\nDave\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "age", "eq", "30", "AND", "balance", "lt", "0" }, "Alice\nBob\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "name", "has", "li" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "in", "1,3,5" }, "Alice\nCharlie\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "Bob\t2\nCharlie\t3\nEve\t5\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "s:100" }, "Eve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "n:100" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "active", "eq", "b:true" }, "Alice\nCharlie\nDave\n");
    try expectQuery(demo, &.{ "--count", "tier", "gte", "2" }, "4\n");
    try expectQuery(demo, &.{ "SELECT", "min:age,max:age", "WHERE", "active", "eq", "true" }, "25.0000\t45.0000\n");
    try expectQuery(demo, &.{ "--format", "json", "SELECT", "count:name,sum:balance", "WHERE", "tier", "gte", "2" }, "{\"count:name\": 4, \"sum:balance\": 5049.7400}\n");
    try expectQuery(demo, &.{ "--limit", "2", "SELECT", "name", "WHERE", "active", "eq", "true" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "--header", "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "name\ttier\nBob\t2\nCharlie\t3\nEve\t5\n");
}

test "json output keeps string values quoted" {
    try expectQuery(
        "{\"name\":\"nancy\",\"id\":\"42\",\"n\":7,\"t\":true,\"o\":{\"a\":[1, 2]}}\n",
        &.{ "--format", "json", "SELECT", "name,id,n,t,o,missing" },
        "{\"name\": \"nancy\", \"id\": \"42\", \"n\": 7, \"t\": true, \"o\": {\"a\":[1, 2]}, \"missing\": null}\n",
    );
}

test "json output skips header and escapes keys" {
    try expectQuery("{\"a\":1}\n", &.{ "--header", "--format", "json", "SELECT", "a" }, "{\"a\": 1}\n");
}

test "keys are only matched in key position" {
    // A value equal to the key name is not the key.
    try expectQuery("{\"msg\":\"error\"}\n", &.{ "--count", "error", "exists" }, "0\n");
    try expectQuery("{\"tag\":\"level\",\"level\":\"debug\"}\n", &.{ "--count", "level", "neq", "debug" }, "0\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name" }, "Bob\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name,a" }, "Bob\tname\n");
    // Escaped quotes inside a string don't start a key.
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\",\"k\":2}\n", &.{ "SELECT", "k" }, "2\n");
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\"}\n", &.{ "--count", "k", "exists" }, "0\n");
    // Whitespace around the colon is fine.
    try expectQuery("{\"k\" :  5}\n", &.{ "SELECT", "k", "WHERE", "k", "eq", "5" }, "5\n");
}

test "string eq is found by its value" {
    const lines =
        \\{"type": "Push", "n": 1}
        \\{"other":"Push","type":"Fork"}
        \\{"type":["Push"]}
        \\{"m":"\"type\":\"Push\"","type":"x"}
        \\{"Push":"type"}
        \\{"a":{"type" : "Push"}}
        \\
    ;
    try expectQuery(lines, &.{ "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "2\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "AND", "n", "eq", "1" }, "1\n");
    try expectQuery(lines, &.{ "--count", "a.type", "eq", "Push" }, "1\n");
    // --fast also finds the nested key.
    try expectQuery(lines, &.{ "--fast", "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n\n");
    try expectQuery(lines, &.{ "--fast", "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "3\n");
    try expectQuery("{\"type\"\t:\t\"Push\"}\n", &.{ "--count", "type", "eq", "Push" }, "1\n");
    // A value that could be a bare literal is still matched as one.
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "12" }, "2\n");
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "true", "OR", "v", "eq", "12" }, "3\n");
}

test "OR over several distinct keys" {
    const keys = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff" };
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(testing.allocator);
    var expected3: usize = 0;
    var expected5: usize = 0;
    for (0..3000) |i| {
        // Varying padding puts the needles at every offset relative to the SIMD chunks.
        try lines.print(testing.allocator, "{{\"pad\":\"{s}\",\"{s}\":\"v{d}\"}}\n", .{ ("x" ** 40)[0 .. i % 37], keys[i % 6], i % 4 });
        const k = i % 6;
        if (k == 0 or k == 1 or (k == 2 and i % 4 == 1)) expected3 += 1;
        if (k < 4 or (k == 4 and i % 4 == 2)) expected5 += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(lines.items, &.{ "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "eq", "v1" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected3}));
    // Five needles take the Teddy path where the target supports it.
    try expectQuery(lines.items, &.{
        "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "exists", "OR", "dddd", "exists", "OR", "eeeee", "eq", "v2",
    }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected5}));
}

test "multi-field select survives escaped quotes in arrays" {
    try expectQuery("{\"arr\":[\"a\\\"b\",\"c\"],\"x\":1,\"y\":\"z\"}\n", &.{ "SELECT", "x,y" }, "1\tz\n");
}

test "integers beyond i64 compare correctly" {
    try expectQuery("{\"id\":18446744073709551615}\n{\"id\":-1}\n", &.{ "--count", "id", "gt", "0" }, "1\n");
    try expectQuery("{\"id\":9223372036854775807}\n", &.{ "--count", "id", "gte", "9223372036854775807" }, "1\n");
}

test "non-numbers are not treated as numbers" {
    try expectQuery("{\"v\":\"nan\"}\n{\"v\":\"inf\"}\n{\"v\":\"0x10\"}\n{\"v\":3}\n", &.{ "SELECT", "sum:v,count:v" }, "3.0000\t4\n");
    try expectQuery("{\"v\":\"inf\"}\n", &.{ "--count", "v", "gt", "0" }, "0\n");
}

test "limit 0 outputs nothing" {
    try expectQuery("{\"a\":1}\n{\"a\":2}\n", &.{ "--limit", "0", "a", "exists" }, "");
    try expectQuery("{\"a\":1}\n", &.{ "--limit", "0", "--count", "a", "exists" }, "0\n");
}

test "nested objects and arrays are extracted whole" {
    try expectQuery("{\"a\": {\"b\": [1, \"]\"]}, \"c\": 2}\n", &.{ "SELECT", "a,c" }, "{\"b\": [1, \"]\"]}\t2\n");
}

test "count skips nulls" {
    try expectQuery("{\"x\":null}\n{\"x\":1}\n{\"y\":1}\n", &.{ "SELECT", "count:x" }, "1\n");
}

test "csv escapes quotes and decodes JSON escapes" {
    try expectQuery(
        "{\"s\":\"say \\\"hi\\\"\\n\\u00e9\\ud83d\\ude00\",\"n\":5}\n",
        &.{ "--format", "csv", "SELECT", "s,n,missing" },
        "\"say \"\"hi\"\"\n\u{e9}\u{1f600}\",\"5\",\n",
    );
}

test "query values are JSON-escaped before matching" {
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "eq", "a\"b" }, "1\n");
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "has", "\"" }, "1\n");
}

test "has respects type prefixes" {
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "s:2" }, "1\n");
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "n:2" }, "1\n");
}

test "last line without trailing newline is processed" {
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "--count", "a", "exists" }, "2\n");
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "SELECT", "a", "WHERE", "NOT", "b", "exists" }, "1\n2\n");
    try expectQuery("{\"a\":1}\r\n{\"a\":2}\r\n", &.{ "a", "eq", "2" }, "{\"a\":2}\n");
}

test "lines longer than a block are handled" {
    const a = testing.allocator;
    const big = try a.alloc(u8, BLOCK_SIZE + BLOCK_SIZE / 2);
    defer a.free(big);
    @memset(big, 'x');
    const input = try std.mem.concat(a, u8, &.{ "{\"a\":0}\n{\"pad\":\"", big, "\",\"a\":1}\n{\"a\":2}\n{\"a\":3}" });
    defer a.free(input);
    try expectQuery(input, &.{ "--count", "a", "exists" }, "4\n");
    try expectQuery(input, &.{ "SELECT", "a", "WHERE", "a", "gte", "1" }, "1\n2\n3\n");
}

test "many blocks with multi-condition and OR plans" {
    const a = testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(a);
    var expected_and: usize = 0;
    var expected_or: usize = 0;
    var i: usize = 0;
    while (list.items.len < 2 * BLOCK_SIZE + 12345) : (i += 1) {
        const lvl = if (i % 7 == 0) "error" else "info";
        const status = 200 + (i % 5) * 100;
        try list.print(a, "{{\"i\":{d},\"level\":\"{s}\",\"status\":{d},\"msg\":\"some text {d}\"}}\n", .{ i, lvl, status, i });
        if (i % 7 == 0 and status >= 500) expected_and += 1;
        if (i % 7 == 0 or status == 300) expected_or += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "AND", "status", "gte", "500" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_and}));
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "OR", "status", "eq", "300" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_or}));
}

test "exact: keys are top-level and paths walk into objects" {
    const line = "{\"id\": 5, \"meta\": {\"id\": 10, \"user\": {\"name\": \"x\"}}}\n";
    try expectQuery(line, &.{ "--count", "id", "eq", "10" }, "0\n");
    try expectQuery(line, &.{ "--count", "meta.id", "eq", "10" }, "1\n");
    try expectQuery(line, &.{ "SELECT", "id,meta.user.name,meta.user,nope.x" }, "5\tx\t{\"name\": \"x\"}\t\n");
    try expectQuery("{\"a.b\":1,\"a\":{\"b\":2}}\n", &.{ "SELECT", "a\\.b,a.b" }, "1\t2\n");
    // A path through a non-object is absent.
    try expectQuery("{\"a\":[{\"b\":1}]}\n", &.{ "--count", "a.b", "exists" }, "0\n");
    try expectQuery(line, &.{ "--fast", "--count", "id", "eq", "10" }, "1\n");
}

test "exact: NOT sees only the value at the path" {
    // The nested "a" must not make `NOT a eq 1` fail.
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "a", "eq", "2", "AND", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"b\":1}\n", &.{ "--count", "NOT", "a", "exists" }, "1\n");
}

test "exact: escapes are decoded" {
    const lines =
        \\{"\u006cevel": "error"}
        \\{"level": "\u0065rror"}
        \\{"level": "err\/or"}
        \\{"msg": "caf\u00e9 \ud83d\ude00", "path": "a\/b"}
        \\{"level": "error"}
        \\
    ;
    try expectQuery(lines, &.{ "--count", "level", "eq", "error" }, "3\n");
    try expectQuery(lines, &.{ "--count", "level", "eq", "err/or" }, "1\n");
    try expectQuery(lines, &.{ "--count", "msg", "has", "caf\u{e9} \u{1f600}" }, "1\n");
    try expectQuery(lines, &.{ "--count", "path", "eq", "a/b" }, "1\n");
    try expectQuery(lines, &.{ "--count", "level", "in", "x,error" }, "3\n");
    // Many anchors take the Teddy path, which must stop at escapes too.
    try expectQuery(lines, &.{ "--count", "level", "eq", "error", "OR", "p1", "exists", "OR", "p2", "exists", "OR", "p3", "exists", "OR", "p4", "exists" }, "3\n");
}

test "exact: numbers compare by value" {
    const lines = "{\"v\":90}\n{\"v\":90.0}\n{\"v\":9e1}\n{\"v\":\"90\"}\n{\"v\":\"90.0\"}\n{\"v\":900}\n{\"v\":-0}\n";
    try expectQuery(lines, &.{ "--count", "v", "eq", "90" }, "5\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "n:90.0" }, "3\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "s:90" }, "1\n");
    try expectQuery(lines, &.{ "--count", "v", "in", "0,9e1" }, "6\n");
    try expectQuery(lines, &.{ "--count", "v", "neq", "90" }, "2\n");
}

test "exact: duplicate keys, last wins" {
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "--count", "a", "eq", "1" }, "0\n");
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "SELECT", "a" }, "2\n");
    try expectQuery("{\"a\":{\"b\":1},\"a\":3}\n", &.{ "--count", "a.b", "exists" }, "0\n");
}

test "exact: invalid lines are skipped" {
    const lines = "{\"a\":1}\n{\"a\":1,}\n{\"a\":01}\n\n{\"a\":\"\xff\"}\n{\"a\":1} x\n[1]\n";
    try expectQuery(lines, &.{ "--count", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{ "--count", "NOT", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{"--count"}, "2\n");
}

test "exact: any JSON whitespace around colons" {
    try expectQuery("{\"a\"\r:\r1}\n", &.{ "--count", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"t\" :\r\"x\"}\n", &.{ "--count", "t", "eq", "x" }, "1\n");
}

/// Writes random JSONL that exercises everything the byte search must see through:
/// escaped spellings of key and value characters, nesting, repeated keys, unusual
/// whitespace, numbers spelled several ways, and some invalid lines.
const FuzzGen = struct {
    rand: std.Random,
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,

    const keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a.b", "p1", "q\"" };
    const strings = [_][]const u8{ "x", "ab", "Push", "1", "90", "90.0", "true", "a/b", "\u{e9}t\u{e9}", "q\"t", "", "-0", "\u{1f600}", "line\nbreak" };
    const numbers = [_][]const u8{ "1", "1.0", "1e0", "90", "9E1", "-0", "0", "12.5", "100", "1E2", "-3" };

    fn print(g: *FuzzGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.a, fmt, args);
    }

    fn chance(g: *FuzzGen, n: u32) bool {
        return g.rand.uintLessThan(u32, n) == 0;
    }

    fn ws(g: *FuzzGen) !void {
        try g.out.appendSlice(g.a, switch (g.rand.uintLessThan(u32, 8)) {
            0 => " ",
            1 => "\t",
            2 => "\r",
            3 => "  ",
            else => "",
        });
    }

    fn hex(g: *FuzzGen, unit: u21) !void {
        if (g.rand.boolean()) try g.print("\\u{x:0>4}", .{unit}) else try g.print("\\u{X:0>4}", .{unit});
    }

    /// A string, with characters randomly written as escapes.
    fn string(g: *FuzzGen, s: []const u8) !void {
        try g.out.append(g.a, '"');
        var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| {
            if (g.chance(5)) {
                if (cp >= 0x10000) {
                    const v = cp - 0x10000;
                    try g.hex(@intCast(0xd800 + (v >> 10)));
                    try g.hex(@intCast(0xdc00 + (v & 0x3ff)));
                } else try g.hex(cp);
            } else switch (cp) {
                '"' => try g.print("\\\"", .{}),
                '\\' => try g.print("\\\\", .{}),
                '\n' => try g.print("\\n", .{}),
                '/' => try g.print("{s}", .{if (g.rand.boolean()) "\\/" else "/"}),
                else => try g.print("{u}", .{cp}),
            }
        }
        try g.out.append(g.a, '"');
    }

    fn value(g: *FuzzGen, depth: u32) error{ OutOfMemory, WriteFailed }!void {
        switch (g.rand.uintLessThan(u32, if (depth < 3) 9 else 6)) {
            0, 1 => try g.string(strings[g.rand.uintLessThan(usize, strings.len)]),
            2, 3 => try g.print("{s}", .{numbers[g.rand.uintLessThan(usize, numbers.len)]}),
            4 => try g.print("{s}", .{([_][]const u8{ "true", "false", "null" })[g.rand.uintLessThan(usize, 3)]}),
            5 => try g.print("{d}", .{g.rand.intRangeAtMost(i32, -200, 200)}),
            6, 7 => try g.object(depth + 1),
            else => {
                try g.out.append(g.a, '[');
                const n = g.rand.uintLessThan(u32, 3);
                for (0..n) |i| {
                    if (i > 0) try g.out.append(g.a, ',');
                    try g.ws();
                    try g.value(depth + 1);
                }
                try g.out.append(g.a, ']');
            },
        }
    }

    fn object(g: *FuzzGen, depth: u32) !void {
        try g.out.append(g.a, '{');
        const n = g.rand.uintLessThan(u32, 5);
        for (0..n) |i| {
            if (i > 0) try g.out.append(g.a, ',');
            try g.ws();
            try g.string(keys[g.rand.uintLessThan(usize, keys.len)]);
            try g.ws();
            try g.out.append(g.a, ':');
            try g.ws();
            try g.value(depth);
        }
        // Padding moves the needles around relative to the SIMD chunks.
        if (g.chance(2)) try g.print(",\"pad\":\"{s}\"", .{("." ** 40)[0..g.rand.uintLessThan(usize, 40)]});
        try g.out.append(g.a, '}');
    }

    fn line(g: *FuzzGen) !void {
        const start = g.out.items.len;
        if (g.chance(20)) try g.value(2) else try g.object(0);
        if (g.chance(20)) g.out.items.len = start + g.rand.uintLessThan(usize, g.out.items.len - start + 1);
        if (g.chance(10)) try g.out.append(g.a, '\r');
        try g.out.append(g.a, '\n');
    }
};

test "differential: the prefilter never drops a line the parser accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x2e60);
    const rand = prng.random();

    const query_keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a\\.b", "a.b", "a.ab", "b.a", "p1", "q\"", "nope" };
    const query_vals = FuzzGen.strings ++ FuzzGen.numbers ++ [_][]const u8{ "false", "null", "t", "/", "\u{e9}" };
    const ops = [_][]const u8{ "eq", "eq", "neq", "has", "in", "exists", "gt", "lte" };

    for (0..20) |_| {
        var gen: FuzzGen = .{ .rand = rand, .a = a };
        for (0..300) |_| try gen.line();

        for (0..40) |_| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            const groups = 1 + rand.uintLessThan(u32, if (rand.boolean()) 2 else 6);
            for (0..groups) |gi| {
                if (gi > 0) try args.append(a, "OR");
                const conds = 1 + rand.uintLessThan(u32, 2);
                for (0..conds) |ci| {
                    if (ci > 0) try args.append(a, "AND");
                    if (rand.uintLessThan(u32, 4) == 0) try args.append(a, "NOT");
                    try args.append(a, query_keys[rand.uintLessThan(usize, query_keys.len)]);
                    const op = ops[rand.uintLessThan(usize, ops.len)];
                    try args.append(a, op);
                    if (std.mem.eql(u8, op, "exists")) continue;
                    const pool: []const []const u8 = if (op[0] == 'g' or op[0] == 'l') &FuzzGen.numbers else &query_vals;
                    var v = pool[rand.uintLessThan(usize, pool.len)];
                    if (std.mem.eql(u8, op, "in")) v = try std.mem.concat(a, u8, &.{ v, ",", pool[rand.uintLessThan(usize, pool.len)] });
                    v = try std.mem.concat(a, u8, &.{ ([_][]const u8{ "", "", "s:", "n:" })[rand.uintLessThan(usize, 4)], v });
                    try args.append(a, v);
                }
            }
            if (rand.boolean()) try args.insertSlice(a, 0, &.{ "SELECT", "a,a.b,p1" });

            const config = (try cli.parseArgs(a, args.items)).run;
            const got = try runTestQuery(a, gen.out.items, config);
            var unfiltered = config;
            unfiltered.prefilter = false;
            const want = try runTestQuery(a, gen.out.items, unfiltered);
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("query:", .{});
                for (args.items) |t| std.debug.print(" '{s}'", .{t});
                std.debug.print("\nwant:\n{s}\ngot:\n{s}\n", .{ want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}
