//! Writing results: selected fields as TSV, CSV or JSON, headers, and aggregations.
const std = @import("std");
const cli = @import("cli.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");

const CompiledPluck = compile.CompiledPluck;
const CompiledPlan = compile.CompiledPlan;
const Value = values.Value;
const Scratch = values.Scratch;
const parseNumber = values.parseNumber;
const stringText = values.stringText;

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
}

pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, s: []const u8, quoted: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    if (quoted) try out.writer.writeByte('"');
    try writeJsonEscaped(&out.writer, s);
    if (quoted) try out.writer.writeByte('"');
    return out.toOwnedSlice();
}

pub const AggState = union(enum) {
    raw: void,
    count: usize,
    sum: f64,
    min: f64,
    max: f64,
    avg: struct { sum: f64, count: usize },
};

fn writeCsvByte(w: *std.Io.Writer, c: u8) !void {
    if (c == '"') try w.writeAll("\"\"") else try w.writeByte(c);
}

fn parseHex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    return std.fmt.parseInt(u16, s[0..4], 16) catch null;
}

/// Writes the contents of a JSON string with escapes decoded, doubling quotes for CSV.
fn writeCsvUnescaped(w: *std.Io.Writer, raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '\\' or i + 1 == raw.len) {
            try writeCsvByte(w, c);
            i += 1;
            continue;
        }
        const e = raw[i + 1];
        i += 2;
        switch (e) {
            'n' => try w.writeByte('\n'),
            't' => try w.writeByte('\t'),
            'r' => try w.writeByte('\r'),
            'b' => try w.writeByte(0x08),
            'f' => try w.writeByte(0x0c),
            'u' => {
                const unit = parseHex4(raw[i..]) orelse {
                    try w.writeAll("\\u");
                    continue;
                };
                i += 4;
                var cp: u21 = unit;
                if (unit >= 0xd800 and unit <= 0xdbff and i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                    if (parseHex4(raw[i + 2 ..])) |low| {
                        if (low >= 0xdc00 and low <= 0xdfff) {
                            cp = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                            i += 6;
                        }
                    }
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8) catch {
                    try w.writeAll("\u{fffd}");
                    continue;
                };
                try w.writeAll(utf8[0..n]);
            },
            else => try writeCsvByte(w, e),
        }
    }
}

fn writeCsvField(w: *std.Io.Writer, v: Value) !void {
    try w.writeByte('"');
    if (v.is_string) {
        try writeCsvUnescaped(w, v.raw);
    } else {
        for (v.raw) |c| try writeCsvByte(w, c);
    }
    try w.writeByte('"');
}

fn writeJsonKey(w: *std.Io.Writer, name: []const u8) !void {
    try w.writeByte('"');
    try writeJsonEscaped(w, name);
    try w.writeAll("\": ");
}

pub fn printFormatted(results: []const ?Value, plucks: []const CompiledPluck, format: cli.OutputFormat, writer: *std.Io.Writer) !void {
    switch (format) {
        .json => {
            try writer.writeByte('{');
            for (results, plucks, 0..) |res, pk, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeJsonKey(writer, pk.original_str);
                if (res) |v| {
                    if (v.is_string) {
                        try writer.writeByte('"');
                        try writer.writeAll(v.raw);
                        try writer.writeByte('"');
                    } else {
                        try writer.writeAll(v.raw);
                    }
                } else {
                    try writer.writeAll("null");
                }
            }
            try writer.writeAll("}\n");
        },
        .csv => {
            for (results, 0..) |res, i| {
                if (i > 0) try writer.writeByte(',');
                if (res) |v| try writeCsvField(writer, v);
            }
            try writer.writeByte('\n');
        },
        .tsv => {
            for (results, 0..) |res, i| {
                if (i > 0) try writer.writeByte('\t');
                if (res) |v| try writer.writeAll(v.raw);
            }
            try writer.writeByte('\n');
        },
    }
}

inline fn formatAggValue(state: AggState, comptime with_nulls: bool, writer: *std.Io.Writer) !void {
    switch (state) {
        .raw => if (with_nulls) try writer.writeAll("null"),
        .count => |c| try writer.print("{d}", .{c}),
        .sum => |s| try writer.print("{d:.4}", .{s}),
        .min => |m| if (m == std.math.inf(f64)) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{m}),
        .max => |m| if (m == -std.math.inf(f64)) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{m}),
        .avg => |a| if (a.count == 0) {
            if (with_nulls) try writer.writeAll("null");
        } else try writer.print("{d:.4}", .{a.sum / @as(f64, @floatFromInt(a.count))}),
    }
}

pub fn printAggregations(agg_states: []const AggState, plucks: []const CompiledPluck, format: cli.OutputFormat, writer: *std.Io.Writer) !void {
    if (format == .json) {
        try writer.writeAll("{");
        for (agg_states, 0..) |state, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeJsonKey(writer, plucks[i].original_str);
            try formatAggValue(state, true, writer);
        }
        try writer.writeAll("}\n");
    } else {
        const sep: u8 = if (format == .csv) ',' else '\t';
        for (agg_states, 0..) |state, i| {
            try formatAggValue(state, false, writer);
            if (i < agg_states.len - 1) try writer.writeByte(sep);
        }
        try writer.writeByte('\n');
    }
}

pub fn printHeader(plan: *const CompiledPlan, writer: *std.Io.Writer) !void {
    // JSON output carries field names in every object, so a header line would only corrupt it.
    if (!plan.header or plan.pluck.len == 0 or plan.count_only or plan.format == .json) return;
    for (plan.pluck, 0..) |p, idx| {
        if (plan.format == .csv) {
            if (idx > 0) try writer.writeByte(',');
            if (std.mem.findAny(u8, p.original_str, ",\"\n") != null) {
                try writeCsvField(writer, .{ .raw = p.original_str, .is_string = false });
            } else {
                try writer.writeAll(p.original_str);
            }
        } else {
            if (idx > 0) try writer.writeByte('\t');
            try writer.writeAll(p.original_str);
        }
    }
    try writer.writeByte('\n');
}

pub fn accumulate(state: *AggState, v: Value, sc: *Scratch) !void {
    if (!v.is_string and std.mem.eql(u8, v.raw, "null")) return;
    switch (state.*) {
        .raw => {},
        .count => |*c| c.* += 1,
        .sum, .min, .max, .avg => {
            const text = if (v.is_string) try stringText(.{ .raw = v.raw, .escaped = std.mem.findScalar(u8, v.raw, '\\') != null }, sc) else v.raw;
            const f = parseNumber(text) orelse return;
            switch (state.*) {
                .sum => |*s| s.* += f,
                .min => |*m| m.* = @min(m.*, f),
                .max => |*m| m.* = @max(m.*, f),
                .avg => |*a| {
                    a.sum += f;
                    a.count += 1;
                },
                .raw, .count => unreachable,
            }
        },
    }
}
