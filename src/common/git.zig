const std = @import("std");
const testing = std.testing;

/// Git file status indicators
pub const GitStatus = enum {
    untracked,      // ?? - Untracked file
    modified,       // M  - Modified in working tree
    added,          // A  - Added to index
    deleted,        // D  - Deleted from working tree
    renamed,        // R  - Renamed
    copied,         // C  - Copied
    updated,        // U  - Updated but unmerged
    ignored,        // !  - Ignored file
    clean,          // Not in git status output - clean file
    not_in_repo,    // File is not in a git repository
    
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
    
    pub fn getColor(self: GitStatus) []const u8 {
        return switch (self) {
            .untracked => "\x1b[31m",      // Red
            .modified => "\x1b[33m",       // Yellow
            .added => "\x1b[32m",          // Green
            .deleted => "\x1b[31m",        // Red
            .renamed => "\x1b[36m",        // Cyan
            .copied => "\x1b[36m",         // Cyan
            .updated => "\x1b[35m",        // Magenta
            .ignored => "\x1b[90m",        // Dark gray
            .clean => "",                  // No color
            .not_in_repo => "",            // No color
        };
    }
};

/// Git repository information and status cache
pub const GitRepo = struct {
    root_path: []const u8,
    status_map: std.StringHashMap(GitStatus),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !?Self {
        const git_root = findGitRoot(allocator, path) catch return null;
        if (git_root == null) return null;
        
        var repo = Self{
            .root_path = git_root.?,
            .status_map = std.StringHashMap(GitStatus).init(allocator),
            .allocator = allocator,
        };
        
        try repo.refreshStatus();
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
    
    pub fn getFileStatus(self: *const Self, file_path: []const u8) GitStatus {
        // Convert absolute path to relative path from git root
        const relative_path = self.makeRelativePath(file_path) catch return .not_in_repo;
        defer if (relative_path.ptr != file_path.ptr) self.allocator.free(relative_path);
        
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
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        
        if (result.term.Exited != 0) return;
        
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
    }
    
    fn makeRelativePath(self: *const Self, abs_path: []const u8) ![]const u8 {
        // If the path is already relative to git root, return it
        if (!std.fs.path.isAbsolute(abs_path)) {
            return abs_path;
        }
        
        // Make absolute path for current directory
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.process.getCwd(&path_buf);
        
        // If abs_path is actually a relative path being passed in, make it absolute
        const full_path = if (std.fs.path.isAbsolute(abs_path)) 
            abs_path 
        else 
            try std.fs.path.resolve(self.allocator, &[_][]const u8{ cwd, abs_path });
        defer if (full_path.ptr != abs_path.ptr) self.allocator.free(full_path);
        
        // Get relative path from git root to this file
        const rel_path = std.fs.path.relative(self.allocator, self.root_path, full_path) catch return abs_path;
        return rel_path;
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

/// Get git status for a directory (used by ls)
pub fn getDirectoryGitStatus(allocator: std.mem.Allocator, dir_path: []const u8) !?GitRepo {
    return GitRepo.init(allocator, dir_path);
}

// Tests
test "parseGitStatus basic cases" {
    try testing.expectEqual(GitStatus.untracked, parseGitStatus("??"));
    try testing.expectEqual(GitStatus.modified, parseGitStatus(" M"));
    try testing.expectEqual(GitStatus.added, parseGitStatus("A "));
    try testing.expectEqual(GitStatus.deleted, parseGitStatus(" D"));
    try testing.expectEqual(GitStatus.clean, parseGitStatus("  "));
}

test "GitStatus getIndicator" {
    try testing.expectEqualStrings("??", GitStatus.untracked.getIndicator());
    try testing.expectEqualStrings("M ", GitStatus.modified.getIndicator());
    try testing.expectEqualStrings("A ", GitStatus.added.getIndicator());
    try testing.expectEqualStrings("  ", GitStatus.clean.getIndicator());
}

test "GitStatus getColor" {
    try testing.expectEqualStrings("\x1b[31m", GitStatus.untracked.getColor());
    try testing.expectEqualStrings("\x1b[33m", GitStatus.modified.getColor());
    try testing.expectEqualStrings("\x1b[32m", GitStatus.added.getColor());
    try testing.expectEqualStrings("", GitStatus.clean.getColor());
}

test "findGitRoot in non-git directory" {
    const allocator = testing.allocator;
    
    // Create a temporary directory that's not in git
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    
    const result = try findGitRoot(allocator, tmp_path);
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "GitRepo init in non-git directory" {
    const allocator = testing.allocator;
    
    // Create a temporary directory that's not in git
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    
    const repo = try GitRepo.init(allocator, tmp_path);
    try testing.expectEqual(@as(?GitRepo, null), repo);
}