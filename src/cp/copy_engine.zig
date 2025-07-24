const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const errors = @import("errors.zig");
const path_resolver = @import("path_resolver.zig");
const user_interaction = @import("user_interaction.zig");
const file_handlers = @import("file_handlers.zig");

pub const CopyEngine = struct {
    ctx: types.CopyContext,
    stats: types.CopyStats,
    
    pub fn init(ctx: types.CopyContext) CopyEngine {
        return CopyEngine{
            .ctx = ctx,
            .stats = types.CopyStats{},
        };
    }
    
    /// Execute a single copy operation
    pub fn executeCopy(self: *CopyEngine, operation: types.CopyOperation) !void {
        // Validate operation before execution
        try self.validateOperation(operation);
        
        // Handle user interaction upfront if needed
        if (self.ctx.options.interactive and operation.dest_exists) {
            const should_proceed = try user_interaction.UserInteraction.shouldOverwrite(operation.final_dest_path);
            if (!should_proceed) {
                // User cancelled, not an error
                return;
            }
        }
        
        // Check for same file
        if (operation.dest_exists) {
            const is_same = path_resolver.PathResolver.isSameFile(operation.source, operation.final_dest_path) catch false;
            if (is_same) {
                const context = errors.ErrorContext{
                    .operation = "copy file",
                    .source_path = operation.source,
                    .dest_path = operation.final_dest_path,
                };
                errors.ErrorHandler.reportError(context, errors.CopyError.SameFile);
                self.stats.addError();
                return errors.CopyError.SameFile;
            }
        }
        
        // Dispatch to appropriate handler based on source type and options
        switch (operation.source_type) {
            .regular_file => {
                try file_handlers.FileHandlers.copyRegularFile(self.ctx, operation, &self.stats);
            },
            .symlink => {
                if (self.ctx.options.no_dereference) {
                    try file_handlers.FileHandlers.copySymlink(self.ctx, operation, &self.stats);
                } else {
                    // Follow the symlink and copy as regular file
                    try file_handlers.FileHandlers.copyRegularFile(self.ctx, operation, &self.stats);
                }
            },
            .directory => {
                try file_handlers.FileHandlers.copyDirectory(self.ctx, operation, &self.stats);
            },
            .special => {
                const context = errors.ErrorContext{
                    .operation = "copy special file",
                    .source_path = operation.source,
                };
                errors.ErrorHandler.reportError(context, errors.CopyError.UnsupportedFileType);
                self.stats.addError();
                return errors.CopyError.UnsupportedFileType;
            },
        }
    }
    
    /// Execute multiple copy operations
    pub fn executeCopyBatch(self: *CopyEngine, operations: []types.CopyOperation) !void {
        for (operations, 0..) |operation, i| {
            // Show progress for large batches
            if (operations.len > 5) {
                try user_interaction.UserInteraction.showProgress(i + 1, operations.len, operation.source);
            }
            
            // Execute the copy operation
            self.executeCopy(operation) catch {
                // Error already reported in executeCopy, continue with next operation
                continue;
            };
        }
        
        // Clear progress line if we showed it
        if (operations.len > 5) {
            try user_interaction.UserInteraction.clearProgress();
        }
    }
    
    /// Validate that an operation is safe to execute
    pub fn validateOperation(self: *CopyEngine, operation: types.CopyOperation) !void {
        // Validate paths
        try path_resolver.PathResolver.validatePath(operation.source);
        try path_resolver.PathResolver.validatePath(operation.final_dest_path);
        
        // Check if source exists (should have been caught during planning, but double-check)
        if (!path_resolver.PathResolver.exists(operation.source)) {
            const context = errors.ErrorContext{
                .operation = "validate source",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(context, errors.CopyError.SourceNotFound);
            return errors.CopyError.SourceNotFound;
        }
        
        // For directories, ensure recursive flag is set
        if (operation.source_type == .directory and !self.ctx.options.recursive) {
            const context = errors.ErrorContext{
                .operation = "validate directory copy",
                .source_path = operation.source,
            };
            errors.ErrorHandler.reportError(context, errors.CopyError.RecursionNotAllowed);
            return errors.CopyError.RecursionNotAllowed;
        }
        
        // Check destination conflicts (except for force/interactive modes)
        if (operation.dest_exists and !self.ctx.options.force and !self.ctx.options.interactive) {
            const context = errors.ErrorContext{
                .operation = "validate destination",
                .dest_path = operation.final_dest_path,
            };
            errors.ErrorHandler.reportError(context, errors.CopyError.DestinationExists);
            return errors.CopyError.DestinationExists;
        }
    }
    
    /// Plan multiple copy operations from command line arguments
    pub fn planOperations(
        self: *CopyEngine,
        args: []const []const u8,
    ) !std.ArrayList(types.CopyOperation) {
        if (args.len < 2) {
            return error.InsufficientArguments;
        }
        
        var operations = std.ArrayList(types.CopyOperation).init(self.ctx.allocator);
        errdefer {
            for (operations.items) |*op| {
                op.deinit(self.ctx.allocator);
            }
            operations.deinit();
        }
        
        const dest = args[args.len - 1];
        
        // If multiple sources, destination must be a directory
        if (args.len > 2) {
            const dest_type = path_resolver.PathResolver.getFileType(dest) catch {
                // Destination doesn't exist - that's an error for multiple sources
                const context = errors.ErrorContext{
                    .operation = "validate multiple source destination",
                    .dest_path = dest,
                };
                errors.ErrorHandler.reportError(context, errors.CopyError.DestinationIsNotDirectory);
                return errors.CopyError.DestinationIsNotDirectory;
            };
            
            if (dest_type != .directory) {
                const context = errors.ErrorContext{
                    .operation = "validate multiple source destination",
                    .dest_path = dest,
                };
                errors.ErrorHandler.reportError(context, errors.CopyError.DestinationIsNotDirectory);
                return errors.CopyError.DestinationIsNotDirectory;
            }
        }
        
        // Plan operation for each source
        for (args[0..args.len - 1]) |source| {
            const operation = try self.ctx.planOperation(source, dest);
            try operations.append(operation);
        }
        
        return operations;
    }
    
    /// Get copy statistics
    pub fn getStats(self: *CopyEngine) types.CopyStats {
        return self.stats;
    }
    
    /// Reset statistics
    pub fn resetStats(self: *CopyEngine) void {
        self.stats = types.CopyStats{};
    }
};

// =============================================================================
// TESTS
// =============================================================================

const TestUtils = @import("test_utils.zig").TestUtils;

test "CopyEngine: execute single file copy" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("source.txt", "Hello, World!");
    
    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest.txt");
    defer testing.allocator.free(dest_path);
    
    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);
    
    try engine.executeCopy(operation);
    
    try test_dir.expectFileContent("dest.txt", "Hello, World!");
    
    const stats = engine.getStats();
    try testing.expectEqual(@as(usize, 1), stats.files_copied);
    try testing.expectEqual(@as(usize, 0), stats.errors_encountered);
}

test "CopyEngine: execute symlink copy with no-dereference" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("target.txt", "target content");
    try test_dir.createSymlink("target.txt", "link.txt");
    
    const link_path = try test_dir.getPath("link.txt");
    defer testing.allocator.free(link_path);
    const dest_path = try test_dir.joinPath("copied_link.txt");
    defer testing.allocator.free(dest_path);
    
    const options = types.CpOptions{ .no_dereference = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    var operation = try context.planOperation(link_path, dest_path);
    defer operation.deinit(testing.allocator);
    
    try engine.executeCopy(operation);
    
    try testing.expect(test_dir.isSymlink("copied_link.txt"));
    const stats = engine.getStats();
    try testing.expectEqual(@as(usize, 1), stats.symlinks_copied);
}

test "CopyEngine: execute directory copy" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createDir("source_dir");
    try test_dir.createFile("source_dir/file.txt", "content");
    
    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.joinPath("dest_dir");
    defer testing.allocator.free(dest_path);
    
    const options = types.CpOptions{ .recursive = true };
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    var operation = try context.planOperation(source_path, dest_path);
    defer operation.deinit(testing.allocator);
    
    try engine.executeCopy(operation);
    
    try test_dir.expectFileContent("dest_dir/file.txt", "content");
    const stats = engine.getStats();
    try testing.expectEqual(@as(usize, 1), stats.files_copied);
    try testing.expectEqual(@as(usize, 1), stats.directories_copied);
}

test "CopyEngine: plan operations from args" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    try test_dir.createFile("file1.txt", "content1");
    try test_dir.createFile("file2.txt", "content2");
    try test_dir.createDir("dest_dir");
    
    const file1_path = try test_dir.getPath("file1.txt");
    defer testing.allocator.free(file1_path);
    const file2_path = try test_dir.getPath("file2.txt");
    defer testing.allocator.free(file2_path);
    const dest_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_path);
    
    const args = [_][]const u8{ file1_path, file2_path, dest_path };
    
    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    var operations = try engine.planOperations(&args);
    defer {
        for (operations.items) |*op| {
            op.deinit(testing.allocator);
        }
        operations.deinit();
    }
    
    try testing.expectEqual(@as(usize, 2), operations.items.len);
    try testing.expectEqual(path_resolver.FileType.regular_file, operations.items[0].source_type);
    try testing.expectEqual(path_resolver.FileType.regular_file, operations.items[1].source_type);
}

test "CopyEngine: validate operation errors" {
    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    // Test validation with non-existent source
    const bad_operation = types.CopyOperation{
        .source = "/nonexistent/source.txt",
        .dest = "/tmp/dest.txt",
        .source_type = path_resolver.FileType.regular_file,
        .dest_exists = false,
        .final_dest_path = "/tmp/dest.txt",
    };
    
    try testing.expectError(errors.CopyError.SourceNotFound, engine.validateOperation(bad_operation));
}

test "CopyEngine: execute batch operations" {
    var test_dir = TestUtils.TestDir.init(testing.allocator);
    defer test_dir.deinit();
    
    // Create multiple source files
    try test_dir.createFile("file1.txt", "content1");
    try test_dir.createFile("file2.txt", "content2");
    try test_dir.createDir("dest_dir");
    
    const file1_path = try test_dir.getPath("file1.txt");
    defer testing.allocator.free(file1_path);
    const file2_path = try test_dir.getPath("file2.txt");
    defer testing.allocator.free(file2_path);
    const dest_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_path);
    
    const args = [_][]const u8{ file1_path, file2_path, dest_path };
    
    const options = types.CpOptions{};
    const context = types.CopyContext.create(testing.allocator, options);
    var engine = CopyEngine.init(context);
    
    var operations = try engine.planOperations(&args);
    defer {
        for (operations.items) |*op| {
            op.deinit(testing.allocator);
        }
        operations.deinit();
    }
    
    try engine.executeCopyBatch(operations.items);
    
    try test_dir.expectFileContent("dest_dir/file1.txt", "content1");
    try test_dir.expectFileContent("dest_dir/file2.txt", "content2");
    
    const stats = engine.getStats();
    try testing.expectEqual(@as(usize, 2), stats.files_copied);
    try testing.expectEqual(@as(usize, 0), stats.errors_encountered);
}