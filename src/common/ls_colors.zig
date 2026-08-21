//! GNU LS_COLORS parsing contract.
//!
//! The implementation is intentionally empty during the test-writing phase.
const std = @import("std");
const testing = std.testing;

pub const ls_colors_entries_max: u32 = 1024;

pub const ParseError = error{
    Unparsable,
    OutOfMemory,
};

pub const Table = struct {
    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(allocator.ptr) != 0);
        self.* = .{};
    }

    pub fn lookupType(self: *const Table, code: []const u8) ?[]const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(code.len == 2);
        return null;
    }

    pub fn lookupSuffix(self: *const Table, name: []const u8) ?[]const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(name.len > 0);
        return null;
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Table {
    std.debug.assert(@intFromPtr(allocator.ptr) != 0);
    std.debug.assert(ls_colors_entries_max > 0);
    _ = text;
    return .{};
}

test "LS_COLORS empty input keeps the overlay empty" {
    var table = try parse(testing.allocator, "");
    defer table.deinit(testing.allocator);

    try testing.expect(table.lookupType("di") == null);
    try testing.expect(table.lookupSuffix("archive.zip") == null);
}

test "LS_COLORS stores a directory type SGR verbatim" {
    var table = try parse(testing.allocator, "di=01;34");
    defer table.deinit(testing.allocator);

    try testing.expectEqualStrings("01;34", table.lookupType("di") orelse "");
    try testing.expect(table.lookupType("ex") == null);
}

test "LS_COLORS stores suffix and type entries together" {
    var table = try parse(testing.allocator, "*.zip=01;31:di=01;34");
    defer table.deinit(testing.allocator);

    try testing.expectEqualStrings("01;31", table.lookupSuffix("archive.zip") orelse "");
    try testing.expectEqualStrings("01;34", table.lookupType("di") orelse "");
}

test "LS_COLORS last listed matching suffix wins in both orders" {
    var longer_last = try parse(
        testing.allocator,
        "*.gz=01;31:*.tar.gz=01;32",
    );
    defer longer_last.deinit(testing.allocator);
    var shorter_last = try parse(
        testing.allocator,
        "*.tar.gz=01;32:*.gz=01;31",
    );
    defer shorter_last.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "01;32",
        longer_last.lookupSuffix("foo.tar.gz") orelse "",
    );
    try testing.expectEqualStrings(
        "01;31",
        shorter_last.lookupSuffix("foo.tar.gz") orelse "",
    );
    try testing.expect(
        !std.mem.eql(u8, shorter_last.lookupSuffix("foo.tar.gz") orelse "", "01;32"),
    );
}

test "LS_COLORS rejects an unrecognized prefix" {
    try testing.expectError(error.Unparsable, parse(testing.allocator, "zz=01"));

    var valid = try parse(testing.allocator, "di=01;34");
    defer valid.deinit(testing.allocator);
    try testing.expectEqualStrings("01;34", valid.lookupType("di") orelse "");
}

test "LS_COLORS zero and empty SGR values are not colored" {
    var empty = try parse(testing.allocator, "ex=");
    defer empty.deinit(testing.allocator);
    var zero = try parse(testing.allocator, "ex=0");
    defer zero.deinit(testing.allocator);
    var double_zero = try parse(testing.allocator, "ex=00");
    defer double_zero.deinit(testing.allocator);
    var colored = try parse(testing.allocator, "ex=01");
    defer colored.deinit(testing.allocator);

    try testing.expect(empty.lookupType("ex") == null);
    try testing.expect(zero.lookupType("ex") == null);
    try testing.expect(double_zero.lookupType("ex") == null);
    try testing.expectEqualStrings("01", colored.lookupType("ex") orelse "");
}

test "LS_COLORS rejects entries beyond the hard cap" {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);

    var pair_count: u32 = 0;
    while (pair_count < ls_colors_entries_max) : (pair_count += 1) {
        if (pair_count > 0) try text.append(testing.allocator, ':');
        try text.appendSlice(testing.allocator, "di=01");
    }
    const exact_cap_len = text.items.len;
    try text.appendSlice(testing.allocator, ":di=01");

    try testing.expectError(error.Unparsable, parse(testing.allocator, text.items));
    var exact_cap = try parse(testing.allocator, text.items[0..exact_cap_len]);
    defer exact_cap.deinit(testing.allocator);
    try testing.expectEqualStrings("01", exact_cap.lookupType("di") orelse "");
}

test "LS_COLORS preserves truecolor SGR values" {
    var table = try parse(testing.allocator, "fi=38;2;1;2;3");
    defer table.deinit(testing.allocator);

    try testing.expectEqualStrings("38;2;1;2;3", table.lookupType("fi") orelse "");
    try testing.expect(table.lookupType("di") == null);
}
