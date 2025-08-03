//! Recursive directory traversal functionality for ls command
const std = @import("std");
const common = @import("common");
const types = @import("types.zig");

const LsOptions = types.LsOptions;

/// Recursively list contents of a subdirectory.
/// BrokenPipe errors are propagated, others are printed but don't stop processing
pub fn recurseIntoSubdirectory(
    sub_dir: std.fs.Dir,
    subdir_path: []const u8,
    writer: anytype,
    stderr_writer: anytype,
    options: LsOptions,
    allocator: std.mem.Allocator,
    style: anytype,
    visited_fs_ids: *common.directory.FileSystemIdSet,
    git_context: ?*const types.GitContext,
) anyerror!void {
    // Import core module to avoid circular dependency
    const core = @import("core.zig");
    core.listDirectoryImplWithVisited(sub_dir, subdir_path, writer, stderr_writer, options, allocator, style, visited_fs_ids, git_context) catch |err| switch (err) {
        error.BrokenPipe => return err, // Propagate BrokenPipe for correct pipe behavior
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "ls", "{s}: {}", .{ subdir_path, err });
            // Continue with other directories even if one fails
        },
    };
}
