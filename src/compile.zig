//! Compiles a parsed query into the form the search evaluates.
const std = @import("std");
const cli = @import("cli.zig");
const json = @import("json.zig");
const finder = @import("finder.zig");
const values = @import("values.zig");
const output = @import("output.zig");

const jsonEscapeAlloc = output.jsonEscapeAlloc;

pub const TypeForced = enum { none, string, numeric };

/// A query value, in the forms the comparisons need.
pub const Literal = struct {
    /// JSON-escaped and quoted, to compare with a string's raw text.
    quoted: []const u8,
    /// As typed: compared with decoded strings, literals and the text of numbers.
    text: []const u8,
    num: ?f64,
    int: ?i64,
};

pub const CompiledCondition = struct {
    /// Finds the last key of the path, at any depth.
    finder: finder.KeyFinder,
    /// Slot of the key path in the exact parser.
    slot: u32,
    val: Literal,
    op: cli.Operator,
    type_forced: TypeForced,
    negated: bool,
    in_vals: []const Literal,
};

pub const CompiledGroup = struct { conditions: []CompiledCondition };

pub const CompiledPluck = struct {
    finder: finder.KeyFinder,
    slot: u32,
    ptype: cli.PluckType,
    original_str: []const u8,
    /// Index of an earlier pluck with the same key, whose extracted value can be reused.
    same_as: ?usize,
};

pub const CompiledPlan = struct {
    groups: []CompiledGroup,
    /// One condition per group that a matching line must pass, so whole blocks can be
    /// searched for anchor keys instead of evaluating every line. Empty when some group
    /// has no usable anchor.
    anchors: []const *const CompiledCondition,
    /// The distinct anchor keys, searched for together in one pass.
    anchor_finder: finder.MultiFinder,
    /// Index into `anchor_finder.finders` of each anchor's key.
    anchor_keys: []const usize,
    pluck: []CompiledPluck,
    has_aggregations: bool,
    /// Lines the byte-level search can't rule out are validated and evaluated by parsing.
    /// Off with --fast, which evaluates on the bytes alone.
    exact: bool,
    /// Exact mode only: parse every line instead of prefiltering. For testing the prefilter.
    prefilter: bool,
    trie: json.PathTrie,
    hazards: finder.Hazards,
    format: cli.OutputFormat,
    limit: ?usize,
    count_only: bool,
    header: bool,
};

/// Splits a key into the path of object keys it names: `a.b` is key `b` inside `a`. `\.`
/// is a literal dot and `\\` a backslash.
fn splitPath(allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var segment: std.ArrayList(u8) = .empty;
    var pos: usize = 0;

    while (pos < key.len) : (pos += 1) {
        const byte = key[pos];
        if (byte == '\\' and pos + 1 < key.len and (key[pos + 1] == '.' or key[pos + 1] == '\\')) {
            // An escaped dot or backslash is part of the segment's text.
            pos += 1;
            try segment.append(allocator, key[pos]);
        } else if (byte == '.') {
            // A segment must not be empty, which rules out `a..b`, `.a` and `a.`.
            if (segment.items.len == 0) return error.InvalidKey;
            try segments.append(allocator, try segment.toOwnedSlice(allocator));
        } else {
            try segment.append(allocator, byte);
        }
    }

    if (segment.items.len == 0) return error.InvalidKey;
    try segments.append(allocator, try segment.toOwnedSlice(allocator));
    return segments.toOwnedSlice(allocator);
}

fn compileLiteral(allocator: std.mem.Allocator, text: []const u8) !Literal {
    return .{
        .quoted = try jsonEscapeAlloc(allocator, text, true),
        .text = try allocator.dupe(u8, text),
        .num = values.parseNumber(text),
        .int = values.parseFastInt(text),
    };
}

/// Compiles one `[NOT] key op value` condition. Its key path is appended to `paths` for the
/// exact parser, and a positive condition's key is registered as a hazard.
fn compileCondition(
    allocator: std.mem.Allocator,
    condition: cli.Condition,
    paths: *std.ArrayList([]const []const u8),
    hazards: *finder.Hazards,
) !CompiledCondition {
    // `s:` forces a string comparison. `n:` and `b:` forbid strings, so the condition only
    // matches non-string JSON values. Without a prefix the type is detected from the line.
    var raw_value = condition.val;
    var type_forced: TypeForced = .none;
    if (std.mem.startsWith(u8, raw_value, "s:")) {
        raw_value = raw_value[2..];
        type_forced = .string;
    } else if (std.mem.startsWith(u8, raw_value, "n:") or std.mem.startsWith(u8, raw_value, "b:")) {
        raw_value = raw_value[2..];
        type_forced = .numeric;
    }

    // `in` takes a comma-separated list. Empty items, as in `a,,b`, are ignored.
    var in_vals: std.ArrayList(Literal) = .empty;
    if (condition.op == .in_op) {
        var items = std.mem.splitScalar(u8, raw_value, ',');
        while (items.next()) |item| {
            if (item.len > 0) try in_vals.append(allocator, try compileLiteral(allocator, item));
        }
    }

    const val = try compileLiteral(allocator, raw_value);
    // Ordering comparisons only make sense against a number.
    switch (condition.op) {
        .gt, .lt, .gte, .lte => {
            if (val.num == null) return error.NonNumericComparison;
        },
        else => {},
    }

    const path = try splitPath(allocator, condition.key);
    try paths.append(allocator, path);
    const key = path[path.len - 1];
    // The keys of positive conditions are registered as hazards, so that escapes which
    // could hide them are detected.
    if (!condition.negated) hazards.add(key);

    return .{
        .finder = .init(try jsonEscapeAlloc(allocator, key, true)),
        .slot = undefined,
        .val = val,
        .op = condition.op,
        .type_forced = type_forced,
        .negated = condition.negated,
        .in_vals = try in_vals.toOwnedSlice(allocator),
    };
}

/// Compiles the WHERE groups. Conditions are appended to `paths` in group order.
fn compileGroups(
    allocator: std.mem.Allocator,
    groups: []const cli.ConditionGroup,
    paths: *std.ArrayList([]const []const u8),
    hazards: *finder.Hazards,
) ![]CompiledGroup {
    const compiled = try allocator.alloc(CompiledGroup, groups.len);

    for (groups, 0..) |group, group_index| {
        const conditions = try allocator.alloc(CompiledCondition, group.conditions.len);
        for (group.conditions, 0..) |condition, condition_index| {
            conditions[condition_index] = try compileCondition(allocator, condition, paths, hazards);
        }
        compiled[group_index] = .{ .conditions = conditions };
    }
    return compiled;
}

/// Picks one anchor per OR group: a positive condition that every line matching the group
/// must pass. Returns an empty slice when some group has no usable anchor.
fn pickAnchors(allocator: std.mem.Allocator, groups: []const CompiledGroup) ![]const *const CompiledCondition {
    // A match satisfies some group, and every operator requires its key to be present, so
    // a line can only match if one group's non-negated condition passes on it. A group of
    // only negated conditions can match any line, which rules out anchoring.
    const anchors = try allocator.alloc(*const CompiledCondition, groups.len);

    for (groups, anchors) |group, *anchor| {
        var best: ?*const CompiledCondition = null;
        for (group.conditions) |*condition| {
            if (condition.negated) continue;
            if (best == null or anchorScore(condition) > anchorScore(best.?)) best = condition;
        }
        anchor.* = best orelse return &.{};
    }
    return anchors;
}

/// Whether two needles run the same search: the same key, and both or neither searching a
/// value of it.
fn sameNeedle(first: finder.Needle, second: finder.Needle) bool {
    const same_key = std.mem.eql(u8, first.finder.key, second.finder.key);
    const same_value_of = std.mem.eql(u8, first.value_of orelse "", second.value_of orelse "");
    const both_or_neither = (first.value_of == null) == (second.value_of == null);
    return same_key and same_value_of and both_or_neither;
}

/// Turns each anchor into a needle and returns, per anchor, the index of its needle in
/// `needles`. Anchors sharing a needle are searched for once.
fn collectNeedles(
    allocator: std.mem.Allocator,
    anchors: []const *const CompiledCondition,
    needles: *std.ArrayList(finder.Needle),
    hazards: *finder.Hazards,
) ![]usize {
    const anchor_keys = try allocator.alloc(usize, anchors.len);

    for (anchors, anchor_keys) |anchor, *anchor_key| {
        // A value anchor searches for the quoted value and then checks that the value
        // belongs to its key. The value's text is a hazard, like a key.
        const needle: finder.Needle = if (searchesValue(anchor)) blk: {
            hazards.add(anchor.val.text);
            break :blk .{ .finder = .init(anchor.val.quoted), .value_of = anchor.finder.key };
        } else .{ .finder = anchor.finder };

        anchor_key.* = for (needles.items, 0..) |existing, index| {
            if (sameNeedle(existing, needle)) break index;
        } else blk: {
            try needles.append(allocator, needle);
            break :blk needles.items.len - 1;
        };
    }
    return anchor_keys;
}

/// Compiles the SELECT fields. Their paths are appended to `paths` after the conditions'.
fn compilePlucks(
    allocator: std.mem.Allocator,
    plucks: []const cli.PluckField,
    paths: *std.ArrayList([]const []const u8),
) ![]CompiledPluck {
    const compiled = try allocator.alloc(CompiledPluck, plucks.len);

    for (plucks, 0..) |pluck, index| {
        const path = try splitPath(allocator, pluck.key);
        try paths.append(allocator, path);
        const key_quoted = try jsonEscapeAlloc(allocator, path[path.len - 1], true);

        // A repeated key reuses the value extracted for its first occurrence, whatever the
        // aggregation of either field.
        var same_as: ?usize = null;
        for (compiled[0..index], 0..) |previous, earlier_index| {
            if (std.mem.eql(u8, previous.finder.key, key_quoted)) {
                same_as = earlier_index;
                break;
            }
        }

        compiled[index] = .{
            .finder = .init(key_quoted),
            .slot = undefined,
            .ptype = pluck.ptype,
            .original_str = pluck.original_str,
            .same_as = same_as,
        };
    }
    return compiled;
}

/// Hands each condition and pluck the slot the trie gave its path. The paths were appended
/// conditions first (group by group), then plucks, and the slots follow that order.
fn assignSlots(groups: []CompiledGroup, plucks: []CompiledPluck, path_slots: []const u32) void {
    var next_path: usize = 0;

    for (groups) |group| {
        for (group.conditions) |*condition| {
            condition.slot = path_slots[next_path];
            next_path += 1;
        }
    }
    for (plucks) |*pluck| {
        pluck.slot = path_slots[next_path];
        next_path += 1;
    }
}

pub fn compilePlan(allocator: std.mem.Allocator, config: cli.Config) !CompiledPlan {
    // Every condition's path, then every pluck's, for the exact parser.
    var paths: std.ArrayList([]const []const u8) = .empty;
    var hazards: finder.Hazards = .{};

    const groups = try compileGroups(allocator, config.groups, &paths, &hazards);
    const anchors = try pickAnchors(allocator, groups);

    var needles: std.ArrayList(finder.Needle) = .empty;
    const anchor_keys = try collectNeedles(allocator, anchors, &needles, &hazards);

    const plucks = try compilePlucks(allocator, config.pluck, &paths);
    // An aggregation in SELECT (count, sum, ...) makes the query compute running totals.
    const has_aggregations = for (config.pluck) |pluck| {
        if (pluck.ptype != .raw) break true;
    } else false;

    const path_slots = try allocator.alloc(u32, paths.items.len);
    const trie = try json.PathTrie.init(allocator, paths.items, path_slots);
    assignSlots(groups, plucks, path_slots);

    var anchor_finder: finder.MultiFinder = try .init(allocator, needles.items);
    anchor_finder.hazards = hazards;

    return CompiledPlan{
        .groups = groups,
        .anchors = anchors,
        .anchor_finder = anchor_finder,
        .anchor_keys = anchor_keys,
        .pluck = plucks,
        .has_aggregations = has_aggregations,
        .exact = !config.fast,
        .prefilter = config.prefilter,
        .trie = trie,
        .hazards = hazards,
        .format = config.format,
        .limit = config.limit,
        .count_only = config.count_only,
        .header = config.header,
    };
}

/// Whether an anchor is found by searching for its value rather than its key. A string
/// `eq` value is usually far rarer than its key (`"GollumEvent"` vs `"type"`). Values that
/// could also match a number or literal are excluded.
fn searchesValue(condition: *const CompiledCondition) bool {
    if (condition.op != .eq or condition.type_forced == .numeric or condition.val.quoted.len < 3) {
        return false;
    }
    if (condition.type_forced == .string) return true;

    const text = condition.val.text;
    return condition.val.num == null and
        !std.mem.eql(u8, text, "true") and
        !std.mem.eql(u8, text, "false") and
        !std.mem.eql(u8, text, "null");
}

/// Prefers value anchors, then the longest needle: it yields the fewest SIMD candidates.
/// The 1000 offset ranks value anchors above key anchors.
fn anchorScore(condition: *const CompiledCondition) usize {
    if (searchesValue(condition)) return 1000 + condition.val.quoted.len;
    return condition.finder.key.len;
}
