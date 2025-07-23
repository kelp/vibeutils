const std = @import("std");

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
    
    /// Check if an entry should be included based on its name
    pub fn shouldInclude(self: EntryFilter, name: []const u8) bool {
        // Skip hidden files unless -a or -A is specified
        if (!self.show_all and !self.show_hidden and name[0] == '.') {
            return false;
        }
        
        // Skip . and .. for -A
        if (self.skip_dots) {
            if (name.len == 1 and name[0] == '.' or
                (name.len == 2 and name[0] == '.' and name[1] == '.')) {
                return false;
            }
        }
        
        return true;
    }
};

/// Cycle detection for recursive directory traversal
pub const CycleDetector = struct {
    visited_inodes: *std.AutoHashMap(u64, void),
    
    pub fn init(visited_inodes: *std.AutoHashMap(u64, void)) CycleDetector {
        return .{ .visited_inodes = visited_inodes };
    }
    
    /// Check if a directory has been visited (cycle detection)
    pub fn hasVisited(self: *CycleDetector, dir: std.fs.Dir) bool {
        if (dir.stat()) |stat| {
            return self.visited_inodes.contains(stat.inode);
        } else |_| {
            return false;
        }
    }
    
    /// Mark a directory as visited
    pub fn markVisited(self: *CycleDetector, dir: std.fs.Dir) !void {
        if (dir.stat()) |stat| {
            try self.visited_inodes.put(stat.inode, {});
        } else |_| {}
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
                (entry.name.len == 2 and entry.name[0] == '.' and entry.name[1] == '.')) {
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