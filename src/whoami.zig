//! whoami - print effective user name
//!
//! The whoami utility prints the user name associated with the current
//! effective user ID. It is equivalent to running "id -un".

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for the whoami utility
const WhoamiArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments (none expected)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .version = .{ .short = 'V', .desc = "output version information and exit" },
    };
};

/// Main entry point for the whoami utility
pub fn runWhoami(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    // Parse command-line arguments
    const parsed_args = common.argparse.ArgParser.parseOrExit(WhoamiArgs, allocator, args, "whoami", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Reject extra positional arguments
    if (parsed_args.positionals.len > 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "whoami", "extra operand '{s}'", .{parsed_args.positionals[0]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Look up the current user
    const uid = common.user_group.getCurrentUserId();
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "whoami", "cannot find name for user ID {d}", .{uid});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(user_info.name);

    try stdout_writer.print("{s}\n", .{user_info.name});
    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runWhoami);
}

/// Print help message to the specified writer
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: whoami [OPTION]...
        \\Print the user name associated with the current effective user ID.
        \\Same as id -un.
        \\
        \\  -h, --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("whoami ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "whoami prints current username" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should return success
    try testing.expectEqual(@as(u8, 0), result);

    // Should print a non-empty username ending with newline
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 1);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);

    // Should not print anything to stderr
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "whoami help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: whoami") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "whoami short help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: whoami") != null);
}

test "whoami version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "whoami") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "whoami short version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "whoami") != null);
}

test "whoami unknown flag returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    const err_out = stderr_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, err_out, "whoami:") != null);
    try testing.expect(std.mem.find(u8, err_out, "unrecognized option") != null);
}

test "whoami unknown short flag returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-x"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "whoami extra arguments returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"extra"};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "whoami output matches current user" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{};
    const result = try runWhoami(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // Verify output matches what user_group reports
    const uid = common.user_group.getCurrentUserId();
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    // Output should be "username\n"
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{user_info.name});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}
