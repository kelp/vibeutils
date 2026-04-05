//! Path resolution utilities shared across vibeutils.
//!
//! Provides `canonicalizeMissing()` for resolving paths where not all
//! components need to exist — used by readlink -m and realpath -m.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Canonicalize a path where components need not exist.
/// Resolves as much as possible via realpath, then appends the remaining
/// parts with `.` and `..` cleaned logically.
pub fn canonicalizeMissing(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) {
        // Empty path: return current directory
        return try std.fs.cwd().realpathAlloc(allocator, ".");
    }

    // Get absolute path
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch return error.FileNotFound;
        break :blk try std.fs.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(abs_path);

    // Collect all components
    var all_components = std.ArrayListUnmanaged([]const u8){};
    defer all_components.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, abs_path, '/');
    while (it.next()) |comp| {
        try all_components.append(allocator, comp);
    }

    if (all_components.items.len == 0) {
        return try allocator.dupe(u8, "/");
    }

    // Try resolving progressively shorter prefixes
    var resolved_prefix: ?[]u8 = null;
    var resolved_count: usize = 0;

    var try_count = all_components.items.len;
    while (try_count > 0) : (try_count -= 1) {
        // Build prefix path
        var prefix_len: usize = 0;
        for (all_components.items[0..try_count]) |comp| {
            prefix_len += 1 + comp.len;
        }
        const prefix = try allocator.alloc(u8, prefix_len);
        defer allocator.free(prefix);
        var pos: usize = 0;
        for (all_components.items[0..try_count]) |comp| {
            prefix[pos] = '/';
            pos += 1;
            @memcpy(prefix[pos .. pos + comp.len], comp);
            pos += comp.len;
        }

        if (std.fs.cwd().realpathAlloc(allocator, prefix)) |resolved| {
            resolved_prefix = resolved;
            resolved_count = try_count;
            break;
        } else |_| {}
    }

    // Build result: resolved prefix + remaining components (cleaned)
    if (resolved_prefix) |prefix| {
        defer allocator.free(prefix);
        if (resolved_count == all_components.items.len) {
            return try allocator.dupe(u8, prefix);
        }

        // Append remaining components, resolving . and ..
        var remaining = std.ArrayListUnmanaged(u8){};
        defer remaining.deinit(allocator);
        try remaining.appendSlice(allocator, prefix);

        for (all_components.items[resolved_count..]) |comp| {
            if (std.mem.eql(u8, comp, ".")) {
                continue;
            } else if (std.mem.eql(u8, comp, "..")) {
                if (std.mem.lastIndexOfScalar(u8, remaining.items, '/')) |last_slash| {
                    if (last_slash > 0) {
                        remaining.shrinkRetainingCapacity(last_slash);
                    } else {
                        remaining.shrinkRetainingCapacity(1); // keep just "/"
                    }
                }
            } else {
                try remaining.append(allocator, '/');
                try remaining.appendSlice(allocator, comp);
            }
        }

        return try allocator.dupe(u8, remaining.items);
    } else {
        // Nothing resolved at all, build cleaned absolute path
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);

        var cleaned = std.ArrayListUnmanaged([]const u8){};
        defer cleaned.deinit(allocator);

        for (all_components.items) |comp| {
            if (std.mem.eql(u8, comp, ".")) {
                continue;
            } else if (std.mem.eql(u8, comp, "..")) {
                if (cleaned.items.len > 0) {
                    _ = cleaned.pop();
                }
            } else {
                try cleaned.append(allocator, comp);
            }
        }

        if (cleaned.items.len == 0) {
            return try allocator.dupe(u8, "/");
        }

        for (cleaned.items) |comp| {
            try result.append(allocator, '/');
            try result.appendSlice(allocator, comp);
        }

        return try allocator.dupe(u8, result.items);
    }
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "canonicalizeMissing: existing path resolves normally" {
    const result = try canonicalizeMissing(testing.allocator, "/tmp");
    defer testing.allocator.free(result);
    // /tmp exists; result should be its realpath (e.g. /private/tmp on macOS)
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}

test "canonicalizeMissing: nonexistent tail appended to real prefix" {
    const result = try canonicalizeMissing(testing.allocator, "/tmp/nonexistent_vibeutils_test_path");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.endsWith(u8, result, "nonexistent_vibeutils_test_path"));
}

test "canonicalizeMissing: dotdot past root returns root" {
    const result = try canonicalizeMissing(testing.allocator, "/nonexistent_vibeutils_test/..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "canonicalizeMissing: empty path returns cwd" {
    const result = try canonicalizeMissing(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}

test "canonicalizeMissing: root only returns root" {
    const result = try canonicalizeMissing(testing.allocator, "/");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "canonicalizeMissing: dotdot past root is clamped (security)" {
    // /../../etc/passwd: multiple leading ".." components must clamp at root
    // before resolving the real path. The result must be the canonical form
    // of /etc/passwd, never a relative escape or something outside root.
    const result = try canonicalizeMissing(testing.allocator, "/../../etc/passwd");
    defer testing.allocator.free(result);
    // Must be an absolute path — never a relative escape.
    try testing.expectEqual(@as(u8, '/'), result[0]);
    // Must resolve to /etc/passwd equivalent (macOS adds /private prefix).
    try testing.expect(std.mem.endsWith(u8, result, "/etc/passwd"));
    // Must not contain any ".." in the resolved output.
    try testing.expect(std.mem.indexOf(u8, result, "..") == null);
}

test "canonicalizeMissing: dotdot past root with fully nonexistent path" {
    // /nonexistent1/../../nonexistent2: no realpathAlloc prefix resolves,
    // so the else-branch does pure string normalization. The second ".." goes
    // past root; the clamp (`if (cleaned.items.len > 0)`) keeps it at root.
    // Result must be /nonexistent2, not /nonexistent1/../nonexistent2 or similar.
    const result = try canonicalizeMissing(testing.allocator, "/nonexistent1_vibeutils/../../nonexistent2_vibeutils");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/nonexistent2_vibeutils", result);
}

test "canonicalizeMissing: many dotdots past root always return root" {
    // /nonexistent/../../../../../.. — far more ".." than path depth.
    // Every branch (resolved prefix and else) must clamp to "/".
    const result = try canonicalizeMissing(testing.allocator, "/nonexistent_vibeutils/../../../../../..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}
