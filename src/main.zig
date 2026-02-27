const std = @import("std");
const Scanner = @import("scanner.zig");

pub const Operator = enum { eq, neq, gt, lt, gte, lte, has, exists };
pub const Condition = struct {
    key: []const u8,
    val: []const u8,
    op: Operator,
    negated: bool = false,
};
pub const ConditionGroup = struct {
    conditions: []Condition,
};
pub const OutputFormat = enum { tsv, csv, json };
pub const PluckType = enum { raw, count, sum, min, max, avg };
pub const PluckField = struct {
    key: []const u8,
    ptype: PluckType,
    original_str: []const u8,
};
pub const Config = struct {
    file_path: ?[]const u8 = null,
    groups: []ConditionGroup,
    pluck: []PluckField,
    format: OutputFormat = .tsv,
    limit: ?usize = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = parseArgs(allocator) catch |err| {
        if (err == error.HelpRequested) std.process.exit(0);
        
        const msg = switch (err) {
            error.MissingFileValue => "Error: --file requires a path argument.",
            error.MissingLimitValue => "Error: --limit requires a number.",
            error.MissingFormatValue => "Error: --format requires 'json', 'csv', or 'tsv'.",
            error.InvalidCondition => "Error: Incomplete WHERE condition. Use <key> <op> <val>.",
            error.UnknownOperator => "Error: Invalid operator. Supported: eq, neq, gt, lt, gte, lte, has, exists.",
            error.MissingArguments => "Error: No query provided. You must provide a search condition or a SELECT clause.",
            else => "Error parsing arguments.",
        };
        std.debug.print("{s}\n\n", .{msg});
        printUsage();
        std.process.exit(1);
    };

    // Enforce File vs Pipe Check: Ensure we aren't just idling on a terminal
    if (config.file_path == null) {
        if (std.io.getStdIn().isTty()) {
            std.debug.print("Error: No input file specified and no data piped to stdin.\n", .{});
            std.debug.print("Provide a file with '--file <path>' or pipe data: 'cat logs.jsonl | zog ...'\n", .{});
            std.process.exit(1);
        }
    }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.BufferedWriter(128 * 1024, @TypeOf(stdout_file)){ .unbuffered_writer = stdout_file };
    const stdout = bw.writer();
    defer bw.flush() catch {};

    if (config.file_path) |_| {
        try Scanner.searchFile(allocator, config, stdout);
    } else {
        try Scanner.searchStream(allocator, config, stdout);
    }
}

fn printUsage() void {
    std.debug.print(
        \\zog - Blisteringly fast JSONL search engine
        \\
        \\Usage: zog [--file <path>] [--format json|csv|tsv] [SELECT <fields> WHERE] <key> <op> <val> [AND/OR ...]
        \\
        \\Options:
        \\  --file <path>       Path to JSONL file (reads from stdin if omitted)
        \\  --format <type>     Output format: tsv (default), csv, or json
        \\  --help, -h          Show this help message
        \\  --version, -v       Show version
        \\
        \\Query Syntax:
        \\  Operators: eq, neq, gt, lt, gte, lte, has
        \\  Types: Auto-detected. Use 's:' for strings or 'n:' for numbers to force types.
        \\  Aggregations: count:field, sum:field, min:field, max:field
        \\
        \\Examples:
        \\  zog --file logs.jsonl level eq error
        \\  cat data.jsonl | zog SELECT name,sum:balance WHERE active eq b:true
        \\
    , .{});
}

fn parseOp(op_str: []const u8) ?Operator {
    if (std.ascii.eqlIgnoreCase(op_str, "eq")) return .eq;
    if (std.ascii.eqlIgnoreCase(op_str, "neq")) return .neq;
    if (std.ascii.eqlIgnoreCase(op_str, "gt")) return .gt;
    if (std.ascii.eqlIgnoreCase(op_str, "lt")) return .lt;
    if (std.ascii.eqlIgnoreCase(op_str, "gte")) return .gte;
    if (std.ascii.eqlIgnoreCase(op_str, "lte")) return .lte;
    if (std.ascii.eqlIgnoreCase(op_str, "has")) return .has;
    if (std.ascii.eqlIgnoreCase(op_str, "exists")) return .exists;
    return null;
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var tokens = std.ArrayList([]const u8).init(allocator);
    var config = Config{ .groups = undefined, .pluck = &[_]PluckField{} };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            config.file_path = try allocator.dupe(u8, args.next() orelse return error.MissingFileValue);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const lim_str = args.next() orelse return error.MissingLimitValue;
            config.limit = try std.fmt.parseInt(usize, lim_str, 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const fmt_str = args.next() orelse return error.MissingFormatValue;
            if (std.ascii.eqlIgnoreCase(fmt_str, "csv")) config.format = .csv
            else if (std.ascii.eqlIgnoreCase(fmt_str, "json")) config.format = .json
            else config.format = .tsv;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zog v0.2.1\n", .{});
            std.process.exit(0);
        } else {
            try tokens.append(try allocator.dupe(u8, arg));
        }
    }

    var i: usize = 0;
    var pluck_keys = std.ArrayList(PluckField).init(allocator);
    if (i < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[i], "select")) {
        i += 1;
        const select_start_idx = i;
        while (i < tokens.items.len and !std.ascii.eqlIgnoreCase(tokens.items[i], "where")) {
            var it = std.mem.splitScalar(u8, tokens.items[i], ',');
            while (it.next()) |p| { 
                if (p.len > 0) {
                    var ptype: PluckType = .raw;
                    var key = p;
                    
                    if (std.ascii.startsWithIgnoreCase(p, "count:")) {
                        ptype = .count;
                        key = p[6..];
                    } else if (std.ascii.startsWithIgnoreCase(p, "sum:")) {
                        ptype = .sum;
                        key = p[4..];
                    } else if (std.ascii.startsWithIgnoreCase(p, "min:")) {
                        ptype = .min;
                        key = p[4..];
                    } else if (std.ascii.startsWithIgnoreCase(p, "max:")) {
                        ptype = .max;
                        key = p[4..];
                    } else if (std.ascii.startsWithIgnoreCase(p, "avg:")) {
                        ptype = .avg;
                        key = p[4..];
                    } 
                    
                    try pluck_keys.append(.{ .key = key, .ptype = ptype, .original_str = p });
                }
            }
            i += 1;
        }
        
        // Error if SELECT was used but no fields were provided before WHERE or end of string
        if (i == select_start_idx) return error.MissingArguments;

        if (i < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[i], "where")) {
            i += 1;
        }
    }
    config.pluck = try pluck_keys.toOwnedSlice();

    var groups = std.ArrayList(ConditionGroup).init(allocator);
    var current_conditions = std.ArrayList(Condition).init(allocator);
    var negated = false;
    while (i < tokens.items.len) {
        if (std.ascii.eqlIgnoreCase(tokens.items[i], "not")) {
            negated = true;
            i += 1;
            continue;
        }

        if (i + 1 >= tokens.items.len) return error.InvalidCondition;
        const key = tokens.items[i];
        const op = parseOp(tokens.items[i+1]) orelse return error.UnknownOperator;
        var val: []const u8 = "";
        
        if (op != .exists) {
            if (i + 2 >= tokens.items.len) return error.InvalidCondition;
            val = tokens.items[i+2];
            i += 3;
        } else {
            i += 2;
        }

        try current_conditions.append(.{ .key = key, .val = val, .op = op, .negated = negated });
        negated = false;

        if (i < tokens.items.len) {
            const logical = tokens.items[i];
            i += 1;
            if (std.ascii.eqlIgnoreCase(logical, "or")) {
                try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
                current_conditions = std.ArrayList(Condition).init(allocator);
            } else if (!std.ascii.eqlIgnoreCase(logical, "and")) {
                // If it's not AND/OR, the query structure is invalid
                return error.InvalidCondition;
            }
        }
    }

    if (current_conditions.items.len > 0) try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
    config.groups = try groups.toOwnedSlice();
    
    // Ensure that some action (either filtering or plucking) was requested
    if (config.groups.len == 0 and config.pluck.len == 0) return error.MissingArguments;
    return config;
}