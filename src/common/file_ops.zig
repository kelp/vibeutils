const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const env = @import("env.zig");
const assert = std.debug.assert;

/// Set file permissions using the most reliable method available
///
/// On macOS in CI environments, File.chmod() can cause SIGABRT errors under fakeroot.
/// On Linux under fakeroot, setting special permissions (setuid, setgid, sticky) can hang.
/// This function uses std.posix.fchmod() directly on the file descriptor and handles
/// platform-specific limitations gracefully.
///
/// # Why posix.fchmod instead of File.chmod?
/// File.chmod() can fail with EFAULT on macOS in certain environments (like GitHub Actions
/// CI with fakeroot). Using std.posix.fchmod() directly on the file descriptor avoids
/// this issue and provides more consistent behavior across platforms.
///
/// # Parameters
/// - handle: Either a std.fs.File or std.fs.Dir
/// - mode: The file mode (permissions) to set
/// - context: Optional context for error reporting (e.g., file path)
/// - program_name: Name of the calling program for error messages
/// - stderr_writer: Writer for warning messages
///
/// # Returns
/// Returns success (0) if the operation succeeds, or general_error (1) if it fails
/// after issuing warnings for platform-specific limitations.
pub fn setPermissions(
    allocator: std.mem.Allocator,
    handle: anytype,
    mode: std.posix.mode_t,
    context: ?[]const u8,
    program_name: []const u8,
    stderr_writer: anytype,
) !u8 {
    // A shared leaf called by cp/mv/chmod/install: an empty program_name would
    // mislabel the warning diagnostics, never a valid invocation. Matches the
    // sibling leaves copyFileWithAttributes/preserveDirAttributes in this file.
    assert(program_name.len > 0);

    const handle_type = @TypeOf(handle);

    // Get the file descriptor based on handle type
    const fd = if (handle_type == std.Io.File)
        handle.handle
    else if (handle_type == std.Io.Dir)
        handle.handle
    else
        @compileError("setPermissions expects std.Io.File or std.Io.Dir");

    // Check for special permissions (setuid, setgid, sticky bit)
    const has_special_bits = (mode & 0o7000) != 0;

    // On Linux under fakeroot, setting special permissions can cause hangs
    // Strip special bits and warn the user
    const effective_mode = if (isRunningUnderLinuxFakeroot() and has_special_bits) blk: {
        setPermissionsWarnStripped(allocator, stderr_writer, program_name, context);
        // This branch is entered only when special bits are set; assert that
        // precondition holds here, since stripping them is the whole reason
        // this branch exists.
        assert((mode & 0o7000) != 0);
        break :blk mode & 0o0777; // Keep only regular permissions
    } else mode;

    const fchmod_result = std.c.fchmod(fd, effective_mode);
    if (fchmod_result != 0) {
        const err = std.posix.unexpectedErrno(std.c.errno(fchmod_result));
        // On macOS, especially in CI environments with fakeroot, permission
        // operations may fail. We report this as a warning but don't fail
        // the operation since the file operation itself succeeded.
        if (builtin.os.tag == .macos) {
            setPermissionsWarnMacosFailed(allocator, stderr_writer, program_name, context, err);
            return @intFromEnum(lib.ExitCode.success);
        }
        return @intFromEnum(lib.ExitCode.general_error);
    }

    return @intFromEnum(lib.ExitCode.success);
}

/// Warn that special permission bits were stripped under Linux fakeroot.
///
/// Extracted from setPermissions so the parent stays within the 70-line limit;
/// emits a context-qualified message when a path is known, a bare message
/// otherwise. Behavior matches the inlined branches exactly.
fn setPermissionsWarnStripped(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    program_name: []const u8,
    context: ?[]const u8,
) void {
    // Shares setPermissions's precondition: an empty program_name would mislabel
    // the warning, and this leaf is only reached from that already-asserted path.
    assert(program_name.len > 0);
    if (context) |ctx| {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "Stripped special permissions on '{s}' (Linux fakeroot limitation)",
            .{ctx},
        );
    } else {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "Stripped special permissions (Linux fakeroot limitation)",
            .{},
        );
    }
}

/// Warn that a chmod failed on macOS, where it is downgraded to a warning.
///
/// Extracted from setPermissions so the parent stays within the 70-line limit;
/// emits a context-qualified message when a path is known, a bare message
/// otherwise. Behavior matches the inlined branches exactly.
fn setPermissionsWarnMacosFailed(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    program_name: []const u8,
    context: ?[]const u8,
    err: anyerror,
) void {
    // Shares setPermissions's precondition: an empty program_name would mislabel
    // the warning, and this leaf is only reached from that already-asserted path.
    assert(program_name.len > 0);
    if (context) |ctx| {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "Failed to set permissions on '{s}' (macOS limitation): {s}",
            .{ ctx, lib.posixErrorString(err) },
        );
    } else {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "Failed to set permissions on macOS: {s}",
            .{lib.posixErrorString(err)},
        );
    }
}

/// Check if running in a CI environment
///
/// Detects common CI environment variables to determine if the code is
/// running in a continuous integration system.
///
/// # Returns
/// true if running in a CI environment, false otherwise
pub fn isRunningInCI() bool {
    // Common CI environment variables to check
    const ci_vars = [_][]const u8{
        "CI",
        "GITHUB_ACTIONS",
        "TRAVIS",
        "CIRCLECI",
        "JENKINS_URL",
        "GITLAB_CI",
        "BUILDKITE",
    };

    // Compile-time-constant sanity check: guards a future edit that empties the
    // list, which would silently make this function always return false.
    assert(ci_vars.len > 0);

    for (ci_vars) |var_name| {
        if (env.getEnv(var_name)) |_| {
            return true;
        }
    }

    return false;
}

/// Check if running under fakeroot on Linux
///
/// Fakeroot sets the FAKEROOTKEY environment variable when active.
/// This is used to detect when special permission operations might hang.
///
/// # Returns
/// true if running under fakeroot on Linux, false otherwise
pub fn isRunningUnderLinuxFakeroot() bool {
    if (builtin.os.tag != .linux) return false;

    return env.getEnv("FAKEROOTKEY") != null;
}

/// Check if should skip privileged tests on macOS CI
///
/// Some privileged operations can cause SIGABRT on macOS in CI environments
/// when running under fakeroot. This function determines if we should skip
/// such tests.
///
/// # Returns
/// true if running on macOS in a CI environment, false otherwise
pub fn shouldSkipMacOSCITest() bool {
    return builtin.os.tag == .macos and isRunningInCI();
}

/// Check if two paths refer to the same file (compares both inode and device).
///
/// Opens both paths and compares their fstat results. Returns false
/// if either file cannot be opened or stat'd.
pub fn isSameFile(io: std.Io, source: []const u8, dest: []const u8) bool {
    const source_file = std.Io.Dir.cwd().openFile(io, source, .{}) catch return false;
    defer source_file.close(io);
    const dest_file = std.Io.Dir.cwd().openFile(io, dest, .{}) catch return false;
    defer dest_file.close(io);
    return isSameFileHandle(source_file.handle, dest_file.handle);
}

fn isSameFileHandle(source_fd: std.posix.fd_t, dest_fd: std.posix.fd_t) bool {
    if (builtin.os.tag == .linux) {
        // On Linux, std.c.fstat is void; use statx via the linux syscall instead.
        // AT_EMPTY_PATH = 0x1000 allows statting an fd without a path.
        const at_empty_path: u32 = 0x1000;
        const mask = std.os.linux.STATX{ .INO = true, .MNT_ID = true };
        var source_buf: std.os.linux.Statx = undefined;
        var dest_buf: std.os.linux.Statx = undefined;
        const src_ret = std.os.linux.statx(source_fd, "", at_empty_path, mask, &source_buf);
        if (src_ret != 0) return false;
        const dst_ret = std.os.linux.statx(dest_fd, "", at_empty_path, mask, &dest_buf);
        if (dst_ret != 0) return false;
        return source_buf.ino == dest_buf.ino and
            source_buf.dev_major == dest_buf.dev_major and
            source_buf.dev_minor == dest_buf.dev_minor;
    } else {
        var source_stat: std.c.Stat = undefined;
        var dest_stat: std.c.Stat = undefined;
        if (std.c.fstat(source_fd, &source_stat) != 0) return false;
        if (std.c.fstat(dest_fd, &dest_stat) != 0) return false;
        return source_stat.ino == dest_stat.ino and source_stat.dev == dest_stat.dev;
    }
}

/// Named constant for the copy buffer size (64 KB).
pub const COPY_BUFFER_SIZE = 64 * 1024;

/// Copy the contents of one open file to another using a fixed-size buffer.
///
/// Reads from source_file and writes to dest_file until EOF. Returns
/// an error if any read or write fails.
pub fn copyFileContents(io: std.Io, source_file: std.Io.File, dest_file: std.Io.File) !void {
    // Compile-time-constant sanity check: a zero-size buffer would make every
    // read return 0 and loop forever on a non-empty source.
    assert(COPY_BUFFER_SIZE > 0);

    var buffer: [COPY_BUFFER_SIZE]u8 = undefined;
    while (true) { // tiger:allow:unbounded-loop reads until short/zero read (EOF)
        const buf_slice: []u8 = &buffer;
        const bytes_read = source_file.readStreaming(io, &.{buf_slice}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        // readStreaming's only destination is buffer, so it can never report
        // more bytes than the buffer holds; bounds the slice below.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;
        try dest_file.writeStreamingAll(io, buffer[0..bytes_read]);
    }
}

/// Copy one regular file preserving mode, timestamps, and ownership.
///
/// Shared so cp and mv's EXDEV fallback (which copies+unlinks across
/// filesystems) preserve attributes identically rather than duplicating this
/// leaf. The destination is created with the source mode, contents are copied,
/// then atime/mtime and uid/gid are restored. The program_name parameter routes
/// diagnostics to the caller's name (cp vs mv), matching setPermissions's
/// convention. Timestamp and ownership failures only warn, since the data copy
/// itself succeeded; EPERM on chown is silent because a non-root user cannot
/// chown to another owner.
pub fn copyFileWithAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr_writer: anytype,
    program_name: []const u8,
    source_path: []const u8,
    dest_path: []const u8,
    source_info: lib.file.FileInfo,
) !void {
    // A shared leaf must self-guard its inputs for both the cp and mv callers:
    // an empty program_name would mislabel diagnostics, and empty paths would
    // name no file in the open/create errors below.
    assert(program_name.len > 0);
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    const source_file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
        lib.printErrorWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot open '{s}': {s}",
            .{ source_path, lib.posixErrorString(err) },
        );
        return error.SourceNotReadable;
    };
    defer source_file.close(io);

    const dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{
        .permissions = std.Io.File.Permissions.fromMode(source_info.mode),
    }) catch |err| {
        lib.printErrorWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot create '{s}': {s}",
            .{ dest_path, lib.posixErrorString(err) },
        );
        return error.DestinationNotWritable;
    };
    defer dest_file.close(io);

    copyFileContents(io, source_file, dest_file) catch |err| {
        lib.printErrorWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "error copying '{s}' to '{s}': {s}",
            .{ source_path, dest_path, lib.posixErrorString(err) },
        );
        return error.SourceNotReadable;
    };

    // Preserve timestamps.
    dest_file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.atime) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.mtime) } },
    }) catch |err| {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot preserve timestamps for '{s}': {s}",
            .{ dest_path, lib.posixErrorString(err) },
        );
    };

    copyFileWithAttributesPreserveOwnership(
        allocator,
        stderr_writer,
        program_name,
        dest_path,
        dest_file.handle,
        source_info,
    );
}

/// Restore the source file's uid/gid onto the copied destination.
///
/// Extracted from copyFileWithAttributes so the parent stays within the 70-line
/// limit. GNU cp -p is --preserve=mode,ownership,timestamps; EPERM is silent
/// because a non-root user cannot chown to other users. Behavior matches the
/// inlined block exactly.
fn copyFileWithAttributesPreserveOwnership(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    program_name: []const u8,
    dest_path: []const u8,
    dest_fd: std.posix.fd_t,
    source_info: lib.file.FileInfo,
) void {
    // Shares copyFileWithAttributes's precondition: an empty program_name would
    // mislabel the warning, and this leaf is only reached from that asserted path.
    assert(program_name.len > 0);
    const fchown_result = std.c.fchown(dest_fd, source_info.uid, source_info.gid);
    if (fchown_result != 0) {
        const errno = std.c._errno().*;
        switch (errno) {
            @intFromEnum(std.c.E.PERM) => {}, // Non-root; silently ignore.
            else => {
                lib.printWarningWithProgram(
                    allocator,
                    stderr_writer,
                    program_name,
                    "cannot preserve ownership for '{s}'",
                    .{dest_path},
                );
            },
        }
    }
}

/// Read the process umask without disturbing it.
///
/// POSIX offers no non-destructive umask read, so we install 0 to learn the old
/// value, then immediately restore it. Callers need this because a post-order
/// chmod bypasses the kernel umask that createDir applied at creation time.
/// Idiom lifted from mkdir's getUmask.
pub fn getUmask() std.posix.mode_t {
    const original = std.c.umask(0);
    const restored = std.c.umask(original);
    // The kernel defines the umask over the nine permission bits only, and the
    // restore must observe the zero we just installed, else our two calls raced.
    assert(original <= 0o777);
    assert(restored == 0);
    return original;
}

/// Apply a mode to a named path with a libc chmod(2), masked to the twelve
/// permission bits. Path-based rather than fchmod because fchmod on a freshly
/// created directory handle returns EBADF on Linux. Best-effort: failure is
/// ignored because callers use this on mode fixups where the copy already
/// succeeded and the OS reports its own errors elsewhere.
pub fn chmodPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: std.posix.mode_t,
) void {
    // An empty path would name no file, and a mode above the twelve permission
    // bits carries file-type bits the caller failed to strip — a caller bug.
    assert(path.len > 0);
    assert(mode <= 0o7777);
    const path_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0) catch return;
    defer allocator.free(path_z);
    _ = std.c.chmod(path_z, @intCast(mode & 0o7777));
}

/// Preserve a copied directory's timestamps and mode onto the destination dir.
///
/// Shared so cp's tree walk and mv's EXDEV directory fallback apply the same
/// post-order preservation leaf. Callers MUST invoke this POST-order (after the
/// directory's children are written): writing a child bumps the parent's mtime,
/// and a read-only (e.g. 0o555) source mode applied too early would block
/// populating the dest. The mode is applied with a path-based libc chmod rather
/// than fchmod, because fchmod on a freshly created directory handle returns
/// EBADF on Linux. Returns true even when a step only warns, since the copy
/// itself already succeeded; the program_name routes diagnostics to the caller.
pub fn preserveDirAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr_writer: anytype,
    program_name: []const u8,
    dest_path: []const u8,
    mode: std.posix.mode_t,
    atime_ns: i128,
    mtime_ns: i128,
) bool {
    // Self-guard the leaf for both callers: cp reaches it through preserveTreeDir
    // (which already asserts), but mv's EXDEV fallback calls it directly. An empty
    // dest_path would name no directory in chmod/setTimestamps, and an empty
    // program_name would mislabel the warning below.
    assert(dest_path.len > 0);
    assert(program_name.len > 0);

    // Apply mtime first, then mode: setting a read-only mode does not block a
    // subsequent timestamp change here, but matching GNU's order keeps the dir
    // writable until the final chmod.
    std.Io.Dir.cwd().setTimestamps(io, dest_path, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(atime_ns) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(mtime_ns) } },
    }) catch |err| {
        lib.printWarningWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot preserve timestamps for '{s}': {s}",
            .{ dest_path, lib.posixErrorString(err) },
        );
    };
    // The source mode still carries file-type bits (S_IFDIR); strip them so the
    // shared chmod leaf sees only permission bits.
    chmodPath(allocator, dest_path, mode & 0o7777);
    return true;
}

test "isSameFile" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.close(io);

    // Same file via same path should match
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp_dir.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const path1 = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.txt", .{dir_path});
    defer std.testing.allocator.free(path1);

    try std.testing.expect(isSameFile(io, path1, path1));

    // Different files should not match
    const file2 = try tmp_dir.dir.createFile(io, "other.txt", .{});
    try file2.close(io);
    const path2 = try std.fmt.allocPrint(std.testing.allocator, "{s}/other.txt", .{dir_path});
    defer std.testing.allocator.free(path2);
    try std.testing.expect(!isSameFile(io, path1, path2));

    // Non-existent file should return false
    try std.testing.expect(!isSameFile(io, path1, "/nonexistent_file_abc123"));
}

test "setPermissions with file" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    defer file.close(io);

    // This should work on all platforms
    const result = try setPermissions(
        std.testing.allocator,
        file,
        0o644,
        "test.txt",
        "test",
        lib.null_writer,
    );
    try std.testing.expectEqual(@as(u8, 0), result);

    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), stat.permissions.toMode() & 0o777);
}

test "setPermissions with directory" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "subdir", .default_dir);
    var dir = try tmp_dir.dir.openDir(io, "subdir", .{});
    defer dir.close(io);

    // This should work on all platforms
    const result = try setPermissions(
        std.testing.allocator,
        dir,
        0o755,
        "subdir",
        "test",
        lib.null_writer,
    );
    try std.testing.expectEqual(@as(u8, 0), result);

    // Verify permissions via the stat method on a file opened from the directory
    const stat = try tmp_dir.dir.statFile(io, "subdir", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "CI detection" {
    // This test just verifies the function compiles and runs
    // Actual result depends on environment
    const in_ci = isRunningInCI();
    _ = in_ci;

    const should_skip = shouldSkipMacOSCITest();
    _ = should_skip;
}

test "Linux fakeroot detection" {
    // This test just verifies the function compiles and runs
    // Actual result depends on environment
    const under_fakeroot = isRunningUnderLinuxFakeroot();

    // On non-Linux platforms, should always return false
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqual(false, under_fakeroot);
    }
    // On Linux platforms, the function should run without error regardless of result
}
