const std = @import("std");
const Scanner = @import("Scanner.zig");

const Config = struct {
    file_path: ?[]const u8 = null, // Now optional!
    key: []const u8 = "",
    val: []const u8 = "",
    pluck: ?[]const u8 = null,     // New pluck feature!
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.debug.print("Usage: zog [--file <path>] --key <key> --val <val> [--pluck <extract_key>]\n", .{});
        std.process.exit(1);
    };

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    defer bw.flush() catch {};

    // Route traffic based on whether a file was provided or if we should read from stdin
    if (config.file_path) |path| {
        try Scanner.searchFile(path, config.key, config.val, config.pluck, stdout);
    } else {
        try Scanner.searchStream(config.key, config.val, config.pluck, stdout);
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); 

    var config = Config{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            config.file_path = args.next() orelse return error.MissingFileValue;
        } else if (std.mem.eql(u8, arg, "--key")) {
            config.key = args.next() orelse return error.MissingKeyValue;
        } else if (std.mem.eql(u8, arg, "--val")) {
            config.val = args.next() orelse return error.MissingValValue;
        } else if (std.mem.eql(u8, arg, "--pluck")) {
            config.pluck = args.next() orelse return error.MissingPluckValue;
        } else {
            return error.InvalidArgument;
        }
    }

    if (config.key.len == 0 or config.val.len == 0) {
        return error.MissingArguments;
    }
    return config;
}