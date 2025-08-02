const std = @import("std");

/// Type alias for HashMap using FileSystemId as keys
pub const FileSystemIdSet = std.HashMap(FileSystemId, void, FileSystemId.Context, std.hash_map.default_max_load_percentage);

/// Unique file system identifier combining device and inode for secure cycle detection
pub const FileSystemId = struct {
    device: u64,
    inode: u64,

    /// Create a FileSystemId from a directory's stat information
    pub fn fromDir(dir: std.fs.Dir) !FileSystemId {
        const stat = try dir.stat();

        return FileSystemId{
            .device = 0, // Device ID not available through std.fs.Dir.stat()
            .inode = stat.inode,
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

/// Entry filtering options for directory traversal
pub const EntryFilter = struct {
    show_hidden: bool = false,
    show_all: bool = false,
    skip_dots: bool = false, // for -A flag

    /// Check if an entry should be included based on its name.
    /// Filters out hidden files unless show_hidden or show_all is true.
    /// When skip_dots is true, excludes "." and ".." entries (for -A flag).
    pub fn shouldInclude(self: EntryFilter, name: []const u8) bool {
        // Skip hidden files unless -a or -A is specified
        if (!self.show_all and !self.show_hidden and name[0] == '.') {
            return false;
        }

        // Skip . and .. for -A
        if (self.skip_dots) {
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
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
        const fs_id = try FileSystemId.fromDir(dir);

        // Atomic check-and-set: if already present, it's a cycle
        const result = try self.visited_fs_ids.getOrPut(fs_id);
        return result.found_existing;
    }
};

/// Build a list of subdirectories from entries for recursive traversal.
/// Filters out "." and ".." entries to prevent infinite recursion.
/// Returns an ArrayList that must be freed by the caller.
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
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }

            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, entry.name });
            errdefer allocator.free(full_path);
            try subdirs.append(SubdirEntry{ .name = entry.name, .path = full_path });
        }
    }

    return subdirs;
}

/// Free paths from a subdirectory list.
/// Call this to clean up paths allocated by collectSubdirectories.
pub fn freeSubdirectoryPaths(subdirs: []const SubdirEntry, allocator: std.mem.Allocator) void {
    for (subdirs) |subdir| {
        allocator.free(subdir.path);
    }
}
