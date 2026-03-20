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
        .diagnose_errors = .{ .short = 'p', .desc = "Diagnose errors writing to non-pipes" },
    };
};

/// Main entry point for tee utility
pub fn runTee(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments
    const parsed_args = common.argparse.ArgParser.parse(TeeArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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
        try setupSignalIgnoring();
    }

    // Read from stdin and process with tee functionality
    const stdin_file = std.fs.File.stdin();

    return runTeeWithInput(
        allocator,
        parsed_args,
        stdin_file,
        stdout_writer,
        stderr_writer,
    );
}

/// Internal function for running tee with a specific input file
/// This allows for easier testing with mock input streams
fn runTeeWithInput(
    allocator: std.mem.Allocator,
    args: TeeArgs,
    input_file: std.fs.File,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Create multi-writer system using the generic type.
    // "-" operands are handled inside MultiWriter: they write
    // to stdout instead of opening a file (GNU tee behavior).
    const MultiWriter = MultiWriterGeneric(@TypeOf(stdout_writer));
    var multi_writer = MultiWriter.init(allocator, stdout_writer, args.positionals, args.append) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "tee", "failed to open files: {s}", .{@errorName(err)});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer multi_writer.deinit();

    var has_error = false;
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = input_file.read(&buffer) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "tee", "read error: {s}", .{@errorName(err)});
            has_error = true;
            break;
        };

        if (bytes_read == 0) {
            break;
        }

        multi_writer.write(buffer[0..bytes_read]) catch |err| {
            if (args.diagnose_errors) {
                common.printErrorWithProgram(allocator, stderr_writer, "tee", "write error: {s}", .{@errorName(err)});
            }
            has_error = true;
            // Continue processing even if some writes fail
        };
    }

    // Flush all outputs
    multi_writer.flush() catch |err| {
        if (args.diagnose_errors) {
            common.printErrorWithProgram(allocator, stderr_writer, "tee", "flush error: {s}", .{@errorName(err)});
        }
        has_error = true;
    };

    return @intFromEnum(if (has_error) common.ExitCode.general_error else common.ExitCode.success);
}

/// Main entry point for the tee command
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runTee(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
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
fn printVersion(writer: anytype) !void {
    try writer.print("tee ({s}) {s}\n", .{ common.name, common.version });
}

/// Set up signal handling to ignore interrupts when -i flag is used
fn setupSignalIgnoring() !void {
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

/// Multi-writer system that writes to stdout and multiple files simultaneously
/// This version works with anytype writers for better testability
fn MultiWriterGeneric(comptime StdoutWriter: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stdout_writer: StdoutWriter,
        files: []std.fs.File,
        is_stdout: []bool,

        /// Initialize multi-writer with stdout and file outputs.
        /// Entries named "-" are treated as additional stdout
        /// copies (GNU tee behavior).
        pub fn init(allocator: std.mem.Allocator, stdout_writer: StdoutWriter, file_names: []const []const u8, append_mode: bool) !Self {
            var files = try allocator.alloc(std.fs.File, file_names.len);
            errdefer allocator.free(files);

            var is_stdout = try allocator.alloc(bool, file_names.len);
            errdefer allocator.free(is_stdout);

            var files_opened: usize = 0;
            errdefer {
                for (files[0..files_opened], is_stdout[0..files_opened]) |file, is_dash| {
                    if (!is_dash) file.close();
                }
            }

            // Open all files ("-" means stdout)
            for (file_names, 0..) |file_name, i| {
                if (std.mem.eql(u8, file_name, "-")) {
                    is_stdout[i] = true;
                    files[i] = undefined;
                    files_opened += 1;
                    continue;
                }
                is_stdout[i] = false;
                if (append_mode) {
                    // For append mode: try to open existing file, create if not found
                    files[i] = std.fs.cwd().openFile(file_name, .{ .mode = .write_only }) catch |open_err| switch (open_err) {
                        error.FileNotFound => try std.fs.cwd().createFile(file_name, .{ .read = false }),
                        else => {
                            // Error reporting is handled by caller
                            return open_err;
                        },
                    };
                    // Seek to end for append mode (only if file supports seeking)
                    files[i].seekFromEnd(0) catch {
                        // Some file types (pipes, devices) don't support seeking
                        // This is expected and not an error for tee
                    };
                } else {
                    // For normal mode, create/truncate file
                    files[i] = std.fs.cwd().createFile(file_name, .{ .read = false, .truncate = true }) catch |err| {
                        // Error reporting is handled by caller
                        return err;
                    };
                }
                files_opened += 1;
            }

            return Self{
                .allocator = allocator,
                .stdout_writer = stdout_writer,
                .files = files,
                .is_stdout = is_stdout,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            for (self.files, self.is_stdout) |file, is_dash| {
                if (!is_dash) file.close();
            }
            self.allocator.free(self.files);
            self.allocator.free(self.is_stdout);
        }

        /// Write data to all outputs
        pub fn write(self: *Self, data: []const u8) !void {
            var any_error = false;

            // Always write to stdout (this is the core functionality of tee)
            self.stdout_writer.writeAll(data) catch {
                // Error will be handled by caller via any_error flag
                any_error = true;
            };

            // Write to all file outputs; "-" entries go to stdout
            for (self.files, self.is_stdout) |file, is_dash| {
                if (is_dash) {
                    self.stdout_writer.writeAll(data) catch {
                        any_error = true;
                    };
                } else {
                    file.writeAll(data) catch {
                        any_error = true;
                    };
                }
            }

            if (any_error) {
                return error.WriteError;
            }
        }

        /// Flush all outputs
        pub fn flush(self: *Self) !void {
            var any_error = false;

            // Try to flush stdout writer if it has a flush method
            // In real usage, the main() function also handles flushing
            // Use comptime check to see if flush method exists
            if (comptime std.meta.hasMethod(@TypeOf(self.stdout_writer), "flush")) {
                self.stdout_writer.flush() catch {
                    any_error = true;
                };
            }

            if (any_error) {
                return error.FlushError;
            }
        }
    };
}

// ============================================================================
//                                   TESTS
// ============================================================================

test "tee --help shows help message" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runTee(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: tee") != null);
}

test "tee --version shows version information" {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runTee(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "tee") != null);
}

test "tee with unknown flag should return error" {
    var stderr_buffer = std.ArrayListUnmanaged(u8){};
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--unknown-flag"};
    const result = try runTee(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unrecognized option") != null);
}

test "tee copies input to stdout and files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create an input file to simulate stdin
    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("hello tee\n");
    try input_file.seekTo(0);

    // Get real path for output file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{tmp_path});
    defer testing.allocator.free(output_path);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{
        .positionals = &.{output_path},
    };

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);

    // Verify stdout received the data
    try testing.expectEqualStrings("hello tee\n", stdout_buffer.items);

    // Verify the output file received the data
    const file_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("hello tee\n", file_content);
}

test "tee -a appends to existing files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create output file with existing content
    {
        const existing = try tmp_dir.dir.createFile("output.txt", .{});
        try existing.writeAll("existing\n");
        existing.close();
    }

    // Create input file
    const input_file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try input_file.writeAll("appended\n");
    try input_file.seekTo(0);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{tmp_path});
    defer testing.allocator.free(output_path);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{
        .append = true,
        .positionals = &.{output_path},
    };

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );
    input_file.close();

    try testing.expectEqual(@as(u8, 0), result);

    // Verify stdout received the new data
    try testing.expectEqualStrings("appended\n", stdout_buffer.items);

    // Verify output file has both existing and appended content
    const file_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("existing\nappended\n", file_content);
}

test "tee dash operand writes stdout twice" {
    // GNU behavior: echo hi | tee - outputs "hi" twice.
    // The normal tee stdout produces one copy, and the "-"
    // operand should produce a second copy to stdout.
    const input_file = try createTempInput("hello\n");
    defer input_file.close();

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{
        .positionals = &.{"-"},
    };

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Expect "hello\n" twice: once from normal stdout,
    // once from the "-" operand.
    try testing.expectEqualStrings("hello\nhello\n", stdout_buffer.items);
}

test "tee two dash operands writes stdout three times" {
    // echo hi | tee - - should output "hi" three times:
    // once from normal stdout, once per "-" operand.
    const input_file = try createTempInput("hello\n");
    defer input_file.close();

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{
        .positionals = &.{ "-", "-" },
    };

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    // Three copies: normal stdout + two "-" operands.
    try testing.expectEqualStrings("hello\nhello\nhello\n", stdout_buffer.items);
}

test "tee dash with file writes stdout twice and to file" {
    // echo hi | tee file.txt - should output "hi" twice
    // to stdout AND write to file.txt.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const input_file = try createTempInput("hello\n");
    defer input_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const output_path = try std.fmt.allocPrint(testing.allocator, "{s}/output.txt", .{tmp_path});
    defer testing.allocator.free(output_path);

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{
        .positionals = &.{ output_path, "-" },
    };

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);

    // Stdout should have two copies: normal + "-" operand.
    try testing.expectEqualStrings("hello\nhello\n", stdout_buffer.items);

    // File should have exactly one copy.
    const file_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "output.txt", 4096);
    defer testing.allocator.free(file_content);
    try testing.expectEqualStrings("hello\n", file_content);
}

test "tee with no files copies stdin to stdout only" {
    const input_file = try createTempInput("piped data\n");
    defer input_file.close();

    var stdout_buffer = std.ArrayListUnmanaged(u8){};
    defer stdout_buffer.deinit(testing.allocator);

    const parsed_args = TeeArgs{};

    const result = try runTeeWithInput(
        testing.allocator,
        parsed_args,
        input_file,
        stdout_buffer.writer(testing.allocator),
        common.null_writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("piped data\n", stdout_buffer.items);
}

/// Helper to create a temporary file with given content, seeked
/// back to the start so it can be used as simulated stdin.
fn createTempInput(content: []const u8) !std.fs.File {
    var tmp_dir = testing.tmpDir(.{});
    // We intentionally do NOT defer cleanup here — the
    // caller closes the file, and the OS reclaims the
    // anonymous tmpDir on process exit.
    const file = try tmp_dir.dir.createFile("input.txt", .{ .read = true });
    try file.writeAll(content);
    try file.seekTo(0);
    return file;
}
