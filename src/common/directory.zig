const std = @import("std");

/// Type alias for HashMap using FileSystemId as keys
pub const FileSystemIdSet = std.HashMap(FileSystemId, void, FileSystemId.Context, std.hash_map.default_max_load_percentage);

/// Unique file system identifier combining device and inode for secure cycle detection
pub const FileSystemId = struct {
    device: u64,
    inode: u64,

    /// Create a FileSystemId from a directory's stat information using raw fstat
    pub fn fromDir(dir: std.fs.Dir) !FileSystemId {
        // Use raw fstat to get device information that's not exposed in std.fs.File.Stat
        var stat_buf: std.c.Stat = undefined;
        const result = std.c.fstat(dir.fd, &stat_buf);
        if (result != 0) {
            return error.StatFailed;
        }

        return FileSystemId{
            .device = @intCast(stat_buf.dev),
            .inode = stat_buf.ino,
        };
    }

    /// Context for HashMap usage with FileSystemId keys
    pub const Context = struct {
        pub fn hash(ctx: @This(), key: FileSystemId) u64 {
            _ = ctx;
            // Hash both device and inode together for better distribution
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.device));
            hasher.update(std.mem.asBytes(&key.inode));
            return hasher.final();
        }

        pub fn eql(ctx: @This(), a: FileSystemId, b: FileSystemId) bool {
            _ = ctx;
            return a.device == b.device and a.inode == b.inode;
        }
    };
};

/// Subdirectory entry for recursive traversal
pub const SubdirEntry = struct {
    name: []const u8,
    path: []const u8,
};

/// Resource limits for directory operations to prevent exhaustion attacks
pub const DirectoryLimits = struct {
    max_entries: usize = 100_000, // Maximum directory entries to process
    max_memory_bytes: usize = 100 * 1024 * 1024, // 100MB memory limit

    /// Check if current usage is within limits
    pub fn checkLimits(self: DirectoryLimits, entry_count: usize, memory_usage: usize) !void {
        if (entry_count > self.max_entries) {
            return error.TooManyEntries;
        }
        if (memory_usage > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }
    }

    /// Get default limits for normal operation
    pub fn defaults() DirectoryLimits {
        return DirectoryLimits{};
    }

    /// Get limits for power users (higher thresholds)
    pub fn powerUser() DirectoryLimits {
        return DirectoryLimits{
            .max_entries = 1_000_000,
            .max_memory_bytes = 1024 * 1024 * 1024, // 1GB
        };
    }
};

/// Entry filtering options for directory traversal
pub const EntryFilter = struct {
    show_hidden: bool = false,
    show_all: bool = false,
    skip_dots: bool = false, // for -A flag

    /// Check if an entry should be included based on its name
    pub fn shouldInclude(self: EntryFilter, name: []const u8) bool {
        // Skip hidden files unless -a or -A is specified
        if (!self.show_all and !self.show_hidden and name[0] == '.') {
            return false;
        }

        // Skip . and .. for -A
        if (self.skip_dots) {
            if (name.len == 1 and name[0] == '.' or
                (name.len == 2 and name[0] == '.' and name[1] == '.'))
            {
                return false;
            }
        }

        return true;
    }
};

/// Secure cycle detection for recursive directory traversal with TOCTOU protection
pub const CycleDetector = struct {
    visited_fs_ids: *FileSystemIdSet,

    pub fn init(visited_fs_ids: *FileSystemIdSet) CycleDetector {
        return .{ .visited_fs_ids = visited_fs_ids };
    }

    /// Atomically check and mark a directory as visited to prevent TOCTOU race conditions
    /// Returns true if this directory was already visited (cycle detected)
    pub fn checkAndMarkVisited(self: *CycleDetector, dir: std.fs.Dir) !bool {
        const fs_id = FileSystemId.fromDir(dir) catch |err| switch (err) {
            error.StatFailed => {
                // If we can't stat the directory, assume it's safe but don't track it
                return false;
            },
            else => return err,
        };

        // Atomic check-and-set: if already present, it's a cycle
        const result = try self.visited_fs_ids.getOrPut(fs_id);
        return result.found_existing;
    }

    /// Check if a directory has been visited (cycle detection) - DEPRECATED
    /// Use checkAndMarkVisited instead for TOCTOU-safe operation
    pub fn hasVisited(self: *CycleDetector, dir: std.fs.Dir) bool {
        const fs_id = FileSystemId.fromDir(dir) catch return false;
        return self.visited_fs_ids.contains(fs_id);
    }

    /// Mark a directory as visited - DEPRECATED
    /// Use checkAndMarkVisited instead for TOCTOU-safe operation
    pub fn markVisited(self: *CycleDetector, dir: std.fs.Dir) !void {
        const fs_id = FileSystemId.fromDir(dir) catch return;
        try self.visited_fs_ids.put(fs_id, {});
    }
};

/// Build a list of subdirectories from entries
pub fn collectSubdirectories(
    comptime EntryType: type,
    entries: []const EntryType,
    base_path: []const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList(SubdirEntry) {
    var subdirs = std.ArrayList(SubdirEntry).init(allocator);
    errdefer {
        for (subdirs.items) |subdir| {
            allocator.free(subdir.path);
        }
        subdirs.deinit();
    }

    for (entries) |entry| {
        if (entry.kind == .directory) {
            // Skip . and .. to avoid infinite recursion
            if (entry.name.len == 1 and entry.name[0] == '.' or
                (entry.name.len == 2 and entry.name[0] == '.' and entry.name[1] == '.'))
            {
                continue;
            }

            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, entry.name });
            errdefer allocator.free(full_path);
            try subdirs.append(SubdirEntry{ .name = entry.name, .path = full_path });
        }
    }

    return subdirs;
}

/// Free paths from a subdirectory list
pub fn freeSubdirectoryPaths(subdirs: []const SubdirEntry, allocator: std.mem.Allocator) void {
    for (subdirs) |subdir| {
        allocator.free(subdir.path);
    }
}
