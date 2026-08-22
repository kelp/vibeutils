const std = @import("std");
const c = std.c;
const testing = std.testing;
const assert = std.debug.assert;

/// No passwd or group field libc can hand back is anywhere near this long, so
/// a span that exceeds it means the entry is corrupt rather than merely long.
const max_c_string_bytes: u32 = 64 * 1024;

/// The platform's `struct passwd`, taken from std rather than hand-rolled:
/// macOS interposes pw_change and pw_class between pw_gid and pw_gecos and
/// appends pw_expire, so a glibc-shaped literal reads gecos at offset 24 where
/// the field actually sits at 40.
pub const c_passwd = c.passwd;

/// The platform's `struct group`. The layout is identical on Linux and macOS;
/// it is exported here so that no caller has to re-declare it.
pub const c_group = c.group;

// C library bindings for user/group lookups.
pub const getpwnam = c.getpwnam;
pub const getpwuid = c.getpwuid;
pub const getgrgid = c.getgrgid;

/// Zig 0.16.0 declares `std.c.getgrnam` as `?*passwd` — an upstream typo, as
/// every other `getgr*` prototype is correct. `group.gid` sits at offset 16
/// and `passwd.gid` at 20, so routing group-by-name lookups through std's
/// declaration would read struct group's tail padding instead of the gid, on
/// Linux as well as macOS. Declare the correct prototype here instead.
pub extern "c" fn getgrnam(name: [*:0]const u8) ?*c_group;

extern "c" fn getuid() c.uid_t;
extern "c" fn getgid() c.gid_t;

/// libc marks every string field of passwd and group optional, and callers
/// only ever print them, so a NULL field reads as empty instead of failing the
/// whole lookup.
pub fn spanOrEmpty(field: ?[*:0]const u8) []const u8 {
    const ptr = field orelse return "";
    const out = std.mem.span(ptr);
    // A field longer than any plausible passwd line means a corrupt entry.
    // This cannot detect a pointer that is not NUL-terminated at all: span
    // scans for the sentinel first, so such a pointer faults inside span
    // before returning here. Only libc fills these in, and libc terminates
    // them, so that case is not reachable.
    assert(out.len <= max_c_string_bytes);
    return out;
}

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
        // The empty-spec guard above returns early, so every path below runs
        // only on a non-empty spec.
        std.debug.assert(spec.len > 0);

        var result = OwnershipSpec{};

        // Check for colon separator
        if (std.mem.indexOf(u8, spec, ":")) |colon_pos| {
            // user:group format
            const user_part = spec[0..colon_pos];
            const group_part = spec[colon_pos + 1 ..];
            // indexOf returns an in-bounds byte index, and the two parts plus
            // the single colon byte must reconstruct the whole spec exactly.
            std.debug.assert(colon_pos < spec.len);
            std.debug.assert(user_part.len + group_part.len + 1 == spec.len);

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
    // The length guard above returned for anything outside [3, 4], so any spec
    // reaching the final check has exactly 3 or 4 bytes.
    std.debug.assert(spec.len >= 3);
    std.debug.assert(spec.len <= 4);
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
    // dupeZ produces a null-terminated copy whose length (excluding the
    // sentinel) equals the source slice length.
    std.debug.assert(name_z.len == name.len);

    const passwd = getpwnam(name_z.ptr) orelse return Error.UserNotFound;
    return passwd.uid;
}

/// Look up group by name using getgrnam
/// This function ONLY performs name lookups - use parseGroup for numeric ID parsing
pub fn lookupGroupByName(name: []const u8, allocator: std.mem.Allocator) Error!gid_t {
    const name_z = allocator.dupeZ(u8, name) catch return Error.OutOfMemory;
    defer allocator.free(name_z);
    // dupeZ produces a null-terminated copy whose length (excluding the
    // sentinel) equals the source slice length.
    std.debug.assert(name_z.len == name.len);

    const group = getgrnam(name_z.ptr) orelse return Error.GroupNotFound;
    return group.gid;
}

/// Get user information by UID
/// Caller owns the returned name slice and must free it with the provided allocator
pub fn getUserById(uid: uid_t, allocator: std.mem.Allocator) Error!UserInfo {
    const passwd = getpwuid(uid) orelse return Error.UserNotFound;
    const name = spanOrEmpty(passwd.name);
    const owned_name = allocator.dupe(u8, name) catch return Error.OutOfMemory;
    // dupe copies the source slice exactly, so the owned copy has the same
    // length as the C-string view of the name field.
    std.debug.assert(owned_name.len == name.len);
    return UserInfo{
        .uid = passwd.uid,
        .gid = passwd.gid,
        .name = owned_name,
    };
}

/// Get group information by GID
/// Caller owns the returned name slice and must free it with the provided allocator
pub fn getGroupById(gid: gid_t, allocator: std.mem.Allocator) Error!GroupInfo {
    const group = getgrgid(gid) orelse return Error.GroupNotFound;
    const name = spanOrEmpty(group.name);
    const owned_name = allocator.dupe(u8, name) catch return Error.OutOfMemory;
    // dupe copies the source slice exactly, so the owned copy has the same
    // length as the C-string view of the name field.
    std.debug.assert(owned_name.len == name.len);
    return GroupInfo{
        .gid = group.gid,
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
    try testing.expectError(
        Error.UserNotFound,
        parseUser("999999999999999999999", testing.allocator),
    );
}

test "parseGroup with numeric overflow falls back to name lookup" {
    // Test numeric overflow - parseGroup falls back to name lookup which fails
    try testing.expectError(
        Error.GroupNotFound,
        parseGroup("999999999999999999999", testing.allocator),
    );
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

test "OwnershipSpec.parse user: sets login group from passwd" {
    // GNU chown: 'user:' (colon, no group) sets the group to the user's primary
    // group from the password database (getpwuid/getpwnam pw_gid field).
    const current_uid = getCurrentUserId();
    const uid_str = try testing.allocator.alloc(u8, 64);
    defer testing.allocator.free(uid_str);
    const uid_colon = try std.fmt.bufPrint(uid_str, "{d}:", .{current_uid});

    // Determine the expected primary group via an independent lookup.
    const user_info = try getUserById(current_uid, testing.allocator);
    defer testing.allocator.free(user_info.name);
    const expected_gid = user_info.gid;

    const spec = try OwnershipSpec.parse(uid_colon, testing.allocator);
    try testing.expectEqual(current_uid, spec.user.?);
    try testing.expectEqual(@as(?gid_t, expected_gid), spec.group);
}

test "OwnershipSpec.parse user: with nonexistent UID returns UserNotFound" {
    // When the specified UID cannot be resolved to a passwd entry the
    // primary group is unknowable, so parse returns UserNotFound -- matching
    // GNU chown's 'invalid user: \'99999:\'' error for unknown numeric UIDs.
    const result = OwnershipSpec.parse("99999:", testing.allocator);
    try testing.expectError(Error.UserNotFound, result);
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
    try testing.expectError(
        Error.UserNotFound,
        lookupUserByName("nonexistent_user_12345", testing.allocator),
    );
}

test "lookupGroupByName with nonexistent group" {
    try testing.expectError(
        Error.GroupNotFound,
        lookupGroupByName("nonexistent_group_12345", testing.allocator),
    );
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

// ============================================================================
// Issue #129: libc passwd/group ABI guards
//
// The same `struct passwd` was hand-rolled in four files. The glibc-shaped
// copies are wrong on macOS, which interposes pw_change and pw_class between
// pw_gid and pw_gecos and appends pw_expire, so every field past pw_gid reads
// the wrong offset there. These guards pin the declarations to std's platform
// structs, which makes a re-hand-rolled copy detectable on Linux even though
// the bytes happen to agree there.
// ============================================================================

test "user_group: c_passwd is std's platform passwd struct" {
    // Type identity, not layout equality: a byte-identical hand-rolled copy is
    // still a distinct type, so this fails on Linux the moment someone
    // re-introduces one -- which is what makes the macOS-only bug catchable
    // without a macOS runner.
    try testing.expect(c_passwd == std.c.passwd);
    // Negative space: passwd and group are different records, and confusing
    // the two is exactly the std.c.getgrnam trap guarded further down.
    try testing.expect(c_passwd != std.c.group);
}

test "user_group: c_group is std's platform group struct" {
    try testing.expect(c_group == std.c.group);
    // Negative space: the group record must not collapse onto the passwd one.
    try testing.expect(c_group != std.c.passwd);
}

test "user_group: the four lookups return pointers to std's platform structs" {
    const pwnam_ret = @typeInfo(@TypeOf(getpwnam)).@"fn".return_type.?;
    const pwuid_ret = @typeInfo(@TypeOf(getpwuid)).@"fn".return_type.?;
    const grnam_ret = @typeInfo(@TypeOf(getgrnam)).@"fn".return_type.?;
    const grgid_ret = @typeInfo(@TypeOf(getgrgid)).@"fn".return_type.?;
    try testing.expect(pwnam_ret == ?*std.c.passwd);
    try testing.expect(pwuid_ret == ?*std.c.passwd);
    try testing.expect(grnam_ret == ?*std.c.group);
    try testing.expect(grgid_ret == ?*std.c.group);
    // Negative space: a group lookup handing back a passwd record is the
    // upstream typo this module has to route around, so pin it shut here too.
    try testing.expect(grnam_ret != ?*std.c.passwd);
    try testing.expect(grgid_ret != ?*std.c.passwd);
}

test "user_group: std.c.getgrnam is mistyped upstream, so a local decl stays" {
    // Zig 0.16.0 declares std.c.getgrnam as `?*passwd` -- an upstream typo;
    // every other getgr* prototype is correct. group.gid sits at offset 16 and
    // passwd.gid at 20, so routing group-by-name lookups through std's
    // declaration would read struct group's tail padding instead of the gid,
    // on Linux as well as macOS. This test is a tripwire, green today and
    // green after the consolidation: when a Zig upgrade fixes the prototype it
    // goes red, and that is the signal to delete the local getgrnam and use
    // std's. build.zig.zon pins 0.16.0, so it cannot flip by accident.
    const std_grnam_ret = @typeInfo(@TypeOf(std.c.getgrnam)).@"fn".return_type.?;
    try testing.expect(std_grnam_ret == ?*std.c.passwd);
    // Negative space: the day this stops being a passwd pointer, delete the
    // local declaration rather than "fixing" this test.
    try testing.expect(std_grnam_ret != ?*std.c.group);
    comptime {
        // The differing gid offsets are what make the typo a live memory bug
        // rather than a cosmetic naming slip.
        std.debug.assert(@offsetOf(std.c.group, "gid") == 16);
        std.debug.assert(@offsetOf(std.c.passwd, "gid") == 20);
    }
}

/// Linux `std.c.passwd` has no `pw_fields`, so a Linux host cannot
/// `@offsetOf` that member. FreeBSD (and DragonFly) append it after expire.
fn passwdHasFieldsMember() bool {
    const has_fields = @hasField(std.c.passwd, "fields");
    const size = @sizeOf(std.c.passwd);
    // Positive: FreeBSD is the 80-byte layout. Negative: everyone else we
    // pin is 72 or 48 and therefore has no trailing fields member.
    if (has_fields) {
        std.debug.assert(size == 80);
    } else {
        std.debug.assert(size == 48 or size == 72);
    }
    return has_fields;
}

test "user_group: platform passwd and group ABI offsets are pinned" {
    // A `comptime` block rather than runtime expectations, because comptime
    // asserts are evaluated by `zig test --test-no-exec -target` even from a
    // Linux-only container. Each OS we ship on is a named prong: a catch-all
    // `else => size == 48` treated FreeBSD as glibc and failed CI.
    comptime {
        std.debug.assert(@offsetOf(std.c.passwd, "name") == 0);
        std.debug.assert(@offsetOf(std.c.passwd, "passwd") == 8);
        std.debug.assert(@offsetOf(std.c.passwd, "uid") == 16);
        std.debug.assert(@offsetOf(std.c.passwd, "gid") == 20);
        switch (@import("builtin").os.tag) {
            .linux => {
                std.debug.assert(@sizeOf(std.c.passwd) == 48);
                std.debug.assert(@offsetOf(std.c.passwd, "gecos") == 24);
                std.debug.assert(@offsetOf(std.c.passwd, "dir") == 32);
                std.debug.assert(@offsetOf(std.c.passwd, "shell") == 40);
                std.debug.assert(!passwdHasFieldsMember());
            },
            .macos, .openbsd, .netbsd => {
                std.debug.assert(@sizeOf(std.c.passwd) == 72);
                std.debug.assert(@offsetOf(std.c.passwd, "change") == 24);
                std.debug.assert(@offsetOf(std.c.passwd, "class") == 32);
                std.debug.assert(@offsetOf(std.c.passwd, "gecos") == 40);
                std.debug.assert(@offsetOf(std.c.passwd, "dir") == 48);
                std.debug.assert(@offsetOf(std.c.passwd, "shell") == 56);
                std.debug.assert(@offsetOf(std.c.passwd, "expire") == 64);
                std.debug.assert(!passwdHasFieldsMember());
            },
            .freebsd => {
                std.debug.assert(@sizeOf(std.c.passwd) == 80);
                std.debug.assert(@offsetOf(std.c.passwd, "change") == 24);
                std.debug.assert(@offsetOf(std.c.passwd, "class") == 32);
                std.debug.assert(@offsetOf(std.c.passwd, "gecos") == 40);
                std.debug.assert(@offsetOf(std.c.passwd, "dir") == 48);
                std.debug.assert(@offsetOf(std.c.passwd, "shell") == 56);
                std.debug.assert(@offsetOf(std.c.passwd, "expire") == 64);
                std.debug.assert(passwdHasFieldsMember());
                std.debug.assert(@offsetOf(std.c.passwd, "fields") == 72);
            },
            else => {
                // Not a glibc-sized fallback. If `.linux` is deleted, this
                // prong is taken on Linux and the assert fires at comptime.
                std.debug.assert(@import("builtin").os.tag != .linux);
            },
        }
        // struct group is identical on Linux, macOS, and the BSDs; pinning
        // it keeps a future "harmless" reshuffle from going unnoticed.
        std.debug.assert(@sizeOf(std.c.group) == 32);
        std.debug.assert(@offsetOf(std.c.group, "gid") == 16);
        std.debug.assert(@offsetOf(std.c.group, "mem") == 24);
    }
    // The block above is the whole test; these two restate its endpoints at
    // runtime so the test body is not assertion-free to a reader.
    try testing.expectEqual(@as(u32, 16), @offsetOf(std.c.passwd, "uid"));
    try testing.expect(@offsetOf(std.c.passwd, "gid") != @offsetOf(std.c.group, "gid"));
}

test "user_group: getUserById mirrors libc's passwd entry for every low uid" {
    // The oracle is libc read through std's struct, so this characterization
    // does not lean on the module's own declaration: if an accessor ever reads
    // the wrong offset the two sources disagree. The scan is bounded because
    // system accounts live in the low uid range on every platform we support.
    const uid_scan_max: u32 = 256;
    var entries_checked: u32 = 0;
    var uid: u32 = 0;
    while (uid < uid_scan_max) : (uid += 1) {
        const entry = std.c.getpwuid(@intCast(uid)) orelse continue;
        const entry_uid: u32 = @intCast(entry.uid);
        const entry_gid: u32 = @intCast(entry.gid);
        // libc hands back a pointer into one static buffer that the next
        // lookup overwrites, so the name has to be copied out first.
        const entry_name = try testing.allocator.dupe(u8, std.mem.span(entry.name.?));
        defer testing.allocator.free(entry_name);

        const info = try getUserById(@intCast(uid), testing.allocator);
        defer testing.allocator.free(info.name);

        try testing.expectEqual(entry_uid, @as(u32, @intCast(info.uid)));
        try testing.expectEqual(entry_gid, @as(u32, @intCast(info.gid)));
        try testing.expectEqualStrings(entry_name, info.name);
        entries_checked += 1;
    }
    // Every Unix has at least a root entry, so an empty scan would mean the
    // assertions above all held vacuously.
    try testing.expect(entries_checked > 0);
    // Negative space: a uid no account owns must not resolve to an entry.
    const absent_uid: u32 = 4_000_000_000;
    if (std.c.getpwuid(@intCast(absent_uid)) == null) {
        try testing.expectError(
            Error.UserNotFound,
            getUserById(absent_uid, testing.allocator),
        );
    }
}

test "user_group: group names round-trip back to their own gid" {
    // Bonus guard for the std.c.getgrnam trap: with group-by-name routed
    // through std's mistyped declaration the gid is read from struct group's
    // tail padding at offset 20 instead of offset 16. Caveat -- that padding
    // is usually garbage but is not guaranteed to differ from the real gid,
    // notably when the gid is 0 in a root container. The deterministic guards
    // are the prototype and offset tests above; this one is not load-bearing.
    const gid_scan_max: u32 = 256;
    var entries_checked: u32 = 0;
    var gid: u32 = 0;
    while (gid < gid_scan_max) : (gid += 1) {
        const entry = std.c.getgrgid(@intCast(gid)) orelse continue;
        // Same static-buffer hazard as the passwd scan above.
        const entry_name = try testing.allocator.dupe(u8, std.mem.span(entry.name.?));
        defer testing.allocator.free(entry_name);

        const info = try getGroupById(@intCast(gid), testing.allocator);
        defer testing.allocator.free(info.name);
        try testing.expectEqualStrings(entry_name, info.name);
        try testing.expectEqual(gid, @as(u32, @intCast(info.gid)));

        const resolved = try lookupGroupByName(entry_name, testing.allocator);
        try testing.expectEqual(gid, @as(u32, @intCast(resolved)));
        entries_checked += 1;
    }
    try testing.expect(entries_checked > 0);
    // Negative space: a name no group owns must not resolve to a gid.
    try testing.expectError(
        Error.GroupNotFound,
        lookupGroupByName("nonexistent_group_129_guard", testing.allocator),
    );
}
