//! tree — list contents of a directory as a tree.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// List a directory as a tree. Implementation is filled in after RED tests.
pub fn runTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    _ = allocator;
    // A later argv scan walks every token; keep that walk bounded.
    std.debug.assert(args.len < 1 << 20);
    std.debug.assert(@intFromPtr(stdout_writer) != 0);
    std.debug.assert(@intFromPtr(stderr_writer) != 0);
    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runTree);
}

// === Tests (appended by the test-writer; do not implement behavior here) ===

const tree_test_env = [_]common.env.Override{
    .{ .key = "VIBEUTILS_STYLE", .value = null },
    .{ .key = "VIBEUTILS_COLOR", .value = null },
    .{ .key = "VIBEUTILS_ICONS", .value = null },
    .{ .key = "LS_ICONS", .value = null },
    .{ .key = "NO_COLOR", .value = null },
    .{ .key = "TERM", .value = "xterm-256color" },
};

fn treeTestStageEnv() []const common.env.Override {
    const saved = common.env.test_overrides;
    common.env.test_overrides = &tree_test_env;
    return saved;
}

fn treeTestCreateFile(dir: std.Io.Dir, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len < std.Io.Dir.max_path_bytes);
    const file = try dir.createFile(testing.io, path, .{});
    file.close(testing.io);
}

const TreeTestFixture = struct {
    tmp_dir: testing.TmpDir,
    root_path: [:0]u8,

    fn init() !TreeTestFixture {
        var tmp_dir = testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        try tmp_dir.dir.createDirPath(testing.io, "root/beta/skipme");
        try tmp_dir.dir.createDirPath(testing.io, "root/.hidden");
        try treeTestCreateFile(tmp_dir.dir, "root/alpha");
        try treeTestCreateFile(tmp_dir.dir, "root/zed");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/nested.txt");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/z.log");
        try treeTestCreateFile(tmp_dir.dir, "root/beta/skipme/buried.txt");
        try treeTestCreateFile(tmp_dir.dir, "root/.dotfile");
        try treeTestCreateFile(tmp_dir.dir, "root/.hidden/visible.txt");
        const root_path = try tmp_dir.dir.realPathFileAlloc(
            testing.io,
            "root",
            testing.allocator,
        );
        std.debug.assert(root_path.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(root_path));
        return .{ .tmp_dir = tmp_dir, .root_path = root_path };
    }

    fn deinit(self: *TreeTestFixture) void {
        std.debug.assert(self.root_path.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(self.root_path));
        testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

const TreeTestRun = struct {
    stdout_aw: std.Io.Writer.Allocating,
    stderr_aw: std.Io.Writer.Allocating,
    exit_code: u8,

    fn init(args: []const []const u8) !TreeTestRun {
        std.debug.assert(args.len < 1 << 20);
        std.debug.assert(@sizeOf(TreeTestRun) > 0);
        var result = TreeTestRun{
            .stdout_aw = .init(testing.allocator),
            .stderr_aw = .init(testing.allocator),
            .exit_code = 255,
        };
        errdefer result.deinit();
        result.exit_code = try runTree(
            testing.allocator,
            testing.io,
            args,
            &result.stdout_aw.writer,
            &result.stderr_aw.writer,
        );
        return result;
    }

    fn deinit(self: *TreeTestRun) void {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        self.stdout_aw.deinit();
        self.stderr_aw.deinit();
    }

    fn stdout(self: *const TreeTestRun) []const u8 {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        return self.stdout_aw.writer.buffered();
    }

    fn stderr(self: *const TreeTestRun) []const u8 {
        std.debug.assert(self.exit_code <= 255);
        std.debug.assert(@intFromPtr(self) != 0);
        return self.stderr_aw.writer.buffered();
    }
};

fn treeTestChdir(tmp_dir: *testing.TmpDir) !std.Io.Dir {
    var saved_cwd = try std.Io.Dir.cwd().openDir(testing.io, ".", .{});
    errdefer saved_cwd.close(testing.io);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        ".",
        testing.allocator,
    );
    defer testing.allocator.free(tmp_path);
    std.debug.assert(tmp_path.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(tmp_path));
    try std.Io.Threaded.chdir(tmp_path);
    return saved_cwd;
}

fn treeTestRestoreCwd(saved_cwd: *std.Io.Dir) void {
    std.debug.assert(saved_cwd.handle >= 0);
    std.debug.assert(saved_cwd.handle != std.posix.AT.FDCWD);
    std.process.setCurrentDir(testing.io, saved_cwd.*) catch
        @panic("failed to restore tree test cwd");
    saved_cwd.close(testing.io);
}

test "tree plan 1: bare directory prints sorted topology and summary" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{fixture.root_path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n" ++
            "├── alpha\n" ++
            "├── beta\n" ++
            "│   ├── nested.txt\n" ++
            "│   ├── skipme\n" ++
            "│   │   └── buried.txt\n" ++
            "│   └── z.log\n" ++
            "└── zed\n\n" ++
            "3 directories, 5 files\n",
        .{fixture.root_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
    try testing.expectEqualStrings("", result.stderr());
}

test "tree plan 1b: empty root counts as one directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "empty");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "empty",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n1 directory, 0 files\n",
        .{path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 2: all includes hidden entries and default prunes hidden directories" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var plain = try TreeTestRun.init(&.{fixture.root_path});
    defer plain.deinit();
    var all = try TreeTestRun.init(&.{ "-a", fixture.root_path });
    defer all.deinit();

    try testing.expect(std.mem.find(u8, plain.stdout(), ".dotfile") == null);
    try testing.expect(std.mem.find(u8, plain.stdout(), ".hidden") == null);
    try testing.expect(std.mem.find(u8, plain.stdout(), "visible.txt") == null);
    try testing.expect(std.mem.find(u8, all.stdout(), ".dotfile") != null);
    try testing.expect(std.mem.find(u8, all.stdout(), ".hidden") != null);
    try testing.expect(std.mem.find(u8, all.stdout(), "visible.txt") != null);
}

test "tree plan 3: directories-only omits files and file summary clause" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-d", fixture.root_path });
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "beta") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "alpha") == null);
    try testing.expect(std.mem.endsWith(u8, result.stdout(), "\n3 directories\n"));
    try testing.expect(std.mem.find(u8, result.stdout(), "files") == null);
}

test "tree plan 4: level one succeeds and prunes grandchildren" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-L", "1", fixture.root_path });
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "beta") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") == null);
    try testing.expectEqualStrings("", result.stderr());
}

test "tree plan 5: level zero prints only the operand" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(&.{ "-L", "0", fixture.root_path });
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n1 directory, 0 files\n",
        .{fixture.root_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 6: invalid missing negative and overflowing levels exit one" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    const cases = [_][]const []const u8{
        &.{ "-L", "nope" },
        &.{"-L"},
        &.{ "-L", "-1" },
        &.{ "-L", "999999999999999999999999999999999999" },
    };
    for (cases) |args| {
        var result = try TreeTestRun.init(args);
        defer result.deinit();
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expect(result.stderr().len > 0);
    }
}

test "tree plan 7: ignore excludes matching files and prunes matching directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var logs = try TreeTestRun.init(&.{ "-I", "*.log", fixture.root_path });
    defer logs.deinit();
    var skipped = try TreeTestRun.init(&.{ "-I", "skipme", fixture.root_path });
    defer skipped.deinit();

    try testing.expect(std.mem.find(u8, logs.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, logs.stdout(), "nested.txt") != null);
    try testing.expect(std.mem.find(u8, skipped.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, skipped.stdout(), "buried.txt") == null);
}

test "tree plan 8: repeated ignore patterns accumulate" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(
        &.{ "-I", "skipme", "-I", "*.log", fixture.root_path },
    );
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "buried.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") != null);
}

test "tree plan 8b: long aliases match their short forms" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    const short_args = [_][]const []const u8{
        &.{ "-I", "skipme", fixture.root_path },
        &.{ "-L", "1", fixture.root_path },
        &.{ "-d", fixture.root_path },
        &.{ "-a", fixture.root_path },
    };
    const long_args = [_][]const []const u8{
        &.{ "--ignore=skipme", fixture.root_path },
        &.{ "--level=1", fixture.root_path },
        &.{ "--directories-only", fixture.root_path },
        &.{ "--all", fixture.root_path },
    };
    for (short_args, long_args) |short, long| {
        var short_result = try TreeTestRun.init(short);
        defer short_result.deinit();
        var long_result = try TreeTestRun.init(long);
        defer long_result.deinit();
        try testing.expectEqual(@as(u8, 0), long_result.exit_code);
        try testing.expect(short_result.stdout().len > 0);
        try testing.expectEqualStrings(short_result.stdout(), long_result.stdout());
    }
}

test "tree plan 8c: clustered ignore options consume their patterns" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var all_ignore = try TreeTestRun.init(&.{ "-aI*.log", fixture.root_path });
    defer all_ignore.deinit();
    var dir_ignore = try TreeTestRun.init(&.{ "-dIskipme", fixture.root_path });
    defer dir_ignore.deinit();

    try testing.expectEqual(@as(u8, 0), all_ignore.exit_code);
    try testing.expect(std.mem.find(u8, all_ignore.stdout(), ".dotfile") != null);
    try testing.expect(std.mem.find(u8, all_ignore.stdout(), "z.log") == null);
    try testing.expectEqual(@as(u8, 0), dir_ignore.exit_code);
    try testing.expect(std.mem.find(u8, dir_ignore.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, dir_ignore.stdout(), "alpha") == null);
}

test "tree plan 9: pipe separates ignore alternatives" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var result = try TreeTestRun.init(
        &.{ "-I", "skipme|*.log", fixture.root_path },
    );
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "skipme") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "buried.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "z.log") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), "nested.txt") != null);
}

test "tree plan 10: filtering recomputes the last-sibling connector" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var ignored = try TreeTestRun.init(&.{ "-I", "zed", fixture.root_path });
    defer ignored.deinit();
    var directories = try TreeTestRun.init(&.{ "-d", fixture.root_path });
    defer directories.deinit();

    try testing.expect(std.mem.find(u8, ignored.stdout(), "└── beta") != null);
    try testing.expect(std.mem.find(u8, ignored.stdout(), "├── beta") == null);
    try testing.expect(std.mem.find(u8, directories.stdout(), "└── beta") != null);
    try testing.expect(std.mem.find(u8, directories.stdout(), "├── beta") == null);
}

test "tree plan 11: no operand defaults to current directory" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try treeTestCreateFile(tmp_dir.dir, "only");
    var saved_cwd = try treeTestChdir(&tmp_dir);
    defer treeTestRestoreCwd(&saved_cwd);
    var result = try TreeTestRun.init(&.{});
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.startsWith(u8, result.stdout(), ".\n"));
    try testing.expect(std.mem.find(u8, result.stdout(), "└── only") != null);
    try testing.expect(std.mem.endsWith(u8, result.stdout(), "1 directory, 1 file\n"));
}

test "tree plan 11b: file operand is a single-node tree" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try treeTestCreateFile(tmp_dir.dir, "single.txt");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "single.txt",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n\n0 directories, 1 file\n",
        .{path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
}

test "tree plan 12: multiple roots concatenate before one combined summary" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "one");
    try tmp_dir.dir.createDirPath(testing.io, "two");
    const one = try tmp_dir.dir.realPathFileAlloc(testing.io, "one", testing.allocator);
    defer testing.allocator.free(one);
    const two = try tmp_dir.dir.realPathFileAlloc(testing.io, "two", testing.allocator);
    defer testing.allocator.free(two);
    var result = try TreeTestRun.init(&.{ one, two });
    defer result.deinit();
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n{s}\n\n2 directories, 0 files\n",
        .{ one, two },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings(expected, result.stdout());
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stdout(), "\n\n"));
}

test "tree plan 13: color modes honor never and NO_COLOR without hiding icons" {
    const saved_env = common.env.test_overrides;
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();

    common.env.test_overrides = &tree_test_env;
    var never = try TreeTestRun.init(&.{ "--color=never", fixture.root_path });
    defer never.deinit();
    try testing.expectEqual(@as(u8, 0), never.exit_code);
    try testing.expect(std.mem.find(u8, never.stdout(), "\x1b") == null);

    const no_color_env = [_]common.env.Override{
        .{ .key = "VIBEUTILS_STYLE", .value = null },
        .{ .key = "VIBEUTILS_COLOR", .value = null },
        .{ .key = "VIBEUTILS_ICONS", .value = null },
        .{ .key = "LS_ICONS", .value = null },
        .{ .key = "NO_COLOR", .value = "1" },
        .{ .key = "TERM", .value = "xterm-256color" },
    };
    common.env.test_overrides = &no_color_env;
    var always = try TreeTestRun.init(&.{ "--color=always", fixture.root_path });
    defer always.deinit();
    try testing.expectEqual(@as(u8, 0), always.exit_code);
    try testing.expect(std.mem.find(u8, always.stdout(), "\x1b") == null);

    var icons = try TreeTestRun.init(&.{ "--icons=always", fixture.root_path });
    defer icons.deinit();
    const theme = common.icons.IconTheme{};
    try testing.expect(std.mem.find(u8, icons.stdout(), theme.directory) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), theme.file) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), "\x1b") == null);
}

test "tree plan 13b: forced color emits escapes and icons distinguish kinds" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var fixture = try TreeTestFixture.init();
    defer fixture.deinit();
    var color = try TreeTestRun.init(&.{ "--color=always", fixture.root_path });
    defer color.deinit();
    var icons = try TreeTestRun.init(&.{ "--icons=always", fixture.root_path });
    defer icons.deinit();
    const theme = common.icons.IconTheme{};
    const dir_icon = common.icons.getIcon(&theme, "beta", true, false, false);
    const file_icon = common.icons.getIcon(&theme, "alpha", false, false, false);

    try testing.expectEqual(@as(u8, 0), color.exit_code);
    try testing.expect(std.mem.find(u8, color.stdout(), "\x1b") != null);
    try testing.expect(!std.mem.eql(u8, dir_icon, file_icon));
    try testing.expect(std.mem.find(u8, icons.stdout(), dir_icon) != null);
    try testing.expect(std.mem.find(u8, icons.stdout(), file_icon) != null);
}

test "tree plan 14: help version and argument errors use documented exit codes" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    const success_cases = [_][]const u8{ "--help", "-h", "--version", "-V" };
    for (success_cases) |arg| {
        var result = try TreeTestRun.init(&.{arg});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expect(result.stdout().len > 0);
    }
    const error_cases = [_][]const u8{
        "--unknown-tree-flag",
        "--color=bogus",
        "--icons=bogus",
    };
    for (error_cases) |arg| {
        var result = try TreeTestRun.init(&.{arg});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expect(result.stderr().len > 0);
    }
}

test "tree plan 15: nonexistent operand reports a clean diagnostic" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var result = try TreeTestRun.init(
        &.{"/tmp/vibeutils-tree-definitely-missing-4d3f9b"},
    );
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(result.stderr().len > 0);
    try testing.expect(std.mem.find(u8, result.stderr(), "error.") == null);
    try testing.expect(std.mem.find(u8, result.stderr(), "FileNotFound") == null);
}

test "tree plan 15b: unreadable root reports a clean diagnostic" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "locked");
    try treeTestCreateFile(tmp_dir.dir, "locked/secret");
    const path = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "locked",
        testing.allocator,
    );
    defer testing.allocator.free(path);
    try tmp_dir.dir.setFilePermissions(
        testing.io,
        "locked",
        std.Io.File.Permissions.fromMode(0o000),
        .{},
    );
    defer tmp_dir.dir.setFilePermissions(
        testing.io,
        "locked",
        std.Io.File.Permissions.fromMode(0o700),
        .{},
    ) catch {};
    var result = try TreeTestRun.init(&.{path});
    defer result.deinit();

    try testing.expect(result.exit_code != 0);
    try testing.expect(result.stderr().len > 0);
    try testing.expect(std.mem.find(u8, result.stderr(), "error.AccessDenied") == null);
}

test "tree plan 16: directory symlink is listed but not followed" {
    const saved_env = treeTestStageEnv();
    defer common.env.test_overrides = saved_env;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(testing.io, "container/root");
    try tmp_dir.dir.createDirPath(testing.io, "target");
    try treeTestCreateFile(tmp_dir.dir, "target/secret.txt");
    tmp_dir.dir.symLink(
        testing.io,
        "../../target",
        "container/root/link",
        .{},
    ) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    const root = try tmp_dir.dir.realPathFileAlloc(
        testing.io,
        "container/root",
        testing.allocator,
    );
    defer testing.allocator.free(root);
    var result = try TreeTestRun.init(&.{root});
    defer result.deinit();

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.find(u8, result.stdout(), "link") != null);
    try testing.expect(std.mem.find(u8, result.stdout(), "secret.txt") == null);
    try testing.expect(std.mem.find(u8, result.stdout(), " -> ") == null);
}
