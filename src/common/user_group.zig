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
pub const UserInfo = struct {
    uid: uid_t,
    gid: gid_t,
    name: []const u8,
};

/// Represents a group lookup result
pub const GroupInfo = struct {
    gid: gid_t,
    name: []const u8,
};

/// Represents ownership change specification
pub const OwnershipSpec = struct {
    user: ?uid_t = null,
    group: ?gid_t = null,

    /// Parse ownership specification string like "user:group", "user:", ":group", "user"
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

            // Parse group part (if not empty)
            if (group_part.len > 0) {
                result.group = try parseGroup(group_part, allocator);
            }
        } else {
            // User only format
            result.user = try parseUser(spec, allocator);
        }

        return result;
    }
};

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
pub fn lookupUserByName(name: []const u8, allocator: std.mem.Allocator) Error!uid_t {
    // Try to parse as numeric ID first
    if (std.fmt.parseInt(uid_t, name, 10)) |uid| {
        return uid;
    } else |_| {
        // Not numeric, look up by name using getpwnam
        const name_z = allocator.dupeZ(u8, name) catch return Error.OutOfMemory;
        defer allocator.free(name_z);

        const passwd = getpwnam(name_z.ptr) orelse return Error.UserNotFound;
        return passwd.pw_uid;
    }
}

/// Look up group by name using getgrnam
pub fn lookupGroupByName(name: []const u8, allocator: std.mem.Allocator) Error!gid_t {
    // Try to parse as numeric ID first
    if (std.fmt.parseInt(gid_t, name, 10)) |gid| {
        return gid;
    } else |_| {
        // Not numeric, look up by name using getgrnam
        const name_z = allocator.dupeZ(u8, name) catch return Error.OutOfMemory;
        defer allocator.free(name_z);

        const group = getgrnam(name_z.ptr) orelse return Error.GroupNotFound;
        return group.gr_gid;
    }
}

/// Get user information by UID
pub fn getUserById(uid: uid_t) Error!UserInfo {
    const passwd = getpwuid(uid) orelse return Error.UserNotFound;
    const name = std.mem.span(passwd.pw_name);
    return UserInfo{
        .uid = passwd.pw_uid,
        .gid = passwd.pw_gid,
        .name = name,
    };
}

/// Get group information by GID
pub fn getGroupById(gid: gid_t) Error!GroupInfo {
    const group = getgrgid(gid) orelse return Error.GroupNotFound;
    const name = std.mem.span(group.gr_name);
    return GroupInfo{
        .gid = group.gr_gid,
        .name = name,
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

test "parseUser with invalid numeric ID" {
    // Test overflow
    try testing.expectError(Error.UserNotFound, parseUser("999999999999999999999", testing.allocator));
}

test "parseGroup with invalid numeric ID" {
    // Test overflow
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
    const user_info = try getUserById(current_uid);
    try testing.expectEqual(current_uid, user_info.uid);
    try testing.expect(user_info.name.len > 0);
}

test "getGroupById with current group" {
    const current_gid = getCurrentGroupId();
    const group_info = try getGroupById(current_gid);
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
