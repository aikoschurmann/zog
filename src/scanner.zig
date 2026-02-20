const std = @import("std");

/// Checks if a JSON line contains `"key": "val"`, ignoring spaces, tabs, or colons.
fn lineMatches(line: []const u8, key_quoted: []const u8, val_quoted: []const u8) bool {
    const vector_len = 32; 
    const V = @Vector(vector_len, u8);
    const first_char_vec: V = @splat(key_quoted[0]);
    
    var i: usize = 0;
    // 1. SIMD Loop
    while (i + vector_len <= line.len) {
        const chunk: V = line[i..][0..vector_len].*;
        const matches = chunk == first_char_vec;

        if (@reduce(.Or, matches)) {
            var mask = @as(u32, @bitCast(matches));
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const pos = i + bit_pos;
                
                // Potential key match
                if (std.mem.startsWith(u8, line[pos..], key_quoted)) {
                    const rest = line[pos + key_quoted.len..];
                    // Find where the value starts (skip spaces/tabs/colons)
                    if (std.mem.indexOfNone(u8, rest, " \t:")) |start_idx| {
                        if (std.mem.startsWith(u8, rest[start_idx..], val_quoted)) return true;
                    }
                    // If this specific occurrence didn't match, DON'T return false.
                    // Keep loop going for other occurrences in the same chunk/line.
                }
                mask &= mask - 1; 
            }
        }
        i += vector_len;
    }

    // 2. Tail Processing (Iterative for 100% Accuracy)
    var tail = line[i..];
    while (std.mem.indexOf(u8, tail, key_quoted)) |key_pos| {
        const rest = tail[key_pos + key_quoted.len..];
        if (std.mem.indexOfNone(u8, rest, " \t:")) |start_idx| {
            if (std.mem.startsWith(u8, rest[start_idx..], val_quoted)) return true;
        }
        tail = rest; // Advance search pointer
    }

    return false;
}

/// Finds a key in a JSON line and extracts its value (string, number, or boolean) without allocating memory.
/// This version correctly handles escaped quotes and false positive keys inside other strings.
fn extractValue(line: []const u8, pluck_key_quoted: []const u8) ?[]const u8 {
    var search_slice = line;
    
    // 1. Iterative Search: Look for the key multiple times if the first match is a false positive
    while (std.mem.indexOf(u8, search_slice, pluck_key_quoted)) |key_pos| {
        const rest = search_slice[key_pos + pluck_key_quoted.len ..];

        // 2. High-Performance Skip: Find where the value actually starts
        const start_idx = std.mem.indexOfNone(u8, rest, " \t:") orelse return null;
        const val_start = rest[start_idx..];

        if (val_start.len == 0) return null;

        // 3. Handle Quoted Strings
        if (val_start[0] == '"') {
            const content_start = 1; // skip opening quote
            var i: usize = content_start;
            while (i < val_start.len) : (i += 1) {
                if (val_start[i] == '"') {
                    // Backslash Counting: Determine if this quote is escaped
                    var backslash_count: usize = 0;
                    var j = i;
                    while (j > content_start) {
                        j -= 1;
                        if (val_start[j] == '\\') {
                            backslash_count += 1;
                        } else break;
                    }
                    
                    // If count is even (0, 2, 4...), the quote is NOT escaped.
                    if (backslash_count % 2 == 0) return val_start[content_start..i];
                }
            }
            // If string never closes, it might be an invalid occurrence; continue search.
        } else {
            // 4. Handle Numbers, Booleans, or Null
            var i: usize = 0;
            while (i < val_start.len) : (i += 1) {
                const c = val_start[i];
                // JSON delimiters for unquoted values
                if (c == ',' or c == '}' or c == ' ' or c == '\r' or c == '\n') {
                    return val_start[0..i];
                }
            }
            // End of line reached
            return val_start;
        }
        
        // Advance search slice to look for the next occurrence of the key in this line
        search_slice = rest;
    }
    
    return null;
}

/// Helper to handle what gets printed (the whole line, or just the plucked value)
fn handleMatch(line: []const u8, pluck_key_quoted: ?[]const u8, writer: anytype) !void {
    if (pluck_key_quoted) |pk| {
        if (extractValue(line, pk)) |val| {
            try writer.print("{s}\n", .{val});
        }
    } else {
        try writer.print("{s}\n", .{line});
    }
}

/// Parses a live stream (like piped stdin) line-by-line using a 64KB stack buffer.
pub fn searchStream(key: []const u8, val: []const u8, pluck: ?[]const u8, writer: anytype) !void {
    // 1. Build the quoted needles on the stack (increased to 4KB to prevent overflow)
    var key_buf: [4096]u8 = undefined;
    const key_quoted = try std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key});
    var val_buf: [4096]u8 = undefined;
    const val_quoted = try std.fmt.bufPrint(&val_buf, "\"{s}\"", .{val});
    
    var pluck_buf: [4096]u8 = undefined;
    var pluck_quoted: ?[]const u8 = null;
    if (pluck) |p| pluck_quoted = try std.fmt.bufPrint(&pluck_buf, "\"{s}\"", .{p});

    // 2. Setup a large Chunk Buffer (256KB)
    const chunk_size = 256 * 1024;
    var buffer: [chunk_size]u8 = undefined;
    var bytes_in_buffer: usize = 0;

    const stdin = std.io.getStdIn().reader();

    // SIMD Setup
    const vector_len = 64;
    const V = @Vector(vector_len, u8);
    const newline_vec: V = @splat('\n');

    while (true) {
        // Read into the buffer, starting AFTER any leftover partial line
        const read_count = try stdin.read(buffer[bytes_in_buffer..]);
        if (read_count == 0 and bytes_in_buffer == 0) break;
        
        const total_data = bytes_in_buffer + read_count;
        var start_of_line: usize = 0;
        var i: usize = 0;

        // 3. The SIMD Loop utilizing high-speed bitmask iteration
        while (i + vector_len <= total_data) : (i += vector_len) {
            const chunk: V = buffer[i..][0..vector_len].*;
            const matches = chunk == newline_vec;
            const mask = @as(u64, @bitCast(matches));

            if (mask != 0) {
                var iter_mask = mask;
                while (iter_mask != 0) {
                    const nl_pos = @ctz(iter_mask);
                    const absolute_nl_pos = i + nl_pos;
                    const line = buffer[start_of_line..absolute_nl_pos];
                    
                    if (lineMatches(line, key_quoted, val_quoted)) {
                        try handleMatch(line, pluck_quoted, writer);
                    }
                    start_of_line = absolute_nl_pos + 1;
                    iter_mask &= iter_mask - 1; // Clear bit to advance
                }
            }
        }

        // 4. Handle Leftovers (The "Shift")
        // If there is data left after the last newline, move it to the front
        if (start_of_line < total_data) {
            const leftover_len = total_data - start_of_line;
            // If the leftover is too big for our buffer, the line is > 256KB
            if (leftover_len == chunk_size) return error.LineTooLong;
            
            std.mem.copyForwards(u8, buffer[0..leftover_len], buffer[start_of_line..total_data]);
            bytes_in_buffer = leftover_len;
        } else {
            bytes_in_buffer = 0;
        }

        if (read_count == 0) {
            // End of stream: process the very last line if it didn't end in \n
            if (bytes_in_buffer > 0) {
                const last_line = std.mem.trimRight(u8, buffer[0..bytes_in_buffer], "\r\n");
                if (last_line.len > 0 and lineMatches(last_line, key_quoted, val_quoted)) {
                    try handleMatch(last_line, pluck_quoted, writer);
                }
            }
            break;
        }
    }
}

/// Maps a physical file to memory and processes it using SIMD vectors.
pub fn searchFile(file_path: []const u8, key: []const u8, val: []const u8, pluck: ?[]const u8, writer: anytype) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.metadata()).size();
    if (file_size == 0) return;

    const file_contents = try std.posix.mmap(
        null, file_size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0,
    );
    defer std.posix.munmap(file_contents);

    var key_buf: [4096]u8 = undefined;
    const key_quoted = try std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key});

    var val_buf: [4096]u8 = undefined;
    const val_quoted = try std.fmt.bufPrint(&val_buf, "\"{s}\"", .{val});

    var pluck_buf: [4096]u8 = undefined;
    var pluck_quoted: ?[]const u8 = null;
    if (pluck) |p| {
        pluck_quoted = try std.fmt.bufPrint(&pluck_buf, "\"{s}\"", .{p});
    }

    const vector_len = 64;
    const V = @Vector(vector_len, u8);
    const newline_vec: V = @splat('\n');

    var start_of_line: usize = 0;
    var i: usize = 0;

    // SIMD Loop utilizing high-speed bitmask iteration
    while (i + vector_len <= file_contents.len) : (i += vector_len) {
        const chunk: V = file_contents[i..][0..vector_len].*;
        const matches = chunk == newline_vec;
        const mask = @as(u64, @bitCast(matches));

        if (mask != 0) {
            var iter_mask = mask;
            while (iter_mask != 0) {
                const nl_pos = @ctz(iter_mask);
                const absolute_nl_pos = i + nl_pos;
                const line = file_contents[start_of_line..absolute_nl_pos];

                if (lineMatches(line, key_quoted, val_quoted)) {
                    try handleMatch(line, pluck_quoted, writer);
                }

                start_of_line = absolute_nl_pos + 1;
                iter_mask &= iter_mask - 1; // Clear bit to advance
            }
        }
    }

    // Process the final tail of the file
    if (start_of_line < file_contents.len) {
        const raw_tail = file_contents[start_of_line..];
        // We trim the right to avoid double-newlines and ghost results
        const last_line = std.mem.trimRight(u8, raw_tail, "\r\n");
        
        if (last_line.len > 0 and lineMatches(last_line, key_quoted, val_quoted)) {
            try handleMatch(last_line, pluck_quoted, writer);
        }
    }
}

// ==========================================
// TESTS
// ==========================================
const testing = std.testing;

test "lineMatches ignores spaces and colons" {
    const key = "\"level\"";
    const val = "\"error\"";

    // Standard format
    try testing.expect(lineMatches("{\"level\":\"error\"}", key, val) == true);
    // Spaced format
    try testing.expect(lineMatches("{\"level\": \"error\"}", key, val) == true);
    // Ugly formatting
    try testing.expect(lineMatches("{\"level\"   :   \"error\"}", key, val) == true);
    // False positive check
    try testing.expect(lineMatches("{\"level\":\"info\"}", key, val) == false);
}

test "extractValue plucks strings and numbers" {
    const key = "\"user_id\"";

    // Pluck a number
    const val1 = extractValue("{\"user_id\": 404, \"name\": \"bob\"}", key);
    try testing.expectEqualStrings("404", val1.?);

    // Pluck a string
    const val2 = extractValue("{\"user_id\": \"uuid-123\"}", key);
    try testing.expectEqualStrings("uuid-123", val2.?);
}

test "lineMatches handles iterative matching and false positives" {
    const key = "\"level\"";
    const val = "\"error\"";

    // The key appears first inside a string value (false positive), 
    // but the real match comes later.
    try testing.expect(lineMatches("{\"msg\": \"the level is info\", \"level\": \"error\"}", key, val) == true);

    // Key appears multiple times, none match the value.
    try testing.expect(lineMatches("{\"msg\": \"level: error\", \"level\": \"info\"}", key, val) == false);
}

test "extractValue handles complex literal backslashes" {
    const key = "\"path\"";

    // Goal: Value is a literal double-backslash: \\
    // JSON needs 4 backslashes: "path": "\\\\"
    // Zig source needs 8 backslashes:
    const val = extractValue("{\"path\": \"\\\\\\\\\"}", key);
    
    // This will succeed because backslash_count is 4 (even).
    try testing.expectEqualStrings("\\\\\\\\", val.?); 
}

test "extractValue plucks booleans and nulls" {
    // Test true
    const val_true = extractValue("{\"active\": true, \"id\": 1}", "\"active\"");
    try testing.expectEqualStrings("true", val_true.?);

    // Test false
    const val_false = extractValue("{\"active\": false}", "\"active\"");
    try testing.expectEqualStrings("false", val_false.?);

    // Test null
    const val_null = extractValue("{\"data\": null, \"active\": true}", "\"data\"");
    try testing.expectEqualStrings("null", val_null.?);
}

test "extractValue edge cases" {
    const key = "\"id\"";

    // Value at the very end of the string (no trailing comma or brace)
    try testing.expectEqualStrings("123", extractValue("\"id\":123", key).?);

    // Deeply nested lookalike key
    const nested = "{\"outer\": {\"id\": 1}, \"id\": 2}";
    try testing.expectEqualStrings("1", extractValue(nested, key).?);
    
    // Key not found
    try testing.expect(extractValue("{\"name\": \"bob\"}", key) == null);
}