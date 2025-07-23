const std = @import("std");
const clap = @import("clap");
const common = @import("common");
const testing = std.testing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define parameters using zig-clap
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-V, --version          Output version information and exit.
        \\-A, --show-all         Equivalent to -vET.
        \\-b, --number-nonblank  Number non-empty output lines, overrides -n.
        \\-e                     Equivalent to -vE.
        \\-E, --show-ends        Display $ at end of each line.
        \\-n, --number           Number all output lines.
        \\-s, --squeeze-blank    Suppress repeated empty output lines.
        \\-t                     Equivalent to -vT.
        \\-T, --show-tabs        Display TAB characters as ^I.
        \\-u                     (ignored)
        \\-v, --show-nonprinting Use ^ and M- notation, except for LFD and TAB.
        \\<str>...               Files to concatenate.
        \\
    );

    // Parse arguments
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Handle help
    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    // Handle version
    if (res.args.version != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("cat ({s}) {s}\n", .{ common.name, common.version });
        return;
    }

    // Create options struct
    // Handle combination flags first
    const show_all = res.args.@"show-all" != 0;
    const e_flag = res.args.e != 0;
    const t_flag = res.args.t != 0;

    const options = CatOptions{
        .number_lines = res.args.number != 0,
        .number_nonblank = res.args.@"number-nonblank" != 0,
        .squeeze_blank = res.args.@"squeeze-blank" != 0,
        .show_ends = res.args.@"show-ends" != 0 or show_all or e_flag,
        .show_tabs = res.args.@"show-tabs" != 0 or show_all or t_flag,
        .show_nonprinting = res.args.@"show-nonprinting" != 0 or show_all or e_flag or t_flag,
    };

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Access positionals - it's a tuple, so we need to access field 0
    const files = res.positionals.@"0";

    var line_state = LineNumberState{};

    if (files.len == 0) {
        // No files specified, read from stdin
        try processInput(stdin, stdout, options, &line_state);
    } else {
        for (files) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                try processInput(stdin, stdout, options, &line_state);
            } else {
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printError("{s}: {}", .{ file_path, err });
                    std.process.exit(1);
                };
                defer file.close();
                try processInput(file.reader(), stdout, options, &line_state);
            }
        }
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: cat [OPTION]... [FILE]...
        \\Concatenate FILE(s) to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -A, --show-all           equivalent to -vET
        \\  -b, --number-nonblank    number nonempty output lines, overrides -n
        \\  -e                       equivalent to -vE
        \\  -E, --show-ends          display $ at end of each line
        \\  -n, --number             number all output lines
        \\  -s, --squeeze-blank      suppress repeated empty output lines
        \\  -t                       equivalent to -vT
        \\  -T, --show-tabs          display TAB characters as ^I
        \\  -u                       (ignored)
        \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Examples:
        \\  cat f - g  Output f's contents, then standard input, then g's contents.
        \\  cat        Copy standard input to standard output.
        \\
    );
}

const CatOptions = struct {
    number_lines: bool = false,
    number_nonblank: bool = false,
    squeeze_blank: bool = false,
    show_ends: bool = false,
    show_tabs: bool = false,
    show_nonprinting: bool = false,
};

const LineNumberState = struct {
    line_number: usize = 1,
    prev_blank: bool = false,
};

fn processInput(reader: anytype, writer: anytype, options: CatOptions, state: *LineNumberState) !void {
    var buf_reader = std.io.bufferedReader(reader);
    var input = buf_reader.reader();

    var line_buf: [8192]u8 = undefined;
    while (true) {
        const maybe_line = try input.readUntilDelimiterOrEof(&line_buf, '\n');
        if (maybe_line) |line| {
            const is_blank = line.len == 0;

            // Handle squeeze blank
            if (options.squeeze_blank and is_blank and state.prev_blank) {
                continue;
            }
            state.prev_blank = is_blank;

            // Handle line numbering
            if (options.number_nonblank and !is_blank) {
                try writer.print("{d: >6}\t", .{state.line_number});
                state.line_number += 1;
            } else if (options.number_lines and !options.number_nonblank) {
                try writer.print("{d: >6}\t", .{state.line_number});
                state.line_number += 1;
            }

            // Write the line content
            if (options.show_tabs or options.show_nonprinting) {
                try writeWithSpecialChars(writer, line, options);
            } else {
                try writer.writeAll(line);
            }

            // Handle line ending
            if (options.show_ends) {
                try writer.writeAll("$");
            }
            try writer.writeAll("\n");
        } else {
            // EOF reached
            break;
        }
    }
}

fn writeWithSpecialChars(writer: anytype, line: []const u8, options: CatOptions) !void {
    for (line) |ch| {
        if (ch == '\t' and options.show_tabs) {
            try writer.writeAll("^I");
        } else if (options.show_nonprinting and ch < 32 and ch != '\t' and ch != '\n') {
            // Control characters
            try writer.print("^{c}", .{ch + 64});
        } else if (options.show_nonprinting and ch == 127) {
            try writer.writeAll("^?");
        } else if (options.show_nonprinting and ch >= 128) {
            // High bit set
            try writer.writeAll("M-");
            const ch_low = ch & 0x7F;
            if (ch_low < 32) {
                try writer.print("^{c}", .{ch_low + 64});
            } else if (ch_low == 127) {
                try writer.writeAll("^?");
            } else {
                try writer.writeByte(ch_low);
            }
        } else {
            try writer.writeByte(ch);
        }
    }
}

// Test helper to create temporary files
fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

test "cat reads single file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Hello, World!\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"test.txt"};
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Hello, World!\n", buffer.items);
}

test "cat concatenates multiple files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "file1.txt", "First file\n");
    try createTestFile(tmp_dir.dir, "file2.txt", "Second file\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "file1.txt", "file2.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("First file\nSecond file\n", buffer.items);
}

test "cat reads from stdin when no files" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const stdin_content = "Input from stdin\n";
    var stdin_stream = std.io.fixedBufferStream(stdin_content);

    const args = [_][]const u8{};
    try catWithStdin(&args, buffer.writer(), null, stdin_stream.reader());

    try testing.expectEqualStrings("Input from stdin\n", buffer.items);
}

test "cat with -n numbers all lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\nLine 3\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("     1\tLine 1\n     2\tLine 2\n     3\tLine 3\n", buffer.items);
}

test "cat with -b numbers non-blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\nLine 3\n\nLine 5\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-b", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5\n", buffer.items);
}

test "cat with -s squeezes blank lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\n\n\n\nLine 2\n\n\nLine 3\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-s", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line 1\n\nLine 2\n\nLine 3\n", buffer.items);
}

test "cat with -E shows ends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line 1$\nLine 2$\n", buffer.items);
}

test "cat with -T shows tabs" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-T", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line^Iwith^Itabs\n", buffer.items);
}

test "cat handles non-existent file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"nonexistent.txt"};
    const result = cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectError(error.FileNotFound, result);
}

test "cat with dash reads stdin" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const stdin_content = "From stdin\n";
    var stdin_stream = std.io.fixedBufferStream(stdin_content);

    const args = [_][]const u8{"-"};
    try catWithStdin(&args, buffer.writer(), null, stdin_stream.reader());

    try testing.expectEqualStrings("From stdin\n", buffer.items);
}

test "cat with -A shows all (equivalent to -vET)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\t\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-A", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line 1^I$\nLine 2$\n", buffer.items);
}

test "cat with -e shows ends and non-printing (equivalent to -vE)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line 1\nLine 2\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line 1$\nLine 2$\n", buffer.items);
}

test "cat with -t shows tabs and non-printing (equivalent to -vT)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Line\twith\ttabs\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-t", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Line^Iwith^Itabs\n", buffer.items);
}

test "cat with -u flag is ignored" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(tmp_dir.dir, "test.txt", "Test content\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-u", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    // -u should be ignored, so output should be normal
    try testing.expectEqualStrings("Test content\n", buffer.items);
}

test "cat with -A and control characters" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file with control character (^A = \x01)
    try createTestFile(tmp_dir.dir, "test.txt", "Test\x01\tEnd\n");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-A", "test.txt" };
    try cat(&args, buffer.writer(), tmp_dir.dir);

    try testing.expectEqualStrings("Test^A^IEnd$\n", buffer.items);
}

// Test implementation that mimics main() but for testing
fn cat(args: []const []const u8, writer: anytype, dir: ?std.fs.Dir) !void {
    var options = CatOptions{};
    var files = std.ArrayList([]const u8).init(testing.allocator);
    defer files.deinit();

    // Parse args manually for tests
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            options.number_lines = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            options.number_nonblank = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            options.squeeze_blank = true;
        } else if (std.mem.eql(u8, arg, "-E")) {
            options.show_ends = true;
        } else if (std.mem.eql(u8, arg, "-T")) {
            options.show_tabs = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            options.show_nonprinting = true;
        } else if (std.mem.eql(u8, arg, "-A")) {
            // -A is equivalent to -vET
            options.show_nonprinting = true;
            options.show_ends = true;
            options.show_tabs = true;
        } else if (std.mem.eql(u8, arg, "-e")) {
            // -e is equivalent to -vE
            options.show_nonprinting = true;
            options.show_ends = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            // -t is equivalent to -vT
            options.show_nonprinting = true;
            options.show_tabs = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            // -u is ignored for POSIX compatibility
        } else if (arg[0] != '-') {
            try files.append(arg);
        }
    }

    var line_state = LineNumberState{};

    if (files.items.len == 0) {
        // Would read from stdin in real implementation
        return;
    }

    for (files.items) |file_path| {
        const file = (dir orelse std.fs.cwd()).openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.FileNotFound;
            return err;
        };
        defer file.close();
        try processInput(file.reader(), writer, options, &line_state);
    }
}

fn catWithStdin(args: []const []const u8, writer: anytype, dir: ?std.fs.Dir, stdin: anytype) !void {
    var options = CatOptions{};
    var has_files = false;

    // Parse args
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-n")) {
            options.number_lines = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            has_files = true;
        } else if (arg[0] != '-') {
            has_files = true;
        }
    }

    var line_state = LineNumberState{};

    if (!has_files) {
        try processInput(stdin, writer, options, &line_state);
    } else {
        // Check if any arg is "-"
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-")) {
                try processInput(stdin, writer, options, &line_state);
                break;
            }
        }
    }

    _ = dir;
}
