//! Source-scan for utilityMain writer-setup needles.
//!
//! `runUtil` tests inject Allocating writers and never construct the 8KB
//! `writerStreaming` buffers or flush them. This lint pins those tokens in
//! production `main.zig`. Scanning from a sibling module (not `main.zig`)
//! keeps needles in this file from self-satisfying.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Tokens that must appear in production `main.zig` (not tests/comments/strings).
pub const needles = [_][]const u8{
    "[8192]u8",
    "writerStreaming",
    "stdout.flush()",
    "stderr.flush()",
};

const source_bytes_max: u32 = 1 << 20;
const scan_steps_max: u32 = 1 << 22;

pub const Error = error{
    /// A required writer-setup needle is absent from production source.
    MissingMainIoNeedle,
    /// `src/common` could not be opened. Never downgraded to a silent pass.
    CommonSourceDirUnavailable,
};

/// Append each missing production needle (one per line) to `missing`.
pub fn collectMissingNeedles(
    gpa: std.mem.Allocator,
    source: []const u8,
    missing: *std.ArrayListUnmanaged(u8),
) !void {
    assert(source.len <= source_bytes_max);
    assert(needles.len == 4);
    assert(missing.items.len == 0);

    var found = [_]bool{false} ** needles.len;
    markFoundNeedles(source, &found);

    var i: u32 = 0;
    while (i < needles.len) : (i += 1) {
        if (found[i]) continue;
        try missing.appendSlice(gpa, needles[i]);
        try missing.append(gpa, '\n');
    }
}

/// Read `main.zig` from `common_dir_path` (`build_options`) and require needles.
pub fn verifyMainZig(
    gpa: std.mem.Allocator,
    io: std.Io,
    common_dir_path: []const u8,
    report_writer: *std.Io.Writer,
) !void {
    assert(common_dir_path.len > 0);
    assert(needles.len == 4);

    var dir = std.Io.Dir.cwd().openDir(io, common_dir_path, .{}) catch
        return Error.CommonSourceDirUnavailable;
    defer dir.close(io);

    const source = try dir.readFileAlloc(io, "main.zig", gpa, .limited(source_bytes_max));
    defer gpa.free(source);

    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(gpa);
    try collectMissingNeedles(gpa, source, &missing);
    if (missing.items.len == 0) return;

    try report_writer.print("main.zig missing production needle(s):\n{s}", .{missing.items});
    return Error.MissingMainIoNeedle;
}

fn markFoundNeedles(source: []const u8, found: *[needles.len]bool) void {
    assert(source.len <= source_bytes_max);
    assert(found.len == needles.len);

    var i: u32 = 0;
    var at_line_start = true;
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps < scan_steps_max);
        if (skipIfNonProduction(source, i, at_line_start)) |next| {
            assert(next > i);
            at_line_start = next > 0 and source[next - 1] == '\n';
            i = next;
            continue;
        }
        markNeedlesAt(source, i, found);
        at_line_start = source[i] == '\n';
        i += 1;
    }
}

fn markNeedlesAt(source: []const u8, i: u32, found: *[needles.len]bool) void {
    assert(i < source.len);
    assert(found.len == needles.len);

    var n: u32 = 0;
    while (n < needles.len) : (n += 1) {
        if (std.mem.startsWith(u8, source[i..], needles[n])) found[n] = true;
    }
}

/// Skip a comment, string, or `test "` body starting at `i`. Null if none.
fn skipIfNonProduction(source: []const u8, i: u32, at_line_start: bool) ?u32 {
    assert(i < source.len);
    assert(source.len <= source_bytes_max);

    if (at_line_start) {
        if (testDeclAt(source, i)) |t| return skipTestDecl(source, t);
        if (lineStartsMultilineString(source, i)) return skipMultilineLines(source, i);
    }
    if (startsLineComment(source, i)) return skipLineComment(source, i);
    if (source[i] == '"') return skipString(source, i);
    if (source[i] == '\'') return skipChar(source, i);
    return null;
}

fn testDeclAt(source: []const u8, line_start: u32) ?u32 {
    assert(line_start <= source.len);
    const i = skipSpaces(source, line_start);
    assert(i >= line_start);
    if (std.mem.startsWith(u8, source[i..], "test \"")) return i;
    return null;
}

fn skipTestDecl(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(std.mem.startsWith(u8, source[start..], "test \""));

    var i = skipString(source, start + 5);
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps < scan_steps_max);
        if (startsLineComment(source, i)) {
            i = skipToNewline(source, i);
            if (i < source.len and source[i] == '\n') i += 1;
            continue;
        }
        const c = source[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        break;
    }
    if (i >= source.len or source[i] != '{') return i;
    return skipBalancedBlock(source, i);
}

fn skipBalancedBlock(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '{');

    var i: u32 = start + 1;
    var depth: u32 = 1;
    var steps: u32 = 0;
    while (i < source.len and depth > 0) : (steps += 1) {
        assert(steps < scan_steps_max);
        if (startsLineComment(source, i)) {
            i = skipToNewline(source, i);
            continue;
        }
        if (source[i] == '"') {
            i = skipString(source, i);
            continue;
        }
        if (source[i] == '\'') {
            i = skipChar(source, i);
            continue;
        }
        if (source[i] == '{') depth += 1;
        if (source[i] == '}') depth -= 1;
        i += 1;
    }
    return i;
}

fn startsLineComment(source: []const u8, i: u32) bool {
    assert(i <= source.len);
    if (i + 1 >= source.len) return false;
    assert(i + 1 < source.len);
    return source[i] == '/' and source[i + 1] == '/';
}

fn skipLineComment(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(startsLineComment(source, start));
    return skipToNewline(source, start);
}

fn skipToNewline(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    const nl = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
    assert(nl >= start);
    return @intCast(nl);
}

fn skipString(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '"');

    var i: u32 = start + 1;
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps < scan_steps_max);
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '"') return i + 1;
        i += 1;
    }
    return i;
}

fn skipChar(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '\'');

    var i: u32 = start + 1;
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps < scan_steps_max);
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '\'') return i + 1;
        i += 1;
    }
    return i;
}

fn lineStartsMultilineString(source: []const u8, line_start: u32) bool {
    assert(line_start <= source.len);
    const i = skipSpaces(source, line_start);
    assert(i >= line_start);
    return std.mem.startsWith(u8, source[i..], "\\\\");
}

fn skipMultilineLines(source: []const u8, line_start: u32) u32 {
    assert(line_start <= source.len);
    assert(lineStartsMultilineString(source, line_start));

    var i = line_start;
    var lines: u32 = 0;
    while (i < source.len and lines < source.len) : (lines += 1) {
        if (!lineStartsMultilineString(source, i)) break;
        i = skipToNewline(source, i);
        if (i < source.len and source[i] == '\n') i += 1;
    }
    assert(i >= line_start);
    return i;
}

fn skipSpaces(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    var i = start;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    assert(i >= start);
    return i;
}

const complete_prod =
    \\var stdout_buffer: [8192]u8 = undefined;
    \\var w = f.writerStreaming(io, &stdout_buffer);
    \\stdout.flush();
    \\stderr.flush();
    \\
;

const decoy_comment =
    \\// [8192]u8 writerStreaming stdout.flush() stderr.flush()
    \\
;

const decoy_string =
    \\const s = "[8192]u8 writerStreaming stdout.flush() stderr.flush()";
    \\
;

const decoy_test =
    \\test "decoy [8192]u8 writerStreaming stdout.flush() stderr.flush()" {
    \\    _ = "[8192]u8 writerStreaming stdout.flush() stderr.flush()";
    \\    stdout.flush();
    \\    stderr.flush();
    \\}
    \\
;

fn expectMissing(
    source: []const u8,
    want_present: []const []const u8,
    want_absent: []const []const u8,
) !void {
    assert(source.len <= source_bytes_max);
    assert(want_present.len + want_absent.len > 0);

    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(testing.allocator);
    try collectMissingNeedles(testing.allocator, source, &missing);

    for (want_present) |n| {
        try testing.expect(std.mem.find(u8, missing.items, n) != null);
    }
    for (want_absent) |n| {
        try testing.expect(std.mem.find(u8, missing.items, n) == null);
    }
}

test "decoy needle in a comment does not satisfy the scan" {
    try expectMissing(decoy_comment, &needles, &.{});
    try testing.expect(decoy_comment.len > 0);
}

test "decoy needle in a string literal does not satisfy the scan" {
    try expectMissing(decoy_string, &needles, &.{});
    try testing.expect(decoy_string.len > 0);
}

test "decoy needle in a test body does not satisfy the scan" {
    try expectMissing(decoy_test, &needles, &.{});
    try testing.expect(decoy_test.len > 0);
}

test "missing production needle is reported by name" {
    const source =
        \\var buf: [4096]u8 = undefined;
        \\var w = f.writerStreaming(io, &buf);
        \\stdout.flush();
        \\stderr.flush();
        \\
    ;
    try expectMissing(source, &.{"[8192]u8"}, &.{
        "writerStreaming",
        "stdout.flush()",
        "stderr.flush()",
    });
    try testing.expect(std.mem.find(u8, source, "[8192]u8") == null);
}

test "complete production snippet is clean even with decoys" {
    const source = decoy_comment ++ decoy_string ++ decoy_test ++ complete_prod;
    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(testing.allocator);
    try collectMissingNeedles(testing.allocator, source, &missing);
    try testing.expectEqual(@as(usize, 0), missing.items.len);
    try testing.expect(source.len > complete_prod.len);
}
