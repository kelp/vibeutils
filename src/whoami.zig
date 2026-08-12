//! whoami - print effective user name
//!
//! The whoami utility prints the user name associated with the current
//! effective user ID. It is equivalent to running "id -un".

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// whoami reports the effective user, so it must not use the shared
/// getCurrentUserId() helper, which returns the real uid. `src/id.zig`
/// declares the same extern for `id -un`.
extern "c" fn geteuid() std.c.uid_t;

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
    const parsed_args = common.argparse.ArgParser.parseOrExit(
        WhoamiArgs,
        allocator,
        args,
        "whoami",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    // GNU acts on whichever of --help and --version comes first, so when both
    // are present the command-line order decides which one wins.
    const show_version = if (parsed_args.help and parsed_args.version)
        versionBeforeHelp(args)
    else
        parsed_args.version;

    if (parsed_args.help or parsed_args.version) {
        if (show_version) {
            try printVersion(stdout_writer);
        } else {
            try printHelp(allocator, stdout_writer);
        }
        return @intFromEnum(common.ExitCode.success);
    }

    // Reject extra positional arguments
    if (parsed_args.positionals.len > 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "whoami",
            "extra operand '{s}'\nTry 'whoami --help' for more information.",
            .{parsed_args.positionals[0]},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Look up the effective user, which is the identity whoami reports.
    const uid: common.user_group.uid_t = @intCast(geteuid());
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "whoami",
            "cannot find name for user ID {d}",
            .{uid},
        );
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(user_info.name);

    try stdout_writer.print("{s}\n", .{user_info.name});
    return @intFromEnum(common.ExitCode.success);
}

/// Report whether --version (or -V) appears before --help (or -h) in the raw
/// arguments. Only the first of the two matters to GNU, and the parser records
/// presence without order, so the decision needs the original argument list.
fn versionBeforeHelp(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len < 4096);

    for (args) |arg| {
        // Everything after the end-of-options marker is an operand.
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--help")) return false;
        if (std.mem.eql(u8, arg, "--version")) return true;
        if (arg.len < 2 or arg[0] != '-') continue;
        // A short cluster such as -Vh decides on its first matching letter.
        for (arg[1..]) |flag| {
            if (flag == 'h') return false;
            if (flag == 'V') return true;
        }
    }
    return false;
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

const StdoutCapture = common.test_utils.StdoutCapture;

/// Run whoami over `args` with output captured, so every test shares one
/// invocation shape and differs only in its assertions.
fn testRunWhoami(capture: *StdoutCapture, args: []const []const u8) !u8 {
    std.debug.assert(args.len < 16);
    return runWhoami(
        testing.allocator,
        testing.io,
        args,
        capture.stdoutWriter(),
        capture.stderrWriter(),
    );
}

/// The exact stderr GNU coreutils 9.5 emits for an extra operand, hint line
/// included. Verified with `LC_ALL=C /usr/bin/whoami extra` on Ubuntu.
fn testExtraOperandMessage(operand: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "whoami: extra operand '{s}'\nTry 'whoami --help' for more information.\n",
        .{operand},
    );
}

/// The exact stdout of `whoami --version`.
fn testVersionOutput() ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "whoami ({s}) {s}\n",
        .{ common.name, common.version },
    );
}

/// The name of the effective user, formatted as whoami must print it.
fn testEffectiveUserLine() ![]u8 {
    const euid: common.user_group.uid_t = @intCast(geteuid());
    const user_info = try common.user_group.getUserById(euid, testing.allocator);
    defer testing.allocator.free(user_info.name);
    std.debug.assert(user_info.name.len > 0);
    return std.fmt.allocPrint(testing.allocator, "{s}\n", .{user_info.name});
}

test "whoami prints the name of the effective user ID" {
    // NOTE: uid == euid in an ordinary test run, so this assertion cannot by
    // itself distinguish getuid() from geteuid(). The setuid case is covered
    // by the root-gated integration test in tests/utilities/whoami_test.sh.
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try testEffectiveUserLine();
    defer testing.allocator.free(expected);
    try capture.expectStdout(expected);
    try capture.expectStderrEmpty();
}

test "whoami help flag" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"--help"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const out = try capture.getStdoutStripped();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "Usage: whoami [OPTION]...\n"));
    try testing.expect(std.mem.find(u8, out, "Same as id -un.") != null);
    // Help must not also print the version banner.
    try testing.expect(std.mem.find(u8, out, "whoami (" ++ common.name ++ ")") == null);
    try capture.expectStderrEmpty();
}

test "whoami short help flag" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"-h"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const out = try capture.getStdoutStripped();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "Usage: whoami [OPTION]...\n"));
    try capture.expectStderrEmpty();
}

test "whoami version flag" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"--version"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try testVersionOutput();
    defer testing.allocator.free(expected);
    try capture.expectStdoutStripped(expected);
    try capture.expectStderrEmpty();
}

test "whoami short version flag" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"-V"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try testVersionOutput();
    defer testing.allocator.free(expected);
    try capture.expectStdoutStripped(expected);
    try capture.expectStderrEmpty();
}

test "whoami --version before --help prints version only" {
    // GNU processes whichever of the two appears FIRST on the command line.
    // Verified: `LC_ALL=C /usr/bin/whoami --version --help` on GNU coreutils
    // 9.5 prints the version banner and no usage text.
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{ "--version", "--help" };
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const out = try capture.getStdoutStripped();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "Usage: whoami") == null);
    const expected = try testVersionOutput();
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, out);
    try capture.expectStderrEmpty();
}

test "whoami --help before --version prints help only" {
    // Verified: `LC_ALL=C /usr/bin/whoami --help --version` on GNU coreutils
    // 9.5 prints the usage text and no version banner.
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{ "--help", "--version" };
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const out = try capture.getStdoutStripped();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "Usage: whoami [OPTION]...\n"));
    try testing.expect(std.mem.find(u8, out, "whoami (" ++ common.name ++ ")") == null);
    try capture.expectStderrEmpty();
}

test "whoami unknown flag returns exit code 1" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    const err_out = try capture.getStderrStripped();
    defer testing.allocator.free(err_out);
    try testing.expect(std.mem.startsWith(u8, err_out, "whoami: "));
    try testing.expect(std.mem.find(u8, err_out, "unrecognized option") != null);
}

test "whoami unknown short flag returns exit code 1" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"-x"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    // GNU words short flags differently from long ones: `--zzz` yields
    // "unrecognized option '--zzz'", but a short flag yields
    // "invalid option -- 'x'". Verified with `LC_ALL=C /usr/bin/whoami -x`
    // on GNU coreutils 9.5, which also exits 1.
    try capture.expectStderrStripped(
        "whoami: invalid option -- 'x'\n" ++
            "Try 'whoami --help' for more information.\n",
    );
}

test "whoami extra operand reports the GNU message" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"extra"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    const expected = try testExtraOperandMessage("extra");
    defer testing.allocator.free(expected);
    try capture.expectStderrStripped(expected);
}

test "whoami dash operand reports the GNU message" {
    // Verified: `LC_ALL=C /usr/bin/whoami -` on GNU coreutils 9.5 reports
    // "extra operand '-'"; a lone dash is an operand, not a flag.
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"-"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    const expected = try testExtraOperandMessage("-");
    defer testing.allocator.free(expected);
    try capture.expectStderrStripped(expected);
}

test "whoami empty operand reports the GNU message" {
    // Verified: `LC_ALL=C /usr/bin/whoami ""` on GNU coreutils 9.5 reports
    // "extra operand ''".
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{""};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    const expected = try testExtraOperandMessage("");
    defer testing.allocator.free(expected);
    try capture.expectStderrStripped(expected);
}

test "whoami bare end-of-options marker succeeds" {
    // Verified: `LC_ALL=C /usr/bin/whoami --` on GNU coreutils 9.5 prints the
    // user name and exits 0; `--` is consumed, not treated as an operand.
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{"--"};
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 0), result);
    const expected = try testEffectiveUserLine();
    defer testing.allocator.free(expected);
    try capture.expectStdout(expected);
    try capture.expectStderrEmpty();
}

test "whoami operand after end-of-options marker reports the GNU message" {
    // Verified: `LC_ALL=C /usr/bin/whoami -- extra` on GNU coreutils 9.5
    // reports "extra operand 'extra'".
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    const args = [_][]const u8{ "--", "extra" };
    const result = try testRunWhoami(&capture, &args);

    try testing.expectEqual(@as(u8, 1), result);
    try capture.expectStdoutEmpty();
    const expected = try testExtraOperandMessage("extra");
    defer testing.allocator.free(expected);
    try capture.expectStderrStripped(expected);
}
