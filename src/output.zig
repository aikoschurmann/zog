//! Writing results: selected fields as TSV, CSV or JSON, headers, and aggregations.
const std = @import("std");
const cli = @import("cli.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");

const Value = values.Value;

/// Writes `text` with JSON escapes. Control characters without a short escape become \u00XX.
fn writeJsonEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

/// `text` JSON-escaped, and wrapped in quotes when `quoted` is set.
pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, text: []const u8, quoted: bool) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);

    if (quoted) try allocating.writer.writeByte('"');
    try writeJsonEscaped(&allocating.writer, text);
    if (quoted) try allocating.writer.writeByte('"');
    return allocating.toOwnedSlice();
}

/// The running state of one SELECT field. `raw` fields are plain values, not aggregations.
pub const AggState = union(enum) {
    raw: void,
    count: usize,
    sum: f64,
    /// Starts at +inf, so it stays +inf until a number is seen.
    min: f64,
    /// Starts at -inf, so it stays -inf until a number is seen.
    max: f64,
    avg: struct { sum: f64, count: usize },
};

/// Writes one byte inside a CSV quoted field. A quote is doubled, which is CSV's escape.
fn writeCsvByte(writer: *std.Io.Writer, byte: u8) !void {
    if (byte == '"') {
        try writer.writeAll("\"\"");
    } else {
        try writer.writeByte(byte);
    }
}

/// Parses the four hex digits of a `\u` escape, or returns null if they are missing or invalid.
fn parseHex4(hex: []const u8) ?u16 {
    if (hex.len < 4) return null;
    return std.fmt.parseInt(u16, hex[0..4], 16) catch null;
}

/// Writes the contents of a JSON string with escapes decoded, doubling quotes for CSV.
fn writeCsvUnescaped(writer: *std.Io.Writer, raw: []const u8) !void {
    var pos: usize = 0;

    while (pos < raw.len) {
        const byte = raw[pos];
        // A backslash at the very end has no escape character after it, so it is copied as is.
        if (byte != '\\' or pos + 1 == raw.len) {
            try writeCsvByte(writer, byte);
            pos += 1;
            continue;
        }

        const escape = raw[pos + 1];
        pos += 2;
        switch (escape) {
            'n' => try writer.writeByte('\n'),
            't' => try writer.writeByte('\t'),
            'r' => try writer.writeByte('\r'),
            'b' => try writer.writeByte(0x08),
            'f' => try writer.writeByte(0x0c),
            'u' => {
                // A malformed `\u` escape is kept as text. The characters after it are then
                // copied by the loop as they are.
                const unit = parseHex4(raw[pos..]) orelse {
                    try writer.writeAll("\\u");
                    continue;
                };
                pos += 4;

                var code_point: u21 = unit;
                // A high surrogate followed by an escaped low surrogate encodes one code point
                // outside the BMP. Any other surrogate is not valid UTF-8 and becomes U+FFFD.
                if (unit >= 0xd800 and unit <= 0xdbff and pos + 6 <= raw.len and
                    raw[pos] == '\\' and raw[pos + 1] == 'u')
                {
                    if (parseHex4(raw[pos + 2 ..])) |low| {
                        if (low >= 0xdc00 and low <= 0xdfff) {
                            code_point = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                            pos += 6;
                        }
                    }
                }

                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code_point, &utf8) catch {
                    try writer.writeAll("\u{fffd}");
                    continue;
                };
                try writer.writeAll(utf8[0..len]);
            },
            // Quotes, backslashes and slashes stand for themselves.
            else => try writeCsvByte(writer, escape),
        }
    }
}

/// Writes one CSV field. Value fields are always quoted, so commas and newlines inside them
/// need no care. Strings are JSON-decoded first.
fn writeCsvField(writer: *std.Io.Writer, value: Value) !void {
    try writer.writeByte('"');
    if (value.is_string) {
        try writeCsvUnescaped(writer, value.raw);
    } else {
        for (value.raw) |byte| try writeCsvByte(writer, byte);
    }
    try writer.writeByte('"');
}

fn writeJsonKey(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonEscaped(writer, name);
    try writer.writeAll("\": ");
}

/// Writes the SELECT fields of one matching line. A missing field is empty, or `null` in JSON.
pub fn printFormatted(
    results: []const ?Value,
    plucks: []const compile.CompiledPluck,
    format: cli.OutputFormat,
    writer: *std.Io.Writer,
) !void {
    switch (format) {
        .json => {
            try writer.writeByte('{');
            for (results, plucks, 0..) |result, pluck, index| {
                if (index > 0) try writer.writeAll(", ");
                try writeJsonKey(writer, pluck.original_str);

                // A string's raw text still has its JSON escapes, so it is written between
                // quotes unchanged. Other values are valid JSON as they are.
                if (result) |value| {
                    if (value.is_string) {
                        try writer.writeByte('"');
                        try writer.writeAll(value.raw);
                        try writer.writeByte('"');
                    } else {
                        try writer.writeAll(value.raw);
                    }
                } else {
                    try writer.writeAll("null");
                }
            }
            try writer.writeAll("}\n");
        },
        .csv => {
            for (results, 0..) |result, index| {
                if (index > 0) try writer.writeByte(',');
                if (result) |value| try writeCsvField(writer, value);
            }
            try writer.writeByte('\n');
        },
        .tsv => {
            // Raw text is written unchanged. String escapes stay escaped, so a value cannot
            // put a literal tab or newline into the row.
            for (results, 0..) |result, index| {
                if (index > 0) try writer.writeByte('\t');
                if (result) |value| try writer.writeAll(value.raw);
            }
            try writer.writeByte('\n');
        },
    }
}

/// Writes one aggregation value. An aggregation with nothing folded in has no value: it is
/// `null` in JSON (`with_nulls`) and an empty field in TSV and CSV. A sum of nothing is 0.
/// min and max are checked against their +inf and -inf starting values for the same reason.
inline fn formatAggValue(state: AggState, comptime with_nulls: bool, writer: *std.Io.Writer) !void {
    switch (state) {
        .raw => {
            if (with_nulls) try writer.writeAll("null");
        },
        .count => |count| try writer.print("{d}", .{count}),
        .sum => |sum| try writer.print("{d:.4}", .{sum}),
        .min => |min_value| {
            if (min_value == std.math.inf(f64)) {
                if (with_nulls) try writer.writeAll("null");
            } else {
                try writer.print("{d:.4}", .{min_value});
            }
        },
        .max => |max_value| {
            if (max_value == -std.math.inf(f64)) {
                if (with_nulls) try writer.writeAll("null");
            } else {
                try writer.print("{d:.4}", .{max_value});
            }
        },
        .avg => |avg| {
            if (avg.count == 0) {
                if (with_nulls) try writer.writeAll("null");
            } else {
                try writer.print("{d:.4}", .{avg.sum / @as(f64, @floatFromInt(avg.count))});
            }
        },
    }
}

/// Writes the single result row of an aggregating query.
pub fn printAggregations(
    agg_states: []const AggState,
    plucks: []const compile.CompiledPluck,
    format: cli.OutputFormat,
    writer: *std.Io.Writer,
) !void {
    if (format == .json) {
        try writer.writeAll("{");
        for (agg_states, 0..) |state, index| {
            if (index > 0) try writer.writeAll(", ");
            try writeJsonKey(writer, plucks[index].original_str);
            try formatAggValue(state, true, writer);
        }
        try writer.writeAll("}\n");
    } else {
        const separator: u8 = if (format == .csv) ',' else '\t';
        for (agg_states, 0..) |state, index| {
            try formatAggValue(state, false, writer);
            if (index < agg_states.len - 1) try writer.writeByte(separator);
        }
        try writer.writeByte('\n');
    }
}

/// Writes the column names, if --header was given and the output has columns.
pub fn printHeader(plan: *const compile.CompiledPlan, writer: *std.Io.Writer) !void {
    // JSON output carries field names in every object, so a header line would only corrupt it.
    if (!plan.header or plan.pluck.len == 0 or plan.count_only or plan.format == .json) return;

    for (plan.pluck, 0..) |pluck, index| {
        if (plan.format == .csv) {
            if (index > 0) try writer.writeByte(',');
            // Unlike value fields, header names are quoted only when they need it.
            if (std.mem.findAny(u8, pluck.original_str, ",\"\n") != null) {
                try writeCsvField(writer, .{ .raw = pluck.original_str, .is_string = false });
            } else {
                try writer.writeAll(pluck.original_str);
            }
        } else {
            if (index > 0) try writer.writeByte('\t');
            try writer.writeAll(pluck.original_str);
        }
    }
    try writer.writeByte('\n');
}

/// Folds one value into an aggregation. A `null` value is skipped by every aggregation.
/// Non-numeric values are skipped by sum, min, max and avg, but `count` counts them.
pub fn accumulate(state: *AggState, value: Value, scratch: *values.Scratch) !void {
    if (!value.is_string and std.mem.eql(u8, value.raw, "null")) return;

    switch (state.*) {
        .raw => {},
        .count => |*count| count.* += 1,
        .sum, .min, .max, .avg => {
            // A string only needs decoding when it has a backslash in it.
            const escaped = std.mem.findScalar(u8, value.raw, '\\') != null;
            const text = if (value.is_string)
                try values.stringText(.{ .raw = value.raw, .escaped = escaped }, scratch)
            else
                value.raw;
            const number = values.parseNumber(text) orelse return;

            switch (state.*) {
                .sum => |*sum| sum.* += number,
                .min => |*min_value| min_value.* = @min(min_value.*, number),
                .max => |*max_value| max_value.* = @max(max_value.*, number),
                .avg => |*avg| {
                    avg.sum += number;
                    avg.count += 1;
                },
                .raw, .count => unreachable,
            }
        },
    }
}
