//! Test directory utilities for managing temporary file systems in tests
//!
//! This module provides TestDir, a comprehensive helper for creating temporary
//! file systems in tests with automatic cleanup. It supports file creation,
//! directory creation, symlinks, and various file system operations needed
//! for testing file utilities.
//!
//! # Basic Usage
//!
//! ```zig
//! var test_dir = TestDir.init(testing.allocator);
//! defer test_dir.deinit();
//!
//! try test_dir.createFile("test.txt", "content", null);
//! try test_dir.expectFileContent("test.txt", "content");
//!
//! // Get absolute paths for passing to utilities under test
//! const path = try test_dir.getPath("test.txt");
//! defer testing.allocator.free(path);
//! ```
//!
//! # Features
//!
//! - Automatic temporary directory creation and cleanup
//! - File and directory creation with optional mode settings
//! - Symbolic link creation and target verification
//! - Content verification helpers
//! - Absolute path resolution via getPath/getBasePath/join (parallel-test safe)

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const path_mod = @import("path.zig");

/// Reconstruct the absolute path of a `testing.TmpDir` without `Dir.realPath`.
/// Zig 0.16 fd-to-path is unsupported on OpenBSD and NetBSD; tmp dirs always
/// live at `<cwd>/.zig-cache/tmp/<sub_path>`.
fn resolveTmpDirBasePath(allocator: std.mem.Allocator, tmp: testing.TmpDir) ![]u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(testing.io, &cwd_buf);
    std.debug.assert(cwd_len > 0);
    std.debug.assert(cwd_len <= cwd_buf.len);
    const constructed = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/tmp/{s}",
        .{ cwd_buf[0..cwd_len], tmp.sub_path },
    );
    defer allocator.free(constructed);
    std.debug.assert(constructed.len > 0);
    var resolved_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try path_mod.realPathLibc(constructed, &resolved_buf);
    std.debug.assert(n > 0);
    return try allocator.dupe(u8, resolved_buf[0..n]);
}

/// Test directory helper for managing temporary file systems in tests
pub const TestDir = struct {
    tmp_dir: testing.TmpDir,
    allocator: std.mem.Allocator,
    /// Canonical absolute path of the sandbox, captured at init so later
    /// `chdirToBase` cannot invalidate reconstruction from getcwd.
    base_path: []u8,

    /// Initialize a test directory
    pub fn init(allocator: std.mem.Allocator) TestDir {
        var tmp = testing.tmpDir(.{});
        const base_path = resolveTmpDirBasePath(allocator, tmp) catch {
            tmp.cleanup();
            @panic("unable to resolve tmp dir path for testing");
        };
        return TestDir{
            .tmp_dir = tmp,
            .allocator = allocator,
            .base_path = base_path,
        };
    }

    /// Clean up test directory
    pub fn deinit(self: *TestDir) void {
        self.allocator.free(self.base_path);
        self.tmp_dir.cleanup();
    }

    /// The sandbox directory handle. Callers that need iterate/openFile/access
    /// reach through this rather than wrapping every Dir method.
    pub fn dir(self: *TestDir) std.Io.Dir {
        const handle = self.tmp_dir.dir.handle;
        std.debug.assert(handle >= 0);
        std.debug.assert(handle != std.posix.AT.FDCWD);
        return self.tmp_dir.dir;
    }

    /// Get the absolute path of a file in the temp directory.
    /// `"."` is the sandbox root itself (same as `getBasePath`).
    pub fn getPath(self: *TestDir, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, ".")) {
            return self.getBasePath();
        }
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try self.realPathFile(name, &buf);
        return try self.allocator.dupe(u8, buf[0..n]);
    }

    /// Get the absolute path of the temp directory itself
    pub fn getBasePath(self: *TestDir) ![]u8 {
        std.debug.assert(self.base_path.len > 0);
        return try self.allocator.dupe(u8, self.base_path);
    }

    /// Copy the sandbox absolute path into `buf`. Replaces `dir().realPath`,
    /// which is OperationUnsupported on OpenBSD and NetBSD.
    pub fn realPath(self: *const TestDir, buf: []u8) !usize {
        std.debug.assert(self.base_path.len > 0);
        if (self.base_path.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..self.base_path.len], self.base_path);
        return self.base_path.len;
    }

    /// Absolute path of `name` inside the sandbox. Joins onto the stored
    /// canonical base and does not realpath the last component, so a symlink
    /// operand stays a symlink (libc realpath would follow it).
    pub fn realPathFile(self: *TestDir, name: []const u8, buf: []u8) !usize {
        std.debug.assert(name.len > 0);
        if (std.mem.eql(u8, name, ".")) return self.realPath(buf);
        const is_link = self.isSymlink(name) catch false;
        if (!self.fileExists(name) and !is_link) return error.FileNotFound;
        const joined = try std.fs.path.join(self.allocator, &.{ self.base_path, name });
        defer self.allocator.free(joined);
        std.debug.assert(joined.len > 0);
        if (joined.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..joined.len], joined);
        return joined.len;
    }

    /// Heap-allocated canonical path of `name`. Callers free with `allocator`.
    pub fn realPathFileAlloc(
        self: *TestDir,
        name: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        std.debug.assert(name.len > 0);
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try self.realPathFile(name, &buf);
        return try allocator.dupe(u8, buf[0..n]);
    }

    /// Join a relative name onto the sandbox without requiring it to exist.
    /// `getPath` realpaths and fails for a dest that has not been created yet.
    pub fn join(self: *TestDir, rel: []const u8) ![]u8 {
        std.debug.assert(rel.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(rel));
        const base = try self.getBasePath();
        defer self.allocator.free(base);
        return try std.fs.path.join(self.allocator, &.{ base, rel });
    }

    /// Create a file with specified content and optional mode
    pub fn createFile(
        self: *TestDir,
        name: []const u8,
        content: []const u8,
        mode: ?std.posix.mode_t,
    ) !void {
        const io = testing.io;
        const file_options: std.Io.Dir.CreateFileOptions = if (mode) |m|
            .{ .permissions = std.Io.File.Permissions.fromMode(m) }
        else
            .{};
        const file = try self.tmp_dir.dir.createFile(io, name, file_options);
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    /// Create a directory
    pub fn createDir(self: *TestDir, name: []const u8) !void {
        const io = testing.io;
        try self.tmp_dir.dir.createDir(io, name, .default_dir);
    }

    /// Create nested directories; parents that do not exist are created too.
    pub fn createDirPath(self: *TestDir, name: []const u8) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(name));
        try self.tmp_dir.dir.createDirPath(testing.io, name);
    }

    /// Create a uniquely named file and return the allocated basename.
    pub fn createUniqueFile(self: *TestDir, base: []const u8, content: []const u8) ![]u8 {
        std.debug.assert(base.len > 0);
        std.debug.assert(std.mem.indexOfScalar(u8, base, '/') == null);
        return try test_utils.createUniqueTestFile(
            testing.io,
            self.tmp_dir.dir,
            self.allocator,
            base,
            content,
        );
    }

    /// Change process cwd to the sandbox. Returns a handle to the prior cwd.
    /// Allowlisted cwd-behavior tests only; restore with `restoreCwd`.
    pub fn chdirToBase(self: *TestDir) !std.Io.Dir {
        const io = testing.io;
        var saved = try std.Io.Dir.cwd().openDir(io, ".", .{});
        errdefer saved.close(io);

        const tmp_abs = try self.getBasePath();
        defer self.allocator.free(tmp_abs);
        std.debug.assert(tmp_abs.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(tmp_abs));
        try std.Io.Threaded.chdir(tmp_abs);

        return saved;
    }

    /// Restore process cwd from a handle returned by `chdirToBase`, then close
    /// it. Panics on failure so a later test cannot run in a deleted sandbox.
    pub fn restoreCwd(saved: *std.Io.Dir) void {
        const io = testing.io;
        std.debug.assert(saved.handle >= 0);
        std.debug.assert(saved.handle != std.posix.AT.FDCWD);
        std.process.setCurrentDir(io, saved.*) catch
            @panic("failed to restore test cwd");
        saved.close(io);
    }

    /// Create a symbolic link
    pub fn createSymlink(self: *TestDir, target: []const u8, link_name: []const u8) !void {
        const io = testing.io;
        try self.tmp_dir.dir.symLink(io, target, link_name, .{});
    }

    /// Check if a file exists
    pub fn fileExists(self: *TestDir, name: []const u8) bool {
        const io = testing.io;
        self.tmp_dir.dir.access(io, name, .{}) catch return false;
        return true;
    }

    /// Read entire file contents into allocated memory
    pub fn readFileAlloc(self: *TestDir, name: []const u8) ![]u8 {
        const io = testing.io;
        return self.tmp_dir.dir.readFileAlloc(io, name, self.allocator, .unlimited);
    }

    /// Verify file content matches expected content
    pub fn expectFileContent(self: *TestDir, name: []const u8, expected: []const u8) !void {
        const actual = try self.readFileAlloc(name);
        defer self.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    /// Check if a path is a symbolic link
    pub fn isSymlink(self: *TestDir, name: []const u8) !bool {
        const io = testing.io;
        var test_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = self.tmp_dir.dir.readLink(io, name, &test_buf) catch |err| switch (err) {
            error.NotLink => return false,
            else => return err,
        };
        return true;
    }

    /// Get the target of a symbolic link
    pub fn getSymlinkTarget(self: *TestDir, name: []const u8) ![]u8 {
        const io = testing.io;
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp_dir.dir.readLink(io, name, &target_buf);
        return try self.allocator.dupe(u8, target_buf[0..len]);
    }

    /// Get file statistics
    pub fn getFileStat(self: *TestDir, name: []const u8) !std.Io.File.Stat {
        const io = testing.io;
        return try self.tmp_dir.dir.statFile(io, name, .{});
    }

    /// Kernel `st_blocks` in 512-byte units. Allocation is filesystem-specific,
    /// so tests that pin `-s` / `du` output must read this after creating the
    /// fixture rather than assuming APFS or ext4 counts.
    pub fn fileBlocks512(self: *TestDir, name: []const u8) !u64 {
        const st = try kernelStatAt(self.dir().handle, name);
        std.debug.assert(name.len > 0);
        std.debug.assert(st.blocks == st.blocks);
        return st.blocks;
    }

    /// Kernel `st_gid` after create. A sandbox dir can inherit a setgid that
    /// is not present in the guest `/etc/group`.
    pub fn fileGid(self: *TestDir, name: []const u8) !u32 {
        const st = try kernelStatAt(self.dir().handle, name);
        std.debug.assert(name.len > 0);
        std.debug.assert(st.gid == st.gid);
        return st.gid;
    }

    /// Kernel `st_dev` widened to u64. Darwin/OpenBSD `dev_t` is a signed i32;
    /// FreeBSD/NetBSD use u64. Tests compare `stat -c %d` to this, not to a
    /// composed `((major<<32)|minor)` that only exists on the Linux path.
    pub fn fileDev(self: *TestDir, name: []const u8) !u64 {
        const st = try kernelStatAt(self.dir().handle, name);
        std.debug.assert(name.len > 0);
        std.debug.assert(st.dev == st.dev);
        return st.dev;
    }

    /// Best-effort `fchown` to `(geteuid(), getegid())` so group tests can stay
    /// live when the sandbox inode inherited a foreign setgid.
    pub fn tryChownToEffective(self: *TestDir, name: []const u8) bool {
        std.debug.assert(name.len > 0);
        var buf: [std.fs.max_name_bytes + 1]u8 = undefined;
        if (name.len > std.fs.max_name_bytes) return false;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const rc = std.c.fchownat(
            self.dir().handle,
            buf[0..name.len :0],
            std.c.geteuid(),
            std.c.getegid(),
            0,
        );
        std.debug.assert(name.len > 0);
        return rc == 0;
    }
};

/// Decimal digit count of `n`. Zero is one column, matching `ls -s` field math.
pub fn decimalDigitWidth(n: u64) usize {
    if (n == 0) {
        std.debug.assert(n == 0);
        std.debug.assert(decimalDigitWidthNonzero(1) == 1);
        return 1;
    }
    const width = decimalDigitWidthNonzero(n);
    std.debug.assert(width >= 1);
    std.debug.assert(n >= 1);
    return width;
}

fn decimalDigitWidthNonzero(n: u64) usize {
    std.debug.assert(n >= 1);
    var x = n;
    var width: usize = 0;
    // A u64 has at most 20 decimal digits, so this is a hard iteration cap.
    for (0..20) |_| {
        if (x == 0) break;
        x = @divFloor(x, 10);
        width += 1;
    }
    std.debug.assert(width >= 1);
    std.debug.assert(width <= 20);
    return width;
}

/// BSD `howmany(st_blocks, 2)`: 512-byte counts rounded up to 1 KiB units.
pub fn howmany512To1k(blocks: u64) u64 {
    const converted = @divFloor(blocks + 1, 2);
    std.debug.assert(converted >= @divFloor(blocks, 2));
    std.debug.assert(blocks == 0 or converted >= 1);
    return converted;
}

/// Skip when a test needs a resolvable group that equals the effective gid.
/// Linux and macOS stay live; only FreeBSD, OpenBSD, and NetBSD skip.
pub fn skipUnlessNamedEgidGroup(gid: u32) !void {
    const tag = builtin.os.tag;
    if (tag != .freebsd and tag != .openbsd and tag != .netbsd) return;
    if (std.c.getgrgid(gid) != null and gid == std.c.getegid()) return;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(std.c.getgrgid(gid) == null or gid != std.c.getegid());
    return error.SkipZigTest;
}

/// Skip when `getgrgid` cannot name `gid`. Group-name tests (`-group`, `%G`,
/// `-nogroup`) are inapplicable if NSS has no entry; GNU then prints digits
/// or matches `-nogroup`, which is correct and must not be inverted.
pub fn skipUnlessGroupNamed(gid: u32) !void {
    const tag = builtin.os.tag;
    if (tag != .freebsd and tag != .openbsd and tag != .netbsd) return;
    if (std.c.getgrgid(gid) != null) return;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(std.c.getgrgid(gid) == null);
    return error.SkipZigTest;
}

/// Skip when the file gid is not the effective gid. GNU `test -G` compares
/// those numbers; a setgid workspace dir is not a production bug.
pub fn skipUnlessGidIsEgid(gid: u32) !void {
    const tag = builtin.os.tag;
    const egid: u32 = @intCast(std.c.getegid());
    if (tag != .freebsd and tag != .openbsd and tag != .netbsd) return;
    if (gid == egid) return;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(gid != egid);
    return error.SkipZigTest;
}

/// Skip human-suffix / `-t1k` `du` cases when the kernel reported less than
/// 1 KiB allocated. `formatHumanReadable` prints a bare integer below the
/// base, so `-h` and `-k` are indistinguishable.
pub fn skipUnlessAllocatedAtLeast1KiB(blocks_512: u64) !void {
    const allocated = blocks_512 * 512;
    if (allocated >= 1024) {
        std.debug.assert(allocated >= 1024);
        std.debug.assert(blocks_512 >= 2);
        return;
    }
    const tag = builtin.os.tag;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(allocated < 1024);
    return error.SkipZigTest;
}

/// Skip `--threshold=-4k` cases when allocated bytes fall outside 1..4 KiB:
/// below 1 KiB there is no human suffix, above 4 KiB the file is excluded.
pub fn skipUnlessAllocatedBetween1KiBAnd4KiB(blocks_512: u64) !void {
    const allocated = blocks_512 * 512;
    if (allocated >= 1024 and allocated <= 4096) {
        std.debug.assert(allocated >= 1024);
        std.debug.assert(allocated <= 4096);
        return;
    }
    const tag = builtin.os.tag;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(allocated < 1024 or allocated > 4096);
    return error.SkipZigTest;
}

/// Skip when this filesystem's `st_blocks` matches a size-derived count for
/// both fixtures, so the test cannot tell `st_blocks` from `ceil(size/512)`.
pub fn skipUnlessBlocksDifferFromSizeDerived(
    sparse_blocks: u64,
    sparse_size: u64,
    tiny_blocks: u64,
    tiny_size: u64,
) !void {
    const sparse_derived = sizeDerivedBlocks512(sparse_size);
    const tiny_derived = sizeDerivedBlocks512(tiny_size);
    if (sparse_blocks != sparse_derived or tiny_blocks != tiny_derived) {
        std.debug.assert(sparse_blocks != sparse_derived or tiny_blocks != tiny_derived);
        std.debug.assert(sparse_size > 0 or tiny_size > 0);
        return;
    }
    const tag = builtin.os.tag;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(sparse_blocks == sparse_derived and tiny_blocks == tiny_derived);
    return error.SkipZigTest;
}

/// Skip when the widest `-s` count still has fewer than `min_digits` columns.
/// The four-column field test is inapplicable if this FS never reports a
/// four-digit `st_blocks` for a practical dense write.
pub fn skipUnlessWidestHasDigits(widest: u64, min_digits: usize) !void {
    const width = decimalDigitWidth(widest);
    if (width >= min_digits) {
        std.debug.assert(width >= min_digits);
        std.debug.assert(min_digits >= 1);
        return;
    }
    const tag = builtin.os.tag;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(width < min_digits);
    return error.SkipZigTest;
}

/// Skip when two block counts have the same digit width, so a right-align
/// fixture cannot be distinguished from an unpadded one.
pub fn skipUnlessWiderBlockField(narrow: u64, wide: u64) !void {
    const narrow_w = decimalDigitWidth(narrow);
    const wide_w = decimalDigitWidth(wide);
    if (wide_w > narrow_w) {
        std.debug.assert(wide_w > narrow_w);
        std.debug.assert(wide >= narrow or wide_w > narrow_w);
        return;
    }
    const tag = builtin.os.tag;
    try testing.expect(tag == .freebsd or tag == .openbsd or tag == .netbsd);
    try testing.expect(wide_w <= narrow_w);
    return error.SkipZigTest;
}

fn sizeDerivedBlocks512(size: u64) u64 {
    if (size == 0) {
        std.debug.assert(size == 0);
        std.debug.assert(@divFloor(@as(u64, 1) + 511, 512) == 1);
        return 0;
    }
    const derived = @divFloor(size + 511, 512);
    std.debug.assert(derived >= 1);
    std.debug.assert(derived * 512 >= size);
    return derived;
}

const KernelStat = struct {
    blocks: u64,
    gid: u32,
    dev: u64,
};

/// `fstatat` / Linux `statx` of `name` relative to `dir_fd`. Tests read
/// allocation and ownership from the kernel so expected strings stay honest
/// across APFS, ext4, FFS, and UFS.
fn kernelStatAt(dir_fd: std.posix.fd_t, name: []const u8) !KernelStat {
    std.debug.assert(name.len > 0);
    var buf: [std.fs.max_name_bytes + 1]u8 = undefined;
    if (name.len > std.fs.max_name_bytes) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z = buf[0..name.len :0];

    if (comptime builtin.os.tag == .linux) {
        var sx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(
            dir_fd,
            name_z,
            0,
            std.os.linux.STATX.BASIC_STATS,
            &sx,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.StatFailed;
        const st = KernelStat{
            .blocks = sx.blocks,
            .gid = sx.gid,
            .dev = (@as(u64, sx.dev_major) << 8) | @as(u64, sx.dev_minor),
        };
        std.debug.assert(name.len > 0);
        return st;
    }

    var stat_buf: std.c.Stat = undefined;
    const rc = std.c.fstatat(dir_fd, name_z, &stat_buf, 0);
    if (rc != 0) return error.StatFailed;
    const st = KernelStat{
        .blocks = @intCast(stat_buf.blocks),
        .gid = @intCast(stat_buf.gid),
        .dev = widenKernelDev(stat_buf.dev),
    };
    std.debug.assert(name.len > 0);
    return st;
}

fn widenKernelDev(dev: anytype) u64 {
    const T = @TypeOf(dev);
    const bits = @bitSizeOf(T);
    std.debug.assert(bits == 32 or bits == 64);
    std.debug.assert(@typeInfo(T) == .int);
    const unsigned: @Int(.unsigned, bits) = @bitCast(dev);
    return @as(u64, unsigned);
}

/// Absolute path of a raw `testing.TmpDir` without `Dir.realPath`.
/// Do not call after a process chdir; use `TestDir` which stores the path.
pub fn tmpDirRealPath(tmp: testing.TmpDir, buf: []u8) !usize {
    const base = try resolveTmpDirBasePath(testing.allocator, tmp);
    defer testing.allocator.free(base);
    std.debug.assert(base.len > 0);
    if (base.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..base.len], base);
    return base.len;
}

/// Canonical path of `name` inside a raw `testing.TmpDir` via libc realpath.
pub fn tmpDirRealPathFile(tmp: testing.TmpDir, name: []const u8, buf: []u8) !usize {
    std.debug.assert(name.len > 0);
    const base = try resolveTmpDirBasePath(testing.allocator, tmp);
    defer testing.allocator.free(base);
    if (std.mem.eql(u8, name, ".")) {
        if (base.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..base.len], base);
        return base.len;
    }
    const joined = try std.fs.path.join(testing.allocator, &.{ base, name });
    defer testing.allocator.free(joined);
    std.debug.assert(joined.len > 0);
    if (joined.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..joined.len], joined);
    return joined.len;
}

/// Heap-allocated canonical path of `name` inside a raw `testing.TmpDir`.
pub fn tmpDirRealPathFileAlloc(
    tmp: testing.TmpDir,
    name: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    std.debug.assert(name.len > 0);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmpDirRealPathFile(tmp, name, &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

// Tests for TestDir functionality

test "TestDir: basic file operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("test.txt", "Hello, World!", null);
    try testing.expect(test_dir.fileExists("test.txt"));
    try test_dir.expectFileContent("test.txt", "Hello, World!");
}

test "TestDir: directory operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("test_dir");
    try testing.expect(test_dir.fileExists("test_dir"));

    const stat = try test_dir.getFileStat("test_dir");
    try testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "TestDir: symbolic link operations" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("target.txt", "Target content", null);
    try test_dir.createSymlink("target.txt", "link.txt");

    try testing.expect(try test_dir.isSymlink("link.txt"));
    try testing.expect(!try test_dir.isSymlink("target.txt"));

    const target = try test_dir.getSymlinkTarget("link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("target.txt", target);
}

test "TestDir: file with mode" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("mode_test.txt", "Content", 0o644);
    const stat = try test_dir.getFileStat("mode_test.txt");

    // Check user permissions (works without privileges)
    const user_perms: u32 = @intCast(stat.permissions.toMode() & 0o700);
    try testing.expectEqual(@as(u32, 0o600), user_perms);
}

test "TestDir: dir() is a real sandbox fd" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const sandbox = test_dir.dir();
    try testing.expect(sandbox.handle >= 0);
    try testing.expect(sandbox.handle != std.posix.AT.FDCWD);
}

test "TestDir: createDirPath makes nested parents" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDirPath("a/b/c");
    try testing.expect(test_dir.fileExists("a/b/c"));
    try testing.expect(!test_dir.fileExists("a/b/missing"));
}

test "TestDir: createUniqueFile returns a distinct basename" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const name = try test_dir.createUniqueFile("base", "unique-body");
    defer testing.allocator.free(name);
    try testing.expect(name.len > 0);
    try testing.expect(!std.mem.eql(u8, name, "base"));
    try test_dir.expectFileContent(name, "unique-body");
}

test "TestDir: join builds an absolute dest that need not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const dest = try test_dir.join("missing/child");
    defer testing.allocator.free(dest);
    try testing.expect(std.fs.path.isAbsolute(dest));
    try testing.expect(std.mem.endsWith(u8, dest, "missing/child"));
    try testing.expect(!test_dir.fileExists("missing/child"));
}

test "TestDir: getPath(\".\") is the sandbox root" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    const via_dot = try test_dir.getPath(".");
    defer testing.allocator.free(via_dot);
    const via_base = try test_dir.getBasePath();
    defer testing.allocator.free(via_base);
    try testing.expect(std.fs.path.isAbsolute(via_dot));
    try testing.expectEqualStrings(via_base, via_dot);
}

test "TestDir: chdirToBase moves cwd and restoreCwd returns" {
    const io = testing.io;
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("marker.txt", "cwd-marker", null);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, "marker.txt", .{}),
    );

    var saved = try test_dir.chdirToBase();
    defer TestDir.restoreCwd(&saved);

    try std.Io.Dir.cwd().access(io, "marker.txt", .{});
}

test "TestDir: fileBlocks512 reads a stable kernel block count" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("one", "x", null);
    const first = try test_dir.fileBlocks512("one");
    const second = try test_dir.fileBlocks512("one");
    try testing.expectEqual(first, second);
    try testing.expect(first < std.math.maxInt(u64));
}

test "TestDir: fileGid matches the inode after an effective chown" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("owned", "x", null);
    const chowned = test_dir.tryChownToEffective("owned");
    const gid = try test_dir.fileGid("owned");
    try testing.expect(gid <= std.math.maxInt(u32));
    if (chowned) {
        try testing.expectEqual(@as(u32, @intCast(std.c.getegid())), gid);
    }
}

test "decimalDigitWidth treats zero as one column" {
    try testing.expectEqual(@as(usize, 1), decimalDigitWidth(0));
    try testing.expectEqual(@as(usize, 1), decimalDigitWidth(8));
    try testing.expectEqual(@as(usize, 2), decimalDigitWidth(16));
    try testing.expectEqual(@as(usize, 4), decimalDigitWidth(2048));
}
