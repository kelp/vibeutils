//! Create directories with optional parent directory creation and permission setting
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const privilege_test = common.privilege_test;
const testing = std.testing;

/// Command-line arguments for mkdir
const MkdirArgs = struct {
    help: bool = false,
    version: bool = false,
    mode: ?[]const u8 = null,
    parents: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .mode = .{ .short = 'm', .desc = "Set file mode (as in chmod)", .value_name = "MODE" },
        .parents = .{
            .short = 'p',
            .desc = "Make parent directories as needed, no error if existing",
        },
        .verbose = .{ .short = 'v', .desc = "Print a message for each created directory" },
    };
};

/// Options controlling directory creation behavior
const MkdirOptions = struct {
    /// File mode for created directories (POSIX mode_t)
    mode: ?std.posix.mode_t = null,

    /// Create parent directories as needed
    parents: bool = false,

    /// Print a message for each created directory
    verbose: bool = false,
};

/// Main entry point for mkdir command
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, run);
}

/// Run mkdir with provided writers for output
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const prog_name = "mkdir";

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        MkdirArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
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

    // Check if we have directories to create
    const dirs = parsed_args.positionals;
    if (dirs.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Build options from parsed flags, parsing -m mode if present.
    const options = run_buildOptions(allocator, parsed_args, prog_name, stderr_writer) catch {
        return @intFromEnum(common.ExitCode.general_error);
    };

    // Process directories - continue processing even if some fail
    // The missing-operand guard above returned for dirs.len == 0, so any path
    // reaching the loop has a non-empty operand list.
    std.debug.assert(dirs.len > 0);
    var exit_code = common.ExitCode.success;
    for (dirs) |dir_path| {
        createDirectory(
            io,
            dir_path,
            options,
            prog_name,
            stdout_writer,
            stderr_writer,
            allocator,
        ) catch {
            // Mark overall failure but continue with remaining directories
            exit_code = common.ExitCode.general_error;
            continue;
        };
    }

    return @intFromEnum(exit_code);
}

/// Build MkdirOptions from parsed flags, parsing the -m mode string if present.
/// On an invalid mode it prints the diagnostic and returns error.InvalidMode.
fn run_buildOptions(
    allocator: std.mem.Allocator,
    parsed_args: MkdirArgs,
    prog_name: []const u8,
    stderr_writer: *std.Io.Writer,
) !MkdirOptions {
    var options = MkdirOptions{
        .parents = parsed_args.parents,
        .verbose = parsed_args.verbose,
    };

    // Parse mode if provided
    if (parsed_args.mode) |mode_str| {
        options.mode = parseMode(mode_str) catch {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "invalid mode '{s}'",
                .{mode_str},
            );
            return error.InvalidMode;
        };
    }

    return options;
}

/// Print help message to provided writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: mkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\  -m, --mode=MODE   set file mode (as in chmod)
        \\  -p, --parents     make parent directories as needed, no error if existing
        \\  -v, --verbose     print a message for each created directory
        \\  -h, --help        display this help and exit
        \\  -V, --version     output version information and exit
        \\
        \\Examples:
        \\  mkdir dir1          Create directory 'dir1'
        \\  mkdir -p a/b/c      Create directory tree including parents
        \\  mkdir -m 755 bin    Create directory with permissions rwxr-xr-x
        \\
    );
}

/// Print version information to provided writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("mkdir ({s}) {s}\n", .{ common.name, common.version });
}

/// Set directory permissions. No-op with warning on Windows.
fn setDirectoryMode(
    io: std.Io,
    path: []const u8,
    mode: std.posix.mode_t,
    prog_name: []const u8,
    stderr_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    _ = io;
    // Precondition: both callers pass a created/cumulative path component, never
    // empty (createDir would already have failed on an empty path).
    std.debug.assert(path.len > 0);
    if (builtin.os.tag == .windows) {
        // Print warning on Windows
        common.printWarningWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "mode flag (-m) is not supported on Windows",
            .{},
        );
        return;
    }

    // mode originates solely from parseMode, which bounds it to 0o7777.
    std.debug.assert(mode <= 0o7777);

    // Use C chmod function for directories on POSIX systems
    const path_z = std.posix.toPosixPath(path) catch {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "path too long: '{s}'",
            .{path},
        );
        return error.ChmodFailed;
    };

    const result = std.c.chmod(&path_z, mode);
    if (result != 0) {
        const err = std.posix.errno(result);
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "cannot set mode on '{s}': {s}",
            .{ path, @tagName(err) },
        );
        return error.ChmodFailed;
    }
}

/// Parse octal or symbolic mode string (e.g. "755" or "u=rwx,go=rx") into
/// a file mode value suitable for chmod(2).
fn getUmask() u32 {
    const m = std.c.umask(0);
    _ = std.c.umask(m);
    // POSIX defines the umask over the nine permission bits only, so the
    // kernel never returns a value outside 0o000..0o777.
    std.debug.assert(m <= 0o777);
    return @intCast(m);
}

fn parseMode(mode_str: []const u8) !std.posix.mode_t {
    if (mode_str.len == 0) {
        return error.InvalidMode;
    }

    // Try octal first: 1-4 octal digits.
    if (common.mode.parseOctal(mode_str)) |octal| {
        // parseOctal rejects any value above 0o7777 on its success path.
        std.debug.assert(octal <= 0o7777);
        return @intCast(octal);
    } else |_| {}

    // Reject purely numeric strings that aren't valid octal.
    var all_numeric = true;
    for (mode_str) |c| {
        if (!std.ascii.isDigit(c)) {
            all_numeric = false;
            break;
        }
    }
    if (all_numeric) {
        return error.InvalidMode;
    }

    const parsed = common.mode.parseSymbolic(mode_str, 0o777, .{
        .is_directory = true,
        .umask = getUmask(),
    }) catch {
        return error.InvalidMode;
    };
    // toOctal ORs at most the three special bits onto a 9-bit permission value,
    // so it never exceeds 0o7777; this bounds the narrowing cast below.
    std.debug.assert(parsed.toOctal() <= 0o7777);
    return @intCast(parsed.toOctal());
}

/// Create directory with specified options
fn createDirectory(
    io: std.Io,
    path: []const u8,
    options: MkdirOptions,
    prog_name: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    if (options.parents) {
        try createPathComponents(
            io,
            path,
            options,
            prog_name,
            stdout_writer,
            stderr_writer,
            allocator,
        );
    } else {
        std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot create directory '{s}': {s}",
                .{ path, common.posixErrorString(err) },
            );
            return err;
        };

        // Set mode if specified
        if (options.mode) |mode| {
            try setDirectoryMode(io, path, mode, prog_name, stderr_writer, allocator);
        }

        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
        }
    }
}

/// Create path components one at a time, supporting -v per directory
/// and -m on the leaf directory only (GNU behavior).
fn createPathComponents(
    io: std.Io,
    path: []const u8,
    options: MkdirOptions,
    prog_name: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    // Handle absolute paths - start with "/"
    const is_absolute = path.len > 0 and path[0] == '/';

    // Count non-empty components to identify the leaf
    const total_components = createPathComponents_countComponents(path);

    // Split path into components
    var iter = std.mem.splitScalar(u8, path, '/');

    // Build up the cumulative path
    var cumulative: std.ArrayListUnmanaged(u8) = .empty;
    defer cumulative.deinit(allocator);

    if (is_absolute) {
        try cumulative.append(allocator, '/');
    }

    var first = true;
    var component_index: usize = 0;
    while (iter.next()) |component| {
        // Skip empty components (from double slashes or trailing slashes)
        if (component.len == 0) continue;

        component_index += 1;
        // The counting pass used the same splitter over the same path, so any
        // non-empty component we reach here was already counted: there is at
        // least one, and our running index never overruns that total.
        std.debug.assert(total_components >= 1);
        std.debug.assert(component_index <= total_components);
        const is_leaf = (component_index == total_components);

        // Add separator (if needed) and append this component to the cumulative
        // path. The `first` toggle is parent loop state, so it lives here.
        try createPathComponents_appendComponent(&cumulative, allocator, component, first);
        first = false;

        const current_path = cumulative.items;
        // We just appended a non-empty component, so the cumulative path holds
        // at least that component (plus a leading '/' for absolute paths).
        std.debug.assert(current_path.len > 0);

        // Try to create this component
        std.Io.Dir.cwd().createDir(io, current_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue, // -p: silently skip existing
            else => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "cannot create directory '{s}': {s}",
                    .{ current_path, common.posixErrorString(err) },
                );
                return err;
            },
        };

        // Directory was created successfully
        // GNU behavior: -m mode applies to the leaf directory only
        if (is_leaf) {
            if (options.mode) |mode| {
                try setDirectoryMode(io, current_path, mode, prog_name, stderr_writer, allocator);
            }
        }

        // Print verbose message for each directory created
        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path });
        }
    }
}

/// Count the non-empty '/'-separated components of `path`. The leaf is the
/// last such component; the caller uses this total to apply -m to it only.
fn createPathComponents_countComponents(path: []const u8) u32 {
    var count_iter = std.mem.splitScalar(u8, path, '/');
    var total: u32 = 0;
    while (count_iter.next()) |component| {
        if (component.len > 0) total += 1;
    }
    // Each component is separated by a distinct '/', so there can be at most
    // one component per character: the count never exceeds the path length.
    std.debug.assert(total <= path.len);
    // An empty path has no components at all (negative-space bound).
    if (path.len == 0) std.debug.assert(total == 0);
    return total;
}

/// Append `component` to the cumulative path, inserting a '/' separator first
/// unless this is the first component or the path is exactly the root "/".
fn createPathComponents_appendComponent(
    cumulative: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    component: []const u8,
    first: bool,
) !void {
    // We only reach here for non-empty components; the parent skips empties.
    std.debug.assert(component.len > 0);
    const len_before = cumulative.items.len;

    // Add separator between components (not before first)
    if (!first and !(cumulative.items.len == 1 and cumulative.items[0] == '/')) {
        try cumulative.append(allocator, '/');
    }

    try cumulative.appendSlice(allocator, component);
    // Appending a non-empty component must grow the buffer by at least its
    // length (more if a separator was also added).
    std.debug.assert(cumulative.items.len >= len_before + component.len);
}

// ============================================================================
// Tests
// ============================================================================

test "mkdir creates single directory" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteDir(io, "test_dir") catch {};

    const args = [_][]const u8{"test_dir"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = try std.Io.Dir.cwd().openDir(io, "test_dir", .{});
    test_dir.close(io);
}

test "mkdir with parents flag creates directory tree" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_parent") catch {};

    const args = [_][]const u8{ "-p", "test_parent/test_child" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directories were created
    var parent_dir = try std.Io.Dir.cwd().openDir(io, "test_parent", .{});
    defer parent_dir.close(io);

    var child_dir = try parent_dir.openDir(io, "test_child", .{});
    child_dir.close(io);
}

test "mkdir with verbose flag prints creation messages" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteDir(io, "test_verbose") catch {};

    const args = [_][]const u8{ "-v", "test_verbose" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(
        u8,
        stdout_aw.writer.buffered(),
        "mkdir: created directory 'test_verbose'",
    ) != null);
}

test "mkdir with mode flag sets permissions" {
    if (builtin.os.tag == .windows) {
        return;
    }
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteDir(io, "test_mode") catch {};

    const args = [_][]const u8{ "-m", "755", "test_mode" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory exists and has correct permissions
    const stat = try std.Io.Dir.cwd().statFile(io, "test_mode", .{});
    const mode = stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), mode);
}

test "mkdir fails for existing directory without parents flag" {
    const io = testing.io;
    // Create directory first
    try std.Io.Dir.cwd().createDir(io, "test_existing", .default_dir);
    defer std.Io.Dir.cwd().deleteDir(io, "test_existing") catch {};

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"test_existing"};
    const result = try run(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "File exists") != null);
}

test "mkdir with parents flag succeeds for existing directory" {
    const io = testing.io;
    // Create directory first
    try std.Io.Dir.cwd().createDir(io, "test_existing_p", .default_dir);
    defer std.Io.Dir.cwd().deleteDir(io, "test_existing_p") catch {};

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-p", "test_existing_p" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
}

test "mkdir fails with missing operand" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try run(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "mkdir shows help with -h flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: mkdir") != null);
    try testing.expect(std.mem.find(
        u8,
        stdout_aw.writer.buffered(),
        "Create the DIRECTORY",
    ) != null);
}

test "mkdir shows version with -V flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "mkdir (vibeutils)") != null);
}

test "mkdir handles invalid mode" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-m", "999", "test_invalid" };
    const result = try run(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "invalid mode") != null);
}

test "mkdir combines parents and verbose flags" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_combo") catch {};

    const args = [_][]const u8{ "-pv", "test_combo/sub/deep" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "created directory") != null);
}

test "mkdir handles multiple directories" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteDir(io, "test_multi1") catch {};
    defer std.Io.Dir.cwd().deleteDir(io, "test_multi2") catch {};
    defer std.Io.Dir.cwd().deleteDir(io, "test_multi3") catch {};

    const args = [_][]const u8{ "test_multi1", "test_multi2", "test_multi3" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var dir1 = try std.Io.Dir.cwd().openDir(io, "test_multi1", .{});
    dir1.close(io);
    var dir2 = try std.Io.Dir.cwd().openDir(io, "test_multi2", .{});
    dir2.close(io);
    var dir3 = try std.Io.Dir.cwd().openDir(io, "test_multi3", .{});
    dir3.close(io);
}

test "parseMode handles valid octal modes" {
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try parseMode("755"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o644), try parseMode("644"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), try parseMode("777"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o000), try parseMode("000"));
}

test "parseMode rejects invalid modes" {
    try testing.expectError(error.InvalidMode, parseMode(""));
    try testing.expectError(error.InvalidMode, parseMode("abc"));
    try testing.expectError(error.InvalidMode, parseMode("888"));
    try testing.expectError(error.InvalidMode, parseMode("1234567890")); // Too long/large
}

test "parseMode handles symbolic modes" {
    // Pin umask to 0o022 for reproducible results on implicit-who tests.
    const saved = std.c.umask(0o022);
    defer _ = std.c.umask(saved);

    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try parseMode("u=rwx,go=rx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), try parseMode("a=rwx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), try parseMode("a+rx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), try parseMode("u=rwx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try parseMode("go-w"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o577), try parseMode("u=rx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o757), try parseMode("g=rx"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o754), try parseMode("u=rwx,g=rx,o=r"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), try parseMode("a+X"));

    try testing.expectEqual(@as(std.posix.mode_t, 0o644), try parseMode("=rw"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try parseMode("=rwx"));
}

test "mkdir handles paths with double slashes" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_slashes") catch {};

    const args = [_][]const u8{ "-p", "test_slashes//sub//deep" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var test_dir = try std.Io.Dir.cwd().openDir(io, "test_slashes/sub/deep", .{});
    test_dir.close(io);
}

test "mkdir handles paths with dot components" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_dots") catch {};

    const args = [_][]const u8{ "-p", "test_dots/../test_dots/./sub" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var test_dir = try std.Io.Dir.cwd().openDir(io, "test_dots/sub", .{});
    test_dir.close(io);
}

test "mkdir verbose with parents shows directory creation" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_verbose_parents") catch {};

    const args = [_][]const u8{ "-pv", "test_verbose_parents/new_child" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "created directory") != null);
}

test "mkdir with mode applies to all created directories with -p" {
    if (builtin.os.tag == .windows) {
        return;
    }
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_mode_parents") catch {};

    const args = [_][]const u8{ "-pm", "755", "test_mode_parents/sub/deep" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var test_dir = try std.Io.Dir.cwd().openDir(io, "test_mode_parents/sub/deep", .{});
    test_dir.close(io);
}

test "mkdir -pv prints each intermediate directory" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_pv_each") catch {};

    const args = [_][]const u8{ "-pv", "test_pv_each/a/b" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "test_pv_each'") != null);
    try testing.expect(std.mem.find(u8, output, "test_pv_each/a'") != null);
    try testing.expect(std.mem.find(u8, output, "test_pv_each/a/b'") != null);
}

test "mkdir -pm sets mode on leaf only (GNU behavior)" {
    if (builtin.os.tag == .windows) return;
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_pm_mode") catch {};

    const args = [_][]const u8{ "-pm", "700", "test_pm_mode/sub/deep" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    const stat = try std.Io.Dir.cwd().statFile(io, "test_pm_mode/sub/deep", .{});
    const mode = stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), mode);

    const stat_mid = try std.Io.Dir.cwd().statFile(io, "test_pm_mode/sub", .{});
    const mode_mid = stat_mid.permissions.toMode() & 0o777;
    try testing.expect(mode_mid != 0o700);
}

test "mkdir -pm applies mode to leaf only, not parents (GNU behavior)" {
    if (builtin.os.tag == .windows) return;
    const io = testing.io;

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_pm_all_levels") catch {};

    const args = [_][]const u8{ "-pm", "700", "test_pm_all_levels/mid/leaf" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    const stat_root = try std.Io.Dir.cwd().statFile(io, "test_pm_all_levels", .{});
    const mode_root = stat_root.permissions.toMode() & 0o777;
    try testing.expect(mode_root != 0o700);

    const stat_mid = try std.Io.Dir.cwd().statFile(io, "test_pm_all_levels/mid", .{});
    const mode_mid = stat_mid.permissions.toMode() & 0o777;
    try testing.expect(mode_mid != 0o700);

    const stat_leaf = try std.Io.Dir.cwd().statFile(io, "test_pm_all_levels/mid/leaf", .{});
    const mode_leaf = stat_leaf.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), mode_leaf);
}

test "mkdir -p handles absolute-like paths" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_len];

    const deep_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/abs_test/sub/dir",
        .{tmp_path},
    );
    defer testing.allocator.free(deep_path);

    const args = [_][]const u8{ "-p", deep_path };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var test_dir = try std.Io.Dir.cwd().openDir(io, deep_path, .{});
    test_dir.close(io);
}

test "mkdir -p with trailing slashes" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, "test_trailing") catch {};

    const args = [_][]const u8{ "-p", "test_trailing/sub/" };
    const result = try run(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    var test_dir = try std.Io.Dir.cwd().openDir(io, "test_trailing/sub", .{});
    test_dir.close(io);
}

test "mkdir error for existing directory uses POSIX-style message" {
    const io = testing.io;
    // Create directory first
    try std.Io.Dir.cwd().createDir(io, "test_posix_err", .default_dir);
    defer std.Io.Dir.cwd().deleteDir(io, "test_posix_err") catch {};

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"test_posix_err"};
    const result = try run(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);

    const stderr_output = stderr_aw.writer.buffered();

    try testing.expect(std.mem.find(u8, stderr_output, "File exists") != null);
    try testing.expect(std.mem.find(u8, stderr_output, "PathAlreadyExists") == null);
    try testing.expect(std.mem.find(
        u8,
        stderr_output,
        "cannot create directory 'test_posix_err'",
    ) != null);
}
