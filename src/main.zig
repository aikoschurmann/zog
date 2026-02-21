const std = @import("std");
const Scanner = @import("scanner.zig");

// Define our raw CLI structures
pub const Condition = struct {
    key: []const u8,
    val: []const u8,
};

pub const ConditionGroup = struct {
    conditions: []Condition,
};

const Config = struct {
    file_path: ?[]const u8 = null,
    groups: []ConditionGroup,
    pluck: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Fix: Omit the capture entirely as required by Zig when not used
    const config = parseArgs(allocator) catch {
        std.debug.print("Usage: zog [--file <path>] --key <key> --val <val> [--or ...] [--pluck <key>]\n", .{});
        std.process.exit(1);
    };

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // Route to searchFile for high-speed macOS hints, or searchStream for pipes
    if (config.file_path) |path| {
        try Scanner.searchFile(allocator, path, config.groups, config.pluck, stdout);
    } else {
        try Scanner.searchStream(allocator, config.groups, config.pluck, stdout);
    }

    // Flush to ensure all results are written before the program exits
    try bw.flush();
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var config = Config{ .groups = undefined };
    var groups = std.ArrayList(ConditionGroup).init(allocator);
    var current_conditions = std.ArrayList(Condition).init(allocator);
    var current_key: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            config.file_path = try allocator.dupe(u8, args.next() orelse return error.MissingFileValue);
        } else if (std.mem.eql(u8, arg, "--key")) {
            current_key = try allocator.dupe(u8, args.next() orelse return error.MissingKeyValue);
        } else if (std.mem.eql(u8, arg, "--val")) {
            const val = try allocator.dupe(u8, args.next() orelse return error.MissingValValue);
            if (current_key) |k| {
                try current_conditions.append(.{ .key = k, .val = val });
                current_key = null;
            } else {
                return error.ValWithoutKey;
            }
        } else if (std.mem.eql(u8, arg, "--or")) {
            if (current_conditions.items.len == 0) return error.EmptyOrGroup;
            // Save the current AND group and start a new one
            try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
            current_conditions = std.ArrayList(Condition).init(allocator);
        } else if (std.mem.eql(u8, arg, "--pluck")) {
            config.pluck = try allocator.dupe(u8, args.next() orelse return error.MissingPluckValue);
        } else {
            return error.InvalidArgument;
        }
    }

    // Append the final group
    if (current_conditions.items.len > 0) {
        try groups.append(.{ .conditions = try current_conditions.toOwnedSlice() });
    }

    if (groups.items.len == 0) return error.MissingArguments;
    config.groups = try groups.toOwnedSlice();
    return config;
}