//! Command-line parsing: options and the query (SELECT fields, WHERE conditions).
const std = @import("std");

pub const max_pluck_fields = 256;

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
        \\zog - search JSONL with SIMD
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

const SelectClause = struct {
    fields: []PluckField,
    /// Token index just after the SELECT clause, including the WHERE keyword if present.
    next_token: usize,
};

/// Parses the comma-separated fields after SELECT, up to WHERE or the end of the tokens.
/// A field is a key, or an aggregation such as `sum:balance`.
fn parseSelectClause(
    allocator: std.mem.Allocator,
    tokens: []const []const u8,
    start: usize,
) !SelectClause {
    var pluck_keys: std.ArrayList(PluckField) = .empty;
    var token_index = start;

    while (token_index < tokens.len and !std.ascii.eqlIgnoreCase(tokens[token_index], "where")) : (token_index += 1) {
        var fields = std.mem.splitScalar(u8, tokens[token_index], ',');
        while (fields.next()) |field| {
            // Empty items, as in `name,,age`, are skipped.
            if (field.len == 0) continue;

            const ptype, const key = parseSelectField(field);
            if (key.len == 0) return error.InvalidSelectField;
            try pluck_keys.append(allocator, .{ .key = key, .ptype = ptype, .original_str = field });
        }
    }

    // SELECT with no fields before WHERE or the end.
    if (token_index == start) return error.MissingArguments;

    if (token_index < tokens.len and std.ascii.eqlIgnoreCase(tokens[token_index], "where")) {
        token_index += 1;
    }

    const fields = try pluck_keys.toOwnedSlice(allocator);
    if (fields.len > max_pluck_fields) return error.TooManyPluckFields;
    return .{ .fields = fields, .next_token = token_index };
}

/// Splits an aggregation prefix (`count:`, `sum:`, ...) off a SELECT field.
fn parseSelectField(field: []const u8) struct { PluckType, []const u8 } {
    inline for (.{ .count, .sum, .min, .max, .avg }) |ptype| {
        const prefix = @tagName(ptype) ++ ":";
        if (std.ascii.startsWithIgnoreCase(field, prefix)) return .{ ptype, field[prefix.len..] };
    }
    return .{ .raw, field };
}

/// Parses `[NOT] <key> <op> [<val>]` conditions joined by AND / OR. AND binds tighter, so
/// the result is a list of OR'ed groups whose conditions are AND'ed.
fn parseWhereClause(allocator: std.mem.Allocator, tokens: []const []const u8, start: usize) ![]ConditionGroup {
    var groups: std.ArrayList(ConditionGroup) = .empty;
    var current_conditions: std.ArrayList(Condition) = .empty;
    // NOT toggles instead of setting, so `NOT NOT key` cancels out. The flag applies only to
    // the next condition.
    var negated = false;
    var token_index = start;

    while (token_index < tokens.len) {
        if (std.ascii.eqlIgnoreCase(tokens[token_index], "not")) {
            negated = !negated;
            token_index += 1;
            continue;
        }

        // A key must be followed by an operator.
        if (token_index + 1 >= tokens.len) return error.InvalidCondition;
        const key = tokens[token_index];
        const op = parseOp(tokens[token_index + 1]) orelse return error.UnknownOperator;

        var val: []const u8 = "";
        if (op != .exists) {
            // Every operator except `exists` takes a value.
            if (token_index + 2 >= tokens.len) return error.InvalidCondition;
            val = tokens[token_index + 2];
            token_index += 3;
        } else {
            token_index += 2;
        }

        try current_conditions.append(allocator, .{ .key = key, .val = val, .op = op, .negated = negated });
        negated = false;

        // A condition is followed by AND, by OR, or by the end of the tokens.
        if (token_index < tokens.len) {
            const logical = tokens[token_index];
            token_index += 1;
            if (std.ascii.eqlIgnoreCase(logical, "or")) {
                // OR closes the current AND group. The group becomes one alternative.
                try groups.append(allocator, .{ .conditions = try current_conditions.toOwnedSlice(allocator) });
                current_conditions = .empty;
            } else if (!std.ascii.eqlIgnoreCase(logical, "and")) {
                return error.InvalidCondition;
            }

            // A trailing AND/OR with nothing after it is an incomplete condition.
            if (token_index == tokens.len) return error.InvalidCondition;
        }
    }

    // A NOT with no condition after it.
    if (negated) return error.InvalidCondition;

    // The last AND group is closed by the end of the tokens. It is empty only when there were
    // no conditions at all.
    if (current_conditions.items.len > 0) {
        try groups.append(allocator, .{ .conditions = try current_conditions.toOwnedSlice(allocator) });
    }
    return groups.toOwnedSlice(allocator);
}

/// Parses the arguments after the program name. `allocator` should be an arena: nothing
/// allocated here is freed individually.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    var tokens: std.ArrayList([]const u8) = .empty;
    var config = Config{ .groups = undefined, .pluck = &[_]PluckField{} };

    // Options may appear anywhere. Everything else is a query token, in order.
    var arg_index: usize = 0;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after `--` is a query token, even if it starts with dashes.
            try tokens.appendSlice(allocator, args[arg_index + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--file")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingFileValue;
            config.file_path = args[arg_index];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingLimitValue;
            config.limit = std.fmt.parseInt(usize, args[arg_index], 10) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--format")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingFormatValue;
            config.format = for (std.enums.values(OutputFormat)) |format| {
                if (std.ascii.eqlIgnoreCase(args[arg_index], @tagName(format))) break format;
            } else return error.InvalidFormat;
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

    // SELECT, if present, comes first among the query tokens.
    var next_token: usize = 0;
    if (next_token < tokens.items.len and std.ascii.eqlIgnoreCase(tokens.items[next_token], "select")) {
        next_token += 1;
        const select = try parseSelectClause(allocator, tokens.items, next_token);
        config.pluck = select.fields;
        next_token = select.next_token;
    }

    config.groups = try parseWhereClause(allocator, tokens.items, next_token);

    if (config.groups.len == 0 and config.pluck.len == 0 and !config.count_only) {
        return error.MissingArguments;
    }
    return .{ .run = config };
}

test "parseArgs flags and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidLimit, parseArgs(allocator, &.{ "--limit", "x", "a", "exists" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(allocator, &.{ "--lmit", "5", "a", "exists" }));
    try std.testing.expectError(error.InvalidSelectField, parseArgs(allocator, &.{ "SELECT", "sum:" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(allocator, &.{ "a", "exists", "AND" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(allocator, &.{ "a", "exists", "AND", "NOT" }));
    try std.testing.expectError(error.MissingArguments, parseArgs(allocator, &.{}));
    try std.testing.expectEqual(Command.help, try parseArgs(allocator, &.{ "a", "--help" }));

    // `--` lets query terms start with dashes; negative numbers never needed it.
    const dashed = (try parseArgs(allocator, &.{ "--", "--weird", "eq", "--x" })).run;
    try std.testing.expectEqualStrings("--weird", dashed.groups[0].conditions[0].key);
    const negative = (try parseArgs(allocator, &.{ "balance", "gt", "-5" })).run;
    try std.testing.expectEqualStrings("-5", negative.groups[0].conditions[0].val);

    const not_not = (try parseArgs(allocator, &.{ "NOT", "NOT", "a", "exists" })).run;
    try std.testing.expect(!not_not.groups[0].conditions[0].negated);

    const limit0 = (try parseArgs(allocator, &.{ "--limit", "0", "a", "exists" })).run;
    try std.testing.expectEqual(@as(?usize, 0), limit0.limit);
}
