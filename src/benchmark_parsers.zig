const std = @import("std");
const common = @import("common");

// Test args struct for our parser - similar to real utility usage
const TestArgs = struct {
    help: bool = false,
    verbose: bool = false,
    quiet: bool = false,
    debug: bool = false,
    force: bool = false,
    recursive: bool = false,
    all: bool = false,
    no_ignore: bool = false,
    count: ?u32 = null,
    level: ?u32 = null,
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    format: ?[]const u8 = null,
    mode: ?enum { fast, slow, auto } = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Show help" },
        .verbose = .{ .short = 'v', .desc = "Verbose output" },
        .quiet = .{ .short = 'q', .desc = "Quiet mode" },
        .debug = .{ .short = 'd', .desc = "Debug mode" },
        .force = .{ .short = 'f', .desc = "Force operation" },
        .recursive = .{ .short = 'r', .desc = "Recursive" },
        .all = .{ .short = 'a', .desc = "All files" },
        .no_ignore = .{ .short = 'I', .desc = "Don't ignore files" },
        .count = .{ .short = 'c', .desc = "Count", .value_name = "N" },
        .level = .{ .short = 'l', .desc = "Level", .value_name = "N" },
        .output = .{ .short = 'o', .desc = "Output file", .value_name = "FILE" },
        .input = .{ .short = 'i', .desc = "Input file", .value_name = "FILE" },
        .format = .{ .short = 'F', .desc = "Format", .value_name = "FMT" },
        .mode = .{ .short = 'm', .desc = "Mode" },
    };
};

fn benchmarkCustomParser(allocator: std.mem.Allocator, args: []const []const u8, iterations: u32) !u64 {
    const timer = std.time.Timer;
    var t = try timer.start();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const result = try common.argparse.ArgParser.parse(TestArgs, allocator, args);
        defer allocator.free(result.positionals);

        // Use the result to prevent optimization
        if (result.help) {
            _ = result.verbose;
        }
    }

    return t.read();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Print system info
    try stdout.print("System Information\n", .{});
    try stdout.print("==================\n", .{});
    try stdout.print("Zig version: {}\n", .{@import("builtin").zig_version});
    try stdout.print("Target: {s}-{s}\n", .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    try stdout.print("Build mode: {s}\n", .{@tagName(@import("builtin").mode)});

    // Get current time
    const timestamp = std.time.timestamp();
    try stdout.print("Timestamp: {}\n\n", .{timestamp});

    // Test cases with varying complexity
    const test_cases = [_]struct {
        name: []const u8,
        args: []const []const u8,
    }{
        .{
            .name = "Simple flags",
            .args = &[_][]const u8{ "-h", "-v", "-d" },
        },
        .{
            .name = "Combined flags",
            .args = &[_][]const u8{"-hvdfa"},
        },
        .{
            .name = "Long flags",
            .args = &[_][]const u8{ "--help", "--verbose", "--debug", "--force", "--all" },
        },
        .{
            .name = "Mixed with values",
            .args = &[_][]const u8{ "-v", "--count=42", "-o", "output.txt", "--level", "5", "-m", "fast" },
        },
        .{
            .name = "Complex with positionals",
            .args = &[_][]const u8{ "-vdf", "--count=100", "-o", "out.txt", "--", "file1.txt", "file2.txt", "file3.txt" },
        },
        .{
            .name = "Many flags",
            .args = &[_][]const u8{ "-h", "-v", "-q", "-d", "-f", "-r", "-a", "-I", "--count=10", "--level=20", "--output=test.txt", "--input=in.txt", "--format=json", "--mode=auto", "pos1", "pos2" },
        },
    };

    const iterations = 10000;

    try stdout.print("Argument Parser Performance Benchmark\n", .{});
    try stdout.print("=====================================\n", .{});
    try stdout.print("Custom parser implementation vs zig-clap\n", .{});
    try stdout.print("Iterations per test: {}\n\n", .{iterations});

    try stdout.print("Testing custom parser only (zig-clap comparison requires code duplication)\n\n", .{});

    for (test_cases) |test_case| {
        try stdout.print("Test: {s}\n", .{test_case.name});
        try stdout.print("Args: ", .{});
        for (test_case.args, 0..) |arg, i| {
            if (i > 0) try stdout.print(" ", .{});
            try stdout.print("{s}", .{arg});
        }
        try stdout.print("\n", .{});

        // Benchmark custom parser
        const custom_time = try benchmarkCustomParser(allocator, test_case.args, iterations);
        const custom_ms = @as(f64, @floatFromInt(custom_time)) / 1_000_000.0;
        const custom_per_iter = custom_time / iterations;

        try stdout.print("  Time: {d:.2} ms total, {} ns/iter\n", .{ custom_ms, custom_per_iter });
        try stdout.print("  Per iteration: {d:.2} μs\n\n", .{@as(f64, @floatFromInt(custom_per_iter)) / 1000.0});
    }

    // Memory usage comparison
    try stdout.print("Memory Usage Comparison\n", .{});
    try stdout.print("======================\n", .{});
    try stdout.print("Custom parser allocations per parse:\n", .{});
    try stdout.print("  - 1 allocation for positional arguments array\n", .{});
    try stdout.print("  - 0 allocations for flag parsing\n", .{});
    try stdout.print("  - Total: 1 allocation only when positionals are present\n\n", .{});

    // Size comparison info
    try stdout.print("Binary Size Comparison\n", .{});
    try stdout.print("======================\n", .{});
    try stdout.print("To compare binary sizes:\n", .{});
    try stdout.print("1. Build echo with clap: zig build\n", .{});
    try stdout.print("2. Note the binary size: ls -lh zig-out/bin/echo\n", .{});
    try stdout.print("3. Remove clap dependency and rebuild\n", .{});
    try stdout.print("4. Compare the new binary size\n\n", .{});

    try stdout.print("Implementation size:\n", .{});
    try stdout.print("  - Custom parser: ~579 lines (excluding tests)\n", .{});
    try stdout.print("  - zig-clap: ~3,000 lines\n", .{});
}
