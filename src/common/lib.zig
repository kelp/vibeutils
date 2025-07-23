const std = @import("std");

/// Common functionality for all zutils
pub const style = @import("style.zig");
pub const args = @import("args.zig");
pub const file = @import("file.zig");

/// Version information
pub const version = "0.2.1";
pub const name = "zutils";

/// Common error types
pub const Error = error{
    ArgumentError,
    FileNotFound,
    PermissionDenied,
    InvalidInput,
    OutputError,
};

/// Standard exit codes
pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    misuse = 2,

    pub fn exit(self: ExitCode) noreturn {
        std.process.exit(@intFromEnum(self));
    }
};

/// Print error message to stderr and exit
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    stderr.print("{s}: " ++ fmt ++ "\n", .{prog_name} ++ fmt_args) catch {};
    ExitCode.general_error.exit();
}

/// Print error message to stderr
pub fn printError(comptime fmt: []const u8, fmt_args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Try to use color for errors
    const StyleType = style.Style(@TypeOf(stderr));
    var s = StyleType.init(stderr);
    s.setColor(.bright_red) catch {};
    stderr.print("{s}: ", .{prog_name}) catch return;
    s.reset() catch {};
    stderr.print(fmt ++ "\n", fmt_args) catch return;
}

/// Common command line options
pub const CommonOpts = struct {
    help: bool = false,
    version: bool = false,

    /// Print help message
    pub fn printHelp(comptime usage: []const u8, comptime description: []const u8) void {
        const stdout = std.io.getStdOut().writer();
        const prog_name = std.fs.path.basename(std.os.argv[0]);

        stdout.print("Usage: {s} {s}\n\n", .{ prog_name, usage }) catch return;
        stdout.print("{s}\n", .{description}) catch return;
    }

    /// Print version
    pub fn printVersion() void {
        const stdout = std.io.getStdOut().writer();
        const prog_name = std.fs.path.basename(std.os.argv[0]);
        stdout.print("{s} ({s}) {s}\n", .{ prog_name, name, version }) catch return;
    }
};

/// Progress indicator for long operations
pub const Progress = struct {
    total: usize,
    current: usize = 0,
    start_time: i64,
    last_update: i64 = 0,
    style: style.Style(std.fs.File.Writer),

    pub fn init(total: usize) Progress {
        return .{
            .total = total,
            .start_time = std.time.milliTimestamp(),
            .style = style.Style(std.fs.File.Writer).init(std.io.getStdErr().writer()),
        };
    }

    pub fn update(self: *Progress, current: usize) void {
        self.current = current;
        const now = std.time.milliTimestamp();

        // Update at most once per 100ms
        if (now - self.last_update < 100) return;
        self.last_update = now;

        self.draw() catch {};
    }

    fn draw(self: *Progress) !void {
        const stderr = std.io.getStdErr().writer();
        const percent = if (self.total > 0)
            @as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(self.total)) * 100.0
        else
            0;

        // Clear line
        try stderr.writeAll("\r\x1b[K");

        // Draw progress bar
        try self.style.setAttribute(.bold);
        try stderr.writeAll("[");

        const bar_width = 30;
        const filled = @as(usize, @intFromFloat(percent / 100.0 * @as(f32, @floatFromInt(bar_width))));

        // Filled portion
        try self.style.setColor(.bright_green);
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            try stderr.writeAll("█");
        }

        // Empty portion
        try self.style.setColor(.bright_black);
        while (i < bar_width) : (i += 1) {
            try stderr.writeAll("░");
        }

        try self.style.reset();
        try stderr.writeAll("] ");

        // Percentage and ETA
        try stderr.print("{d:.1}%", .{percent});

        if (self.current > 0 and self.current < self.total) {
            const now = std.time.milliTimestamp();
            const elapsed = now - self.start_time;
            const rate = @as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(elapsed));
            const remaining = @as(f32, @floatFromInt(self.total - self.current)) / rate / 1000.0;
            try stderr.print(" ETA: {d:.0}s", .{remaining});
        }
    }

    pub fn finish(_: *Progress) void {
        const stderr = std.io.getStdErr().writer();
        stderr.writeAll("\r\x1b[K") catch {};
    }
};

test "common library basics" {
    // Test that we can import and use basic functionality
    const ec = ExitCode.success;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ec));
}
