const std = @import("std");
const clap = @import("clap");
const common = @import("common");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-V, --version          Output version information and exit.
        \\-n, --number           Number all output lines.
        \\-b, --number-nonblank  Number non-empty output lines.
        \\-s, --squeeze-blank    Suppress repeated empty output lines.
        \\-E, --show-ends        Display $ at end of each line.
        \\-T, --show-tabs        Display TAB characters as ^I.
        \\-v, --show-nonprinting Use ^ and M- notation, except for LFD and TAB.
        \\<file>...              Files to concatenate.
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("Usage: cat [OPTION]... [FILE]...\n");
        try stdout.writeAll("Concatenate FILE(s) to standard output.\n\n");
        try clap.help(stdout, clap.Help, &params, .{});
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("cat ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Access parsed options
    const number_lines = res.args.number != 0;
    const number_nonblank = res.args.@"number-nonblank" != 0;
    const squeeze_blank = res.args.@"squeeze-blank" != 0;
    const show_ends = res.args.@"show-ends" != 0;
    const show_tabs = res.args.@"show-tabs" != 0;

    // Access positional arguments (files)
    const files = res.positionals;

    std.debug.print("Options:\n", .{});
    std.debug.print("  number_lines: {}\n", .{number_lines});
    std.debug.print("  number_nonblank: {}\n", .{number_nonblank});
    std.debug.print("  squeeze_blank: {}\n", .{squeeze_blank});
    std.debug.print("  show_ends: {}\n", .{show_ends});
    std.debug.print("  show_tabs: {}\n", .{show_tabs});
    std.debug.print("Files: {d} files\n", .{files.len});
    for (files) |file| {
        std.debug.print("  - {s}\n", .{file});
    }
}
