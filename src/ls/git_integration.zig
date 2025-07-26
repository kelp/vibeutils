const std = @import("std");
const common = @import("common");
const types = @import("types.zig");

const Entry = types.Entry;

/// Initialize Git repository for status detection
pub fn initGitRepo(allocator: std.mem.Allocator, dir_path: []const u8) ?common.git.GitRepo {
    return common.git.GitRepo.init(allocator, dir_path) catch null;
}

/// Get Git status for a specific file entry
pub fn getFileGitStatus(git_repo: ?*common.git.GitRepo, filename: []const u8) common.git.GitStatus {
    if (git_repo) |repo| {
        return repo.getFileStatus(filename);
    }
    return .not_in_repo;
}

/// Enhance entries with Git status information
pub fn enhanceEntriesWithGitStatus(entries: []Entry, git_repo: ?*common.git.GitRepo) void {
    if (git_repo == null) return;

    for (entries) |*entry| {
        entry.git_status = git_repo.?.getFileStatus(entry.name);
    }
}

/// Check if Git status should be displayed
pub fn shouldShowGitStatus(options: types.LsOptions) bool {
    return options.show_git_status;
}

// Tests
const testing = std.testing;

test "git_integration - getFileGitStatus without repo" {
    const status = getFileGitStatus(null, "test.txt");
    try testing.expectEqual(common.git.GitStatus.not_in_repo, status);
}

test "git_integration - shouldShowGitStatus" {
    const options_with_git = types.LsOptions{ .show_git_status = true };
    try testing.expect(shouldShowGitStatus(options_with_git));

    const options_without_git = types.LsOptions{ .show_git_status = false };
    try testing.expect(!shouldShowGitStatus(options_without_git));
}
