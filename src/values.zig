//! Reading JSON values out of raw line bytes: numbers, strings and whole values.
const std = @import("std");
const json = @import("json.zig");
const simd = @import("simd.zig");

const KeyFinder = @import("finder.zig").KeyFinder;

pub const Value = struct {
    /// String contents without the surrounding quotes (still JSON-escaped), or the literal,
    /// object or array text.
    raw: []const u8,
    is_string: bool,
};

/// Bytes that end a bare number or literal: separators, closing brackets and whitespace.
const term_mask = blk: {
    var mask = [_]bool{false} ** 256;
    for (",}] \t\r\n") |c| {
        mask[c] = true;
    }
    break :blk mask;
};

/// Whether `c` can end a number or literal (`true`, `false`, `null`).
pub inline fn isPrimitiveTerminator(c: u8) bool {
    return term_mask[c];
}

/// Parses a JSON integer. Up to 18 digits always fit in an i64 (10^18 < 2^63), so those skip
/// std.fmt.parseInt and accumulate directly. Longer inputs use parseInt, which reports overflow
/// as an error. The digit check in front of it rejects forms such as "+1" that parseInt accepts.
pub inline fn parseFastInt(text: []const u8) ?i64 {
    const neg = text.len > 0 and text[0] == '-';
    const digits = if (neg) text[1..] else text;
    if (digits.len == 0) return null;
    if (digits.len > 18) {
        for (digits) |c| {
            if (c < '0' or c > '9') return null;
        }

        return std.fmt.parseInt(i64, text, 10) catch null;
    }
    var result: i64 = 0;
    for (digits) |c| {
        // `-%` wraps bytes below '0' to large values, so one `> 9` test rejects those as well
        // as bytes above '9'.
        const digit = c -% '0';
        if (digit > 9) return null;
        result = result * 10 + @as(i64, digit);
    }
    return if (neg) -result else result;
}

/// Parses a JSON number. Rejects forms that std.fmt.parseFloat accepts but JSON doesn't
/// (inf, nan, hex), so strings like "nan" or "Infinity" aren't treated as numbers.
pub fn parseNumber(text: []const u8) ?f64 {
    // Plain integers take the integer path first. It is cheaper, and the conversion to f64
    // only rounds integers above 2^53.
    if (parseFastInt(text)) |int_value| {
        return @floatFromInt(int_value);
    }

    // The first digit comes after an optional '-'. This rejects forms like ".5" and "+1".
    const digits_start: usize = if (text.len > 0 and text[0] == '-') 1 else 0;
    if (digits_start >= text.len or text[digits_start] < '0' or text[digits_start] > '9') {
        return null;
    }
    // Only characters that can occur in a JSON number are allowed. This is what rules out
    // inf, nan and hex, which parseFloat would accept.
    for (text) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    return std.fmt.parseFloat(f64, text) catch null;
}

/// Holds decoded strings, reused across values.
pub const Scratch = struct {
    /// Allocator that grows `buf`.
    gpa: std.mem.Allocator,
    /// Decoded text of the most recent escaped string. Reused between decodes, so a result
    /// stays valid only until the next decode.
    buf: std.ArrayList(u8) = .empty,

    /// Decodes the JSON-escaped `raw_text` into `buf` and returns the decoded slice.
    fn decode(self: *Scratch, raw_text: []const u8) ![]const u8 {
        // Keep the buffer's capacity, so repeated decodes do not allocate.
        self.buf.clearRetainingCapacity();
        try json.decodeInto(&self.buf, self.gpa, raw_text);
        return self.buf.items;
    }
};

/// The raw text between a string's quotes, and whether that text contains a backslash.
const StrContents = struct { raw: []const u8, escaped: bool };

/// The raw contents of the string whose opening quote is at `value[0]`. Stops at the closing
/// quote, at a newline, or at the end of `value`.
pub fn stringContents(value: []const u8) StrContents {
    var end: usize = 1;
    var escaped = false;
    while (true) {
        end = findStringSpecial(value, end);
        if (end >= value.len or value[end] != '\\') {
            return .{ .raw = value[1..end], .escaped = escaped };
        }
        escaped = true;
        end = skipEscape(value, end);
    }
}

/// The position after the escape whose backslash is at `pos`. Skipping the escaped byte keeps
/// an escaped quote from ending the string. A newline is never skipped, though: it is not part
/// of an escape, and a value never extends past the end of its line.
inline fn skipEscape(text: []const u8, pos: usize) usize {
    if (pos + 1 < text.len and text[pos + 1] == '\n') return pos + 1;
    return @min(pos + 2, text.len);
}

/// The decoded text of a string. A string without escapes is returned as a slice of the
/// input. An escaped string is decoded into `scratch`, so it is valid until the next decode.
pub fn stringText(contents: StrContents, scratch: *Scratch) ![]const u8 {
    return if (contents.escaped) scratch.decode(contents.raw) else contents.raw;
}

/// The text of the number or literal at the start of `value`, up to the first terminator.
pub fn primitiveToken(value: []const u8) []const u8 {
    var end: usize = 0;
    while (end < value.len and !isPrimitiveTerminator(value[end])) end += 1;
    return value[0..end];
}

/// Index of the first '"', '\\' or '\n' at or after `start`, or `text.len` if there is none.
/// Checks one vector of bytes per step, then takes the lowest lane that matched.
fn findStringSpecial(text: []const u8, start: usize) usize {
    const backslash_vec: simd.V = @splat('\\');
    var pos = start;
    while (pos + simd.vector_len <= text.len) : (pos += simd.vector_len) {
        const chunk = simd.load(text, pos);
        const special = simd.vor(
            simd.vor(chunk == simd.quote_vec, chunk == backslash_vec),
            chunk == simd.nl_vec,
        );
        // The lowest set lane is the first special byte in this chunk.
        if (@reduce(.Or, special)) return pos + @ctz(@as(simd.Mask, @bitCast(special)));
    }
    // Fewer bytes than a vector are left, so scan them one at a time.
    while (pos < text.len and text[pos] != '"' and text[pos] != '\\' and text[pos] != '\n') {
        pos += 1;
    }
    return pos;
}

/// Extracts the value starting at `value[0]`, or returns null if there is none. Strings honour
/// escapes, objects and arrays are bracket-matched, and nothing extends past a newline.
fn extractValue(value: []const u8) ?Value {
    if (value.len == 0) return null;
    switch (value[0]) {
        '"' => {
            var pos: usize = 1;
            while (true) {
                pos = findStringSpecial(value, pos);

                // An unterminated string ends at a newline or at the end of the input.
                if (pos == value.len or value[pos] == '\n') {
                    return .{ .raw = value[1..pos], .is_string = true };
                }
                if (value[pos] == '"') {
                    return .{ .raw = value[1..pos], .is_string = true };
                }

                pos = skipEscape(value, pos);
            }
        },
        '{', '[' => {
            // `depth` counts open brackets, and the value ends where it returns to zero.
            var depth: usize = 0;
            var in_string = false;
            var pos: usize = 0;
            while (pos < value.len) : (pos += 1) {
                const c = value[pos];
                // A newline ends the value, even inside a string.
                if (c == '\n') break;
                if (in_string) {
                    // A backslash skips the next byte, so an escaped quote does not end the
                    // string. The newline that ends the line is never skipped.
                    if (c == '\\') {
                        pos = skipEscape(value, pos) - 1;
                    } else if (c == '"') {
                        in_string = false;
                    }
                    continue;
                }

                switch (c) {
                    '"' => in_string = true,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) {
                            return .{ .raw = value[0 .. pos + 1], .is_string = false };
                        }
                    },
                    else => {},
                }
            }
            // The value never closed. It runs up to the newline or the end of the input.
            return .{ .raw = value[0..pos], .is_string = false };
        },
        else => {
            // A bare number or literal ends at its first terminator.
            var end: usize = 0;
            while (end < value.len and !isPrimitiveTerminator(value[end])) : (end += 1) {}
            // Starts with a terminator, such as `,` or `]`, so there is no value here.
            if (end == 0) return null;
            return .{ .raw = value[0..end], .is_string = false };
        },
    }
}

/// The value of the first occurrence of the key in `line`, at any depth (--fast).
pub fn extractField(line: []const u8, finder: *const KeyFinder) ?Value {
    const hit = finder.next(line, 0) orelse return null;
    return extractValue(line[hit.val_pos..]);
}

/// The value in an exact-parser slot, in the form `extractValue` gives. A slot holds a string
/// with its quotes, which are stripped here.
pub fn slotValue(slot: ?[]const u8) ?Value {
    const slot_text = slot orelse return null;
    if (slot_text[0] == '"') {
        return .{ .raw = slot_text[1 .. slot_text.len - 1], .is_string = true };
    }
    return .{ .raw = slot_text, .is_string = false };
}

const testing = std.testing;

test "a backslash before a newline does not escape it" {
    const contents = stringContents("\"abc\\\n{\"b\":1}");
    try testing.expectEqualStrings("abc\\", contents.raw);
    try testing.expect(contents.escaped);

    try testing.expectEqualStrings("abc\\", extractValue("\"abc\\\n\"").?.raw);
    try testing.expectEqualStrings("[\"x\\", extractValue("[\"x\\\n]").?.raw);
}

test "parseFastInt" {
    try testing.expectEqual(@as(?i64, -42), parseFastInt("-42"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("-"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("1.5"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseFastInt("9223372036854775807"));
    try testing.expectEqual(@as(?i64, null), parseFastInt("9223372036854775808"));
}
