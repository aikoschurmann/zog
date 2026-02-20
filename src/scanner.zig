const std = @import("std");

/// Checks if a JSON line contains `"key": "val"`, ignoring spaces, tabs, or colons.
fn lineMatches(line: []const u8, key_quoted: []const u8, val_quoted: []const u8) bool {
    const key_pos = std.mem.indexOf(u8, line, key_quoted) orelse return false;
    const rest_of_line = line[key_pos + key_quoted.len ..];

    var i: usize = 0;
    while (i < rest_of_line.len) : (i += 1) {
        const c = rest_of_line[i];
        if (c == ' ' or c == '\t' or c == ':') {
            continue;
        } else break;
    }
    return std.mem.startsWith(u8, rest_of_line[i..], val_quoted);
}

// Finds a key in a JSON line and extracts its value (string, number, or boolean) without allocating memory.
fn extractValue(line: []const u8, pluck_key_quoted: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, line, pluck_key_quoted) orelse return null;
    const rest = line[key_pos + pluck_key_quoted.len ..];

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c == ' ' or c == '\t' or c == ':') continue else break;
    }

    if (i >= rest.len) return null;

    if (rest[i] == '"') {
        i += 1;
        const start = i;
        while (i < rest.len) : (i += 1) {
            if (rest[i] == '"' and rest[i - 1] != '\\') return rest[start..i];
        }
    } else {
        const start = i;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
$            if (c == ',' or c == '}' or c == ' ' or c == '\r' or c == '\n') {
                return rest[start..i];
            }
        }
        if (start < rest.len) return rest[start..];
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
    // 1. Build the quoted needles on the stack
    var key_buf: [128]u8 = undefined;
    const key_quoted = try std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key});
    var val_buf: [128]u8 = undefined;
    const val_quoted = try std.fmt.bufPrint(&val_buf, "\"{s}\"", .{val});
    
    var pluck_buf: [128]u8 = undefined;
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

        // 3. The SIMD Loop idem to mmap
        while (i + vector_len <= total_data) : (i += vector_len) {
            const chunk: V = buffer[i..][0..vector_len].*;
            const matches = chunk == newline_vec;

            if (@reduce(.Or, matches)) {
                var chunk_offset: usize = 0;
                const current_slice = buffer[i .. i + vector_len];

                while (std.mem.indexOfScalar(u8, current_slice[chunk_offset..], '\n')) |nl_pos| {
                    const absolute_nl_pos = i + chunk_offset + nl_pos;
                    const line = buffer[start_of_line..absolute_nl_pos];
                    
                    if (lineMatches(line, key_quoted, val_quoted)) {
                        try handleMatch(line, pluck_quoted, writer);
                    }
                    start_of_line = absolute_nl_pos + 1;
                    chunk_offset += nl_pos + 1;
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

    var key_buf: [128]u8 = undefined;
    const key_quoted = try std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key});

    var val_buf: [128]u8 = undefined;
    const val_quoted = try std.fmt.bufPrint(&val_buf, "\"{s}\"", .{val});

    var pluck_buf: [128]u8 = undefined;
    var pluck_quoted: ?[]const u8 = null;
    if (pluck) |p| {
        pluck_quoted = try std.fmt.bufPrint(&pluck_buf, "\"{s}\"", .{p});
    }

    const vector_len = 64;
    const V = @Vector(vector_len, u8);
    const newline_vec: V = @splat('\n');

    var start_of_line: usize = 0;
    var i: usize = 0;

    while (i + vector_len <= file_contents.len) : (i += vector_len) {
        const chunk: V = file_contents[i..][0..vector_len].*;
        const matches = chunk == newline_vec;

        if (@reduce(.Or, matches)) {
            var chunk_offset: usize = 0;
            const current_slice = file_contents[i .. i + vector_len];

            while (std.mem.indexOfScalar(u8, current_slice[chunk_offset..], '\n')) |nl_pos| {
                const absolute_nl_pos = i + chunk_offset + nl_pos;
                const line = file_contents[start_of_line..absolute_nl_pos];

                if (lineMatches(line, key_quoted, val_quoted)) {
                    try handleMatch(line, pluck_quoted, writer);
                }

                start_of_line = absolute_nl_pos + 1;
                chunk_offset += nl_pos + 1;
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