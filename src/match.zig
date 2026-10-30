//! Evaluating query conditions against the bytes of a value or a line.
const std = @import("std");
const cli = @import("cli.zig");
const finder = @import("finder.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");

const CompiledCondition = compile.CompiledCondition;
const Scratch = values.Scratch;
const stringContents = values.stringContents;
const stringText = values.stringText;
const primitiveToken = values.primitiveToken;

/// Whether the bare token at the start of `value` is exactly `literal` (`true`, `null`, ...).
/// The literal must end where the token ends, so `true` does not match `trueish`.
inline fn primitiveEquals(value: []const u8, literal: []const u8) bool {
    if (!std.mem.startsWith(u8, value, literal)) return false;
    return literal.len == value.len or values.isPrimitiveTerminator(value[literal.len]);
}

/// Ordering for the `gt`, `lt`, `gte` and `lte` operators. Other operators never reach here.
inline fn compare(comptime T: type, left: T, right: T, op: cli.Operator) bool {
    return switch (op) {
        .gt => left > right,
        .lt => left < right,
        .gte => left >= right,
        .lte => left <= right,
        else => unreachable,
    };
}

/// Whether the number text `text` equals the query's number. An integer query is compared
/// exactly, as i64, when the text is also a plain integer. Otherwise both sides go through
/// f64, so `1.0` equals `1`.
fn numEquals(text: []const u8, literal: *const compile.Literal) bool {
    if (literal.int) |target| {
        if (values.parseFastInt(text)) |number| {
            return number == target;
        }
    }

    const target = literal.num orelse return false;
    return (values.parseNumber(text) orelse return false) == target;
}

/// `eq` on the value starting at `value`:
/// - A string equals the query when its raw text starts with `literal.quoted`, the query
///   JSON-quoted including its closing quote. The closing quote makes this an exact match,
///   not a prefix match.
/// - An escaped string is decoded first, so the JSON text `"caf\u00e9"` equals `café`.
/// - A numeric query also matches numeric strings by value, so `"12"` equals `12`. This is
///   off when the type is forced with `s:`.
/// - `s:` makes strings the only possible match. `n:` and `b:` forbid strings entirely.
/// - Objects and arrays never equal a scalar query.
/// - A literal (`true`, `null`) compares by text. A number also compares by value.
fn eqMatch(
    value: []const u8,
    type_forced: compile.TypeForced,
    literal: *const compile.Literal,
    scratch: *Scratch,
) !bool {
    if (value[0] == '"') {
        if (type_forced == .numeric) return false;
        if (std.mem.startsWith(u8, value, literal.quoted)) return true;

        // Unescaped strings were fully compared by the quoted prefix above. Only escaped
        // strings and numeric-looking strings need decoding.
        const contents = stringContents(value);
        const numeric_strings_match = type_forced == .none and literal.num != null;
        if (!contents.escaped and !numeric_strings_match) return false;

        const text = try stringText(contents, scratch);
        if (contents.escaped and std.mem.eql(u8, text, literal.text)) return true;
        return numeric_strings_match and numEquals(text, literal);
    }
    if (type_forced == .string or value[0] == '{' or value[0] == '[') return false;
    return primitiveEquals(value, literal.text) or numEquals(primitiveToken(value), literal);
}

/// The text that `has` and the comparisons work on: the decoded contents of a string, or the
/// token of a number or literal.
inline fn comparableText(value: []const u8, is_string: bool, scratch: *Scratch) ![]const u8 {
    if (is_string) return stringText(stringContents(value), scratch);
    return primitiveToken(value);
}

/// Whether the value starting at `value` satisfies `cond`. Only the value's own bytes decide
/// the result, so `value` may run on past the end of it.
///
/// This one test serves both layers. The byte-level search applies it to every occurrence of
/// the key, and the exact layer applies it to the value at the key's path. That value is one
/// of the occurrences, so the search never rules out a line the exact layer would accept.
pub fn valueMatches(value: []const u8, cond: *const CompiledCondition, scratch: *Scratch) !bool {
    if (value.len == 0) return false;

    const is_string = value[0] == '"';
    const is_container = value[0] == '{' or value[0] == '[';

    // `has` and the ordering operators only see values that the type forcing allows.
    // `eq` and `in` apply the forcing inside `eqMatch`.
    const type_ok = switch (cond.type_forced) {
        .none => true,
        .string => is_string,
        .numeric => !is_string,
    };

    switch (cond.op) {
        .exists => return true,
        .eq => return eqMatch(value, cond.type_forced, &cond.val, scratch),
        .neq => return !try eqMatch(value, cond.type_forced, &cond.val, scratch),
        .in_op => {
            for (cond.in_vals) |*candidate| {
                if (try eqMatch(value, cond.type_forced, candidate, scratch)) return true;
            }
            return false;
        },
        .has => {
            if (!type_ok or is_container) return false;
            const text = try comparableText(value, is_string, scratch);
            return contains(text, cond.val.text);
        },
        .gt, .lt, .gte, .lte => {
            if (!type_ok or is_container) return false;
            const text = try comparableText(value, is_string, scratch);

            // When both sides are integers, compare exactly as i64.
            if (cond.val.int) |target| {
                if (values.parseFastInt(text)) |int_value| {
                    return compare(i64, int_value, target, cond.op);
                }
            }
            // Otherwise compare as f64. `num` is set for every comparison query, because
            // compile rejects comparisons against non-numeric values.
            const number = values.parseNumber(text) orelse return false;
            return compare(f64, number, cond.val.num.?, cond.op);
        },
    }
}

/// The next occurrence of the condition's key at or after `start` whose value satisfies it,
/// or null if there is none. An `exists` condition needs no value check.
pub fn nextPassing(
    cond: *const CompiledCondition,
    data: []const u8,
    start: usize,
    scratch: *Scratch,
) !?finder.Hit {
    var pos = start;
    while (cond.finder.next(data, pos)) |hit| {
        if (cond.op == .exists or try valueMatches(data[hit.val_pos..], cond, scratch)) return hit;
        // Resume one byte past this key so the search does not find the same key again.
        pos = hit.key_pos + 1;
    }
    return null;
}

/// Whether any occurrence of the condition's key in `line` passes.
pub fn lineMatches(line: []const u8, cond: *const CompiledCondition, scratch: *Scratch) !bool {
    return try nextPassing(cond, line, 0, scratch) != null;
}

/// --fast: evaluates the plan on the bytes of the line, without parsing it.
///
/// The plan is an OR over its groups and an AND within each group. The loop breaks on the
/// first failing condition, so the `else` branch runs only when every condition in the group
/// passed, and that group then accepts the line.
pub fn evaluatePlan(line: []const u8, plan: *const compile.CompiledPlan, scratch: *Scratch) !bool {
    // A plan without groups has no filter, so it accepts every line.
    if (plan.groups.len == 0) return true;
    // Lines shorter than two bytes are rejected outright, even when a negated condition
    // would have passed on them.
    if (line.len < 2) return false;

    for (plan.groups) |*group| {
        for (group.conditions) |*cond| {
            // A condition fails when its match result equals `negated`. A plain condition
            // fails when nothing matches, and a negated one fails when something matches.
            if (try lineMatches(line, cond, scratch) == cond.negated) break;
        } else return true;
    }
    return false;
}

/// Substring search for the short needles of `has`. Not std.mem.find: it builds a 2KB
/// Boyer-Moore table per call for haystacks of 52+ bytes.
fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var search_from: usize = 0;
    // findScalarPos jumps to each candidate position, where the first needle byte matches.
    while (std.mem.findScalarPos(u8, hay, search_from, needle[0])) |pos| {
        // Later candidates start even further right, so none of them can fit either.
        if (pos + needle.len > hay.len) return false;
        if (std.mem.eql(u8, hay[pos..][0..needle.len], needle)) return true;

        search_from = pos + 1;
    }
    return false;
}
