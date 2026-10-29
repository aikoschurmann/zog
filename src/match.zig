//! Evaluating query conditions against the bytes of a value or a line.
const std = @import("std");
const cli = @import("cli.zig");
const finder = @import("finder.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");

const Hit = finder.Hit;
const TypeForced = compile.TypeForced;
const Literal = compile.Literal;
const CompiledCondition = compile.CompiledCondition;
const CompiledPlan = compile.CompiledPlan;
const Scratch = values.Scratch;
const isPrimitiveTerminator = values.isPrimitiveTerminator;
const parseFastInt = values.parseFastInt;
const parseNumber = values.parseNumber;
const stringContents = values.stringContents;
const stringText = values.stringText;
const primitiveToken = values.primitiveToken;

inline fn primitiveEquals(vs: []const u8, literal: []const u8) bool {
    if (!std.mem.startsWith(u8, vs, literal)) return false;
    return literal.len == vs.len or isPrimitiveTerminator(vs[literal.len]);
}

inline fn compare(comptime T: type, a: T, b: T, op: cli.Operator) bool {
    return switch (op) {
        .gt => a > b,
        .lt => a < b,
        .gte => a >= b,
        .lte => a <= b,
        else => unreachable,
    };
}

fn numEquals(text: []const u8, lit: *const Literal) bool {
    if (lit.int) |target| {
        if (parseFastInt(text)) |n| return n == target;
    }
    const target = lit.num orelse return false;
    return (parseNumber(text) orelse return false) == target;
}

/// `eq`: a string equals the query text, a literal has the same text, and when the query is
/// a number, numbers and numeric strings equal it by value.
fn eqMatch(vs: []const u8, tf: TypeForced, lit: *const Literal, sc: *Scratch) !bool {
    if (vs[0] == '"') {
        if (tf == .numeric) return false;
        if (std.mem.startsWith(u8, vs, lit.quoted)) return true;
        const s = stringContents(vs);
        const numeric = tf == .none and lit.num != null;
        if (!s.escaped and !numeric) return false;
        const text = try stringText(s, sc);
        if (s.escaped and std.mem.eql(u8, text, lit.text)) return true;
        return numeric and numEquals(text, lit);
    }
    if (tf == .string or vs[0] == '{' or vs[0] == '[') return false;
    return primitiveEquals(vs, lit.text) or numEquals(primitiveToken(vs), lit);
}

/// Whether the value starting at `vs` satisfies `cond`; `vs` may run on past the value.
/// This one test serves both layers: the byte-level search applies it to every occurrence
/// of the key, the exact layer to the value at the key's path. That value is one of the
/// occurrences, so a line the exact layer accepts is never ruled out by the search.
pub fn valueMatches(vs: []const u8, cond: *const CompiledCondition, sc: *Scratch) !bool {
    if (vs.len == 0) return false;
    const is_string = vs[0] == '"';
    const is_container = vs[0] == '{' or vs[0] == '[';
    const type_ok = switch (cond.type_forced) {
        .none => true,
        .string => is_string,
        .numeric => !is_string,
    };
    switch (cond.op) {
        .exists => return true,
        .eq => return eqMatch(vs, cond.type_forced, &cond.val, sc),
        .neq => return !try eqMatch(vs, cond.type_forced, &cond.val, sc),
        .in_op => {
            for (cond.in_vals) |*v| {
                if (try eqMatch(vs, cond.type_forced, v, sc)) return true;
            }
            return false;
        },
        .has => {
            if (!type_ok or is_container) return false;
            const text = if (is_string) try stringText(stringContents(vs), sc) else primitiveToken(vs);
            return contains(text, cond.val.text);
        },
        .gt, .lt, .gte, .lte => {
            if (!type_ok or is_container) return false;
            const text = if (is_string) try stringText(stringContents(vs), sc) else primitiveToken(vs);
            if (cond.val.int) |target| {
                if (parseFastInt(text)) |n| return compare(i64, n, target, cond.op);
            }
            const n = parseNumber(text) orelse return false;
            return compare(f64, n, cond.val.num.?, cond.op);
        },
    }
}

/// Next occurrence of the condition's key at or after `start` whose value satisfies it.
pub fn nextPassing(cond: *const CompiledCondition, data: []const u8, start: usize, sc: *Scratch) !?Hit {
    var pos = start;
    while (cond.finder.next(data, pos)) |hit| {
        if (cond.op == .exists or try valueMatches(data[hit.val_pos..], cond, sc)) return hit;
        pos = hit.key_pos + 1;
    }
    return null;
}

pub fn lineMatches(line: []const u8, cond: *const CompiledCondition, sc: *Scratch) !bool {
    return try nextPassing(cond, line, 0, sc) != null;
}

/// --fast: evaluates the plan on the bytes of the line, without parsing it.
pub fn evaluatePlan(line: []const u8, plan: *const CompiledPlan, sc: *Scratch) !bool {
    if (plan.groups.len == 0) return true;
    if (line.len < 2) return false;

    for (plan.groups) |*group| {
        for (group.conditions) |*cond| {
            if (try lineMatches(line, cond, sc) == cond.negated) break;
        } else return true;
    }
    return false;
}

/// Substring search for the short needles of `has`. Not std.mem.find: it builds a 2KB
/// Boyer-Moore table per call for haystacks of 52+ bytes.
fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, hay, i, needle[0])) |pos| {
        if (pos + needle.len > hay.len) return false;
        if (std.mem.eql(u8, hay[pos..][0..needle.len], needle)) return true;
        i = pos + 1;
    }
    return false;
}
