const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const env = @import("env.zig");
const progress = @import("progress.zig");
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
/// - handle: A std.Io.File (directories must use chmodPath instead)
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

    // Files only: fchmod(2) on a directory descriptor returns EBADF on Linux,
    // which is exactly why the sibling chmodPath exists. Directories must go
    // through that path-based leaf instead.
    const fd = if (handle_type == std.Io.File)
        handle.handle
    else
        @compileError("setPermissions expects std.Io.File; use chmodPath for directories");

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
        // EPERM (not the owner) and EROFS are ordinary, expected outcomes here;
        // routing them through unexpectedErrno dumps a stack trace in Debug
        // builds, polluting the diagnostic channel. Reserve it for the rest.
        const err = switch (std.c.errno(fchmod_result)) {
            .PERM => error.AccessDenied,
            .ROFS => error.ReadOnlyFileSystem,
            else => |e| std.posix.unexpectedErrno(e),
        };
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
    return copyFileContentsWithProgress(io, source_file, dest_file, null);
}

/// Copy file contents through the progress-aware API.
///
/// After every successful write the tracker (when present) observes the
/// running byte total, and the tracker is finished on EVERY return — success
/// and error alike — so a caller's diagnostic always starts on a clean line
/// instead of gluing to (or being wiped by) a live status line.
pub fn copyFileContentsWithProgress(
    io: std.Io,
    source_file: std.Io.File,
    dest_file: std.Io.File,
    tracker: ?*progress.Tracker,
) !void {
    // Compile-time-constant sanity check: a zero-size buffer would make every
    // read return 0 and loop forever on a non-empty source.
    assert(COPY_BUFFER_SIZE > 0);

    var copied: u64 = 0;
    var buffer: [COPY_BUFFER_SIZE]u8 = undefined;
    while (true) { // tiger:allow:unbounded-loop reads until short/zero read (EOF)
        const buf_slice: []u8 = &buffer;
        const bytes_read = source_file.readStreaming(io, &.{buf_slice}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                if (tracker) |t| t.finish(t.now(io));
                return err;
            },
        };
        // readStreaming's only destination is buffer, so it can never report
        // more bytes than the buffer holds; bounds the slice below.
        assert(bytes_read <= buffer.len);
        if (bytes_read == 0) break;
        dest_file.writeStreamingAll(io, buffer[0..bytes_read]) catch |err| {
            if (tracker) |t| t.finish(t.now(io));
            return err;
        };
        copied += bytes_read;
        if (tracker) |t| t.update(t.now(io), copied);
    }
    if (tracker) |t| t.finish(t.now(io));
}

/// Copy one regular file preserving mode, timestamps, and ownership.
///
/// Shared so cp and mv's EXDEV fallback (which copies+unlinks across
/// filesystems) preserve attributes identically rather than duplicating this
/// leaf. The sequence mirrors GNU cp -p exactly: the destination is created
/// carrying only the source's OWNER bits, contents are copied, then atime/mtime,
/// then uid/gid, and finally the full source mode via fchmod. Each step of that
/// order is load-bearing. Creating with owner bits only keeps the file from
/// being transiently group/other-accessible while it is still owned by the
/// copier rather than the source's owner. The trailing chmod — not open(2)'s
/// mode argument — is what actually establishes the mode, because the kernel
/// masks that argument by the process umask and ignores it outright when the
/// destination already exists. And that chmod must follow the chown, since
/// chown(2) clears setuid/setgid on Linux even for a same-owner no-op.
///
/// The program_name parameter routes diagnostics to the caller's name (cp vs
/// mv), matching setPermissions's convention. Failure policy is per-attribute,
/// as in GNU: timestamp and ownership failures only warn (the data copy itself
/// succeeded) and EPERM on chown is silent because a non-root user cannot chown
/// to another owner, while a failed mode preservation returns
/// error.ModeNotPreserved so the caller exits nonzero.
///
/// The optional tracker feeds the cp/mv auto-progress line; the content copy
/// finishes it on every return, so the error prints below always start on a
/// clean line. Pass null when no progress is wanted.
pub fn copyFileWithAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr_writer: anytype,
    program_name: []const u8,
    source_path: []const u8,
    dest_path: []const u8,
    source_info: lib.file.FileInfo,
    tracker: ?*progress.Tracker,
) !void {
    // A shared leaf must self-guard its inputs for both the cp and mv callers:
    // an empty program_name would mislabel diagnostics, and empty paths would
    // name no file in the open/create errors below.
    assert(program_name.len > 0);
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    const files = try copyFileWithAttributesOpen(
        allocator,
        io,
        stderr_writer,
        program_name,
        source_path,
        dest_path,
        source_info,
    );
    const source_file = files.source;
    defer source_file.close(io);
    const dest_file = files.dest;
    defer dest_file.close(io);

    copyFileContentsWithProgress(io, source_file, dest_file, tracker) catch |err| {
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

    try copyFileWithAttributesPreserveOwnerAndMode(
        allocator,
        stderr_writer,
        program_name,
        dest_path,
        dest_file,
        source_info,
    );
}

/// The opened source and freshly created destination of an
/// attribute-preserving copy. The caller owns closing both files.
const CopyFilePair = struct {
    source: std.Io.File,
    dest: std.Io.File,
};

/// Open the source and create the destination for copyFileWithAttributes,
/// reporting failures under the caller's program name. Extracted so the
/// parent stays within the 70-line limit after gaining the tracker hook.
fn copyFileWithAttributesOpen(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr_writer: anytype,
    program_name: []const u8,
    source_path: []const u8,
    dest_path: []const u8,
    source_info: lib.file.FileInfo,
) !CopyFilePair {
    // Shares copyFileWithAttributes's preconditions: empty inputs would
    // mislabel or unname the diagnostics printed below.
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

    // Owner bits only, matching GNU: the real mode is applied by the trailing
    // chmod, and a narrow creation mode keeps the copy from being briefly
    // group/other-accessible while still owned by the copying user.
    const dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{
        .permissions = std.Io.File.Permissions.fromMode(source_info.mode & 0o700),
    }) catch |err| {
        source_file.close(io);
        lib.printErrorWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot create '{s}': {s}",
            .{ dest_path, lib.posixErrorString(err) },
        );
        return error.DestinationNotWritable;
    };
    return .{ .source = source_file, .dest = dest_file };
}

/// Restore the source file's uid/gid and then its exact mode onto the copy.
///
/// Extracted from copyFileWithAttributes so the parent stays within the 70-line
/// limit. Both steps live in ONE leaf because their ORDER is the correctness
/// invariant: chown(2) clears setuid/setgid on Linux even for a same-owner
/// no-op, so the chmod must come last — splitting them into sibling leaves
/// would let a later refactor silently reorder them. The chmod is
/// unconditional because open(2)'s creation mode is umask-masked and is
/// ignored outright when the destination already existed.
///
/// GNU's failure policy is per-attribute and is reproduced here: a chown EPERM
/// is silent (a non-root user cannot chown to another owner), while a failed
/// mode preservation is reported and returns error.ModeNotPreserved.
fn copyFileWithAttributesPreserveOwnerAndMode(
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    program_name: []const u8,
    dest_path: []const u8,
    dest_file: std.Io.File,
    source_info: lib.file.FileInfo,
) !void {
    // Shares copyFileWithAttributes's preconditions: an empty program_name would
    // mislabel the diagnostics, and an empty dest_path would name no file in
    // them; this leaf is only reached from that already-asserted path.
    assert(program_name.len > 0);
    assert(dest_path.len > 0);

    const fchown_result = std.c.fchown(dest_file.handle, source_info.uid, source_info.gid);
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

    // source_info.mode is the raw stat mode and still carries S_IFREG; the
    // shared chmod leaf must see only the twelve permission bits.
    const chmod_status = try setPermissions(
        allocator,
        dest_file,
        source_info.mode & 0o7777,
        dest_path,
        program_name,
        stderr_writer,
    );
    if (chmod_status != @intFromEnum(lib.ExitCode.success)) {
        lib.printErrorWithProgram(
            allocator,
            stderr_writer,
            program_name,
            "cannot preserve permissions for '{s}'",
            .{dest_path},
        );
        return error.ModeNotPreserved;
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

/// Apply an owner and group to a named path with a libc chown(2). Path-based
/// rather than fchown for the same reason as the sibling chmodPath: the
/// post-order directory preservation leaf holds a path, not a live handle.
/// Best-effort like chmodPath, and EPERM in particular is expected rather than
/// exceptional — a non-root user cannot chown to another owner — which mirrors
/// the silent-EPERM policy on the regular-file path's fchown.
pub fn chownPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    uid: std.c.uid_t,
    gid: std.c.gid_t,
) void {
    // An empty path would name no file, and an over-long one cannot be a real
    // path — either is a caller bug rather than a runtime condition.
    assert(path.len > 0);
    assert(path.len <= std.Io.Dir.max_path_bytes);
    const path_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0) catch return;
    defer allocator.free(path_z);
    // std.c exposes no bare chown; fchownat with AT.FDCWD and no flags is the
    // identical operation (relative to cwd, symlinks followed).
    _ = std.c.fchownat(std.c.AT.FDCWD, path_z, uid, gid, 0);
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
/// Ownership is restored between the timestamps and the mode for the same
/// reason the regular-file leaf chmods last: chown(2) clears setgid on Linux
/// even for a same-owner no-op.
pub fn preserveDirAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr_writer: anytype,
    program_name: []const u8,
    dest_path: []const u8,
    source_info: lib.file.FileInfo,
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
    // Before the chmod, never after: chown clears setgid on Linux even when the
    // owner does not actually change.
    chownPath(allocator, dest_path, source_info.uid, source_info.gid);
    // The source mode still carries file-type bits (S_IFDIR); strip them so the
    // shared chmod leaf sees only permission bits.
    chmodPath(allocator, dest_path, source_info.mode & 0o7777);
    return true;
}

test "isSameFile" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    file.close(io);

    // Same file via same path should match
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const path1 = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.txt", .{dir_path});
    defer std.testing.allocator.free(path1);

    try std.testing.expect(isSameFile(io, path1, path1));

    // Different files should not match
    const file2 = try tmp_dir.dir.createFile(io, "other.txt", .{});
    file2.close(io);
    const path2 = try std.fmt.allocPrint(std.testing.allocator, "{s}/other.txt", .{dir_path});
    defer std.testing.allocator.free(path2);
    try std.testing.expect(!isSameFile(io, path1, path2));

    // Non-existent file should return false
    try std.testing.expect(!isSameFile(io, path1, "/nonexistent_file_abc123"));
}

test "copyFileContentsWithProgress updates and emits for every copied block" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const size: usize = 3 * COPY_BUFFER_SIZE;
    const content = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(content);
    @memset(content, 'x');

    const source_create = try tmp_dir.dir.createFile(io, "source.bin", .{});
    try source_create.writeStreamingAll(io, content);
    source_create.close(io);
    const source = try tmp_dir.dir.openFile(io, "source.bin", .{});
    defer source.close(io);
    const dest = try tmp_dir.dir.createFile(io, "dest.bin", .{});
    defer dest.close(io);

    var progress_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer progress_output.deinit();
    var tracker = progress.Tracker{
        .writer = &progress_output.writer,
        .program = "cp",
        .label = "source.bin",
        .total = @intCast(size),
        .delay_ns = 0,
        .interval_ns = 0,
        .start_ns = 0,
        .last_emit_ns = 0,
        .bytes_done = 0,
        .shown = false,
        .last_width = 0,
        .enabled = true,
        .kind = .copy_line,
    };

    try copyFileContentsWithProgress(io, source, dest, &tracker);

    try std.testing.expectEqual(@as(u64, @intCast(size)), tracker.bytes_done);
    try std.testing.expect(std.mem.find(u8, progress_output.writer.buffered(), "\r") != null);
}

/// Drain one copy-sized buffer from a pipe read end, then close it so the
/// writer's next buffer fails after a successful `update` (`shown == true`).
fn consumeOneCopyBufferThenClose(io: std.Io, file: std.Io.File) void {
    var buf: [COPY_BUFFER_SIZE]u8 = undefined;
    var got: usize = 0;
    var reads: u32 = 0;
    while (got < COPY_BUFFER_SIZE and reads < COPY_BUFFER_SIZE) : (reads += 1) {
        const n = std.posix.read(file.handle, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    assert(got <= COPY_BUFFER_SIZE);
    assert(reads <= COPY_BUFFER_SIZE);
    file.close(io);
}

test "copyFileContentsWithProgress finishes before a mid-copy write error diagnostic" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const size: usize = 3 * COPY_BUFFER_SIZE;
    const content = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(content);
    @memset(content, 'x');

    const source_create = try tmp_dir.dir.createFile(io, "source.bin", .{});
    try source_create.writeStreamingAll(io, content);
    source_create.close(io);
    const source = try tmp_dir.dir.openFile(io, "source.bin", .{});
    defer source.close(io);

    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.fcntl(pipe_fds[0], std.os.linux.F.SETPIPE_SZ, COPY_BUFFER_SIZE);
    }
    const pipe_read = std.Io.File{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
    const pipe_write = std.Io.File{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    const reader = try std.Thread.spawn(.{}, consumeOneCopyBufferThenClose, .{ io, pipe_read });
    defer {
        pipe_write.close(io);
        reader.join();
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = progress.Tracker{
        .writer = &output.writer,
        .program = "cp",
        .label = "source.bin",
        .total = @intCast(size),
        .delay_ns = 0,
        .interval_ns = 0,
        .start_ns = 0,
        .last_emit_ns = 0,
        .bytes_done = 0,
        .shown = false,
        .last_width = 0,
        .enabled = true,
        .kind = .copy_line,
    };

    if (copyFileContentsWithProgress(io, source, pipe_write, &tracker)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try output.writer.print("cp: cannot copy: {s}\n", .{lib.posixErrorString(err)});
    }

    const diagnostic = "cp: cannot copy:";
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.find(u8, rendered, diagnostic) != null);
    const last_cr = std.mem.lastIndexOfScalar(u8, rendered, '\r').?;
    const after_cr = rendered[last_cr + 1 ..];
    try std.testing.expect(std.mem.startsWith(u8, after_cr, diagnostic));
    try std.testing.expect(std.mem.find(u8, after_cr, "copying") == null);
    try std.testing.expect(!tracker.shown);
    try std.testing.expect(tracker.bytes_done >= COPY_BUFFER_SIZE);
}

test "copyFileContents without a tracker still copies bytes" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const source_create = try tmp_dir.dir.createFile(io, "source.txt", .{});
    try source_create.writeStreamingAll(io, "plain copy");
    source_create.close(io);
    const source = try tmp_dir.dir.openFile(io, "source.txt", .{});
    defer source.close(io);
    const dest = try tmp_dir.dir.createFile(io, "dest.txt", .{});
    defer dest.close(io);

    try copyFileContents(io, source, dest);

    const copied = try tmp_dir.dir.readFileAlloc(
        io,
        "dest.txt",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("plain copy", copied);
    try std.testing.expectEqual(@as(usize, 10), copied.len);
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

// ===========================================================================
// Intended-RED tests for issue #81: copyFileWithAttributes (the shared leaf
// behind cp -p/-a/--preserve and mv's EXDEV fallback) sets the destination
// mode ONLY via createFile's O_CREAT argument, which the kernel masks by the
// process umask and ignores outright when the destination already exists.
// A separate ordering defect: copyFileWithAttributesPreserveOwnership calls
// fchown unconditionally LAST, with no chmod afterward, so Linux's
// chown-clears-setuid/setgid semantics silently strip those bits even for a
// same-owner no-op chown. GNU cp -p: openat(O_CREAT, src_mode & 0o700) ->
// utimensat -> fchown -> fchmod(full mode). Each test below must FAIL today
// on its KEY assertion, not on a compile error or crash, and go GREEN once
// the fix chowns before an unconditional final chmod with the exact source
// mode.
// ===========================================================================

test "copyFileWithAttributes bypasses the process umask for a new destination" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const saved_umask = std.c.umask(0);
    defer _ = std.c.umask(saved_umask);

    // Source created under umask 0 so 0o644 sticks exactly; only the copy
    // itself runs under the perturbed umask below.
    const source_file = try tmp_dir.dir.createFile(io, "src.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    source_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.txt", .{dir_path});
    defer std.testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.txt", .{dir_path});
    defer std.testing.allocator.free(dest_path);

    const source_info = try lib.file.FileInfo.stat(io, source_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), source_info.mode & 0o777);

    _ = std.c.umask(0o077);

    var stderr_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_aw.deinit();

    try copyFileWithAttributes(
        std.testing.allocator,
        io,
        &stderr_aw.writer,
        "test",
        source_path,
        dest_path,
        source_info,
        null,
    );

    // KEY RED ASSERTION: today the mode is set only as createFile's O_CREAT
    // argument, which the kernel masks by the process umask 0o077, yielding
    // 0o600 instead of the source's exact 0o644.
    const dest_info = try lib.file.FileInfo.stat(io, dest_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), dest_info.mode & 0o777);
}

// FENCE 15 (leaf-level): the mtime must be preserved regardless of any
// chown/chmod reordering a fix introduces. Split out from the umask test
// above so this fence is meaningful even while the suite is red -- inside a
// single test, the mode expectEqual would abort before an appended mtime
// check ever ran, so it would only start guarding once the fix already
// landed. cp.zig's U10 covers the same fence at the CLI level.
test "copyFileWithAttributes preserves mtime independent of the mode fix" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const source_file = try tmp_dir.dir.createFile(io, "src.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    source_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.txt", .{dir_path});
    defer std.testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.txt", .{dir_path});
    defer std.testing.allocator.free(dest_path);

    const source_info = try lib.file.FileInfo.stat(io, source_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_aw.deinit();

    try copyFileWithAttributes(
        std.testing.allocator,
        io,
        &stderr_aw.writer,
        "test",
        source_path,
        dest_path,
        source_info,
        null,
    );

    const dest_info = try lib.file.FileInfo.stat(io, dest_path);
    const src_mtime_s = @divFloor(source_info.mtime, std.time.ns_per_s);
    const dst_mtime_s = @divFloor(dest_info.mtime, std.time.ns_per_s);
    try std.testing.expectEqual(src_mtime_s, dst_mtime_s);
}

test "copyFileWithAttributes updates an existing destination's mode and truncates in place" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const saved_umask = std.c.umask(0);
    defer _ = std.c.umask(saved_umask);

    const source_file = try tmp_dir.dir.createFile(io, "src.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    try source_file.writeStreamingAll(io, "new content");
    source_file.close(io);

    const dest_file = try tmp_dir.dir.createFile(io, "dst.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try dest_file.writeStreamingAll(io, "old");
    dest_file.close(io);

    const dest_stat_before = try tmp_dir.dir.statFile(io, "dst.txt", .{});

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.txt", .{dir_path});
    defer std.testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.txt", .{dir_path});
    defer std.testing.allocator.free(dest_path);

    const source_info = try lib.file.FileInfo.stat(io, source_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), source_info.mode & 0o777);

    var stderr_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_aw.deinit();

    try copyFileWithAttributes(
        std.testing.allocator,
        io,
        &stderr_aw.writer,
        "test",
        source_path,
        dest_path,
        source_info,
        null,
    );

    // KEY RED ASSERTION: O_CREAT's mode argument is ignored by the kernel
    // when the destination already exists, so today the mode stays 0o600
    // instead of being updated to the source's 0o644.
    const dest_info = try lib.file.FileInfo.stat(io, dest_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), dest_info.mode & 0o777);

    const content = try tmp_dir.dir.readFileAlloc(io, "dst.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new content", content);

    // FENCE: GNU truncates the existing destination in place rather than
    // unlinking and recreating it; the inode must be unchanged.
    const dest_stat_after = try tmp_dir.dir.statFile(io, "dst.txt", .{});
    try std.testing.expectEqual(dest_stat_before.inode, dest_stat_after.inode);
}

test "copyFileWithAttributes preserves setuid by chowning before the final chmod" {
    if (isRunningUnderLinuxFakeroot()) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // std.c.umask is process-global and shared across every embedded test in
    // this binary; pin it explicitly rather than depending on whatever umask
    // the runner inherits, matching the idiom used by the other tests in
    // this block. Special bits are unaffected by umask either way, so this
    // is belt-and-suspenders, not load-bearing.
    const saved_umask = std.c.umask(0o022);
    defer _ = std.c.umask(saved_umask);

    const source_file = try tmp_dir.dir.createFile(io, "src.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o755),
    });
    source_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.txt", .{dir_path});
    defer std.testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.txt", .{dir_path});
    defer std.testing.allocator.free(dest_path);

    // chmod is not umask-masked; if the platform silently drops or alters
    // the setuid bit (root/fakeroot oddities), skip rather than assert on an
    // unverified precondition.
    const source_path_z =
        try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}", .{source_path}, 0);
    defer std.testing.allocator.free(source_path_z);
    if (std.c.chmod(source_path_z, 0o4755) != 0) return error.SkipZigTest;
    const source_info = try lib.file.FileInfo.stat(io, source_path);
    if (source_info.mode & 0o7777 != 0o4755) return error.SkipZigTest;

    var stderr_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_aw.deinit();

    try copyFileWithAttributes(
        std.testing.allocator,
        io,
        &stderr_aw.writer,
        "test",
        source_path,
        dest_path,
        source_info,
        null,
    );

    // KEY RED ASSERTION -- ordering: chown must run BEFORE the final chmod,
    // else Linux's chown-clears-setuid semantics silently strip the bit even
    // for this no-op same-owner chown. Today fchown runs LAST, unconditionally,
    // with no chmod ever issued afterward, so the bit is lost regardless.
    const dest_info = try lib.file.FileInfo.stat(io, dest_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o4755), dest_info.mode & 0o7777);
}

test "copyFileWithAttributes preserves a source mode with no owner permission bits" {
    // Reading the source afterward needs root, since a 0-owner-bit file
    // denies its own owner read access under normal DAC checks. Under Linux
    // fakeroot, geteuid() is faked to 0 while the kernel still enforces DAC
    // against the real uid, so the euid check alone would let this run in an
    // environment where the source open can genuinely EACCES; guard both.
    if (std.c.geteuid() != 0) return error.SkipZigTest;
    if (isRunningUnderLinuxFakeroot()) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const source_file = try tmp_dir.dir.createFile(io, "src.txt", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    try source_file.writeStreamingAll(io, "hello");
    source_file.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try @import("test_dir.zig").tmpDirRealPath(tmp_dir, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.txt", .{dir_path});
    defer std.testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.txt", .{dir_path});
    defer std.testing.allocator.free(dest_path);

    const source_path_z =
        try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}", .{source_path}, 0);
    defer std.testing.allocator.free(source_path_z);
    if (std.c.chmod(source_path_z, 0o044) != 0) return error.SkipZigTest;
    const source_info = try lib.file.FileInfo.stat(io, source_path);
    if (source_info.mode & 0o777 != 0o044) return error.SkipZigTest;

    // 0o044 has no bits in common with the default umask (0o022 only clears
    // write bits), so a restrictive umask 0o077 is required to actually
    // exercise the creation-time masking this test guards against.
    const saved_umask = std.c.umask(0o077);
    defer _ = std.c.umask(saved_umask);

    var stderr_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_aw.deinit();

    try copyFileWithAttributes(
        std.testing.allocator,
        io,
        &stderr_aw.writer,
        "test",
        source_path,
        dest_path,
        source_info,
        null,
    );

    // KEY RED ASSERTION: today the mode is set only via createFile's O_CREAT
    // argument, masked by umask 0o077 (which clears the group/other bits
    // 0o044 relies on entirely), leaving 0o000 instead of the source's exact
    // 0o044. A fix that creation-masks to `& 0o700` and then skips the final
    // chmod when that result is "trivial" would fail identically.
    const dest_info = try lib.file.FileInfo.stat(io, dest_path);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o044), dest_info.mode & 0o777);
    const content = try tmp_dir.dir.readFileAlloc(io, "dst.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}
