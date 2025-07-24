const std = @import("std");
const path_resolver = @import("path_resolver.zig");

/// Copy operation options
pub const CpOptions = struct {
    recursive: bool = false,
    interactive: bool = false,
    force: bool = false,
    preserve: bool = false,
    no_dereference: bool = false,
};

/// Represents a planned copy operation
pub const CopyOperation = struct {
    source: []const u8,
    dest: []const u8,
    source_type: path_resolver.FileType,
    dest_exists: bool,
    final_dest_path: []const u8, // resolved destination path
    
    pub fn deinit(self: *CopyOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.final_dest_path);
    }
};

/// Context for copy operations containing shared state
pub const CopyContext = struct {
    allocator: std.mem.Allocator,
    options: CpOptions,
    
    pub fn create(allocator: std.mem.Allocator, options: CpOptions) CopyContext {
        return CopyContext{
            .allocator = allocator,
            .options = options,
        };
    }
    
    /// Plan a copy operation by analyzing source and destination
    pub fn planOperation(self: CopyContext, source: []const u8, dest: []const u8) !CopyOperation {
        // Validate paths
        try path_resolver.PathResolver.validatePath(source);
        try path_resolver.PathResolver.validatePath(dest);
        
        // Determine source type
        // For no-dereference mode, check if it's a symlink first (even if broken)
        const source_type = if (self.options.no_dereference and path_resolver.PathResolver.isSymlink(source))
            path_resolver.FileType.symlink
        else
            try path_resolver.PathResolver.getFileType(source);
        
        // Resolve final destination path
        const final_dest_path = try path_resolver.PathResolver.resolveFinalDestination(
            self.allocator,
            source,
            dest
        );
        
        // Check if final destination exists
        const dest_exists = path_resolver.PathResolver.exists(final_dest_path);
        
        return CopyOperation{
            .source = source,
            .dest = dest,
            .source_type = source_type,
            .dest_exists = dest_exists,
            .final_dest_path = final_dest_path,
        };
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

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;
const TestUtils = @import("test_utils.zig").TestUtils;

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

test "CopyContext: create and planOperation" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    // Create test files
    try test_dir.createFile("source.txt", "test content");
    try test_dir.createDir("dest_dir");
    
    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_path);
    
    // Create context and plan operation
    const options = CpOptions{};
    var context = CopyContext.create(testing.allocator, options);
    
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);
    
    // Verify operation was planned correctly
    try testing.expectEqualStrings(source_path, operation.source);
    try testing.expectEqualStrings(dest_path, operation.dest);
    try testing.expectEqual(path_resolver.FileType.regular_file, operation.source_type);
    // dest_exists should be false since final dest (dest_dir/source.txt) doesn't exist yet
    try testing.expect(!operation.dest_exists);
    try testing.expect(std.mem.endsWith(u8, operation.final_dest_path, "dest_dir/source.txt"));
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

test "CopyOperation: memory management" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("source.txt", "content");
    
    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    
    const options = CpOptions{};
    var context = CopyContext.create(testing.allocator, options);
    
    var operation = try context.planOperation(source_path, "dest.txt");
    defer operation.deinit(testing.allocator);
    
    // Test that final_dest_path was allocated
    try testing.expect(operation.final_dest_path.len > 0);
}