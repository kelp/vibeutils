const std = @import("std");
const common = @import("common");

/// Specific error types for copy operations
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

/// Error context for better error reporting
pub const ErrorContext = struct {
    operation: []const u8,
    source_path: ?[]const u8 = null,
    dest_path: ?[]const u8 = null,
    system_error: ?anyerror = null,
};

pub const ErrorHandler = struct {
    /// Convert system errors to our specific copy errors
    pub fn mapSystemError(system_err: anyerror) CopyError {
        return switch (system_err) {
            error.FileNotFound => CopyError.SourceNotFound,
            error.AccessDenied => CopyError.PermissionDenied,
            error.PermissionDenied => CopyError.PermissionDenied,
            error.IsDir => CopyError.SourceIsDirectory,
            error.NotDir => CopyError.DestinationIsNotDirectory,
            error.PathAlreadyExists => CopyError.DestinationExists,
            error.NoSpaceLeft => CopyError.NoSpaceLeft,
            error.OutOfMemory => CopyError.OutOfMemory,
            error.CrossDeviceLink => CopyError.CrossDevice,
            error.DiskQuota => CopyError.QuotaExceeded,
            error.EmptyPath => CopyError.EmptyPath,
            error.PathTooLong => CopyError.PathTooLong,
            error.InvalidPath => CopyError.InvalidPath,
            else => CopyError.Unexpected,
        };
    }

    /// Report an error with context to stderr
    pub fn reportError(stderr_writer: anytype, context: ErrorContext, copy_err: CopyError) void {
        const program_name = "cp";

        switch (copy_err) {
            CopyError.SourceNotFound => {
                if (context.source_path) |source| {
                    common.printErrorTo(stderr_writer, "{s}: cannot stat '{s}': No such file or directory", .{ program_name, source });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: source file not found", .{program_name});
                }
            },
            CopyError.SourceNotReadable => {
                if (context.source_path) |source| {
                    common.printErrorTo(stderr_writer, "{s}: cannot read '{s}': Permission denied", .{ program_name, source });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: cannot read source file", .{program_name});
                }
            },
            CopyError.SourceIsDirectory => {
                if (context.source_path) |source| {
                    common.printErrorTo(stderr_writer, "{s}: '{s}' is a directory (not copied)", .{ program_name, source });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: source is a directory", .{program_name});
                }
            },
            CopyError.DestinationExists => {
                if (context.dest_path) |dest| {
                    common.printErrorTo(stderr_writer, "{s}: '{s}' already exists", .{ program_name, dest });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: destination already exists", .{program_name});
                }
            },
            CopyError.DestinationNotWritable => {
                if (context.dest_path) |dest| {
                    common.printErrorTo(stderr_writer, "{s}: cannot write to '{s}': Permission denied", .{ program_name, dest });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: cannot write to destination", .{program_name});
                }
            },
            CopyError.DestinationIsNotDirectory => {
                if (context.dest_path) |dest| {
                    common.printErrorTo(stderr_writer, "{s}: target '{s}' is not a directory", .{ program_name, dest });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: target is not a directory", .{program_name});
                }
            },
            CopyError.DestinationIsDirectory => {
                if (context.dest_path) |dest| {
                    common.printErrorTo(stderr_writer, "{s}: cannot overwrite directory '{s}'", .{ program_name, dest });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: cannot overwrite directory", .{program_name});
                }
            },
            CopyError.PermissionDenied, CopyError.AccessDenied => {
                if (context.source_path != null and context.dest_path != null) {
                    common.printErrorTo(stderr_writer, "{s}: cannot copy '{s}' to '{s}': Permission denied", .{ program_name, context.source_path.?, context.dest_path.? });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: permission denied", .{program_name});
                }
            },
            CopyError.CrossDevice => {
                common.printErrorTo(stderr_writer, "{s}: cannot copy across different filesystems", .{program_name});
            },
            CopyError.NoSpaceLeft => {
                common.printErrorTo(stderr_writer, "{s}: no space left on device", .{program_name});
            },
            CopyError.QuotaExceeded => {
                common.printErrorTo(stderr_writer, "{s}: disk quota exceeded", .{program_name});
            },
            CopyError.RecursionNotAllowed => {
                if (context.source_path) |source| {
                    common.printErrorTo(stderr_writer, "{s}: '{s}' is a directory (use -r to copy recursively)", .{ program_name, source });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: use -r to copy directories recursively", .{program_name});
                }
            },
            CopyError.UserCancelled => {
                // Don't print anything for user cancellation
            },
            CopyError.SameFile => {
                if (context.source_path != null and context.dest_path != null) {
                    common.printErrorTo(stderr_writer, "{s}: '{s}' and '{s}' are the same file", .{ program_name, context.source_path.?, context.dest_path.? });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: source and destination are the same file", .{program_name});
                }
            },
            CopyError.EmptyPath => {
                common.printErrorTo(stderr_writer, "{s}: empty path", .{program_name});
            },
            CopyError.PathTooLong => {
                common.printErrorTo(stderr_writer, "{s}: path too long", .{program_name});
            },
            CopyError.InvalidPath => {
                common.printErrorTo(stderr_writer, "{s}: invalid path", .{program_name});
            },
            CopyError.UnsupportedFileType => {
                if (context.source_path) |source| {
                    common.printErrorTo(stderr_writer, "{s}: '{s}': unsupported file type", .{ program_name, source });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: unsupported file type", .{program_name});
                }
            },
            CopyError.OutOfMemory => {
                common.printErrorTo(stderr_writer, "{s}: out of memory", .{program_name});
            },
            CopyError.Unexpected => {
                if (context.system_error) |sys_err| {
                    common.printErrorTo(stderr_writer, "{s}: unexpected error: {s}", .{ program_name, @errorName(sys_err) });
                } else {
                    common.printErrorTo(stderr_writer, "{s}: unexpected error", .{program_name});
                }
            },
        }
    }

    /// Handle and report an error, then return appropriate exit code
    pub fn handleError(stderr_writer: anytype, context: ErrorContext, copy_err: CopyError) common.ExitCode {
        reportError(stderr_writer, context, copy_err);

        return switch (copy_err) {
            CopyError.UserCancelled => common.ExitCode.success,
            CopyError.SourceNotFound, CopyError.EmptyPath, CopyError.PathTooLong, CopyError.InvalidPath => common.ExitCode.misuse,
            else => common.ExitCode.general_error,
        };
    }

    /// Wrap a system operation and convert errors
    pub fn wrapSystemCall(
        comptime T: type,
        stderr_writer: anytype,
        operation: anytype,
        context: ErrorContext,
    ) CopyError!T {
        return operation catch |err| {
            const copy_err = mapSystemError(err);
            var ctx = context;
            ctx.system_error = err;
            reportError(stderr_writer, ctx, copy_err);
            return copy_err;
        };
    }
};

// Convenience functions for common error scenarios
pub fn sourceNotFound(stderr_writer: anytype, source_path: []const u8) CopyError {
    const context = ErrorContext{
        .operation = "stat source",
        .source_path = source_path,
    };
    ErrorHandler.reportError(stderr_writer, context, CopyError.SourceNotFound);
    return CopyError.SourceNotFound;
}

pub fn destinationExists(stderr_writer: anytype, dest_path: []const u8) CopyError {
    const context = ErrorContext{
        .operation = "check destination",
        .dest_path = dest_path,
    };
    ErrorHandler.reportError(stderr_writer, context, CopyError.DestinationExists);
    return CopyError.DestinationExists;
}

pub fn permissionDenied(stderr_writer: anytype, source_path: []const u8, dest_path: []const u8) CopyError {
    const context = ErrorContext{
        .operation = "copy file",
        .source_path = source_path,
        .dest_path = dest_path,
    };
    ErrorHandler.reportError(stderr_writer, context, CopyError.PermissionDenied);
    return CopyError.PermissionDenied;
}

pub fn recursionNotAllowed(stderr_writer: anytype, source_path: []const u8) CopyError {
    const context = ErrorContext{
        .operation = "copy directory",
        .source_path = source_path,
    };
    ErrorHandler.reportError(stderr_writer, context, CopyError.RecursionNotAllowed);
    return CopyError.RecursionNotAllowed;
}

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;

test "ErrorHandler: mapSystemError" {
    try testing.expectEqual(CopyError.SourceNotFound, ErrorHandler.mapSystemError(error.FileNotFound));
    try testing.expectEqual(CopyError.PermissionDenied, ErrorHandler.mapSystemError(error.AccessDenied));
    try testing.expectEqual(CopyError.SourceIsDirectory, ErrorHandler.mapSystemError(error.IsDir));
    try testing.expectEqual(CopyError.OutOfMemory, ErrorHandler.mapSystemError(error.OutOfMemory));
    try testing.expectEqual(CopyError.Unexpected, ErrorHandler.mapSystemError(error.InvalidParameter));
}

test "ErrorHandler: error context" {
    const context = ErrorContext{
        .operation = "copy file",
        .source_path = "/source/path",
        .dest_path = "/dest/path",
        .system_error = error.AccessDenied,
    };

    try testing.expectEqualStrings("copy file", context.operation);
    try testing.expectEqualStrings("/source/path", context.source_path.?);
    try testing.expectEqualStrings("/dest/path", context.dest_path.?);
    try testing.expectEqual(error.AccessDenied, context.system_error.?);
}

test "ErrorHandler: handleError exit codes" {
    const context = ErrorContext{ .operation = "test" };
    var test_stderr = std.ArrayList(u8).init(testing.allocator);
    defer test_stderr.deinit();
    const stderr_writer = test_stderr.writer();

    try testing.expectEqual(common.ExitCode.success, ErrorHandler.handleError(stderr_writer, context, CopyError.UserCancelled));
    try testing.expectEqual(common.ExitCode.misuse, ErrorHandler.handleError(stderr_writer, context, CopyError.SourceNotFound));
    try testing.expectEqual(common.ExitCode.general_error, ErrorHandler.handleError(stderr_writer, context, CopyError.PermissionDenied));
}
