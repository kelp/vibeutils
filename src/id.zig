//! id - print real and effective user and group IDs
//!
//! The id utility prints user and group information for the specified user,
//! or for the current user if no user is specified.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// C library bindings for effective/real IDs and supplementary groups
extern "c" fn geteuid() std.c.uid_t;
extern "c" fn getegid() std.c.gid_t;
extern "c" fn getgroups(size: c_int, list: [*]std.c.gid_t) c_int;
extern "c" fn getgrouplist(user: [*:0]const u8, group: std.c.gid_t, groups: [*]std.c.gid_t, ngroups: *c_int) c_int;

// C library bindings for passwd entry access (used by -F and -P flags)
// macOS passwd struct includes pw_change, pw_class, pw_expire fields
// that are absent on Linux. Must match the platform's struct layout.
const c_passwd = if (@import("builtin").os.tag == .macos) extern struct {
    pw_name: [*:0]u8,
    pw_passwd: [*:0]u8,
    pw_uid: std.c.uid_t,
    pw_gid: std.c.gid_t,
    pw_change: c_long, // __darwin_time_t
    pw_class: [*:0]u8,
    pw_gecos: [*:0]u8,
    pw_dir: [*:0]u8,
    pw_shell: [*:0]u8,
    pw_expire: c_long, // __darwin_time_t
} else extern struct {
    pw_name: [*:0]u8,
    pw_passwd: [*:0]u8,
    pw_uid: std.c.uid_t,
    pw_gid: std.c.gid_t,
    pw_gecos: [*:0]u8,
    pw_dir: [*:0]u8,
    pw_shell: [*:0]u8,
};

extern "c" fn getpwuid(uid: std.c.uid_t) ?*c_passwd;

/// Command-line arguments for the id utility
const IdArgs = struct {
    /// Print only the effective user ID
    user: bool = false,
    /// Print only the effective group ID
    group: bool = false,
    /// Print all group IDs
    groups: bool = false,
    /// Print name instead of number (with -u, -g, -G)
    name: bool = false,
    /// Print human-readable output
    pretty: bool = false,
    /// Print real ID instead of effective
    real: bool = false,
    /// Use NUL delimiter instead of newline
    zero: bool = false,
    /// Display all group memberships (compatibility alias for -G)
    all: bool = false,
    /// Display process audit properties (stub)
    audit: bool = false,
    /// Display user's full name (GECOS field)
    full_name: bool = false,
    /// Display passwd file entry
    passwd_entry: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments (optional USERNAME)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .user = .{ .short = 'u', .desc = "Print only the effective user ID" },
        .group = .{ .short = 'g', .desc = "Print only the effective group ID" },
        .groups = .{ .short = 'G', .desc = "Print all group IDs" },
        .name = .{ .short = 'n', .desc = "Print name instead of number (with -u, -g, -G)" },
        .pretty = .{ .short = 'p', .desc = "Print human-readable output" },
        .real = .{ .short = 'r', .desc = "Print real ID instead of effective" },
        .zero = .{ .short = 'z', .desc = "Delimit entries with NUL characters, not whitespace" },
        .all = .{ .short = 'a', .desc = "Display all group memberships (same as -G)" },
        .audit = .{ .short = 'A', .desc = "Display process audit properties (stub)" },
        .full_name = .{ .short = 'F', .desc = "Display user's full name (GECOS field)" },
        .passwd_entry = .{ .short = 'P', .desc = "Display passwd file entry" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Main entry point for the id utility
pub fn runId(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    _ = io;
    // Parse command-line arguments
    const parsed = common.argparse.ArgParser.parseOrExit(IdArgs, allocator, args, "id", stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed.positionals);

    // Handle help
    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle -A (audit) stub: print diagnostic and exit 1
    if (parsed.audit) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "-A (audit) not supported on this platform", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Reject extra positional arguments (at most one USERNAME)
    if (parsed.positionals.len > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "extra operand '{s}'", .{parsed.positionals[1]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // GNU id: -a is a no-op (ignored), not an alias for -G
    const show_groups = parsed.groups;

    // -n and -r only make sense with -u, -g, or -G
    if (parsed.name and !parsed.user and !parsed.group and !show_groups) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot print only names in default format", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
    if (parsed.real and !parsed.user and !parsed.group and !show_groups) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot print only real IDs in default format", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // GNU id: -z requires a format flag (-u, -g, or -G)
    if (parsed.zero and !parsed.user and !parsed.group and !show_groups) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "option --zero not permitted in default format", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Mutually exclusive: -u, -g, -G
    const mode_count: u8 = @as(u8, @intFromBool(parsed.user)) +
        @as(u8, @intFromBool(parsed.group)) +
        @as(u8, @intFromBool(show_groups));
    if (mode_count > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot print 'only' of more than one choice", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -p is mutually exclusive with -u, -g, -G
    if (parsed.pretty and mode_count > 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot print 'only' of more than one choice", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const delimiter: u8 = if (parsed.zero) 0 else '\n';

    // Resolve target user
    var uid: common.user_group.uid_t = undefined;
    var gid: common.user_group.gid_t = undefined;
    var is_specified_user = false;

    if (parsed.positionals.len == 1) {
        // Look up specified user
        is_specified_user = true;
        const username = parsed.positionals[0];
        const user_info = common.user_group.getUserById(
            common.user_group.parseUser(username, allocator) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "id", "'{s}': no such user", .{username});
                return @intFromEnum(common.ExitCode.general_error);
            },
            allocator,
        ) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", "'{s}': no such user", .{username});
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer allocator.free(user_info.name);
        uid = user_info.uid;
        gid = user_info.gid;
    } else {
        // Current user
        if (parsed.real) {
            uid = common.user_group.getCurrentUserId();
            gid = common.user_group.getCurrentGroupId();
        } else {
            uid = @intCast(geteuid());
            gid = @intCast(getegid());
        }
    }

    // Handle -F (full name from GECOS field)
    if (parsed.full_name) {
        const pw = getpwuid(@intCast(uid));
        if (pw) |passwd| {
            const gecos = std.mem.span(passwd.pw_gecos);
            try stdout_writer.print("{s}", .{gecos});
            try stdout_writer.writeByte(delimiter);
            return @intFromEnum(common.ExitCode.success);
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot find full name for user ID {d}", .{uid});
            return @intFromEnum(common.ExitCode.general_error);
        }
    }

    // Handle -P (passwd file entry)
    // Format: name:passwd:uid:gid:class:change:expire:gecos:home:shell
    if (parsed.passwd_entry) {
        const pw = getpwuid(@intCast(uid));
        if (pw) |passwd| {
            const pw_name = std.mem.span(passwd.pw_name);
            const pw_passwd = std.mem.span(passwd.pw_passwd);
            const pw_gecos = std.mem.span(passwd.pw_gecos);
            const pw_dir = std.mem.span(passwd.pw_dir);
            const pw_shell = std.mem.span(passwd.pw_shell);
            if (@import("builtin").os.tag == .macos) {
                const pw_class = std.mem.span(passwd.pw_class);
                try stdout_writer.print("{s}:{s}:{d}:{d}:{s}:{d}:{d}:{s}:{s}:{s}", .{
                    pw_name,
                    pw_passwd,
                    passwd.pw_uid,
                    passwd.pw_gid,
                    pw_class,
                    passwd.pw_change,
                    passwd.pw_expire,
                    pw_gecos,
                    pw_dir,
                    pw_shell,
                });
            } else {
                try stdout_writer.print("{s}:{s}:{d}:{d}::0:0:{s}:{s}:{s}", .{
                    pw_name,
                    pw_passwd,
                    passwd.pw_uid,
                    passwd.pw_gid,
                    pw_gecos,
                    pw_dir,
                    pw_shell,
                });
            }
            try stdout_writer.writeByte(delimiter);
            return @intFromEnum(common.ExitCode.success);
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot find passwd entry for user ID {d}", .{uid});
            return @intFromEnum(common.ExitCode.general_error);
        }
    }

    // Handle -p (human-readable output)
    if (parsed.pretty) {
        return printPrettyFormat(allocator, uid, gid, is_specified_user, stdout_writer, stderr_writer);
    }

    // Handle -u (user only)
    if (parsed.user) {
        const target_uid = blk: {
            if (is_specified_user) break :blk uid;
            if (parsed.real) break :blk common.user_group.getCurrentUserId();
            break :blk @as(common.user_group.uid_t, @intCast(geteuid()));
        };

        if (parsed.name) {
            const info = common.user_group.getUserById(target_uid, allocator) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot find name for user ID {d}", .{target_uid});
                return @intFromEnum(common.ExitCode.general_error);
            };
            defer allocator.free(info.name);
            try stdout_writer.print("{s}", .{info.name});
        } else {
            try stdout_writer.print("{d}", .{target_uid});
        }
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle -g (group only)
    if (parsed.group) {
        const target_gid = blk: {
            if (is_specified_user) break :blk gid;
            if (parsed.real) break :blk common.user_group.getCurrentGroupId();
            break :blk @as(common.user_group.gid_t, @intCast(getegid()));
        };

        if (parsed.name) {
            const info = common.user_group.getGroupById(target_gid, allocator) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot find name for group ID {d}", .{target_gid});
                return @intFromEnum(common.ExitCode.general_error);
            };
            defer allocator.free(info.name);
            try stdout_writer.print("{s}", .{info.name});
        } else {
            try stdout_writer.print("{d}", .{target_gid});
        }
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle -G (all groups)
    if (show_groups) {
        const group_separator: u8 = if (parsed.zero) 0 else ' ';

        // Get group list: getgrouplist(3) for a named user,
        // getgroups(2) for the current process.
        const group_list: []std.c.gid_t = if (is_specified_user)
            getGroupsForUser(uid, @intCast(gid), allocator) orelse {
                return printSingleGroup(allocator, gid, parsed.name, delimiter, stdout_writer, stderr_writer);
            }
        else blk: {
            const ngroups = getgroups(0, undefined);
            if (ngroups <= 0) {
                return printSingleGroup(allocator, gid, parsed.name, delimiter, stdout_writer, stderr_writer);
            }
            const buf = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "id", "memory allocation failed", .{});
                return @intFromEnum(common.ExitCode.general_error);
            };
            const actual = getgroups(@intCast(ngroups), buf.ptr);
            if (actual <= 0) {
                allocator.free(buf);
                return printSingleGroup(allocator, gid, parsed.name, delimiter, stdout_writer, stderr_writer);
            }
            const count: usize = @intCast(actual);
            if (count == buf.len) break :blk buf;
            // Shrink to exact count so free() sees the right length.
            const exact = allocator.alloc(std.c.gid_t, count) catch {
                allocator.free(buf);
                common.printErrorWithProgram(allocator, stderr_writer, "id", "memory allocation failed", .{});
                return @intFromEnum(common.ExitCode.general_error);
            };
            @memcpy(exact, buf[0..count]);
            allocator.free(buf);
            break :blk exact;
        };
        defer allocator.free(group_list);

        for (group_list, 0..) |g, i| {
            const group_gid: common.user_group.gid_t = @intCast(g);
            if (i > 0) try stdout_writer.writeByte(group_separator);

            if (parsed.name) {
                const info = common.user_group.getGroupById(group_gid, allocator) catch {
                    // Fall back to numeric if name lookup fails
                    try stdout_writer.print("{d}", .{group_gid});
                    continue;
                };
                defer allocator.free(info.name);
                try stdout_writer.print("{s}", .{info.name});
            } else {
                try stdout_writer.print("{d}", .{group_gid});
            }
        }
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Default format: uid=N(name) gid=N(name) groups=N(name),N(name),...
    return printDefaultFormat(allocator, uid, gid, is_specified_user, delimiter, stdout_writer, stderr_writer);
}

/// Print a single group in -G mode
fn printSingleGroup(
    allocator: Allocator,
    target_gid: common.user_group.gid_t,
    print_name: bool,
    delimiter: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    if (print_name) {
        const info = common.user_group.getGroupById(target_gid, allocator) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", "cannot find name for group ID {d}", .{target_gid});
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer allocator.free(info.name);
        try stdout_writer.print("{s}", .{info.name});
    } else {
        try stdout_writer.print("{d}", .{target_gid});
    }
    try stdout_writer.writeByte(delimiter);
    return @intFromEnum(common.ExitCode.success);
}

/// Get the full group list for a named user via getgrouplist(3).
/// Returns the allocated group slice, or null if the lookup fails.
/// Caller must free the returned slice with allocator.free().
///
/// Safety details:
/// - `getpwuid(3)` returns a pointer to a static buffer. We copy `pw_name`
///   into an owned buffer so subsequent libc calls inside `getgrouplist`
///   (which may invoke getpw* internally on macOS) cannot invalidate it.
/// - The retry loop is bounded: on macOS `getgrouplist` may return -1
///   without growing `ngroups` under certain OpenDirectory conditions,
///   which would hang an unbounded loop. We cap at 8 iterations and
///   force `ngroups` to at least double on each retry.
fn getGroupsForUser(uid: common.user_group.uid_t, gid: std.c.gid_t, allocator: Allocator) ?[]std.c.gid_t {
    const pw = getpwuid(@intCast(uid)) orelse return null;

    // Copy the username out of the libc static buffer.
    const name_slice = std.mem.sliceTo(pw.pw_name, 0);
    const owned_name = allocator.dupeZ(u8, name_slice) catch return null;
    defer allocator.free(owned_name);

    var ngroups: c_int = 16;
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const buf = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch return null;
        var call_ngroups = ngroups;
        const rc = getgrouplist(owned_name.ptr, gid, buf.ptr, &call_ngroups);
        if (rc >= 0) {
            const count: usize = @intCast(call_ngroups);
            // Shrink to exact size so callers can free the returned slice.
            if (allocator.resize(buf, count)) {
                return buf[0..count];
            }
            // resize failed; copy into a new allocation of exact size.
            const result = allocator.alloc(std.c.gid_t, count) catch {
                allocator.free(buf);
                return null;
            };
            @memcpy(result, buf[0..count]);
            allocator.free(buf);
            return result;
        }
        allocator.free(buf);
        // On failure, libc should have updated `call_ngroups` to the required
        // size. Guard against implementations that leave it unchanged by
        // forcing strict growth.
        if (call_ngroups > ngroups) {
            ngroups = call_ngroups;
        } else {
            ngroups *= 2;
        }
    }
    return null;
}

/// Print the default format: uid=N(name) gid=N(name) groups=N(name),...
fn printDefaultFormat(
    allocator: Allocator,
    uid: common.user_group.uid_t,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    delimiter: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Print uid=N(name)
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        // Print without name if lookup fails
        try stdout_writer.print("uid={d}", .{uid});
        return printDefaultGidAndGroups(allocator, uid, gid, is_specified_user, delimiter, stdout_writer, stderr_writer);
    };
    defer allocator.free(user_info.name);
    try stdout_writer.print("uid={d}({s})", .{ uid, user_info.name });

    return printDefaultGidAndGroups(allocator, uid, gid, is_specified_user, delimiter, stdout_writer, stderr_writer);
}

/// Print the gid and groups portions of default format
fn printDefaultGidAndGroups(
    allocator: Allocator,
    uid: common.user_group.uid_t,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    delimiter: u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Print gid=N(name)
    const group_info = common.user_group.getGroupById(gid, allocator) catch {
        try stdout_writer.print(" gid={d}", .{gid});
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    };
    defer allocator.free(group_info.name);
    try stdout_writer.print(" gid={d}({s})", .{ gid, group_info.name });

    // Print groups=...
    // Get group list: getgrouplist(3) for a named user,
    // getgroups(2) for the current process.
    const group_list: []std.c.gid_t = if (is_specified_user)
        getGroupsForUser(uid, @intCast(gid), allocator) orelse {
            try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
            try stdout_writer.writeByte(delimiter);
            return @intFromEnum(common.ExitCode.success);
        }
    else blk: {
        const ngroups = getgroups(0, undefined);
        if (ngroups <= 0) {
            try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
            try stdout_writer.writeByte(delimiter);
            return @intFromEnum(common.ExitCode.success);
        }
        const buf = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", "memory allocation failed", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        const actual = getgroups(@intCast(ngroups), buf.ptr);
        if (actual <= 0) {
            allocator.free(buf);
            try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
            try stdout_writer.writeByte(delimiter);
            return @intFromEnum(common.ExitCode.success);
        }
        const count: usize = @intCast(actual);
        if (count == buf.len) break :blk buf;
        const exact = allocator.alloc(std.c.gid_t, count) catch {
            allocator.free(buf);
            common.printErrorWithProgram(allocator, stderr_writer, "id", "memory allocation failed", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        @memcpy(exact, buf[0..count]);
        allocator.free(buf);
        break :blk exact;
    };
    defer allocator.free(group_list);

    try stdout_writer.writeAll(" groups=");
    for (group_list, 0..) |g, i| {
        const group_gid: common.user_group.gid_t = @intCast(g);
        if (i > 0) try stdout_writer.writeByte(',');

        const gi = common.user_group.getGroupById(group_gid, allocator) catch {
            try stdout_writer.print("{d}", .{group_gid});
            continue;
        };
        defer allocator.free(gi.name);
        try stdout_writer.print("{d}({s})", .{ group_gid, gi.name });
    }

    try stdout_writer.writeByte(delimiter);
    return @intFromEnum(common.ExitCode.success);
}

/// Print human-readable format: uid\tusername\ngroups\tgroup1 group2 ...
fn printPrettyFormat(
    allocator: Allocator,
    uid: common.user_group.uid_t,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Print uid line
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        try stdout_writer.print("uid\t{d}\n", .{uid});
        return printPrettyGroups(allocator, gid, is_specified_user, stdout_writer, stderr_writer);
    };
    defer allocator.free(user_info.name);
    try stdout_writer.print("uid\t{s}\n", .{user_info.name});

    return printPrettyGroups(allocator, gid, is_specified_user, stdout_writer, stderr_writer);
}

/// Print the groups portion of pretty format
fn printPrettyGroups(
    allocator: Allocator,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = stderr_writer;

    try stdout_writer.writeAll("groups\t");

    if (is_specified_user) {
        // For specified user, show primary group name
        const gi = common.user_group.getGroupById(gid, allocator) catch {
            try stdout_writer.print("{d}\n", .{gid});
            return @intFromEnum(common.ExitCode.success);
        };
        defer allocator.free(gi.name);
        try stdout_writer.print("{s}\n", .{gi.name});
        return @intFromEnum(common.ExitCode.success);
    }

    // Get supplementary groups for current user
    const ngroups = getgroups(0, undefined);
    if (ngroups <= 0) {
        // No supplementary groups, show primary
        const gi = common.user_group.getGroupById(gid, allocator) catch {
            try stdout_writer.print("{d}\n", .{gid});
            return @intFromEnum(common.ExitCode.success);
        };
        defer allocator.free(gi.name);
        try stdout_writer.print("{s}\n", .{gi.name});
        return @intFromEnum(common.ExitCode.success);
    }

    const group_list = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch {
        try stdout_writer.writeByte('\n');
        return @intFromEnum(common.ExitCode.success);
    };
    defer allocator.free(group_list);

    const actual = getgroups(@intCast(ngroups), group_list.ptr);
    if (actual <= 0) {
        try stdout_writer.writeByte('\n');
        return @intFromEnum(common.ExitCode.success);
    }

    const count: usize = @intCast(actual);
    for (group_list[0..count], 0..) |g, i| {
        const group_gid: common.user_group.gid_t = @intCast(g);
        if (i > 0) try stdout_writer.writeByte(' ');

        const gi = common.user_group.getGroupById(group_gid, allocator) catch {
            try stdout_writer.print("{d}", .{group_gid});
            continue;
        };
        defer allocator.free(gi.name);
        try stdout_writer.print("{s}", .{gi.name});
    }
    try stdout_writer.writeByte('\n');
    return @intFromEnum(common.ExitCode.success);
}

pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runId);
}

/// Print help message to the specified writer
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: id [OPTION]... [USER]
        \\Print user and group information for the specified USER,
        \\or (when USER omitted) for the current user.
        \\
        \\  -u, --user      print only the effective user ID
        \\  -g, --group     print only the effective group ID
        \\  -G, --groups    print all group IDs
        \\  -a              display all group memberships (same as -G)
        \\  -A              display process audit properties (stub)
        \\  -F              display the user's full name (GECOS field)
        \\  -P              display the passwd file entry
        \\  -n, --name      print a name instead of a number, for -ugG
        \\  -p, --pretty    print human-readable output
        \\  -r, --real      print the real ID instead of the effective ID, for -ugG
        \\  -z, --zero      delimit entries with NUL characters, not whitespace
        \\  -h, --help      display this help and exit
        \\  -V, --version   output version information and exit
        \\
        \\Without any OPTION, print the full identity information.
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("id ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "id default output contains uid and gid" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "uid=") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "gid=") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id -u prints effective user ID" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-u"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Output should be a number followed by newline
    try testing.expect(stdout_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
    // Should be a valid number
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    _ = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id -g prints effective group ID" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-g"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    _ = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id -G prints all group IDs" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-G"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should have at least one group ID
    try testing.expect(stdout_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id -G <username> uses getgrouplist to include supplementary groups" {
    // I5: When a named user is passed, id -G must call getgrouplist(3) to
    // enumerate all supplementary groups, not just the primary group.
    const io = testing.io;
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    var stdout_named_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_named_aw.deinit();
    var stdout_current_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_current_aw.deinit();

    // id -G <username>  (named user path → getgrouplist)
    const args_named = [_][]const u8{ "-G", user_info.name };
    const result_named = try runId(
        testing.allocator,
        io,
        &args_named,
        &stdout_named_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result_named);

    // id -G  (current-process path → getgroups)
    const args_current = [_][]const u8{"-G"};
    const result_current = try runId(
        testing.allocator,
        io,
        &args_current,
        &stdout_current_aw.writer,
        common.null_writer,
    );
    try testing.expectEqual(@as(u8, 0), result_current);

    // Both code paths must produce non-empty output ending with newline.
    try testing.expect(stdout_named_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_named_aw.writer.buffered()[stdout_named_aw.writer.buffered().len - 1]);

    // The named-user output should contain the primary GID at minimum.
    const gid_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{user_info.gid});
    defer testing.allocator.free(gid_str);
    try testing.expect(std.mem.find(u8, stdout_named_aw.writer.buffered(), gid_str) != null);

    // When the named user is the current process user, both outputs must
    // contain identical group sets (modulo ordering: both are space-separated
    // numeric GIDs; a simple string comparison works when both call the same
    // underlying getgrouplist path, but the named path may differ in order
    // from getgroups(2) — we only assert membership, not ordering).
    // Verify the primary GID appears in the named output.
    try testing.expect(std.mem.find(u8, stdout_named_aw.writer.buffered(), gid_str) != null);
}

test "id -un prints effective user name" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-n" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should match whoami output
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{user_info.name});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

test "id -gn prints effective group name" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-g", "-n" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should be a non-empty name
    try testing.expect(stdout_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id -ru prints real user ID" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-u" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    const real_uid = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqual(common.user_group.getCurrentUserId(), @as(common.user_group.uid_t, real_uid));
}

test "id -rg prints real group ID" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-g" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimEnd(u8, stdout_aw.writer.buffered(), "\n");
    const real_gid = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqual(common.user_group.getCurrentGroupId(), @as(common.user_group.gid_t, real_gid));
}

test "id -z uses NUL delimiter" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-u", "-z" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should end with NUL instead of newline
    try testing.expect(stdout_aw.writer.buffered().len > 0);
    try testing.expectEqual(@as(u8, 0), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
}

test "id help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: id") != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id short help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-h"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage: id") != null);
}

test "id version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--version"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "id") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), common.name) != null);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());
}

test "id short version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-V"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "id") != null);
}

test "id unknown flag returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--invalid"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_aw.writer.buffered());
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "id:") != null);
}

test "id -n without -u/-g/-G returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-n"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "cannot print only names") != null);
}

test "id -r without -u/-g/-G returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-r"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "cannot print only real IDs") != null);
}

test "id mutually exclusive -u and -g" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-u", "-g" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "cannot print") != null);
}

test "id extra operand returns misuse" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "user1", "user2" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "extra operand") != null);
}

test "id nonexistent user returns error" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"nonexistent_user_12345"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "no such user") != null);
}

test "id default output has groups field" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "groups=") != null);
}

test "id -Gn prints group names" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-G", "-n" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Output should have at least one group name (non-numeric)
    try testing.expect(stdout_aw.writer.buffered().len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
}

test "id with numeric user ID" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Look up current user's UID and pass it as string
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const uid_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{uid});
    defer testing.allocator.free(uid_str);

    const args = [_][]const u8{uid_str};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "uid=") != null);
}

test "id -p outputs human-readable format with uid line" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-p"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain "uid" label at start of a line
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "uid\t") != null);
}

test "id -p outputs groups line" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-p"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should contain "groups" label
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "groups\t") != null);
}

test "id -p is mutually exclusive with -u -g -G" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-p", "-u" };
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 2), result);
}

test "id -p does not contain uid= format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-p"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should NOT contain the default format "uid=..."
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "uid=") == null);
}

test "id -a is a no-op (GNU behavior), produces default format" {
    const io = testing.io;
    var stdout_a_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_a_aw.deinit();
    var stdout_default_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_default_aw.deinit();

    const args_a = [_][]const u8{"-a"};
    const result_a = try runId(testing.allocator, io, &args_a, &stdout_a_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_a);

    const args_default = [_][]const u8{};
    const result_default = try runId(testing.allocator, io, &args_default, &stdout_default_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_default);

    // GNU: -a is a no-op, so output should match plain id
    try testing.expectEqualStrings(stdout_default_aw.writer.buffered(), stdout_a_aw.writer.buffered());
}

test "id -a with -n is rejected (GNU: -a is no-op, -n alone is invalid)" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-a", "-n" };
    const result = try runId(testing.allocator, io, &args, common.null_writer, &stderr_aw.writer);
    // -a is no-op, -n without -u/-g/-G is an error
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "id -A prints audit stub and exits 1" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-A"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "-A (audit) not supported") != null);
}

test "id -F displays full name" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-F"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Output should end with a newline
    try testing.expect(stdout_aw.writer.buffered().len >= 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
}

test "id -P displays passwd entry format" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-P"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Passwd entry format should contain colons separating fields
    const colon_count = blk: {
        var count: usize = 0;
        for (stdout_aw.writer.buffered()) |ch| {
            if (ch == ':') count += 1;
        }
        break :blk count;
    };
    // passwd entry has at least 6 colons (name:passwd:uid:gid::change:expire:gecos:home:shell)
    try testing.expect(colon_count >= 6);
    // Should end with newline
    try testing.expectEqual(@as(u8, '\n'), stdout_aw.writer.buffered()[stdout_aw.writer.buffered().len - 1]);
}

test "id -P output contains current username" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{"-P"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);

    // Should start with the current username
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    try testing.expect(std.mem.startsWith(u8, stdout_aw.writer.buffered(), user_info.name));
}

test "printSingleGroup outputs numeric GID with delimiter" {
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const gid = @as(common.user_group.gid_t, @intCast(getegid()));
    const result = try printSingleGroup(
        testing.allocator,
        gid,
        false, // print_name = false → numeric output
        '\n', // delimiter
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("", stderr_aw.writer.buffered());

    // Output should be the numeric GID followed by a newline
    const expected = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{gid});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_aw.writer.buffered());
}

/// Return true if every space-separated token in `subset` also appears in
/// `superset`. Used to verify `id -G <user>` returns a superset of `id -G`
/// without requiring strict equality — on macOS, getgroups(2) is capped at
/// NGROUPS_MAX=16 while getgrouplist(3) is uncapped, so counts legitimately
/// diverge for users with >16 supplementary groups.
fn isGroupSuperset(superset: []const u8, subset: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, subset, ' ');
    outer: while (it.next()) |needle| {
        var sup_it = std.mem.tokenizeScalar(u8, superset, ' ');
        while (sup_it.next()) |hay| {
            if (std.mem.eql(u8, needle, hay)) continue :outer;
        }
        return false;
    }
    return true;
}

test "id -G with named user is superset of id -G without username" {
    // On macOS getgroups(2) caps the process credential set at NGROUPS_MAX=16
    // but getgrouplist(3) is uncapped, so the named form can legitimately
    // have more groups than the no-user form. The cross-platform invariant
    // is that every group in `id -G` must appear in `id -G <user>`.
    const io = testing.io;
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    var stdout_no_user_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_no_user_aw.deinit();
    const args_no_user = [_][]const u8{"-G"};
    const result_no_user = try runId(testing.allocator, io, &args_no_user, &stdout_no_user_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_no_user);

    var stdout_named_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_named_aw.deinit();
    const args_named = [_][]const u8{ "-G", user_info.name };
    const result_named = try runId(testing.allocator, io, &args_named, &stdout_named_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_named);

    const no_user_trimmed = std.mem.trimEnd(u8, stdout_no_user_aw.writer.buffered(), "\n");
    const named_trimmed = std.mem.trimEnd(u8, stdout_named_aw.writer.buffered(), "\n");

    try testing.expect(no_user_trimmed.len > 0);
    try testing.expect(named_trimmed.len > 0);
    try testing.expect(isGroupSuperset(named_trimmed, no_user_trimmed));
}

test "id -Gn with named user is superset of id -Gn without username" {
    const io = testing.io;
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    var stdout_no_user_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_no_user_aw.deinit();
    const args_no_user = [_][]const u8{ "-G", "-n" };
    const result_no_user = try runId(testing.allocator, io, &args_no_user, &stdout_no_user_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_no_user);

    var stdout_named_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_named_aw.deinit();
    const args_named = [_][]const u8{ "-G", "-n", user_info.name };
    const result_named = try runId(testing.allocator, io, &args_named, &stdout_named_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_named);

    const no_user_trimmed = std.mem.trimEnd(u8, stdout_no_user_aw.writer.buffered(), "\n");
    const named_trimmed = std.mem.trimEnd(u8, stdout_named_aw.writer.buffered(), "\n");

    try testing.expect(no_user_trimmed.len > 0);
    try testing.expect(named_trimmed.len > 0);
    try testing.expect(isGroupSuperset(named_trimmed, no_user_trimmed));
}

test "id default format with named user includes all groups (superset)" {
    // Same cross-platform invariant as the -G test: the named-user form
    // must return every group that the no-user form returns, but may
    // have more on macOS due to NGROUPS_MAX capping getgroups(2).
    const io = testing.io;
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    var stdout_no_user_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_no_user_aw.deinit();
    const args_no_user = [_][]const u8{};
    const result_no_user = try runId(testing.allocator, io, &args_no_user, &stdout_no_user_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_no_user);

    var stdout_named_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_named_aw.deinit();
    const args_named = [_][]const u8{user_info.name};
    const result_named = try runId(testing.allocator, io, &args_named, &stdout_named_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_named);

    // Extract the groups= portion, strip trailing newline, extract the
    // inner comma-separated list (format is "groups=gid1(name),gid2(name)").
    const no_user_groups_start = std.mem.find(u8, stdout_no_user_aw.writer.buffered(), "groups=") orelse
        return error.TestUnexpectedResult;
    const named_groups_start = std.mem.find(u8, stdout_named_aw.writer.buffered(), "groups=") orelse
        return error.TestUnexpectedResult;

    const no_user_groups = std.mem.trimEnd(u8, stdout_no_user_aw.writer.buffered()[no_user_groups_start + "groups=".len ..], " \n");
    const named_groups = std.mem.trimEnd(u8, stdout_named_aw.writer.buffered()[named_groups_start + "groups=".len ..], " \n");

    // Every comma-separated entry in no_user_groups must appear in named_groups.
    var it = std.mem.tokenizeScalar(u8, no_user_groups, ',');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        if (trimmed.len == 0) continue;
        try testing.expect(std.mem.find(u8, named_groups, trimmed) != null);
    }
}

// ============================================================================
// Audit finding tests (IMPORTANT) — wave 5
// ============================================================================

test "id -z alone without format flag should exit 2 (GNU rejects)" {
    // GNU id: "id: cannot print only names or real IDs in default format"
    // vibeutils currently accepts -z alone and outputs default format with NUL.
    // GNU rejects -z without -u/-g/-G, exiting 2.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"-z"};
    const result = try runId(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // GNU behavior: -z alone is an error (exit 2)
    try testing.expectEqual(@as(u8, 2), result);
    // stderr should contain a diagnostic message
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "id -a is a no-op in GNU, not an alias for -G" {
    // GNU id: -a is ignored (has no effect in default format).
    // vibeutils treats -a as -G, changing the output format.
    // Expected: id -a should produce the SAME output as plain id.
    const io = testing.io;
    var stdout_default_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_default_aw.deinit();
    var stdout_with_a_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_with_a_aw.deinit();

    const args_default = [_][]const u8{};
    const result_default = try runId(testing.allocator, io, &args_default, &stdout_default_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_default);

    const args_a = [_][]const u8{"-a"};
    const result_a = try runId(testing.allocator, io, &args_a, &stdout_with_a_aw.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result_a);

    // GNU: id -a should produce default format (uid=... gid=... groups=...)
    // not just the -G style group list
    try testing.expect(std.mem.find(u8, stdout_with_a_aw.writer.buffered(), "uid=") != null);
}
