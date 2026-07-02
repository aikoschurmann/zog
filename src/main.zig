const std = @import("std");
const Scanner = @import("scanner.zig");

pub const VERSION = "0.1.5";

pub const MAX_PLUCK_FIELDS = 256;

pub const Operator = enum { eq, neq, gt, lt, gte, lte, has, exists, in_op };
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
    count_only: bool = false,
    header: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() == .leak) std.debug.print("warning: memory leak detected\n", .{});

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
            error.UnknownOperator => "Error: Invalid operator. Supported: eq, neq, gt, lt, gte, lte, has, exists, in.",
            error.MissingArguments => "Error: No query provided. You must provide a search condition or a SELECT clause.",
            error.TooManyPluckFields => "Error: Too many SELECT fields (max 256).",
            error.InvalidFormat => "Error: --format must be 'json', 'csv', or 'tsv'.",
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
            std.debug.print("Run 'zog --help' for usage information.\n", .{});
            std.process.exit(1);
        }
    }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.BufferedWriter(128 * 1024, @TypeOf(stdout_file)){ .unbuffered_writer = stdout_file };
    const stdout = bw.writer();

    if (config.file_path) |_| {
        const matched = try Scanner.searchFile(allocator, config, stdout);
        bw.flush() catch {};
        if (matched == 0) std.process.exit(1);
    } else {
        const matched = try Scanner.searchStream(allocator, config, stdout);
        bw.flush() catch {};
        if (matched == 0) std.process.exit(1);
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
        \\  --count, -c         Print only the count of matching lines
        \\  --header            Print column header row (for TSV/CSV with SELECT)
        \\  --limit <n>         Stop after n matches
        \\  --help, -h          Show this help message
        \\  --version, -v       Show version
        \\
        \\Query Syntax:
        \\  Operators: eq, neq, gt, lt, gte, lte, has, exists, in
        \\  Types:     Auto-detected. Use 's:' for strings or 'n:' for numbers to force types.
        \\  NOT:       Negate any condition with NOT before the key  (e.g. NOT level eq debug)
        \\  exists:    Check key presence only, no value needed       (e.g. error exists)
        \\  AND / OR:  Chain conditions                               (e.g. level eq error AND code gt 500)
        \\  Aggregations: count:field, sum:field, min:field, max:field, avg:field
        \\
        \\Exit Codes:
        \\  0  At least one match found
        \\  1  No matches found
        \\
        \\Examples:
        \\  zog --file logs.jsonl level eq error
        \\  zog --file logs.jsonl level in error,critical,warn
        \\  zog --file data.jsonl SELECT name,age
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
    if (std.ascii.eqlIgnoreCase(op_str, "in")) return .in_op;
    return null;
}

fn parseSelectClause(allocator: std.mem.Allocator, tokens: []const []const u8, start: usize) !struct { fields: []PluckField, next_i: usize } {
    var pluck_keys: std.ArrayListUnmanaged(PluckField) = .empty;
    var i = start;
    const select_start_idx = i;

    while (i < tokens.len and !std.ascii.eqlIgnoreCase(tokens[i], "where")) {
        var it = std.mem.splitScalar(u8, tokens[i], ',');
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

                try pluck_keys.append(allocator, .{ .key = key, .ptype = ptype, .original_str = p });
            }
        }
        i += 1;
    }

    // SELECT was present but no fields were listed before WHERE / end of input
    if (i == select_start_idx) return error.MissingArguments;

    // Consume the optional WHERE keyword
    if (i < tokens.len and std.ascii.eqlIgnoreCase(tokens[i], "where")) i += 1;

    const fields = try pluck_keys.toOwnedSlice(allocator);
    if (fields.len > MAX_PLUCK_FIELDS) return error.TooManyPluckFields;
    return .{ .fields = fields, .next_i = i };
}

fn parseWhereClause(allocator: std.mem.Allocator, tokens: []const []const u8, start: usize) ![]ConditionGroup {
    var groups: std.ArrayListUnmanaged(ConditionGroup) = .empty;
    var current_conditions: std.ArrayListUnmanaged(Condition) = .empty;
    var negated = false;
    var i = start;

    while (i < tokens.len) {
        if (std.ascii.eqlIgnoreCase(tokens[i], "not")) {
            negated = true;
            i += 1;
            continue;
        }

        if (i + 1 >= tokens.len) return error.InvalidCondition;
        const key = tokens[i];
        const op = parseOp(tokens[i + 1]) orelse return error.UnknownOperator;
        var val: []const u8 = "";

        if (op != .exists) {
            if (i + 2 >= tokens.len) return error.InvalidCondition;
            val = tokens[i + 2];
            i += 3;
        } else {
            i += 2;
        }

        try current_conditions.append(allocator, .{ .key = key, .val = val, .op = op, .negated = negated });
        negated = false;

        if (i < tokens.len) {
            const logical = tokens[i];
            i += 1;
            if (std.ascii.eqlIgnoreCase(logical, "or")) {
                try groups.append(allocator, .{ .conditions = try current_conditions.toOwnedSlice(allocator) });
                current_conditions = .empty;
            } else if (!std.ascii.eqlIgnoreCase(logical, "and")) {
                return error.InvalidCondition;
            }
        }
    }

    if (current_conditions.items.len > 0) try groups.append(allocator, .{ .conditions = try current_conditions.toOwnedSlice(allocator) });
    return groups.toOwnedSlice(allocator);
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = std.process.args();
    _ = args.skip();

    // All allocations go into an arena whose lifetime is tied to main(); no manual frees needed.
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var config = Config{ .groups = undefined, .pluck = &[_]PluckField{} };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            config.file_path = try allocator.dupe(u8, args.next() orelse return error.MissingFileValue);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const lim_str = args.next() orelse return error.MissingLimitValue;
            config.limit = try std.fmt.parseInt(usize, lim_str, 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const fmt_str = args.next() orelse return error.MissingFormatValue;
            if (std.ascii.eqlIgnoreCase(fmt_str, "csv")) config.format = .csv else if (std.ascii.eqlIgnoreCase(fmt_str, "json")) config.format = .json else if (std.ascii.eqlIgnoreCase(fmt_str, "tsv")) config.format = .tsv else return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.io.getStdOut().writer().print("zog v{s}\n", .{VERSION}) catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--count") or std.mem.eql(u8, arg, "-c")) {
            config.count_only = true;
        } else if (std.mem.eql(u8, arg, "--header")) {
            config.header = true;
        } else {
            try tokens.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    var i: usize = 0;

    if (i < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[i], "select")) {
        i += 1;
        const result = try parseSelectClause(allocator, tokens.items, i);
        config.pluck = result.fields;
        i = result.next_i;
    }

    config.groups = try parseWhereClause(allocator, tokens.items, i);

    // Ensure that some action (filtering, plucking, or counting) was requested
    if (config.groups.len == 0 and config.pluck.len == 0 and !config.count_only) return error.MissingArguments;
    return config;
}
