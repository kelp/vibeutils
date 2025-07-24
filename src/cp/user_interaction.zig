const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");

pub const UserInteraction = struct {
    /// Prompt user for overwrite confirmation
    pub fn shouldOverwrite(dest_path: []const u8) !bool {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("cp: overwrite '{s}'? ", .{dest_path});
        
        return try promptYesNo();
    }
    
    /// Prompt user with a yes/no question
    pub fn promptYesNo() !bool {
        var buffer: [10]u8 = undefined;
        const stdin = std.io.getStdIn().reader();
        
        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            if (line.len > 0) {
                const first_char = std.ascii.toLower(line[0]);
                return first_char == 'y';
            }
        }
        
        return false; // Default to no if no input or error
    }
    
    /// Prompt user with a custom message
    pub fn promptUser(message: []const u8) !bool {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("{s} ", .{message});
        
        return try promptYesNo();
    }
    
    /// Check if we should proceed with overwrite based on options
    pub fn checkOverwritePolicy(
        dest_path: []const u8,
        interactive: bool,
        force: bool,
    ) !bool {
        // Force mode - always overwrite
        if (force) {
            return true;
        }
        
        // Interactive mode - ask user
        if (interactive) {
            return try shouldOverwrite(dest_path);
        }
        
        // Default mode - don't overwrite, return error
        return errors.destinationExists(dest_path);
    }
    
    /// Handle force removal of destination file
    pub fn handleForceOverwrite(dest_path: []const u8) !void {
        // Try to remove the destination file first
        std.fs.cwd().deleteFile(dest_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already doesn't exist, that's fine
            error.IsDir => {
                // Can't remove directory with deleteFile
                return err;
            },
            else => return err,
        };
    }
    
    /// Display progress information for long operations
    pub fn showProgress(current: usize, total: usize, item_name: []const u8) !void {
        const stderr = std.io.getStdErr().writer();
        
        if (total > 10) { // Only show progress for operations with more than 10 items
            const percent = (current * 100) / total;
            try stderr.print("\rCopying: {s} ({d}/{d} - {d}%)", .{ item_name, current, total, percent });
            
            if (current == total) {
                try stderr.print("\n", .{}); // Final newline
            }
        }
    }
    
    /// Clear progress line
    pub fn clearProgress() !void {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\r\x1b[K", .{}); // Clear line
    }
};

/// Mock interface for testing user interactions
pub const MockUserInteraction = struct {
    responses: std.ArrayList(bool),
    current_response: usize,
    
    pub fn init(allocator: std.mem.Allocator) MockUserInteraction {
        return MockUserInteraction{
            .responses = std.ArrayList(bool).init(allocator),
            .current_response = 0,
        };
    }
    
    pub fn deinit(self: *MockUserInteraction) void {
        self.responses.deinit();
    }
    
    pub fn addResponse(self: *MockUserInteraction, response: bool) !void {
        try self.responses.append(response);
    }
    
    pub fn shouldOverwrite(self: *MockUserInteraction, dest_path: []const u8) !bool {
        _ = dest_path; // Unused in mock
        return self.getNextResponse();
    }
    
    pub fn promptYesNo(self: *MockUserInteraction) !bool {
        return self.getNextResponse();
    }
    
    pub fn promptUser(self: *MockUserInteraction, message: []const u8) !bool {
        _ = message; // Unused in mock
        return self.getNextResponse();
    }
    
    fn getNextResponse(self: *MockUserInteraction) !bool {
        if (self.current_response >= self.responses.items.len) {
            return error.NoMoreResponses;
        }
        
        const response = self.responses.items[self.current_response];
        self.current_response += 1;
        return response;
    }
    
    pub fn reset(self: *MockUserInteraction) void {
        self.current_response = 0;
    }
};

// =============================================================================
// TESTS
// =============================================================================

test "UserInteraction: checkOverwritePolicy" {
    // Force mode should always return true
    try testing.expect(try UserInteraction.checkOverwritePolicy("/test/path", false, true));
    try testing.expect(try UserInteraction.checkOverwritePolicy("/test/path", true, true));
    
    // Non-interactive, non-force should return error
    try testing.expectError(
        errors.CopyError.DestinationExists,
        UserInteraction.checkOverwritePolicy("/test/path", false, false)
    );
}

test "MockUserInteraction: basic functionality" {
    var mock = MockUserInteraction.init(testing.allocator);
    defer mock.deinit();
    
    // Add some responses
    try mock.addResponse(true);
    try mock.addResponse(false);
    try mock.addResponse(true);
    
    // Test responses are returned in order
    try testing.expect(try mock.shouldOverwrite("/test1"));
    try testing.expect(!try mock.promptYesNo());
    try testing.expect(try mock.promptUser("Test message?"));
    
    // Should error when no more responses
    try testing.expectError(error.NoMoreResponses, mock.promptYesNo());
    
    // Reset should start from beginning
    mock.reset();
    try testing.expect(try mock.shouldOverwrite("/test1"));
}

test "UserInteraction: progress display" {
    // Test progress display doesn't crash
    // In real usage this would write to stderr, but in tests it's fine
    try UserInteraction.showProgress(1, 5, "test.txt");
    try UserInteraction.showProgress(5, 5, "final.txt");
    try UserInteraction.clearProgress();
    
    // Test with large number of items (should show progress)
    try UserInteraction.showProgress(50, 100, "large_operation.txt");
    try UserInteraction.clearProgress();
}