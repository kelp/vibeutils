//! Copy operation configuration and options
//!
//! This module defines the configuration structures and options used throughout
//! the copy engine. It follows the simplified architecture pattern.

const std = @import("std");

/// Copy operation options
pub const CpOptions = struct {
    recursive: bool = false,
    interactive: bool = false,
    force: bool = false,
    preserve: bool = false,
    no_dereference: bool = false,
};

/// File type enumeration for copy operations
pub const FileType = enum {
    regular_file,
    directory,
    symlink,
    special,
};

/// Represents a planned copy operation
pub const CopyOperation = struct {
    source: []const u8,
    dest: []const u8,
    source_type: FileType,
    dest_exists: bool,
    final_dest_path: []const u8, // resolved destination path

    pub fn deinit(self: *CopyOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.final_dest_path);
    }
};

/// Statistics for copy operations
pub const CopyStats = struct {
    files_copied: usize = 0,
    directories_copied: usize = 0,
    symlinks_copied: usize = 0,
    bytes_copied: u64 = 0,
    errors_encountered: usize = 0,

    pub fn totalItems(self: CopyStats) usize {
        return self.files_copied + self.directories_copied + self.symlinks_copied;
    }

    pub fn addFile(self: *CopyStats, size: u64) void {
        self.files_copied += 1;
        self.bytes_copied += size;
    }

    pub fn addDirectory(self: *CopyStats) void {
        self.directories_copied += 1;
    }

    pub fn addSymlink(self: *CopyStats) void {
        self.symlinks_copied += 1;
    }

    pub fn addError(self: *CopyStats) void {
        self.errors_encountered += 1;
    }
};

/// Copy errors specific to cp operations
pub const CopyError = error{
    // Source errors
    SourceNotFound,
    SourceNotReadable,
    SourceIsDirectory,

    // Destination errors
    DestinationExists,
    DestinationNotWritable,
    DestinationIsNotDirectory,
    DestinationIsDirectory,

    // Permission errors
    PermissionDenied,
    AccessDenied,

    // File system errors
    CrossDevice,
    NoSpaceLeft,
    QuotaExceeded,

    // Operation errors
    RecursionNotAllowed,
    UserCancelled,
    SameFile,

    // Path errors
    EmptyPath,
    PathTooLong,
    InvalidPath,

    // General errors
    UnsupportedFileType,
    OutOfMemory,
    Unexpected,
};

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;

test "CpOptions: default values" {
    const options = CpOptions{};
    try testing.expect(!options.recursive);
    try testing.expect(!options.interactive);
    try testing.expect(!options.force);
    try testing.expect(!options.preserve);
    try testing.expect(!options.no_dereference);
}

test "CpOptions: custom values" {
    const options = CpOptions{
        .recursive = true,
        .force = true,
    };
    try testing.expect(options.recursive);
    try testing.expect(!options.interactive);
    try testing.expect(options.force);
    try testing.expect(!options.preserve);
    try testing.expect(!options.no_dereference);
}

test "CopyStats: basic functionality" {
    var stats = CopyStats{};

    // Test initial state
    try testing.expectEqual(@as(usize, 0), stats.totalItems());
    try testing.expectEqual(@as(u64, 0), stats.bytes_copied);

    // Add some operations
    stats.addFile(100);
    stats.addFile(200);
    stats.addDirectory();
    stats.addSymlink();
    stats.addError();

    // Check final state
    try testing.expectEqual(@as(usize, 2), stats.files_copied);
    try testing.expectEqual(@as(usize, 1), stats.directories_copied);
    try testing.expectEqual(@as(usize, 1), stats.symlinks_copied);
    try testing.expectEqual(@as(u64, 300), stats.bytes_copied);
    try testing.expectEqual(@as(usize, 1), stats.errors_encountered);
    try testing.expectEqual(@as(usize, 4), stats.totalItems());
}
