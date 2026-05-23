const std = @import("std");
const harness = @import("harness.zig");
const testing = std.testing;

// Per-utility harness config. Utilities not listed default to stdin mode.
// Templates must contain exactly one "{INPUT}" token (enforced by
// harness.validateTemplate at first lookup).
const argv_printf: []const []const u8 = &.{"{INPUT}"};
const argv_grep: []const []const u8 = &.{ "-E", "{INPUT}", "/dev/null" };
const argv_date: []const []const u8 = &.{ "-d", "{INPUT}" };
const argv_test: []const []const u8 = &.{"{INPUT}"};

const file_template: []const []const u8 = &.{"{INPUT}"};

pub fn lookup(name: []const u8) harness.Harness {
    if (std.mem.eql(u8, name, "printf")) return .{ .argv = .{ .template = argv_printf } };
    if (std.mem.eql(u8, name, "grep")) return .{ .argv = .{ .template = argv_grep } };
    if (std.mem.eql(u8, name, "date")) return .{ .argv = .{ .template = argv_date } };
    if (std.mem.eql(u8, name, "test")) return .{ .argv = .{ .template = argv_test } };
    if (std.mem.eql(u8, name, "[")) return .{ .argv = .{ .template = argv_test } };
    if (std.mem.eql(u8, name, "stat")) return .{ .file_arg = .{ .template = file_template } };
    if (std.mem.eql(u8, name, "readlink")) return .{ .file_arg = .{ .template = file_template } };
    if (std.mem.eql(u8, name, "realpath")) return .{ .file_arg = .{ .template = file_template } };
    return .{ .stdin = {} };
}

test "lookup returns stdin for unlisted utility (wc)" {
    const h = lookup("wc");
    try testing.expectEqual(harness.Mode.stdin, std.meta.activeTag(h));
}

test "lookup returns stdin for unlisted utility (cat)" {
    const h = lookup("cat");
    try testing.expectEqual(harness.Mode.stdin, std.meta.activeTag(h));
}

test "lookup returns argv for printf with {INPUT} as format string" {
    const h = lookup("printf");
    try testing.expectEqual(harness.Mode.argv, std.meta.activeTag(h));
    try harness.validateTemplate(h.argv.template);
}

test "lookup returns argv for grep with {INPUT} as pattern" {
    const h = lookup("grep");
    try testing.expectEqual(harness.Mode.argv, std.meta.activeTag(h));
    try harness.validateTemplate(h.argv.template);
}

test "lookup returns argv for date with {INPUT} as format" {
    const h = lookup("date");
    try testing.expectEqual(harness.Mode.argv, std.meta.activeTag(h));
    try harness.validateTemplate(h.argv.template);
}

test "lookup returns argv for test" {
    const h = lookup("test");
    try testing.expectEqual(harness.Mode.argv, std.meta.activeTag(h));
    try harness.validateTemplate(h.argv.template);
}

test "lookup returns file_arg for stat with {INPUT} as file path" {
    const h = lookup("stat");
    try testing.expectEqual(harness.Mode.file_arg, std.meta.activeTag(h));
    try harness.validateTemplate(h.file_arg.template);
}

test "lookup returns file_arg for readlink" {
    const h = lookup("readlink");
    try testing.expectEqual(harness.Mode.file_arg, std.meta.activeTag(h));
    try harness.validateTemplate(h.file_arg.template);
}

test "lookup returns file_arg for realpath" {
    const h = lookup("realpath");
    try testing.expectEqual(harness.Mode.file_arg, std.meta.activeTag(h));
    try harness.validateTemplate(h.file_arg.template);
}
