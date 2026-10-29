//! Compiles a parsed query into the form the search evaluates.
const std = @import("std");
const cli = @import("cli.zig");
const json = @import("json.zig");
const finder = @import("finder.zig");
const values = @import("values.zig");
const output = @import("output.zig");

const KeyFinder = finder.KeyFinder;
const MultiFinder = finder.MultiFinder;
const Hazards = finder.Hazards;
const Needle = finder.Needle;
const parseFastInt = values.parseFastInt;
const parseNumber = values.parseNumber;
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
    finder: KeyFinder,
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
    finder: KeyFinder,
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
    anchor_finder: MultiFinder,
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
    hazards: Hazards,
    format: cli.OutputFormat,
    limit: ?usize,
    count_only: bool,
    header: bool,
};

/// Splits a key into the path of object keys it names: `a.b` is key `b` inside `a`. `\.`
/// is a literal dot and `\\` a backslash.
fn splitPath(allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var seg: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < key.len) : (i += 1) {
        const c = key[i];
        if (c == '\\' and i + 1 < key.len and (key[i + 1] == '.' or key[i + 1] == '\\')) {
            i += 1;
            try seg.append(allocator, key[i]);
        } else if (c == '.') {
            if (seg.items.len == 0) return error.InvalidKey;
            try segs.append(allocator, try seg.toOwnedSlice(allocator));
        } else try seg.append(allocator, c);
    }
    if (seg.items.len == 0) return error.InvalidKey;
    try segs.append(allocator, try seg.toOwnedSlice(allocator));
    return segs.toOwnedSlice(allocator);
}

fn compileLiteral(allocator: std.mem.Allocator, text: []const u8) !Literal {
    return .{
        .quoted = try jsonEscapeAlloc(allocator, text, true),
        .text = try allocator.dupe(u8, text),
        .num = parseNumber(text),
        .int = parseFastInt(text),
    };
}

pub fn compilePlan(allocator: std.mem.Allocator, config: cli.Config) !CompiledPlan {
    var comp_groups = try allocator.alloc(CompiledGroup, config.groups.len);
    // Every condition's path, then every pluck's, for the exact parser.
    var paths: std.ArrayListUnmanaged([]const []const u8) = .empty;
    var hazards: Hazards = .{};

    for (config.groups, 0..) |g, i| {
        var comp_conds = try allocator.alloc(CompiledCondition, g.conditions.len);
        for (g.conditions, 0..) |c, j| {
            var actual_val = c.val;
            var type_forced: TypeForced = .none;
            if (std.mem.startsWith(u8, actual_val, "s:")) {
                actual_val = actual_val[2..];
                type_forced = .string;
            } else if (std.mem.startsWith(u8, actual_val, "n:") or std.mem.startsWith(u8, actual_val, "b:")) {
                actual_val = actual_val[2..];
                type_forced = .numeric;
            }

            var in_vals: std.ArrayListUnmanaged(Literal) = .empty;
            if (c.op == .in_op) {
                var it = std.mem.splitScalar(u8, actual_val, ',');
                while (it.next()) |v| {
                    if (v.len > 0) try in_vals.append(allocator, try compileLiteral(allocator, v));
                }
            }

            const val = try compileLiteral(allocator, actual_val);
            switch (c.op) {
                .gt, .lt, .gte, .lte => if (val.num == null) return error.NonNumericComparison,
                else => {},
            }

            const path = try splitPath(allocator, c.key);
            try paths.append(allocator, path);
            // The prefilter searches for the keys of positive conditions.
            if (!c.negated) hazards.add(path[path.len - 1]);
            comp_conds[j] = .{
                .finder = .init(try jsonEscapeAlloc(allocator, path[path.len - 1], true)),
                .slot = undefined,
                .val = val,
                .op = c.op,
                .type_forced = type_forced,
                .negated = c.negated,
                .in_vals = try in_vals.toOwnedSlice(allocator),
            };
        }
        comp_groups[i] = .{ .conditions = comp_conds };
    }

    // A match satisfies some group, and every operator requires its key to be present, so
    // a line can only match if one group's non-negated condition passes on it. A group of
    // only negated conditions can match any line, which rules out anchoring.
    var anchors = try allocator.alloc(*const CompiledCondition, comp_groups.len);
    for (comp_groups, 0..) |*g, gi| {
        var best: ?*const CompiledCondition = null;
        for (g.conditions) |*c| {
            if (!c.negated and (best == null or anchorScore(c) > anchorScore(best.?))) best = c;
        }
        anchors[gi] = best orelse {
            anchors = &.{};
            break;
        };
    }
    var needles = std.array_list.Managed(Needle).init(allocator);
    const anchor_keys = try allocator.alloc(usize, anchors.len);
    for (anchors, anchor_keys) |a, *ki| {
        const needle: Needle = if (searchesValue(a)) blk: {
            hazards.add(a.val.text);
            break :blk .{ .finder = .init(a.val.quoted), .value_of = a.finder.key };
        } else .{ .finder = a.finder };
        ki.* = for (needles.items, 0..) |n, j| {
            if (std.mem.eql(u8, n.finder.key, needle.finder.key) and
                std.mem.eql(u8, n.value_of orelse "", needle.value_of orelse "") and
                (n.value_of == null) == (needle.value_of == null)) break j;
        } else blk: {
            try needles.append(needle);
            break :blk needles.items.len - 1;
        };
    }

    var pks = try allocator.alloc(CompiledPluck, config.pluck.len);
    var has_aggs = false;
    for (config.pluck, 0..) |p, i| {
        const path = try splitPath(allocator, p.key);
        try paths.append(allocator, path);
        const key_quoted = try jsonEscapeAlloc(allocator, path[path.len - 1], true);
        var same_as: ?usize = null;
        for (pks[0..i], 0..) |prev, j| {
            if (std.mem.eql(u8, prev.finder.key, key_quoted)) {
                same_as = j;
                break;
            }
        }
        pks[i] = .{
            .finder = .init(key_quoted),
            .slot = undefined,
            .ptype = p.ptype,
            .original_str = p.original_str,
            .same_as = same_as,
        };
        if (p.ptype != .raw) has_aggs = true;
    }

    const path_slots = try allocator.alloc(u32, paths.items.len);
    const trie = try json.PathTrie.init(allocator, paths.items, path_slots);
    var next_path: usize = 0;
    for (comp_groups) |g| {
        for (g.conditions) |*c| {
            c.slot = path_slots[next_path];
            next_path += 1;
        }
    }
    for (pks) |*p| {
        p.slot = path_slots[next_path];
        next_path += 1;
    }

    var anchor_finder: MultiFinder = try .init(allocator, needles.items);
    anchor_finder.hazards = hazards;
    return CompiledPlan{
        .groups = comp_groups,
        .anchors = anchors,
        .anchor_finder = anchor_finder,
        .anchor_keys = anchor_keys,
        .pluck = pks,
        .has_aggregations = has_aggs,
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
fn searchesValue(c: *const CompiledCondition) bool {
    if (c.op != .eq or c.type_forced == .numeric or c.val.quoted.len < 3) return false;
    if (c.type_forced == .string) return true;
    const v = c.val.text;
    return c.val.num == null and !std.mem.eql(u8, v, "true") and
        !std.mem.eql(u8, v, "false") and !std.mem.eql(u8, v, "null");
}

/// Prefers value anchors, then the longest needle: it yields the fewest SIMD candidates.
fn anchorScore(c: *const CompiledCondition) usize {
    return if (searchesValue(c)) 1000 + c.val.quoted.len else c.finder.key.len;
}
