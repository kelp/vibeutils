const std = @import("std");
const c = std.c;
const testing = std.testing;

// C library structures for user/group lookups
const c_passwd = extern struct {
    pw_name: [*:0]u8,
    pw_passwd: [*:0]u8,
    pw_uid: c.uid_t,
    pw_gid: c.gid_t,
    pw_gecos: [*:0]u8,
    pw_dir: [*:0]u8,
    pw_shell: [*:0]u8,
};

const c_group = extern struct {
    gr_name: [*:0]u8,
    gr_passwd: [*:0]u8,
    gr_gid: c.gid_t,
    gr_mem: [*][*:0]u8,
};

// C library bindings for user/group lookups
extern "c" fn getpwnam(name: [*:0]const u8) ?*c_passwd;
extern "c" fn getgrnam(name: [*:0]const u8) ?*c_group;
extern "c" fn getpwuid(uid: c.uid_t) ?*c_passwd;
extern "c" fn getgrgid(gid: c.gid_t) ?*c_group;
extern "c" fn getuid() c.uid_t;
extern "c" fn getgid() c.gid_t;

/// User and group ID types
pub const uid_t = std.posix.uid_t;
pub const gid_t = std.posix.gid_t;

/// Error types for user/group operations
pub const Error = error{
    UserNotFound,
    GroupNotFound,
    InvalidFormat,
    SystemError,
    OutOfMemory,
};

/// Represents a user lookup result
/// Note: The caller owns the name slice and must free it with the same allocator
/// used to obtain the UserInfo.
pub const UserInfo = struct {
    uid: uid_t,
    gid: gid_t,
    name: []const u8,
};

/// Represents a group lookup result
/// Note: The caller owns the name slice and must free it with the same allocator
/// used to obtain the GroupInfo.
pub const GroupInfo = struct {
    gid: gid_t,
    name: []const u8,
};

/// Represents ownership change specification
pub const OwnershipSpec = struct {
    user: ?uid_t = null,
    group: ?gid_t = null,
    warn_octal_confusion: bool = false,

    /// Parse ownership specification string like "user:group", "user:", ":group", "user"
    /// Per GNU coreutils: if a colon follows the user name but no group name is
    /// given, the user's login group is used as the new group.
    pub fn parse(spec: []const u8, allocator: std.mem.Allocator) Error!OwnershipSpec {
        if (spec.len == 0) return Error.InvalidFormat;

        var result = OwnershipSpec{};

        // Check for colon separator
        if (std.mem.indexOf(u8, spec, ":")) |colon_pos| {
            // user:group format
            const user_part = spec[0..colon_pos];
            const group_part = spec[colon_pos + 1 ..];

            // Parse user part (if not empty)
            if (user_part.len > 0) {
                result.user = try parseUser(user_part, allocator);
            }

            // Parse group part
            if (group_part.len > 0) {
                result.group = try parseGroup(group_part, allocator);
            } else if (user_part.len > 0) {
                // "user:" with no group — set to user's login group
                if (result.user) |uid| {
                    const user_info = getUserById(uid, allocator) catch
                        return Error.UserNotFound;
                    defer allocator.free(user_info.name);
                    result.group = user_info.gid;
                }
            }
        } else {
            // User only format
            result.user = try parseUser(spec, allocator);
            // Warn if the spec looks like an octal permission mode
            if (looksLikeOctalMode(spec)) {
                result.warn_octal_confusion = true;
            }
        }

        return result;
    }
};

/// Check if a string looks like an octal permission mode (e.g., 644, 755, 0700).
/// Returns true for 3-digit octal strings (like 755) or 4-digit octal strings
/// that start with '0' (like 0755). This avoids false positives for common UIDs
/// like 1000 which are 4-digit numbers that happen to use only octal digits.
fn looksLikeOctalMode(spec: []const u8) bool {
    if (spec.len < 3 or spec.len > 4) return false;
    for (spec) |ch| {
        if (ch < '0' or ch > '7') return false;
    }
    // 4-digit octal modes always start with 0 (e.g., 0755);
    // numbers like 1000 are common UIDs, not permission modes
    if (spec.len == 4 and spec[0] != '0') return false;
    return true;
}

/// Parse user specification (name or numeric ID)
pub fn parseUser(user_spec: []const u8, allocator: std.mem.Allocator) Error!uid_t {
    // Try to parse as numeric ID first
    if (std.fmt.parseInt(uid_t, user_spec, 10)) |uid| {
        return uid;
    } else |_| {
        // Not numeric, look up by name
        return lookupUserByName(user_spec, allocator);
    }
}

/// Parse group specification (name or numeric ID)
pub fn parseGroup(group_spec: []const u8, allocator: std.mem.Allocator) Error!gid_t {
    // Try to parse as numeric ID first
    if (std.fmt.parseInt(gid_t, group_spec, 10)) |gid| {
        return gid;
    } else |_| {
        // Not numeric, look up by name
        return lookupGroupByName(group_spec, allocator);
    }
}

/// Look up user by name using getpwnam
/// This function ONLY performs name lookups - use parseUser for numeric ID parsing
pub fn lookupUserByName(name: []const u8, allocator: std.mem.Allocator) Error!uid_t {
    const name_z = allocator.dupeZ(u8, name) catch return Error.OutOfMemory;
    defer allocator.free(name_z);

    const passwd = getpwnam(name_z.ptr) orelse return Error.UserNotFound;
    return passwd.pw_uid;
}

/// Look up group by name using getgrnam
/// This function ONLY performs name lookups - use parseGroup for numeric ID parsing
pub fn lookupGroupByName(name: []const u8, allocator: std.mem.Allocator) Error!gid_t {
    const name_z = allocator.dupeZ(u8, name) catch return Error.OutOfMemory;
    defer allocator.free(name_z);

    const group = getgrnam(name_z.ptr) orelse return Error.GroupNotFound;
    return group.gr_gid;
}

/// Get user information by UID
/// Caller owns the returned name slice and must free it with the provided allocator
pub fn getUserById(uid: uid_t, allocator: std.mem.Allocator) Error!UserInfo {
    const passwd = getpwuid(uid) orelse return Error.UserNotFound;
    const name = std.mem.span(passwd.pw_name);
    const owned_name = allocator.dupe(u8, name) catch return Error.OutOfMemory;
    return UserInfo{
        .uid = passwd.pw_uid,
        .gid = passwd.pw_gid,
        .name = owned_name,
    };
}

/// Get group information by GID
/// Caller owns the returned name slice and must free it with the provided allocator
pub fn getGroupById(gid: gid_t, allocator: std.mem.Allocator) Error!GroupInfo {
    const group = getgrgid(gid) orelse return Error.GroupNotFound;
    const name = std.mem.span(group.gr_name);
    const owned_name = allocator.dupe(u8, name) catch return Error.OutOfMemory;
    return GroupInfo{
        .gid = group.gr_gid,
        .name = owned_name,
    };
}

/// Get current user's UID
pub fn getCurrentUserId() uid_t {
    return @intCast(getuid());
}

/// Get current user's GID
pub fn getCurrentGroupId() gid_t {
    return @intCast(getgid());
}

// ==================== TESTS ====================

test "parseUser with numeric ID" {
    const uid = try parseUser("1000", testing.allocator);
    try testing.expectEqual(@as(uid_t, 1000), uid);
}

test "parseGroup with numeric ID" {
    const gid = try parseGroup("100", testing.allocator);
    try testing.expectEqual(@as(gid_t, 100), gid);
}

test "parseUser with numeric overflow falls back to name lookup" {
    // Test numeric overflow - parseUser falls back to name lookup which fails
    try testing.expectError(Error.UserNotFound, parseUser("999999999999999999999", testing.allocator));
}

test "parseGroup with numeric overflow falls back to name lookup" {
    // Test numeric overflow - parseGroup falls back to name lookup which fails
    try testing.expectError(Error.GroupNotFound, parseGroup("999999999999999999999", testing.allocator));
}

test "OwnershipSpec.parse user only" {
    const spec = try OwnershipSpec.parse("1000", testing.allocator);
    try testing.expectEqual(@as(uid_t, 1000), spec.user.?);
    try testing.expectEqual(@as(?gid_t, null), spec.group);
}

test "OwnershipSpec.parse user and group" {
    const spec = try OwnershipSpec.parse("1000:100", testing.allocator);
    try testing.expectEqual(@as(uid_t, 1000), spec.user.?);
    try testing.expectEqual(@as(gid_t, 100), spec.group.?);
}

test "OwnershipSpec.parse group only" {
    const spec = try OwnershipSpec.parse(":100", testing.allocator);
    try testing.expectEqual(@as(?uid_t, null), spec.user);
    try testing.expectEqual(@as(gid_t, 100), spec.group.?);
}

test "OwnershipSpec.parse user with empty group" {
    const spec = try OwnershipSpec.parse("1000:", testing.allocator);
    try testing.expectEqual(@as(uid_t, 1000), spec.user.?);
    try testing.expectEqual(@as(?gid_t, null), spec.group);
}

test "OwnershipSpec.parse empty string" {
    try testing.expectError(Error.InvalidFormat, OwnershipSpec.parse("", testing.allocator));
}

test "getCurrentUserId returns valid UID" {
    const uid = getCurrentUserId();
    try testing.expect(uid >= 0);
}

test "getCurrentGroupId returns valid GID" {
    const gid = getCurrentGroupId();
    try testing.expect(gid >= 0);
}

test "getUserById with current user" {
    const current_uid = getCurrentUserId();
    const user_info = try getUserById(current_uid, testing.allocator);
    defer testing.allocator.free(user_info.name);
    try testing.expectEqual(current_uid, user_info.uid);
    try testing.expect(user_info.name.len > 0);
}

test "getGroupById with current group" {
    const current_gid = getCurrentGroupId();
    const group_info = try getGroupById(current_gid, testing.allocator);
    defer testing.allocator.free(group_info.name);
    try testing.expectEqual(current_gid, group_info.gid);
    try testing.expect(group_info.name.len > 0);
}

test "lookupUserByName with root user" {
    // Root user should exist on all Unix systems
    const uid = lookupUserByName("root", testing.allocator) catch |err| switch (err) {
        Error.UserNotFound => {
            // Skip test on systems without root user (e.g., some containers)
            return;
        },
        else => return err,
    };
    try testing.expectEqual(@as(uid_t, 0), uid);
}

test "lookupGroupByName with root group" {
    // Root group should exist on most Unix systems
    const gid = lookupGroupByName("root", testing.allocator) catch |err| switch (err) {
        Error.GroupNotFound => {
            // Skip test on systems without root group
            return;
        },
        else => return err,
    };
    try testing.expectEqual(@as(gid_t, 0), gid);
}

test "lookupUserByName with nonexistent user" {
    try testing.expectError(Error.UserNotFound, lookupUserByName("nonexistent_user_12345", testing.allocator));
}

test "lookupGroupByName with nonexistent group" {
    try testing.expectError(Error.GroupNotFound, lookupGroupByName("nonexistent_group_12345", testing.allocator));
}

test "octal confusion warning for 700" {
    const spec = try OwnershipSpec.parse("700", testing.allocator);
    try testing.expect(spec.warn_octal_confusion);
}

test "octal confusion warning for 755" {
    const spec = try OwnershipSpec.parse("755", testing.allocator);
    try testing.expect(spec.warn_octal_confusion);
}

test "octal confusion warning for 644" {
    const spec = try OwnershipSpec.parse("644", testing.allocator);
    try testing.expect(spec.warn_octal_confusion);
}

test "no octal confusion for 1000 (valid UID, 4 digits with non-octal range)" {
    const spec = try OwnershipSpec.parse("1000", testing.allocator);
    try testing.expect(!spec.warn_octal_confusion);
}

test "no octal confusion for username" {
    // Non-numeric strings won't trigger the warning (they fail user lookup instead)
    // We test with a numeric UID that doesn't look octal
    const spec = try OwnershipSpec.parse("65534", testing.allocator);
    try testing.expect(!spec.warn_octal_confusion);
}

test "no octal confusion for 900 (contains 9, not valid octal)" {
    const spec = try OwnershipSpec.parse("900", testing.allocator);
    try testing.expect(!spec.warn_octal_confusion);
}

test "octal confusion for 4-digit octal 0755" {
    const spec = try OwnershipSpec.parse("0755", testing.allocator);
    try testing.expect(spec.warn_octal_confusion);
}

test "octal confusion for 000" {
    const spec = try OwnershipSpec.parse("000", testing.allocator);
    try testing.expect(spec.warn_octal_confusion);
}

test "no octal confusion for 99 (too short)" {
    const spec = try OwnershipSpec.parse("99", testing.allocator);
    try testing.expect(!spec.warn_octal_confusion);
}

test "no octal confusion for user:group format" {
    const spec = try OwnershipSpec.parse("755:100", testing.allocator);
    // When colon is present, it's clearly a user:group spec, no warning
    try testing.expect(!spec.warn_octal_confusion);
}
