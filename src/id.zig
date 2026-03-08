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
    /// Print real ID instead of effective
    real: bool = false,
    /// Use NUL delimiter instead of newline
    zero: bool = false,
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
        .real = .{ .short = 'r', .desc = "Print real ID instead of effective" },
        .zero = .{ .short = 'z', .desc = "Delimit entries with NUL characters, not whitespace" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Main entry point for the id utility
pub fn runId(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse command-line arguments
    const parsed = common.argparse.ArgParser.parse(IdArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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

    // Reject extra positional arguments (at most one USERNAME)
    if (parsed.positionals.len > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "extra operand '{s}'", .{parsed.positionals[1]});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // -n and -r only make sense with -u, -g, or -G
    if (parsed.name and !parsed.user and !parsed.group and !parsed.groups) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot print only names in default format", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }
    if (parsed.real and !parsed.user and !parsed.group and !parsed.groups) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot print only real IDs in default format", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Mutually exclusive: -u, -g, -G
    const mode_count: u8 = @as(u8, @intFromBool(parsed.user)) +
        @as(u8, @intFromBool(parsed.group)) +
        @as(u8, @intFromBool(parsed.groups));
    if (mode_count > 1) {
        common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot print 'only' of more than one choice", .{});
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
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "'{s}': no such user", .{username});
                return @intFromEnum(common.ExitCode.general_error);
            },
            allocator,
        ) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "'{s}': no such user", .{username});
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

    // Handle -u (user only)
    if (parsed.user) {
        const target_uid = blk: {
            if (is_specified_user) break :blk uid;
            if (parsed.real) break :blk common.user_group.getCurrentUserId();
            break :blk @as(common.user_group.uid_t, @intCast(geteuid()));
        };

        if (parsed.name) {
            const info = common.user_group.getUserById(target_uid, allocator) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot find name for user ID {d}", .{target_uid});
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
                common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot find name for group ID {d}", .{target_gid});
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
    if (parsed.groups) {
        const group_separator: u8 = if (parsed.zero) 0 else ' ';

        if (is_specified_user) {
            // For specified user, we just show the primary group
            // (getgroups only works for current process)
            return printSingleGroup(allocator, gid, parsed.name, group_separator, delimiter, stdout_writer, stderr_writer);
        }

        // Get supplementary groups for current user
        const ngroups = getgroups(0, undefined);
        if (ngroups < 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot get supplementary group list", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }

        if (ngroups == 0) {
            // No supplementary groups, just print primary group
            return printSingleGroup(allocator, gid, parsed.name, group_separator, delimiter, stdout_writer, stderr_writer);
        }

        const group_list = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "memory allocation failed", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
        defer allocator.free(group_list);

        const actual = getgroups(@intCast(ngroups), group_list.ptr);
        if (actual < 0) {
            common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot get supplementary group list", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }

        const count: usize = @intCast(actual);
        for (group_list[0..count], 0..) |g, i| {
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
    group_separator: u8,
    delimiter: u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    _ = group_separator;
    if (print_name) {
        const info = common.user_group.getGroupById(target_gid, allocator) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "cannot find name for group ID {d}", .{target_gid});
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

/// Print the default format: uid=N(name) gid=N(name) groups=N(name),...
fn printDefaultFormat(
    allocator: Allocator,
    uid: common.user_group.uid_t,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    delimiter: u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Print uid=N(name)
    const user_info = common.user_group.getUserById(uid, allocator) catch {
        // Print without name if lookup fails
        try stdout_writer.print("uid={d}", .{uid});
        return printDefaultGidAndGroups(allocator, gid, is_specified_user, delimiter, stdout_writer, stderr_writer);
    };
    defer allocator.free(user_info.name);
    try stdout_writer.print("uid={d}({s})", .{ uid, user_info.name });

    return printDefaultGidAndGroups(allocator, gid, is_specified_user, delimiter, stdout_writer, stderr_writer);
}

/// Print the gid and groups portions of default format
fn printDefaultGidAndGroups(
    allocator: Allocator,
    gid: common.user_group.gid_t,
    is_specified_user: bool,
    delimiter: u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
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
    if (is_specified_user) {
        // For specified user, just show primary group
        try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    // Get supplementary groups for current user
    const ngroups = getgroups(0, undefined);
    if (ngroups <= 0) {
        // No supplementary groups or error, just show primary
        try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    const group_list = allocator.alloc(std.c.gid_t, @intCast(ngroups)) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "id", std.fs.File.stderr().isTty(), "memory allocation failed", .{});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer allocator.free(group_list);

    const actual = getgroups(@intCast(ngroups), group_list.ptr);
    if (actual <= 0) {
        try stdout_writer.print(" groups={d}({s})", .{ gid, group_info.name });
        try stdout_writer.writeByte(delimiter);
        return @intFromEnum(common.ExitCode.success);
    }

    try stdout_writer.writeAll(" groups=");
    const count: usize = @intCast(actual);
    for (group_list[0..count], 0..) |g, i| {
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runId(allocator, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: id [OPTION]... [USER]
        \\Print user and group information for the specified USER,
        \\or (when USER omitted) for the current user.
        \\
        \\  -u, --user      print only the effective user ID
        \\  -g, --group     print only the effective group ID
        \\  -G, --groups    print all group IDs
        \\  -n, --name      print a name instead of a number, for -ugG
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
fn printVersion(writer: anytype) !void {
    try writer.print("id ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
// TESTS
// ============================================================================

test "id default output contains uid and gid" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "uid=") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "gid=") != null);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id -u prints effective user ID" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-u"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Output should be a number followed by newline
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
    // Should be a valid number
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    _ = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id -g prints effective group ID" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-g"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    _ = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id -G prints all group IDs" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-G"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Should have at least one group ID
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id -un prints effective user name" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-n" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Should match whoami output
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const user_info = try common.user_group.getUserById(uid, testing.allocator);
    defer testing.allocator.free(user_info.name);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{user_info.name});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, stdout_buffer.items);
}

test "id -gn prints effective group name" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-g", "-n" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Should be a non-empty name
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id -ru prints real user ID" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-r", "-u" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    const real_uid = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqual(common.user_group.getCurrentUserId(), @as(common.user_group.uid_t, real_uid));
}

test "id -rg prints real group ID" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-r", "-g" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    const trimmed = std.mem.trimRight(u8, stdout_buffer.items, "\n");
    const real_gid = try std.fmt.parseInt(u32, trimmed, 10);
    try testing.expectEqual(common.user_group.getCurrentGroupId(), @as(common.user_group.gid_t, real_gid));
}

test "id -z uses NUL delimiter" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-z" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    // Should end with NUL instead of newline
    try testing.expect(stdout_buffer.items.len > 0);
    try testing.expectEqual(@as(u8, 0), stdout_buffer.items[stdout_buffer.items.len - 1]);
}

test "id help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: id") != null);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id short help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: id") != null);
}

test "id version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "id") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.name) != null);
    try testing.expectEqualStrings("", stderr_buffer.items);
}

test "id short version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "id") != null);
}

test "id unknown flag returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--invalid"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expectEqualStrings("", stdout_buffer.items);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "id:") != null);
}

test "id -n without -u/-g/-G returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-n"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot print only names") != null);
}

test "id -r without -u/-g/-G returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-r"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot print only real IDs") != null);
}

test "id mutually exclusive -u and -g" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-u", "-g" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot print") != null);
}

test "id extra operand returns misuse" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "user1", "user2" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "extra operand") != null);
}

test "id nonexistent user returns error" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"nonexistent_user_12345"};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "no such user") != null);
}

test "id default output has groups field" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "groups=") != null);
}

test "id -Gn prints group names" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-G", "-n" };
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    // Output should have at least one group name (non-numeric)
    try testing.expect(stdout_buffer.items.len > 1);
    try testing.expectEqual(@as(u8, '\n'), stdout_buffer.items[stdout_buffer.items.len - 1]);
}

test "id with numeric user ID" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Look up current user's UID and pass it as string
    const uid = @as(common.user_group.uid_t, @intCast(geteuid()));
    const uid_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{uid});
    defer testing.allocator.free(uid_str);

    const args = [_][]const u8{uid_str};
    const result = try runId(testing.allocator, &args, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "uid=") != null);
}
