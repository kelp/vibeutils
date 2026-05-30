//! tee - read from stdin, write to stdout and files
//!
//! Supports append mode (-a), signal ignoring (-i), and
//! error diagnosis (-p). POSIX-compliant with GNU extensions.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for tee
const TeeArgs = struct {
    help: bool = false,
    version: bool = false,
    append: bool = false,
    ignore_interrupts: bool = false,
    diagnose_errors: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .append = .{ .short = 'a', .desc = "Append to files instead of overwriting" },
        .ignore_interrupts = .{ .short = 'i', .desc = "Ignore interrupt signals" },
        .diagnose_errors = .{ .short = 'p', .desc = "Diagnose errors writing to non pipes" },
    };
};

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTee);
}

/// Public entry point that reads from stdin
pub fn runTee(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    // Parse arguments
    const parsed_args = common.argparse.ArgParser.parseOrExit(TeeArgs, allocator, args, "tee", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
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

    // Set up signal handling if ignore_interrupts is enabled
    if (parsed_args.ignore_interrupts) {
        setupSignalIgnoring();
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    return runTeeWithInput(
        allocator,
        io,
        parsed_args,
        &stdin_reader.interface,
        stdout_writer,
        stderr_writer,
    );
}

/// Internal function for running tee with a specific input reader.
/// This allows for easier testing with fixed readers.
fn runTeeWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: TeeArgs,
    reader: *std.Io.Reader,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Open all output files
    var multi = try MultiWriter.init(allocator, io, stderr_writer, args.positionals, args.append);
    defer multi.deinit(io);

    var has_error = false;
    var stdout_broken = false;
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = reader.readSliceShort(&buffer) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tee", "read error", .{});
            has_error = true;
            break;
        };

        if (bytes_read == 0) {
            break;
        }

        const data = buffer[0..bytes_read];

        // Write to stdout unless it is already broken
        if (!stdout_broken) {
            stdout_writer.writeAll(data) catch |err| {
                // Without -p, a broken stdout pipe means exit
                // (matches GNU default SIGPIPE behavior).
                if (!args.diagnose_errors) {
                    has_error = true;
                    break;
                }
                // With -p, mark stdout broken and continue
                // writing to files.
                stdout_broken = true;
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "standard output: {s}", .{common.posixErrorString(err)});
                has_error = true;
            };
        }

        // Write to each file output
        for (multi.files, multi.is_stdout, args.positionals) |*file_entry, is_dash, name| {
            if (is_dash) {
                // "-" operand means another stdout copy
                if (!stdout_broken) {
                    stdout_writer.writeAll(data) catch |err| {
                        if (!args.diagnose_errors) {
                            has_error = true;
                            stdout_broken = true;
                        } else {
                            stdout_broken = true;
                            common.printErrorWithProgram(allocator, stderr_writer, "tee", "standard output: {s}", .{common.posixErrorString(err)});
                        }
                        has_error = true;
                    };
                }
            } else {
                file_entry.writer.interface.writeAll(data) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "tee", "{s}: {s}", .{ name, common.posixErrorString(err) });
                    has_error = true;
                };
            }
        }

        // Without -p, if stdout broke during file writes, stop
        if (stdout_broken and !args.diagnose_errors) {
            break;
        }
    }

    // Flush stdout: buffered writes (e.g. to /dev/full) only surface
    // their underlying error on flush, not on writeAll. GNU tee always
    // reports a diagnostic on stdout failure, even without -p.
    if (!stdout_broken) {
        stdout_writer.flush() catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "tee", "standard output: {s}", .{common.posixErrorString(err)});
            has_error = true;
        };
    }

    // Flush per-file writers for the same reason.
    for (multi.files, multi.is_stdout, args.positionals) |*file_entry, is_dash, name| {
        if (is_dash) continue;
        file_entry.writer.interface.flush() catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "tee", "{s}: {s}", .{ name, common.posixErrorString(err) });
            has_error = true;
        };
    }

    return @intFromEnum(if (has_error) common.ExitCode.general_error else common.ExitCode.success);
}

/// Entry for a file opened by tee
const FileEntry = struct {
    file: std.Io.File,
    buf: [8192]u8,
    writer: std.Io.File.Writer,
};

/// Manages opened file handles for tee output targets.
const MultiWriter = struct {
    allocator: std.mem.Allocator,
    files: []FileEntry,
    is_stdout: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stderr_writer: *std.Io.Writer,
        file_names: []const []const u8,
        append_mode: bool,
    ) !MultiWriter {
        var files = try allocator.alloc(FileEntry, file_names.len);
        errdefer allocator.free(files);

        var is_stdout = try allocator.alloc(bool, file_names.len);
        errdefer allocator.free(is_stdout);

        var files_opened: usize = 0;
        errdefer {
            for (files[0..files_opened], is_stdout[0..files_opened]) |*fe, is_dash| {
                if (!is_dash) fe.file.close(io);
            }
        }

        for (file_names, 0..) |file_name, i| {
            if (std.mem.eql(u8, file_name, "-")) {
                is_stdout[i] = true;
                files[i] = undefined;
                files_opened += 1;
                continue;
            }
            is_stdout[i] = false;
            const opened_file = if (append_mode) blk: {
                // Open with O_WRONLY|O_CREAT|O_APPEND for true append semantics
                const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
                const fd = std.posix.openat(std.posix.AT.FDCWD, file_name, flags, 0o666) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "tee", "{s}: {s}", .{ file_name, common.posixErrorString(err) });
                    return err;
                };
                break :blk std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            } else std.Io.Dir.cwd().createFile(io, file_name, .{ .read = false, .truncate = true }) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "{s}: {s}", .{ file_name, common.posixErrorString(err) });
                return err;
            };
            files[i].file = opened_file;
            files[i].writer = opened_file.writerStreaming(io, &files[i].buf);
            files_opened += 1;
        }

        return MultiWriter{
            .allocator = allocator,
            .files = files,
            .is_stdout = is_stdout,
        };
    }

    pub fn deinit(self: *MultiWriter, io: std.Io) void {
        for (self.files, self.is_stdout) |*fe, is_dash| {
            if (!is_dash) {
                fe.writer.interface.flush() catch {};
                fe.file.close(io);
            }
        }
        self.allocator.free(self.files);
        self.allocator.free(self.is_stdout);
    }
};

/// Print help message to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: tee [OPTION]... [FILE]...
        \\Copy standard input to each FILE, and also to standard output.
        \\
        \\  -a, --append      append to the given FILEs
        \\  -i, --ignore-interrupts  ignore interrupt signals
        \\  -p                diagnose errors writing to non pipes
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("tee ({s}) {s}\n", .{ common.name, common.version });
}

/// Set up signal handling to ignore interrupts when -i flag is used
fn setupSignalIgnoring() void {
    // On POSIX systems, ignore SIGINT when -i is specified
    if (builtin.os.tag != .windows) {
        const os = std.posix;
        const SIG = os.SIG;

        // Properly initialize signal mask to empty set
        const empty_mask = os.sigemptyset();

        // Ignore SIGINT (Ctrl+C)
        const ignore_action = os.Sigaction{
            .handler = .{ .handler = SIG.IGN },
            .mask = empty_mask,
            .flags = 0,
        };

        _ = os.sigaction(SIG.INT, &ignore_action, null);
    }
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tee --help shows help message" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runTee(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: tee") != null);
}

test "tee --version shows version information" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runTee(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "tee") != null);
}

test "tee with unknown flag should return error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTee(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "unrecognized option") != null);
}

test "tee copies input to stdout and files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const output_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(output_path);
    const out_file_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{output_path});
    defer testing.allocator.free(out_file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{
        .positionals = &.{out_file_path},
    };

    var reader: std.Io.Reader = .fixed("hello tee\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello tee\n", stdout_aw.writer.buffered());

    // Verify the output file received the data
    const file_content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .limited(4096));
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("hello tee\n", file_content);
}

test "tee -a appends to existing files" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create output file with existing content
    {
        const existing = try tmp_dir.dir.createFile(io, "output.txt", .{});
        try existing.writeStreamingAll(io, "existing\n");
        existing.close(io);
    }

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{tmp_path});
    defer testing.allocator.free(output_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{
        .append = true,
        .positionals = &.{output_path},
    };

    var reader: std.Io.Reader = .fixed("appended\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("appended\n", stdout_aw.writer.buffered());

    // Verify output file has both existing and appended content
    const file_content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .limited(4096));
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("existing\nappended\n", file_content);
}

test "tee dash operand writes stdout twice" {
    // GNU behavior: echo hi | tee - outputs "hi" twice.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{
        .positionals = &.{"-"},
    };

    var reader: std.Io.Reader = .fixed("hello\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Expect "hello\n" twice: once from normal stdout, once from the "-" operand.
    try testing.expectEqualStrings("hello\nhello\n", stdout_aw.writer.buffered());
}

test "tee two dash operands writes stdout three times" {
    // echo hi | tee - - should output "hi" three times
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{
        .positionals = &.{ "-", "-" },
    };

    var reader: std.Io.Reader = .fixed("hello\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Three copies: normal stdout + two "-" operands.
    try testing.expectEqualStrings("hello\nhello\nhello\n", stdout_aw.writer.buffered());
}

test "tee dash with file writes stdout twice and to file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{tmp_path});
    defer testing.allocator.free(output_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{
        .positionals = &.{ output_path, "-" },
    };

    var reader: std.Io.Reader = .fixed("hello\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);

    // Stdout should have two copies: normal + "-" operand.
    try testing.expectEqualStrings("hello\nhello\n", stdout_aw.writer.buffered());

    // File should have exactly one copy.
    const file_content = try tmp_dir.dir.readFileAlloc(io, "output.txt", testing.allocator, .limited(4096));
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("hello\n", file_content);
}

test "tee with no files copies stdin to stdout only" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const parsed_args = TeeArgs{};

    var reader: std.Io.Reader = .fixed("piped data\n");
    const result = try runTeeWithInput(
        testing.allocator,
        io,
        parsed_args,
        &reader,
        &stdout_aw.writer,
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("piped data\n", stdout_aw.writer.buffered());
}
