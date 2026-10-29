const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const Scanner = @import("scanner.zig");

const Config = cli.Config;
const parseArgs = cli.parseArgs;
const printUsage = cli.printUsage;

pub const VERSION = build_options.version;

/// Exit codes follow grep: 0 = match found, 1 = no match, 2 = error.
pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, allocator) catch return outOfMemory();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| args.append(allocator, arg) catch return outOfMemory();

    const command = parseArgs(allocator, args.items) catch |err| {
        const msg = switch (err) {
            error.MissingFileValue => "Error: --file requires a path argument.",
            error.MissingLimitValue => "Error: --limit requires a number.",
            error.InvalidLimit => "Error: --limit must be a non-negative integer.",
            error.MissingFormatValue => "Error: --format requires 'json', 'csv', or 'tsv'.",
            error.InvalidCondition => "Error: Incomplete WHERE condition. Use <key> <op> <val>.",
            error.UnknownOperator => "Error: Invalid operator. Supported: eq, neq, gt, lt, gte, lte, has, exists, in.",
            error.UnknownOption => "Error: Unknown option. Put '--' before query terms that start with '--'.",
            error.MissingArguments => "Error: No query provided. You must provide a search condition or a SELECT clause.",
            error.TooManyPluckFields => "Error: Too many SELECT fields (max 256).",
            error.InvalidSelectField => "Error: Aggregation needs a field name (e.g. sum:balance).",
            error.InvalidFormat => "Error: --format must be 'json', 'csv', or 'tsv'.",
            error.OutOfMemory => return outOfMemory(),
        };
        std.debug.print("{s}\n\n", .{msg});
        printUsage();
        return 2;
    };

    const config = switch (command) {
        .help => {
            printUsage();
            return 0;
        },
        .version => {
            var ver_buf: [64]u8 = undefined;
            var ver_writer = std.Io.File.stdout().writerStreaming(io, &ver_buf);
            ver_writer.interface.print("zog v{s}\n", .{VERSION}) catch {};
            ver_writer.interface.flush() catch {};
            return 0;
        },
        .run => |c| c,
    };

    if (config.file_path == null) {
        if (std.Io.File.stdin().isTty(io) catch false) {
            std.debug.print("Error: No input file specified and no data piped to stdin.\n", .{});
            std.debug.print("Provide a file with '--file <path>' or pipe data: 'cat logs.jsonl | zog ...'\n", .{});
            std.debug.print("Run 'zog --help' for usage information.\n", .{});
            return 2;
        }
    }

    var stdout_buffer: [128 * 1024]u8 = undefined;
    // Streaming rather than positional, so `zog ... >> out` appends instead of overwriting
    // the file from offset 0.
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const matched = runQuery(allocator, config, stdout, io) catch |err| {
        switch (err) {
            error.WriteFailed => {
                const write_err = stdout_writer.err orelse error.WriteFailed;
                // The reader went away (e.g. `zog ... | head -1`): not an error for us.
                if (write_err == error.BrokenPipe) return 0;
                std.debug.print("zog: write error: {s}\n", .{@errorName(write_err)});
            },
            error.NonNumericComparison => std.debug.print("zog: gt, lt, gte and lte need a numeric value.\n", .{}),
            error.InvalidKey => std.debug.print("zog: keys can't be empty or have empty path segments.\n", .{}),
            error.FileNotFound => std.debug.print("zog: {s}: No such file\n", .{config.file_path.?}),
            else => if (config.file_path) |path|
                std.debug.print("zog: {s}: {s}\n", .{ path, @errorName(err) })
            else
                std.debug.print("zog: {s}\n", .{@errorName(err)}),
        }
        return 2;
    };
    return if (matched == 0) 1 else 0;
}

fn runQuery(allocator: std.mem.Allocator, config: Config, stdout: *std.Io.Writer, io: std.Io) !usize {
    const matched = if (config.file_path != null)
        try Scanner.searchFile(allocator, config, stdout, io)
    else
        try Scanner.searchStream(allocator, config, stdout, io);
    try stdout.flush();
    return matched;
}

fn outOfMemory() u8 {
    std.debug.print("zog: out of memory\n", .{});
    return 2;
}

test {
    _ = cli;
    _ = Scanner;
}
