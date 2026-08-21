//! GNU LS_COLORS parsing (`parse_ls_color`) and indicator lookup.
const std = @import("std");
const constants = @import("constants.zig");
const testing = std.testing;

pub const ls_colors_entries_max: u32 = 1024;

pub const ParseError = error{
    Unparsable,
    OutOfMemory,
};

/// Extra detail for an `Unparsable` result so ls can print GNU diagnostics.
pub const ParseReport = struct {
    unrecognized_prefix: ?[2]u8 = null,
};

const default_lc = "\x1b[";
const default_rc = "m";
const default_rs = "0";
const other_write_bit: u32 = 0o002;
const indicator_count: u8 = 24;

/// GNU `indicator_name` order. Two-letter keys outside this list are a FAIL.
const indicator_names: [indicator_count][2]u8 = .{
    "lc".*, "rc".*, "ec".*, "rs".*, "no".*, "fi".*, "di".*, "ln".*,
    "pi".*, "so".*, "bd".*, "cd".*, "mi".*, "or".*, "ex".*, "do".*,
    "su".*, "sg".*, "st".*, "ow".*, "tw".*, "ca".*, "mh".*, "cl".*,
};

const Suffix = struct {
    suffix: []const u8,
    sgr: []const u8,
};

/// Result of classifying a name against a parsed table.
/// `missing` keeps the compiled palette; `uncolored` is empty/`0`/`00`
/// (no color and no compiled fallback).
pub const ColorHit = union(enum) {
    missing,
    uncolored,
    sgr: []const u8,
};

const Measure = struct {
    pair_count: u32 = 0,
    suffix_count: u32 = 0,
    byte_count: u32 = 0,
};

const Segment = struct {
    seg: []const u8,
    rest: []const u8,
};

pub const Table = struct {
    type_sgr: [indicator_count]?[]const u8 = .{null} ** indicator_count,
    suffixes: []const Suffix = &.{},
    bytes: []u8 = &.{},
    suffix_buf: []Suffix = &.{},
    lc: []const u8 = default_lc,
    rc: []const u8 = default_rc,
    ec: ?[]const u8 = null,
    rs: []const u8 = default_rs,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(allocator.ptr) != 0);
        if (self.bytes.len > 0) allocator.free(self.bytes);
        if (self.suffix_buf.len > 0) allocator.free(self.suffix_buf);
        self.* = .{};
    }

    pub fn lookupType(self: *const Table, code: []const u8) ?[]const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(code.len == 2);
        return switch (self.lookupTypeHit(code)) {
            .sgr => |sgr| sgr,
            .missing, .uncolored => null,
        };
    }

    pub fn lookupSuffix(self: *const Table, name: []const u8) ?[]const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(name.len > 0);
        return switch (self.lookupSuffixHit(name)) {
            .sgr => |sgr| sgr,
            .missing, .uncolored => null,
        };
    }

    fn lookupTypeHit(self: *const Table, code: []const u8) ColorHit {
        std.debug.assert(code.len == 2);
        std.debug.assert(@intFromPtr(self) != 0);
        const idx = indicatorIndex(code) orelse return .missing;
        const sgr = self.type_sgr[idx] orelse return .missing;
        if (!isColoredSgr(sgr)) return .uncolored;
        return .{ .sgr = sgr };
    }

    fn lookupSuffixHit(self: *const Table, name: []const u8) ColorHit {
        std.debug.assert(name.len > 0);
        std.debug.assert(@intFromPtr(self) != 0);
        var i: u32 = 0;
        while (i < self.suffixes.len) : (i += 1) {
            const entry = self.suffixes[i];
            if (!std.mem.endsWith(u8, name, entry.suffix)) continue;
            if (!isColoredSgr(entry.sgr)) return .uncolored;
            return .{ .sgr = entry.sgr };
        }
        return .missing;
    }

    pub fn leftSeq(self: *const Table) []const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(default_lc.len == 2);
        return self.lc;
    }

    pub fn rightSeq(self: *const Table) []const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(default_rc.len == 1);
        return self.rc;
    }

    pub fn resetSeq(self: *const Table) []const u8 {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(default_rs.len == 1);
        return self.rs;
    }
};

fn indicatorIndex(code: []const u8) ?u8 {
    std.debug.assert(code.len == 2);
    std.debug.assert(indicator_count == indicator_names.len);
    var i: u8 = 0;
    while (i < indicator_names.len) : (i += 1) {
        if (indicator_names[i][0] == code[0] and indicator_names[i][1] == code[1]) {
            return i;
        }
    }
    return null;
}

fn isColoredSgr(sgr: []const u8) bool {
    std.debug.assert(sgr.len < 1 << 16);
    if (sgr.len == 0) {
        std.debug.assert(sgr.len == 0);
        return false;
    }
    if (std.mem.eql(u8, sgr, "0")) {
        std.debug.assert(sgr.len == 1);
        return false;
    }
    if (std.mem.eql(u8, sgr, "00")) {
        std.debug.assert(sgr.len == 2);
        return false;
    }
    std.debug.assert(sgr.len > 0);
    return true;
}

fn isControlIndex(idx: u8) bool {
    std.debug.assert(idx < indicator_count);
    // lc/rc/ec/rs occupy the first four GNU indicator slots.
    std.debug.assert(indicator_names[0][0] == 'l');
    return idx < 4;
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Table {
    std.debug.assert(@intFromPtr(allocator.ptr) != 0);
    std.debug.assert(ls_colors_entries_max > 0);
    var report = ParseReport{};
    return parseWithReport(allocator, text, &report);
}

pub fn parseWithReport(
    allocator: std.mem.Allocator,
    text: []const u8,
    report: *ParseReport,
) ParseError!Table {
    std.debug.assert(@intFromPtr(allocator.ptr) != 0);
    std.debug.assert(@intFromPtr(report) != 0);
    if (text.len == 0) return .{};
    const measure = try measurePairs(text, report);
    return fillTable(allocator, text, measure);
}

fn measurePairs(text: []const u8, report: *ParseReport) ParseError!Measure {
    std.debug.assert(text.len > 0);
    std.debug.assert(@intFromPtr(report) != 0);
    var measure = Measure{};
    var remaining = text;
    while (remaining.len > 0) {
        const split = splitSegment(remaining);
        remaining = split.rest;
        if (split.seg.len == 0) continue;
        measure.pair_count += 1;
        if (measure.pair_count > ls_colors_entries_max) return error.Unparsable;
        try measureOnePair(split.seg, &measure, report);
    }
    return measure;
}

fn splitSegment(text: []const u8) Segment {
    std.debug.assert(text.len > 0);
    const sep = std.mem.indexOfScalar(u8, text, ':');
    if (sep) |i| {
        std.debug.assert(i <= text.len);
        return .{ .seg = text[0..i], .rest = text[i + 1 ..] };
    }
    return .{ .seg = text, .rest = text[text.len..] };
}

fn measureOnePair(seg: []const u8, measure: *Measure, report: *ParseReport) ParseError!void {
    std.debug.assert(seg.len > 0);
    std.debug.assert(@intFromPtr(measure) != 0);
    const eq = std.mem.indexOfScalar(u8, seg, '=') orelse return error.Unparsable;
    const key = seg[0..eq];
    const value = seg[eq + 1 ..];
    if (key.len > 0 and key[0] == '*') {
        measure.suffix_count += 1;
        measure.byte_count += @intCast(key.len - 1 + value.len);
        return;
    }
    if (key.len != 2) return error.Unparsable;
    if (indicatorIndex(key) == null) {
        report.unrecognized_prefix = .{ key[0], key[1] };
        return error.Unparsable;
    }
    measure.byte_count += @intCast(value.len);
}

fn fillTable(allocator: std.mem.Allocator, text: []const u8, measure: Measure) ParseError!Table {
    std.debug.assert(measure.pair_count <= ls_colors_entries_max);
    std.debug.assert(measure.suffix_count <= measure.pair_count);
    var table = Table{};
    if (measure.byte_count > 0) {
        table.bytes = allocator.alloc(u8, measure.byte_count) catch return error.OutOfMemory;
    }
    errdefer if (table.bytes.len > 0) allocator.free(table.bytes);
    if (measure.suffix_count > 0) {
        table.suffix_buf = allocator.alloc(Suffix, measure.suffix_count) catch
            return error.OutOfMemory;
    }
    errdefer if (table.suffix_buf.len > 0) allocator.free(table.suffix_buf);
    fillPairs(&table, text, measure);
    return table;
}

fn fillPairs(table: *Table, text: []const u8, measure: Measure) void {
    std.debug.assert(@intFromPtr(table) != 0);
    std.debug.assert(text.len > 0);
    var byte_off: u32 = 0;
    var suffix_next: u32 = measure.suffix_count;
    var remaining = text;
    while (remaining.len > 0) {
        const split = splitSegment(remaining);
        remaining = split.rest;
        if (split.seg.len == 0) continue;
        fillOnePair(table, split.seg, &byte_off, &suffix_next);
    }
    std.debug.assert(suffix_next == 0);
    std.debug.assert(byte_off == measure.byte_count);
    table.suffixes = table.suffix_buf;
}

fn fillOnePair(table: *Table, seg: []const u8, byte_off: *u32, suffix_next: *u32) void {
    std.debug.assert(seg.len > 0);
    std.debug.assert(@intFromPtr(table) != 0);
    const eq = std.mem.indexOfScalar(u8, seg, '=') orelse unreachable;
    const key = seg[0..eq];
    const value = seg[eq + 1 ..];
    const copied = copyBytes(table.bytes, byte_off, value);
    if (key.len > 0 and key[0] == '*') {
        const suffix = copyBytes(table.bytes, byte_off, key[1..]);
        suffix_next.* -= 1;
        table.suffix_buf[suffix_next.*] = .{ .suffix = suffix, .sgr = copied };
        return;
    }
    const idx = indicatorIndex(key) orelse unreachable;
    storeTypeOrControl(table, idx, copied);
}

fn copyBytes(storage: []u8, off: *u32, src: []const u8) []const u8 {
    if (src.len == 0) {
        std.debug.assert(off.* <= storage.len);
        return storage[off.*..off.*];
    }
    std.debug.assert(off.* + src.len <= storage.len);
    const start = off.*;
    @memcpy(storage[start .. start + src.len], src);
    off.* += @intCast(src.len);
    std.debug.assert(off.* <= storage.len);
    return storage[start .. start + src.len];
}

fn storeTypeOrControl(table: *Table, idx: u8, sgr: []const u8) void {
    std.debug.assert(idx < indicator_count);
    std.debug.assert(@intFromPtr(table) != 0);
    if (isControlIndex(idx)) {
        storeControl(table, idx, sgr);
        return;
    }
    table.type_sgr[idx] = sgr;
}

fn storeControl(table: *Table, idx: u8, sgr: []const u8) void {
    std.debug.assert(isControlIndex(idx));
    std.debug.assert(@intFromPtr(table) != 0);
    switch (idx) {
        0 => table.lc = sgr,
        1 => table.rc = sgr,
        2 => table.ec = sgr,
        3 => table.rs = sgr,
        else => unreachable,
    }
}

fn firstColored(hit: ColorHit) ?[]const u8 {
    std.debug.assert(@intFromEnum(hit) <= @intFromEnum(ColorHit.sgr));
    return switch (hit) {
        .sgr => |sgr| sgr,
        .missing, .uncolored => null,
    };
}

fn coloredOrSkip(table: *const Table, code: []const u8) ?[]const u8 {
    std.debug.assert(code.len == 2);
    std.debug.assert(@intFromPtr(table) != 0);
    return firstColored(table.lookupTypeHit(code));
}

pub fn sgrFor(
    table: *const Table,
    kind: std.Io.File.Kind,
    mode: ?u32,
    nlink: u32,
    name: []const u8,
    dangling: bool,
) ColorHit {
    std.debug.assert(@intFromPtr(table) != 0);
    std.debug.assert(name.len > 0);
    if (dangling) {
        if (coloredOrSkip(table, "or")) |sgr| return .{ .sgr = sgr };
        return table.lookupTypeHit("mi");
    }
    return switch (kind) {
        .directory => sgrForDirectory(table, mode),
        .sym_link => table.lookupTypeHit("ln"),
        .named_pipe => table.lookupTypeHit("pi"),
        .unix_domain_socket => table.lookupTypeHit("so"),
        .block_device => table.lookupTypeHit("bd"),
        .character_device => table.lookupTypeHit("cd"),
        .file => sgrForRegularFile(table, mode, nlink, name),
        .door => table.lookupTypeHit("do"),
        else => .missing,
    };
}

fn sgrForDirectory(table: *const Table, mode: ?u32) ColorHit {
    std.debug.assert(@intFromPtr(table) != 0);
    std.debug.assert(constants.STICKY_BIT == 0o1000);
    if (mode) |m| {
        const sticky = (m & constants.STICKY_BIT) != 0;
        const owrite = (m & other_write_bit) != 0;
        if (sticky and owrite) if (coloredOrSkip(table, "tw")) |sgr| return .{ .sgr = sgr };
        if (owrite) if (coloredOrSkip(table, "ow")) |sgr| return .{ .sgr = sgr };
        if (sticky) if (coloredOrSkip(table, "st")) |sgr| return .{ .sgr = sgr };
    }
    return table.lookupTypeHit("di");
}

fn sgrForRegularFile(
    table: *const Table,
    mode: ?u32,
    nlink: u32,
    name: []const u8,
) ColorHit {
    std.debug.assert(@intFromPtr(table) != 0);
    std.debug.assert(name.len > 0);
    if (mode) |m| {
        if (m & constants.SETUID_BIT != 0) {
            if (coloredOrSkip(table, "su")) |sgr| return .{ .sgr = sgr };
        }
        if (m & constants.SETGID_BIT != 0) {
            if (coloredOrSkip(table, "sg")) |sgr| return .{ .sgr = sgr };
        }
        if (m & constants.EXECUTE_BIT != 0) {
            if (coloredOrSkip(table, "ex")) |sgr| return .{ .sgr = sgr };
        }
    }
    if (nlink > 1) {
        if (coloredOrSkip(table, "mh")) |sgr| return .{ .sgr = sgr };
    }
    const suffix = table.lookupSuffixHit(name);
    if (suffix != .missing) return suffix;
    return table.lookupTypeHit("fi");
}

pub fn writeWrapped(writer: anytype, table: *const Table, sgr: []const u8) !void {
    std.debug.assert(sgr.len > 0);
    std.debug.assert(@intFromPtr(table) != 0);
    try writer.writeAll(table.leftSeq());
    try writer.writeAll(sgr);
    try writer.writeAll(table.rightSeq());
}

/// GNU end sequence: `ec` if set, otherwise `lc`+`rs`+`rc`.
pub fn writeEnd(writer: anytype, table: *const Table) !void {
    std.debug.assert(@intFromPtr(table) != 0);
    std.debug.assert(default_rs.len == 1);
    if (table.ec) |ec| {
        try writer.writeAll(ec);
        return;
    }
    try writer.writeAll(table.leftSeq());
    try writer.writeAll(table.resetSeq());
    try writer.writeAll(table.rightSeq());
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
