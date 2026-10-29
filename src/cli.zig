//! Command-line parsing: options and the query (SELECT fields, WHERE conditions).
const std = @import("std");

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
    /// Evaluate on the raw bytes only, without the exact parse.
    fast: bool = false,
    /// Rule lines out with the byte-level search before parsing. Only turned off by tests.
    prefilter: bool = true,
};
pub const Command = union(enum) {
    help,
    version,
    run: Config,
};

pub fn printUsage() void {
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
        \\  --fast              Match on raw bytes only: faster, but approximate (keys at any depth,
        \\                      no escape decoding, no validation)
        \\  --help, -h          Show this help message
        \\  --version, -v       Show version
        \\  --                  Treat all following arguments as query terms
        \\
        \\Query Syntax:
        \\  Operators: eq, neq, gt, lt, gte, lte, has, exists, in
        \\  Types:     Auto-detected. Use 's:' for strings or 'n:' for numbers to force types.
        \\  NOT:       Negate any condition with NOT before the key  (e.g. NOT level eq debug)
        \\  exists:    Check key presence only, no value needed       (e.g. error exists)
        \\  Paths:     Keys are top-level; use dots for nested keys   (e.g. user.id eq 5, a\.b for a literal dot)
        \\  AND / OR:  Chain conditions                               (e.g. level eq error AND code gt 500)
        \\  Aggregations: count:field, sum:field, min:field, max:field, avg:field
        \\
        \\Exit Codes:
        \\  0  At least one match found
        \\  1  No matches found
        \\  2  Error
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
                if (key.len == 0) return error.InvalidSelectField;

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
            negated = !negated;
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
            // A trailing AND/OR with nothing after it is an incomplete condition.
            if (i == tokens.len) return error.InvalidCondition;
        }
    }

    if (negated) return error.InvalidCondition;
    if (current_conditions.items.len > 0) try groups.append(allocator, .{ .conditions = try current_conditions.toOwnedSlice(allocator) });
    return groups.toOwnedSlice(allocator);
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    // All allocations go into an arena whose lifetime is tied to main(); no manual frees needed.
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var config = Config{ .groups = undefined, .pluck = &[_]PluckField{} };

    var a: usize = 0;
    while (a < args.len) : (a += 1) {
        const arg = args[a];
        if (std.mem.eql(u8, arg, "--")) {
            try tokens.appendSlice(allocator, args[a + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--file")) {
            a += 1;
            if (a == args.len) return error.MissingFileValue;
            config.file_path = args[a];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            a += 1;
            if (a == args.len) return error.MissingLimitValue;
            config.limit = std.fmt.parseInt(usize, args[a], 10) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--format")) {
            a += 1;
            if (a == args.len) return error.MissingFormatValue;
            const fmt_str = args[a];
            if (std.ascii.eqlIgnoreCase(fmt_str, "csv")) config.format = .csv else if (std.ascii.eqlIgnoreCase(fmt_str, "json")) config.format = .json else if (std.ascii.eqlIgnoreCase(fmt_str, "tsv")) config.format = .tsv else return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--count") or std.mem.eql(u8, arg, "-c")) {
            config.count_only = true;
        } else if (std.mem.eql(u8, arg, "--header")) {
            config.header = true;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            config.fast = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try tokens.append(allocator, arg);
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
    return .{ .run = config };
}

test "parseArgs flags and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.InvalidLimit, parseArgs(a, &.{ "--limit", "x", "a", "exists" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(a, &.{ "--lmit", "5", "a", "exists" }));
    try std.testing.expectError(error.InvalidSelectField, parseArgs(a, &.{ "SELECT", "sum:" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(a, &.{ "a", "exists", "AND" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(a, &.{ "a", "exists", "AND", "NOT" }));
    try std.testing.expectError(error.MissingArguments, parseArgs(a, &.{}));
    try std.testing.expectEqual(Command.help, try parseArgs(a, &.{ "a", "--help" }));

    // `--` lets query terms start with dashes; negative numbers never needed it.
    const dashed = (try parseArgs(a, &.{ "--", "--weird", "eq", "--x" })).run;
    try std.testing.expectEqualStrings("--weird", dashed.groups[0].conditions[0].key);
    const negative = (try parseArgs(a, &.{ "balance", "gt", "-5" })).run;
    try std.testing.expectEqualStrings("-5", negative.groups[0].conditions[0].val);

    const not_not = (try parseArgs(a, &.{ "NOT", "NOT", "a", "exists" })).run;
    try std.testing.expect(!not_not.groups[0].conditions[0].negated);

    const limit0 = (try parseArgs(a, &.{ "--limit", "0", "a", "exists" })).run;
    try std.testing.expectEqual(@as(?usize, 0), limit0.limit);
}
