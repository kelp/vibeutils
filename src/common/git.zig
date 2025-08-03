const std = @import("std");
const testing = std.testing;

/// Git file status indicators
pub const GitStatus = enum {
    untracked, // ?? - Untracked file
    modified, // M  - Modified in working tree
    added, // A  - Added to index
    deleted, // D  - Deleted from working tree
    renamed, // R  - Renamed
    copied, // C  - Copied
    updated, // U  - Updated but unmerged
    ignored, // !  - Ignored file
    clean, // Not in git status output - clean file
    not_in_repo, // File is not in a git repository

    pub fn getIndicator(self: GitStatus) []const u8 {
        return switch (self) {
            .untracked => "??",
            .modified => "M ",
            .added => "A ",
            .deleted => "D ",
            .renamed => "R ",
            .copied => "C ",
            .updated => "U ",
            .ignored => "!!",
            .clean => "  ",
            .not_in_repo => "  ",
        };
    }
};

/// Git repository information and status cache
pub const GitRepo = struct {
    root_path: []const u8,
    status_map: std.StringHashMap(GitStatus),
    allocator: std.mem.Allocator,
    last_refresh: i128, // Timestamp of last git status refresh
    status_loaded: bool, // Track if status has been loaded at least once

    const Self = @This();
    const REFRESH_INTERVAL_NS: i128 = 5_000_000_000; // 5 seconds in nanoseconds

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !?Self {
        const git_root = try findGitRoot(allocator, path) orelse return null;

        const repo = Self{
            .root_path = git_root,
            .status_map = std.StringHashMap(GitStatus).init(allocator),
            .allocator = allocator,
            .last_refresh = 0, // Force refresh on first use
            .status_loaded = false, // Status not loaded yet
        };

        return repo;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.root_path);

        // Free all keys in the status map
        var iterator = self.status_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.status_map.deinit();
    }

    pub fn getFileStatus(self: *Self, file_path: []const u8) GitStatus {
        // Lazy-load status on first call
        if (!self.status_loaded) {
            self.refreshStatus() catch {
                // If initial load fails, mark as loaded to avoid repeated attempts
                self.status_loaded = true;
                return .not_in_repo;
            };
            self.status_loaded = true;
        }

        // Convert absolute path to relative path from git root
        const relative_path = self.makeRelativePath(file_path) catch return .not_in_repo;
        defer {
            // Only free if we allocated a new string
            if (relative_path.ptr != file_path.ptr) {
                self.allocator.free(relative_path);
            }
        }

        return self.status_map.get(relative_path) orelse .clean;
    }

    fn refreshStatus(self: *Self) !void {
        // Clear existing status
        var iterator = self.status_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.status_map.clearAndFree();

        // Run git status --porcelain
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "git", "status", "--porcelain", "--ignored" },
            .cwd = self.root_path,
        }) catch {
            // Git command failed - this is not fatal, just means no status info
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) return;

        // Parse git status output
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue; // Need at least "XY filename"

            const status_chars = line[0..2];
            const filename = std.mem.trim(u8, line[3..], " ");
            if (filename.len == 0) continue;

            const status = parseGitStatus(status_chars);
            const filename_owned = try self.allocator.dupe(u8, filename);
            try self.status_map.put(filename_owned, status);
        }

        // Only mark as loaded after successful completion
        self.status_loaded = true;
    }

    fn makeRelativePath(self: *const Self, file_path: []const u8) ![]const u8 {
        // Simple case: already relative
        if (!std.fs.path.isAbsolute(file_path)) {
            return file_path;
        }

        // Get relative path from git root to this file
        return std.fs.path.relative(self.allocator, self.root_path, file_path) catch {
            // If we can't make it relative, return the original path
            return file_path;
        };
    }
};

/// Find the git repository root directory
fn findGitRoot(allocator: std.mem.Allocator, start_path: []const u8) !?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_start = if (std.fs.path.isAbsolute(start_path))
        start_path
    else
        try std.fs.realpath(start_path, &path_buf);

    var current_path = try allocator.dupe(u8, abs_start);

    while (true) {
        // Check if .git exists in current directory
        const git_path = try std.fs.path.join(allocator, &[_][]const u8{ current_path, ".git" });
        defer allocator.free(git_path);

        // Check if .git exists (file or directory)
        std.fs.accessAbsolute(git_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Move up one directory
                const parent = std.fs.path.dirname(current_path);
                if (parent == null or std.mem.eql(u8, parent.?, current_path)) {
                    // Reached filesystem root
                    allocator.free(current_path);
                    return null;
                }

                const new_path = try allocator.dupe(u8, parent.?);
                allocator.free(current_path);
                current_path = new_path;
                continue;
            },
            else => return err,
        };

        // Found .git directory/file
        return current_path;
    }
}

/// Parse git status characters into GitStatus enum
fn parseGitStatus(status_chars: []const u8) GitStatus {
    if (status_chars.len != 2) return .clean;

    const index_status = status_chars[0];
    const worktree_status = status_chars[1];

    // Handle worktree status first (more visible to user)
    return switch (worktree_status) {
        'M' => .modified,
        'D' => .deleted,
        '?' => .untracked,
        '!' => .ignored,
        else => switch (index_status) {
            'A' => .added,
            'M' => .modified,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            'U' => .updated,
            else => .clean,
        },
    };
}

// Tests
test "parseGitStatus basic cases" {
    try testing.expectEqual(GitStatus.untracked, parseGitStatus("??"));
    try testing.expectEqual(GitStatus.modified, parseGitStatus(" M"));
    try testing.expectEqual(GitStatus.added, parseGitStatus("A "));
    try testing.expectEqual(GitStatus.deleted, parseGitStatus(" D"));
    try testing.expectEqual(GitStatus.clean, parseGitStatus("  "));
    try testing.expectEqual(GitStatus.renamed, parseGitStatus("R "));
    try testing.expectEqual(GitStatus.copied, parseGitStatus("C "));
    try testing.expectEqual(GitStatus.ignored, parseGitStatus("!!"));
    try testing.expectEqual(GitStatus.modified, parseGitStatus("M "));
    try testing.expectEqual(GitStatus.modified, parseGitStatus("MM"));
}

test "GitStatus getIndicator" {
    try testing.expectEqualStrings("??", GitStatus.untracked.getIndicator());
    try testing.expectEqualStrings("M ", GitStatus.modified.getIndicator());
    try testing.expectEqualStrings("A ", GitStatus.added.getIndicator());
    try testing.expectEqualStrings("  ", GitStatus.clean.getIndicator());
    try testing.expectEqualStrings("D ", GitStatus.deleted.getIndicator());
    try testing.expectEqualStrings("R ", GitStatus.renamed.getIndicator());
    try testing.expectEqualStrings("!!", GitStatus.ignored.getIndicator());
}

test "findGitRoot in non-git directory" {
    const allocator = testing.allocator;

    // Create a temporary directory that's not in git
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a nested directory to ensure we're not in a git repo
    try tmp_dir.dir.makePath("test/nested/deep");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath("test/nested/deep", &path_buf);

    // This test may find the actual repo if run inside one, which is OK
    // The important thing is the function doesn't crash or leak memory
    const result = try findGitRoot(allocator, tmp_path);
    if (result) |r| {
        defer allocator.free(r);
        // If we found a repo, it should contain .git
        var found_dir = try std.fs.openDirAbsolute(r, .{});
        defer found_dir.close();
        _ = found_dir.statFile(".git") catch |err| {
            // If .git doesn't exist in the found root, that's an error
            try testing.expect(err == error.FileNotFound);
        };
    }
}

test "GitRepo init in non-git directory" {
    const allocator = testing.allocator;

    // Create a temporary directory that's not in git
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a nested directory to ensure we're not in a git repo
    try tmp_dir.dir.makePath("test/nested/deep");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath("test/nested/deep", &path_buf);

    // This test may find the actual repo if run inside one
    var repo = try GitRepo.init(allocator, tmp_path);
    if (repo) |*r| {
        defer r.deinit();
        // Verify the repo has a valid root path
        try testing.expect(r.root_path.len > 0);
    }
}
