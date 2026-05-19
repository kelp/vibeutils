//! Path resolution utilities shared across vibeutils.
//!
//! Provides `canonicalizeMissing()` for resolving paths where no
//! components need exist (readlink -m, realpath -m), and
//! `canonicalizeParentMustExist()` where only the last component
//! may be missing (GNU -E default for realpath and readlink -f).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Canonicalize a path where all components except the last must exist.
/// This matches GNU `realpath -E` (the default) and `readlink -f` semantics:
/// the parent directory must be resolvable via realpath and must actually
/// be a directory, but the final component may or may not exist.
///
/// Returns `error.FileNotFound` or `error.NotDir` (or the underlying realpath
/// error) if the parent cannot be resolved or is not a directory.
pub fn canonicalizeParentMustExist(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {

    // Empty path — GNU realpath exits with FileNotFound on empty input.
    if (path.len == 0) {
        return error.FileNotFound;
    }

    // If the full path resolves, use that.
    if (std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)) |resolved| {
        return resolved;
    } else |_| {}

    // Split into parent + basename. The parent must resolve AND be a directory.
    const dirname = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);

    // Empty basename means path ended in '/', which is a directory request
    // and the whole path should have resolved above. Fall through to error.
    if (basename.len == 0) {
        return error.FileNotFound;
    }

    // "." or ".." as the basename — these are directory operations; the
    // whole path must exist. If realPathFileAlloc on the full path failed, bail.
    if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.FileNotFound;
    }

    // Verify parent is an actual directory. `realPathFileAlloc` resolves files
    // too, so without this check /etc/passwd/foo would succeed. openDir
    // returns NotDir for files, which propagates the correct GNU error.
    var parent_dir = try std.Io.Dir.cwd().openDir(io, dirname, .{});
    try parent_dir.close(io);

    // Resolve parent; propagate error (FileNotFound, NotDir, etc.) on failure.
    const resolved_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, dirname, allocator);
    defer allocator.free(resolved_parent);

    // Join resolved parent + basename.
    if (std.mem.eql(u8, resolved_parent, "/")) {
        return try std.fmt.allocPrint(allocator, "/{s}", .{basename});
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resolved_parent, basename });
}

/// Canonicalize a path where components need not exist.
/// Resolves as much as possible via realpath, then appends the remaining
/// parts with `.` and `..` cleaned logically.
pub fn canonicalizeMissing(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {

    if (path.len == 0) {
        // Empty path: return current directory
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.cwd().realPath(io, &buf);
        return try allocator.dupe(u8, buf[0..len]);
    }

    // Get absolute path
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
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

        if (std.Io.Dir.cwd().realPathFileAlloc(io, prefix, allocator)) |resolved| {
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
                if (std.mem.findLastScalar(u8, remaining.items, '/')) |last_slash| {
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
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/tmp");
    defer testing.allocator.free(result);
    // /tmp exists; result should be its realpath (e.g. /private/tmp on macOS)
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}

test "canonicalizeMissing: nonexistent tail appended to real prefix" {
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/tmp/nonexistent_vibeutils_test_path");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.endsWith(u8, result, "nonexistent_vibeutils_test_path"));
}

test "canonicalizeMissing: dotdot past root returns root" {
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/nonexistent_vibeutils_test/..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "canonicalizeMissing: empty path returns cwd" {
    const result = try canonicalizeMissing(testing.allocator, testing.io, "");
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}

test "canonicalizeMissing: root only returns root" {
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

test "canonicalizeMissing: dotdot past root is clamped (security)" {
    // /../../etc/passwd: multiple leading ".." components must clamp at root
    // before resolving the real path. The result must be the canonical form
    // of /etc/passwd, never a relative escape or something outside root.
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/../../etc/passwd");
    defer testing.allocator.free(result);
    // Must be an absolute path — never a relative escape.
    try testing.expectEqual(@as(u8, '/'), result[0]);
    // Must resolve to /etc/passwd equivalent (macOS adds /private prefix).
    try testing.expect(std.mem.endsWith(u8, result, "/etc/passwd"));
    // Must not contain any ".." in the resolved output.
    try testing.expect(std.mem.find(u8, result, "..") == null);
}

test "canonicalizeMissing: dotdot past root with fully nonexistent path" {
    // /nonexistent1/../../nonexistent2: no realPathFileAlloc prefix resolves,
    // so the else-branch does pure string normalization. The second ".." goes
    // past root; the clamp (`if (cleaned.items.len > 0)`) keeps it at root.
    // Result must be /nonexistent2, not /nonexistent1/../nonexistent2 or similar.
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/nonexistent1_vibeutils/../../nonexistent2_vibeutils");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/nonexistent2_vibeutils", result);
}

test "canonicalizeMissing: many dotdots past root always return root" {
    // /nonexistent/../../../../../.. — far more ".." than path depth.
    // Every branch (resolved prefix and else) must clamp to "/".
    const result = try canonicalizeMissing(testing.allocator, testing.io, "/nonexistent_vibeutils/../../../../../..");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/", result);
}

// ============================================================================
// canonicalizeParentMustExist tests
// ============================================================================

test "canonicalizeParentMustExist: existing path resolves fully" {
    const result = try canonicalizeParentMustExist(testing.allocator, testing.io, "/tmp");
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}

test "canonicalizeParentMustExist: nonexistent last component at root succeeds" {
    // Parent is "/", which exists; last component may be missing.
    const result = try canonicalizeParentMustExist(testing.allocator, testing.io, "/nonexistent_vibeutils_parent_test");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/nonexistent_vibeutils_parent_test", result);
}

test "canonicalizeParentMustExist: nonexistent last component under existing dir succeeds" {
    const result = try canonicalizeParentMustExist(testing.allocator, testing.io, "/tmp/nonexistent_vibeutils_last_test");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.endsWith(u8, result, "nonexistent_vibeutils_last_test"));
}

test "canonicalizeParentMustExist: missing intermediate fails" {
    const result = canonicalizeParentMustExist(testing.allocator, testing.io, "/nonexistent_vibeutils_dir/file");
    try testing.expectError(error.FileNotFound, result);
}

test "canonicalizeParentMustExist: file as parent fails with NotDir" {
    // Create a real file and try to treat it as a parent directory.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try tmp.dir.createFile(io, "real_file", .{});
    try f.writeStreamingAll(io, "x");
    try f.close(io);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const bad = try std.fmt.allocPrint(testing.allocator, "{s}/real_file/ghost", .{dir_path});
    defer testing.allocator.free(bad);
    const result = canonicalizeParentMustExist(testing.allocator, io, bad);
    try testing.expectError(error.NotDir, result);
}

test "canonicalizeParentMustExist: empty path returns FileNotFound" {
    const result = canonicalizeParentMustExist(testing.allocator, testing.io, "");
    try testing.expectError(error.FileNotFound, result);
}

test "canonicalizeParentMustExist: basename '.' with nonexistent path fails" {
    const result = canonicalizeParentMustExist(testing.allocator, testing.io, "/nonexistent_vibeutils_dot/.");
    try testing.expectError(error.FileNotFound, result);
}

test "canonicalizeParentMustExist: basename '..' with nonexistent path fails" {
    const result = canonicalizeParentMustExist(testing.allocator, testing.io, "/nonexistent_vibeutils_dotdot/..");
    try testing.expectError(error.FileNotFound, result);
}

test "canonicalizeParentMustExist: relative path with existing cwd" {
    // Relative paths need an existing parent relative to cwd.
    // "some_nonexistent_file" has dirname=".", which always resolves.
    const result = try canonicalizeParentMustExist(testing.allocator, testing.io, "nonexistent_vibeutils_rel");
    defer testing.allocator.free(result);
    try testing.expect(std.fs.path.isAbsolute(result));
    try testing.expect(std.mem.endsWith(u8, result, "nonexistent_vibeutils_rel"));
}

test "canonicalizeParentMustExist: trailing slash on existing dir resolves" {
    const result = try canonicalizeParentMustExist(testing.allocator, testing.io, "/tmp/");
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u8, '/'), result[0]);
}
