const std = @import("std");
const Scanner = @import("scanner.zig");

pub const Operator = enum { eq, neq, gt, lt, gte, lte, has };

pub const Condition = struct {
    key: []const u8,
    val: []const u8,
    op: Operator,
};

pub const ConditionGroup = struct {
    conditions: []Condition,
};

pub const Config = struct {
    file_path: ?[]const u8 = null,
    groups: []ConditionGroup,
    pluck: [][]const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = parseArgs(allocator) catch |err| {
        if (err == error.HelpRequested) std.process.exit(0);
        std.debug.print("Error parsing ZQL: {}\n", .{err});
        std.debug.print(
            \\Usage: zog [--file <path>] [SELECT <fields> WHERE] <key> <op> <val> [AND/OR ...]
            \\
            \\Operators: eq, neq, gt, lt, gte, lte, has
            \\Types: Auto-detected (Inclusive). Use s:<val> or n:<val> to force strict types.
            \\
            \\Examples:
            \\  zog level eq error
            \\  zog status gte 400 AND active eq true
            \\  zog SELECT id,status WHERE balance lt 100
            \\
        , .{});
        std.process.exit(1);
    };

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.BufferedWriter(128 * 1024, @TypeOf(stdout_file)){ .unbuffered_writer = stdout_file };
    const stdout = bw.writer();
    defer bw.flush() catch {};

    if (config.file_path) |path| {
        try Scanner.searchFile(allocator, path, config.groups, config.pluck, stdout);
    } else {
        try Scanner.searchStream(allocator, config.groups, config.pluck, stdout);
    }
}

fn parseOp(op_str: []const u8) ?Operator {
    if (std.ascii.eqlIgnoreCase(op_str, "eq")) return .eq;
    if (std.ascii.eqlIgnoreCase(op_str, "neq")) return .neq;
    if (std.ascii.eqlIgnoreCase(op_str, "gt")) return .gt;
    if (std.ascii.eqlIgnoreCase(op_str, "lt")) return .lt;
    if (std.ascii.eqlIgnoreCase(op_str, "gte")) return .gte;
    if (std.ascii.eqlIgnoreCase(op_str, "lte")) return .lte;
    if (std.ascii.eqlIgnoreCase(op_str, "has")) return .has;
    return null;
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var tokens = std.ArrayList([]const u8).init(allocator);
    var config = Config{ .groups = undefined, .pluck = &[_][]const u8{} };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            config.file_path = try allocator.dupe(u8, args.next() orelse return error.MissingFileValue);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("zog - Blisteringly fast JSONL search engine\n", .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zog v0.2.1\n", .{});
            std.process.exit(0);
        } else {
            try tokens.append(try allocator.dupe(u8, arg));
        }
    }

    var i: usize = 0;
    var pluck_keys = std.ArrayList([]const u8).init(allocator);

    if (i < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[i], "select")) {
        i += 1;
        while (i < tokens.items.len and !std.ascii.eqlIgnoreCase(tokens.items[i], "where")) {
            var it = std.mem.splitScalar(u8, tokens.items[i], ',');
            while (it.next()) |p| { if (p.len > 0) try pluck_keys.append(p); }
            i += 1;
        }
        if (i < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[i], "where")) {
            i += 1;
        }
    }
    config.pluck = try pluck_keys.toOwnedSlice();

    var groups = std.ArrayList(ConditionGroup).init(allocator);
    var current_conditions = std.ArrayList(Condition).init(allocator);

    while (i < tokens.items.len) {
        if (i + 2 >= tokens.items.len) return error.InvalidCondition;
        const key = tokens.items[i];
        const op = parseOp(tokens.items[i+1]) orelse return error.UnknownOperator;
        const val = tokens.items[i+2];
        i += 3;

        try current_conditions.append(.{ .key = key, .val = val, .op = op });

        if (i < tokens.items.len) {
            const logical = tokens.items[i];
            i += 1;
            if (std.ascii.eqlIgnoreCase(logical, "or")) {
                try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
                current_conditions = std.ArrayList(Condition).init(allocator);
            }
        }
    }

    if (current_conditions.items.len > 0) try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
    config.groups = try groups.toOwnedSlice();
    if (config.groups.len == 0 and config.pluck.len == 0) return error.MissingArguments;
    return config;
}