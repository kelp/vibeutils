//! Build-gating lint: listed utility tests must not call `testing.tmpDir(`
//! (TODO ### 3). After GREEN they use `common.test_dir.TestDir` instead.
//!
//! The *logic* lives here but the *test* that calls `verify` against the real
//! tree lives in `lib.zig`, the test root. If this file were dropped from the
//! force-import block, its fixture tests would go dormant — but the caller in
//! `lib.zig` still runs and still fails. Do not move that caller here.

const std = @import("std");
const assert = std.debug.assert;

/// Exact floor: the locked table is 39 paths, not "at least cat.zig".
pub const listed_files_min: u32 = 39;

/// Loop bounds. Tiger Style forbids unbounded iteration.
const files_max: u32 = 64;
const bytes_max: u32 = 2 * 1024 * 1024;
const allowlist_len: u32 = 29;

/// Heading order, then `mv`, then `src/ls/*.zig` sorted. Last path is
/// `src/ls/types.zig` so a single-violation fixture cannot skip the tail.
pub const listed_paths = [_][]const u8{
    "src/cat.zig",
    "src/chmod.zig",
    "src/chown.zig",
    "src/cut.zig",
    "src/dd.zig",
    "src/du.zig",
    "src/find.zig",
    "src/grep.zig",
    "src/head.zig",
    "src/ln.zig",
    "src/mkdir.zig",
    "src/mktemp.zig",
    "src/nl.zig",
    "src/pwd.zig",
    "src/readlink.zig",
    "src/realpath.zig",
    "src/rm.zig",
    "src/rmdir.zig",
    "src/stat.zig",
    "src/tac.zig",
    "src/tail.zig",
    "src/tee.zig",
    "src/test.zig",
    "src/touch.zig",
    "src/tr.zig",
    "src/uniq.zig",
    "src/wc.zig",
    "src/mv.zig",
    "src/ls/core.zig",
    "src/ls/display.zig",
    "src/ls/entry_collector.zig",
    "src/ls/formatter.zig",
    "src/ls/integration_test.zig",
    "src/ls/main.zig",
    "src/ls/recursive.zig",
    "src/ls/security_test.zig",
    "src/ls/sorter.zig",
    "src/ls/test_utils.zig",
    "src/ls/types.zig",
};

const AllowlistedBody = struct {
    path: []const u8,
    name: []const u8,
};

/// Residual cwd-behavior tests (plan decision 3; 29 bodies). After GREEN
/// every body here contains `chdirToBase(` and every `chdirToBase(` sits in
/// one of these.
const chdir_allowlist = [_]AllowlistedBody{
    .{
        .path = "src/grep.zig",
        .name = "walker-migration: recursive search with no operands " ++
            "searches the current directory",
    },
    .{
        .path = "src/readlink.zig",
        .name = "readlink -m relative path with missing tail resolves via cwd " ++
            "(issue #51)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: relative --relative-to=. resolves against cwd " ++
            "(issue #46)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: relative --relative-base=sub resolves against cwd " ++
            "(issue #46)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -e resolves a relative existing file to an " ++
            "absolute path (issue #46)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s relative existing path resolves via cwd (issue #51)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s relative path with dot components resolves via " ++
            "cwd (issue #51)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -m relative path with missing tail resolves via cwd " ++
            "(issue #51)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -m relative path with existing components resolves " ++
            "via cwd (issue #51)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s pop of dotdot past missing component errors " ++
            "ENOENT (issue #62)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s pop of dotdot past non-directory errors ENOTDIR " ++
            "(issue #62)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -m -s pop of dotdot past missing component succeeds " ++
            "(issue #62)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s pop past existing dir with missing final " ++
            "component succeeds (issue #62)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s pop past symlink-to-directory succeeds (issue #62)",
    },
    .{
        .path = "src/realpath.zig",
        .name = "realpath: -s pop past symlink-to-file errors ENOTDIR (issue #62)",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls prints a subdirectory operand exactly as given, not its " ++
            "basename (short format)",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -l ends a subdirectory operand's line with the full operand path",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -1t sorts distinct-mtime file operands newest first, " ++
            "ignoring argv order",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -1S sorts distinct-size file operands largest first, " ++
            "ignoring argv order",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -1 sorts file operands by name by default, ignoring argv order",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -1U preserves argv order for file operands (guards against " ++
            "over-sorting)",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -1r reverses the default name sort for file operands",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls sorts directory operands by name too, so a_dir's header " ++
            "comes before b_dir's",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls mixed operands: files first, one blank line before the dir section",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -C lays out multiple file operands in columns, not one per line",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -s prints the block prefix for file operands and no total line",
    },
    .{
        .path = "src/ls/main.zig",
        .name = "ls -s sizes the operand block field across all operands, not " ++
            "per operand",
    },
    .{ .path = "src/rmdir.zig", .name = "rmdir: remove with parents" },
    .{ .path = "src/ls/main.zig", .name = "AclFixture.init" },
};

const needle_tmp_dir = "testing.tmpDir";
const needle_threaded = "Threaded.chdir";
const needle_set_cwd = "setCurrentDir";
const needle_chdir = "chdirToBase";
const needle_mv = "inner: common.test_dir.TestDir";
const needle_create_dir = "Dir.cwd().createDir";
const needle_create_dir_path = "Dir.cwd().createDirPath";
const needle_create_file = "Dir.cwd().createFile";
const needle_delete_dir = "Dir.cwd().deleteDir";
const needle_delete_tree = "Dir.cwd().deleteTree";
const acl_init_sig = "fn init() !AclFixture {";
const src_prefix = "src/";

comptime {
    assert(listed_paths.len == listed_files_min);
    assert(chdir_allowlist.len == allowlist_len);
    assert(std.mem.eql(u8, listed_paths[listed_paths.len - 1], "src/ls/types.zig"));
}

pub const Error = error{
    /// One or more listed files still contain a forbidden needle.
    TestdirLintFailed,
    /// A path in the locked table could not be read.
    ListedPathMissing,
    /// The table passed to the scanner was empty.
    ListedTableEmpty,
    /// The scanned count was not exactly `listed_files_min`.
    ListedCountMismatch,
    /// `dirname(common_source_dir)` was missing or could not be opened.
    SrcRootUnavailable,
    /// A listed file exceeded `bytes_max`.
    FileTooLarge,
    /// More files than the loop bound allows.
    TooManyFiles,
};

const ScanInput = struct {
    path: []const u8,
    source: []const u8,
};

const Body = struct {
    name: []const u8,
    start: u32,
    end: u32,
};

/// True when `path` is in the locked listed-path table.
pub fn hasListedPath(path: []const u8) bool {
    assert(path.len > 0);
    assert(listed_paths.len == listed_files_min);

    for (listed_paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

/// Run the lint against the real tree.
///
/// `common_dir_path` is `build_options.common_source_dir` (`src/common`).
/// `src` is `dirname` of that path; listed paths drop the `src/` prefix
/// relative to it. Injected rather than resolved from cwd so a wrong
/// working directory cannot pass the lint vacuously.
pub fn verify(
    gpa: std.mem.Allocator,
    io: std.Io,
    common_dir_path: []const u8,
    report_writer: *std.Io.Writer,
) !void {
    assert(common_dir_path.len > 0);
    assert(listed_paths.len == listed_files_min);

    const src_root = std.fs.path.dirname(common_dir_path) orelse
        return Error.SrcRootUnavailable;
    try verifyTable(gpa, io, src_root, &listed_paths, report_writer);
}

fn verifyTable(
    gpa: std.mem.Allocator,
    io: std.Io,
    src_root: []const u8,
    table: []const []const u8,
    report_writer: *std.Io.Writer,
) !void {
    assert(src_root.len > 0);
    if (table.len == 0) return Error.ListedTableEmpty;
    if (table.len > files_max) return Error.TooManyFiles;
    if (table.len != listed_files_min) return Error.ListedCountMismatch;
    assert(table.len == listed_files_min);

    var dir = std.Io.Dir.cwd().openDir(io, src_root, .{}) catch
        return Error.SrcRootUnavailable;
    defer dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = try readListed(arena, io, dir, table);
    assert(inputs.len == listed_files_min);

    var report: std.ArrayListUnmanaged(u8) = .empty;
    const violations = try scanInputs(arena, inputs, &report);
    if (violations == 0) return;

    try report_writer.print(
        "\nTODO ### 3 violation - leftover testing.tmpDir / cwd fixtures:\n" ++
            "{s}\nReplace testing.tmpDir( with common.test_dir.TestDir " ++
            "in listed utilities.\n",
        .{report.items},
    );
    return Error.TestdirLintFailed;
}

fn readListed(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    table: []const []const u8,
) ![]ScanInput {
    assert(table.len == listed_files_min);
    assert(table.len <= files_max);

    var out: std.ArrayListUnmanaged(ScanInput) = .empty;
    var scanned: u32 = 0;
    for (table) |listed| {
        scanned += 1;
        if (scanned > files_max) return Error.TooManyFiles;
        const rel = srcRelative(listed);
        const source = dir.readFileAlloc(
            io,
            rel,
            arena,
            .limited(bytes_max),
        ) catch |err| switch (err) {
            error.StreamTooLong => return Error.FileTooLarge,
            else => return Error.ListedPathMissing,
        };
        try out.append(arena, .{ .path = listed, .source = source });
    }
    assert(scanned == table.len);
    if (scanned != listed_files_min) return Error.ListedCountMismatch;
    return out.items;
}

fn srcRelative(listed: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, listed, src_prefix));
    assert(listed.len > src_prefix.len);
    return listed[src_prefix.len..];
}

/// Scan `inputs` for leftover needles. The chdirToBase allowlist (every
/// allowlisted body has a call; every call sits in an allowlisted body)
/// runs only when tmpDir, cwd-fixture, Threaded.chdir, setCurrentDir, and
/// mv-wrapper hits are already zero. Otherwise current main would RED for
/// "allowlisted test missing chdirToBase" on top of leftover tmpDir hits,
/// mixing two reasons.
fn scanInputs(
    gpa: std.mem.Allocator,
    inputs: []const ScanInput,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(inputs.len > 0);
    assert(inputs.len <= files_max);

    var always: u32 = 0;
    for (inputs) |input| {
        always += try scanAlways(gpa, input, report);
    }
    if (always > 0) return always;

    var chdir_hits: u32 = 0;
    for (inputs) |input| {
        chdir_hits += try scanChdir(gpa, input, report);
    }
    return chdir_hits;
}

fn scanAlways(
    gpa: std.mem.Allocator,
    input: ScanInput,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(input.path.len > 0);
    assert(input.source.len <= bytes_max);

    var marked = try markSource(gpa, input.source);
    defer gpa.free(marked.in_code);
    defer marked.tests.deinit(gpa);

    var n: u32 = 0;
    n += try recordCall(
        gpa,
        input,
        marked.in_code,
        needle_tmp_dir,
        "testing.tmpDir(",
        report,
    );
    n += try recordCall(
        gpa,
        input,
        marked.in_code,
        needle_threaded,
        "Threaded.chdir(",
        report,
    );
    n += try recordCall(
        gpa,
        input,
        marked.in_code,
        needle_set_cwd,
        "setCurrentDir(",
        report,
    );
    n += try recordText(gpa, input, marked.in_code, needle_mv, report);
    n += try recordCwdHits(gpa, input, marked.in_code, marked.tests.items, report);
    return n;
}

fn scanChdir(
    gpa: std.mem.Allocator,
    input: ScanInput,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(input.path.len > 0);
    assert(input.source.len <= bytes_max);

    var marked = try markSource(gpa, input.source);
    defer gpa.free(marked.in_code);
    defer marked.tests.deinit(gpa);

    var bodies: std.ArrayListUnmanaged(Body) = .empty;
    defer bodies.deinit(gpa);
    try bodies.appendSlice(gpa, marked.tests.items);
    if (std.mem.eql(u8, input.path, "src/ls/main.zig")) {
        if (findAclInit(input.source, marked.in_code)) |b| {
            try bodies.append(gpa, b);
        }
    }

    var n: u32 = 0;
    n += try recordUnlistedChdir(gpa, input, marked.in_code, bodies.items, report);
    n += try recordMissingChdir(gpa, input, marked.in_code, bodies.items, report);
    return n;
}

const Marked = struct {
    in_code: []bool,
    tests: std.ArrayListUnmanaged(Body),
};

fn markSource(gpa: std.mem.Allocator, source: []const u8) !Marked {
    assert(source.len <= bytes_max);
    const in_code = try gpa.alloc(bool, source.len);
    errdefer gpa.free(in_code);
    markCode(source, in_code);

    var tests: std.ArrayListUnmanaged(Body) = .empty;
    errdefer tests.deinit(gpa);
    try collectNamedTests(gpa, source, in_code, &tests);
    assert(tests.items.len <= source.len);
    return .{ .in_code = in_code, .tests = tests };
}

fn recordCall(
    gpa: std.mem.Allocator,
    input: ScanInput,
    in_code: []const bool,
    name: []const u8,
    label: []const u8,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(name.len > 0);
    assert(label.len > 0);
    const len: u32 = @intCast(input.source.len);
    if (findCall(input.source, in_code, 0, len, name) == null) return 0;
    try report.print(gpa, "  {s}: {s}\n", .{ input.path, label });
    return 1;
}

fn recordText(
    gpa: std.mem.Allocator,
    input: ScanInput,
    in_code: []const bool,
    needle: []const u8,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(needle.len > 0);
    assert(input.path.len > 0);
    const len: u32 = @intCast(input.source.len);
    if (findInCode(input.source, in_code, 0, len, needle) == null) return 0;
    try report.print(gpa, "  {s}: {s}\n", .{ input.path, needle });
    return 1;
}

fn recordCwdHits(
    gpa: std.mem.Allocator,
    input: ScanInput,
    in_code: []const bool,
    tests: []const Body,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(input.path.len > 0);
    assert(in_code.len == input.source.len);

    const cwd_needles = [_][2][]const u8{
        .{ needle_create_dir, "Dir.cwd().createDir(" },
        .{ needle_create_dir_path, "Dir.cwd().createDirPath(" },
        .{ needle_create_file, "Dir.cwd().createFile(" },
        .{ needle_delete_dir, "Dir.cwd().deleteDir(" },
        .{ needle_delete_tree, "Dir.cwd().deleteTree(" },
    };
    var n: u32 = 0;
    for (cwd_needles) |pair| {
        if (findCallInTests(input.source, in_code, tests, pair[0]) == null) continue;
        try report.print(gpa, "  {s}: {s}\n", .{ input.path, pair[1] });
        n += 1;
    }
    return n;
}

fn recordUnlistedChdir(
    gpa: std.mem.Allocator,
    input: ScanInput,
    in_code: []const bool,
    bodies: []const Body,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(input.path.len > 0);
    assert(in_code.len == input.source.len);

    var pos: u32 = 0;
    const len: u32 = @intCast(input.source.len);
    var steps: u32 = 0;
    while (pos < len) : (steps += 1) {
        assert(steps <= len);
        const found = findCall(input.source, in_code, pos, len, needle_chdir) orelse
            return 0;
        const name = bodyNameAt(bodies, found);
        if (name == null or !isAllowlisted(input.path, name.?)) {
            try report.print(
                gpa,
                "  {s}: chdirToBase( outside allowlist\n",
                .{input.path},
            );
            return 1;
        }
        pos = found + 1;
    }
    return 0;
}

fn recordMissingChdir(
    gpa: std.mem.Allocator,
    input: ScanInput,
    in_code: []const bool,
    bodies: []const Body,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(input.path.len > 0);
    assert(chdir_allowlist.len == allowlist_len);

    var n: u32 = 0;
    for (chdir_allowlist) |entry| {
        if (!std.mem.eql(u8, entry.path, input.path)) continue;
        // A body not present in this buffer is skipped: synthetic fixtures
        // cover one file at a time. On the live tree the allowlisted tests
        // exist; dropping chdir from one of them is the RED this catches.
        const body = findBodyByName(bodies, entry.name) orelse continue;
        if (findCall(input.source, in_code, body.start, body.end, needle_chdir) != null) {
            continue;
        }
        try report.print(
            gpa,
            "  {s}: allowlisted body missing chdirToBase(: {s}\n",
            .{ input.path, entry.name },
        );
        n += 1;
    }
    return n;
}

fn isAllowlisted(path: []const u8, name: []const u8) bool {
    assert(path.len > 0);
    assert(name.len > 0);
    for (chdir_allowlist) |e| {
        if (std.mem.eql(u8, e.path, path) and std.mem.eql(u8, e.name, name)) {
            return true;
        }
    }
    return false;
}

fn findBodyByName(bodies: []const Body, name: []const u8) ?Body {
    assert(name.len > 0);
    assert(bodies.len < 1 << 20);
    for (bodies) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

fn bodyNameAt(bodies: []const Body, pos: u32) ?[]const u8 {
    assert(bodies.len < 1 << 20);
    assert(pos < 1 << 24);
    for (bodies) |b| {
        if (pos >= b.start and pos < b.end) return b.name;
    }
    return null;
}

fn findCallInTests(
    source: []const u8,
    in_code: []const bool,
    tests: []const Body,
    name: []const u8,
) ?u32 {
    assert(name.len > 0);
    assert(in_code.len == source.len);
    var pos: u32 = 0;
    const len: u32 = @intCast(source.len);
    var steps: u32 = 0;
    while (pos < len) : (steps += 1) {
        assert(steps <= len);
        const found = findCall(source, in_code, pos, len, name) orelse return null;
        if (bodyNameAt(tests, found) != null) return found;
        pos = found + 1;
    }
    return null;
}

fn findCall(
    source: []const u8,
    in_code: []const bool,
    start: u32,
    end: u32,
    name: []const u8,
) ?u32 {
    assert(in_code.len == source.len);
    assert(name.len > 0);
    assert(start <= end);
    assert(end <= source.len);

    var pos = start;
    var steps: u32 = 0;
    while (pos < end) : (steps += 1) {
        assert(steps <= end);
        const found_us = std.mem.findPos(u8, source[0..end], pos, name) orelse
            return null;
        const found: u32 = @intCast(found_us);
        if (found >= end) return null;
        const name_end = found + @as(u32, @intCast(name.len));
        if (name_end > end) return null;
        if (!in_code[found] or identBefore(source, start, found)) {
            pos = found + 1;
            continue;
        }
        const after = skipCodeWs(source, in_code, name_end, end);
        if (after < end and source[after] == '(') return found;
        pos = found + 1;
    }
    return null;
}

fn findInCode(
    source: []const u8,
    in_code: []const bool,
    start: u32,
    end: u32,
    needle: []const u8,
) ?u32 {
    assert(in_code.len == source.len);
    assert(needle.len > 0);
    assert(start <= end);
    assert(end <= source.len);

    var pos = start;
    var steps: u32 = 0;
    while (pos < end) : (steps += 1) {
        assert(steps <= end);
        const found_us = std.mem.findPos(u8, source[0..end], pos, needle) orelse
            return null;
        const found: u32 = @intCast(found_us);
        if (found >= end) return null;
        if (in_code[found]) return found;
        pos = found + 1;
    }
    return null;
}

fn identBefore(source: []const u8, start: u32, found: u32) bool {
    assert(found >= start);
    assert(found <= source.len);
    if (found == start or found == 0) return false;
    return isIdentChar(source[found - 1]);
}

fn skipCodeWs(source: []const u8, in_code: []const bool, i: u32, end: u32) u32 {
    assert(i <= end);
    assert(end <= source.len);
    var j = i;
    while (j < end and in_code[j] and isWs(source[j])) : (j += 1) {}
    return j;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn collectNamedTests(
    arena: std.mem.Allocator,
    source: []const u8,
    in_code: []const bool,
    out: *std.ArrayListUnmanaged(Body),
) !void {
    assert(in_code.len == source.len);
    assert(out.items.len == 0);

    var line_start: u32 = 0;
    var checked: u32 = 0;
    while (line_start < source.len) : (checked += 1) {
        assert(checked <= source.len);
        const rest = source[line_start..];
        if (parseNamedTest(rest)) |name| {
            const name_off: u32 = line_start + @as(u32, "test \"".len);
            const after_name: u32 = name_off + @as(u32, @intCast(name.len)) + 1;
            if (findCodeChar(source, in_code, after_name, '{')) |brace| {
                const end = matchBrace(source, in_code, brace);
                try out.append(arena, .{ .name = name, .start = brace, .end = end });
            }
        }
        const nl = std.mem.findScalar(u8, rest, '\n') orelse break;
        line_start += @intCast(nl + 1);
    }
}

fn parseNamedTest(line: []const u8) ?[]const u8 {
    const prefix = "test \"";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    assert(line.len >= prefix.len);
    const rest = line[prefix.len..];
    const q = std.mem.findScalar(u8, rest, '"') orelse return null;
    assert(q <= rest.len);
    return rest[0..q];
}

fn findCodeChar(
    source: []const u8,
    in_code: []const bool,
    start: u32,
    c: u8,
) ?u32 {
    assert(in_code.len == source.len);
    assert(start <= source.len);
    var i = start;
    while (i < source.len) : (i += 1) {
        if (in_code[i] and source[i] == c) return i;
    }
    return null;
}

fn matchBrace(source: []const u8, in_code: []const bool, open: u32) u32 {
    assert(open < source.len);
    assert(source[open] == '{');
    var depth: u32 = 1;
    var i = open + 1;
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps <= source.len);
        if (!in_code[i]) {
            i += 1;
            continue;
        }
        if (source[i] == '{') depth += 1;
        if (source[i] == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return @intCast(source.len);
}

fn findAclInit(source: []const u8, in_code: []const bool) ?Body {
    assert(in_code.len == source.len);
    assert(acl_init_sig.len > 0);
    const len: u32 = @intCast(source.len);
    const pos = findInCode(source, in_code, 0, len, acl_init_sig) orelse
        return null;
    const brace = pos + acl_init_sig.len - 1;
    assert(source[brace] == '{');
    return .{
        .name = "AclFixture.init",
        .start = @intCast(brace),
        .end = matchBrace(source, in_code, @intCast(brace)),
    };
}

fn markCode(source: []const u8, in_code: []bool) void {
    assert(in_code.len == source.len);
    assert(source.len <= bytes_max);

    var i: u32 = 0;
    var line_start = true;
    var steps: u32 = 0;
    while (i < source.len) : (steps += 1) {
        assert(steps <= source.len + 1);
        if (line_start) {
            i = markIndent(source, in_code, i);
            if (i >= source.len) break;
            if (startsLineString(source, i)) {
                i = skipToEol(source, in_code, i, false);
                continue;
            }
            line_start = false;
            continue;
        }
        if (startsLineComment(source, i)) {
            i = skipToEol(source, in_code, i, false);
            continue;
        }
        if (source[i] == '"' or source[i] == '\'') {
            i = markString(source, in_code, i);
            continue;
        }
        if (source[i] == '\n') {
            in_code[i] = true;
            i += 1;
            line_start = true;
            continue;
        }
        in_code[i] = true;
        i += 1;
    }
}

fn markIndent(source: []const u8, in_code: []bool, i: u32) u32 {
    assert(i <= source.len);
    assert(in_code.len == source.len);
    var j = i;
    while (j < source.len and (source[j] == ' ' or source[j] == '\t')) : (j += 1) {
        in_code[j] = true;
    }
    return j;
}

fn startsLineString(source: []const u8, i: u32) bool {
    assert(i <= source.len);
    if (i + 1 >= source.len) return false;
    return source[i] == '\\' and source[i + 1] == '\\';
}

fn startsLineComment(source: []const u8, i: u32) bool {
    assert(i < source.len);
    if (i + 1 >= source.len) return false;
    return source[i] == '/' and source[i + 1] == '/';
}

fn skipToEol(source: []const u8, in_code: []bool, i: u32, code: bool) u32 {
    assert(i < source.len);
    assert(in_code.len == source.len);
    var j = i;
    while (j < source.len and source[j] != '\n') : (j += 1) {
        in_code[j] = code;
    }
    return j;
}

fn markString(source: []const u8, in_code: []bool, i: u32) u32 {
    assert(i < source.len);
    const delim = source[i];
    assert(delim == '"' or delim == '\'');
    in_code[i] = false;
    var j = i + 1;
    var esc = false;
    while (j < source.len) : (j += 1) {
        in_code[j] = false;
        if (esc) {
            esc = false;
            continue;
        }
        if (source[j] == '\\') {
            esc = true;
            continue;
        }
        if (source[j] == delim) return j + 1;
        if (source[j] == '\n') return j;
    }
    return j;
}

// ---------------------------------------------------------------------------
// Tests — synthetic buffers, not the live tree. The live-tree caller is in
// lib.zig so dropping this module from the force-import block cannot silence
// the gate.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scanOne(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(path.len > 0);
    assert(source.len <= bytes_max);
    const input = ScanInput{ .path = path, .source = source };
    return scanInputs(gpa, &.{input}, report);
}

fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    assert(buf.len >= 64);
    assert(tmp.sub_path.len > 0);
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "testing.tmpDir(.{}) is a hit" {
    const source =
        \\test "x" {
        \\    var tmp = testing.tmpDir(.{});
        \\    _ = tmp;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/cat.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "testing.tmpDir(") != null);
    try testing.expect(std.mem.find(u8, report.items, "src/cat.zig") != null);
}

test "std.testing.tmpDir(.{ .iterate = true }) is a hit" {
    const source =
        \\test "x" {
        \\    var tmp = std.testing.tmpDir(.{ .iterate = true });
        \\    _ = tmp;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/wc.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "testing.tmpDir(") != null);
    try testing.expect(std.mem.find(u8, report.items, "src/wc.zig") != null);
}

test "multiline testing.tmpDir( is a hit" {
    const source =
        \\test "x" {
        \\    var tmp = testing.tmpDir(
        \\        .{},
        \\    );
        \\    _ = tmp;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/chmod.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "testing.tmpDir(") != null);
}

test "comment testing.tmpDir nests under .zig-cache is not a hit" {
    const source =
        \\// testing.tmpDir nests under .zig-cache
        \\const x = 1;
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/cat.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "setCurrentDir( in a comment is not a hit" {
    const source =
        \\// setCurrentDir( must not fire from a comment
        \\const x = 1;
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/cat.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "std.process.setCurrentDir(io, dir) is a hit" {
    const source =
        \\fn f() !void {
        \\    try std.process.setCurrentDir(io, dir);
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/cat.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "setCurrentDir(") != null);
}

test "Dir.cwd().createDir( in a test body is a hit" {
    const source =
        \\test "mkdir creates a directory" {
        \\    try std.Io.Dir.cwd().createDir(io, "d", .default_dir);
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/mkdir.zig", source, &report);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.find(u8, report.items, "Dir.cwd().createDir(") != null);
}

test "Dir.cwd().createDir( in fn removeDirectories is not a hit" {
    const source =
        \\fn removeDirectories() !void {
        \\    std.Io.Dir.cwd().createDir(io, "d", .default_dir) catch {};
        \\    std.Io.Dir.cwd().deleteDir(io, "d") catch {};
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/rmdir.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "Dir.cwd().openDir in a test body is not a hit" {
    const source =
        \\test "opens cwd" {
        \\    var d = try std.Io.Dir.cwd().openDir(io, "x", .{});
        \\    _ = d.statFile(io, "x") catch {};
        \\    _ = std.Io.Dir.cwd().access(io, "x", .{}) catch {};
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/chown.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "Threaded.chdir( is a hit" {
    const source =
        \\fn f() !void {
        \\    try std.Io.Threaded.chdir(io, dir);
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/pwd.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "Threaded.chdir(") != null);
}

test "mv wrapper inner: common.test_dir.TestDir is a hit" {
    const source =
        \\const TestDir = struct {
        \\    inner: common.test_dir.TestDir,
        \\};
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/mv.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, needle_mv) != null);
}

test "hasListedPath: date and common walker are out, ls paths are in" {
    try testing.expect(!hasListedPath("src/date.zig"));
    try testing.expect(hasListedPath("src/ls/main.zig"));
    try testing.expect(!hasListedPath("src/common/walker.zig"));
    try testing.expect(hasListedPath("src/ls/sorter.zig"));
    try testing.expect(hasListedPath("src/ls/types.zig"));
    try testing.expect(!hasListedPath("src/cp.zig"));
}

test "verifyTable: an empty listed table is a coverage error" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    try testing.expectError(
        Error.ListedTableEmpty,
        verifyTable(testing.allocator, testing.io, ".", &.{}, &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verifyTable: a table whose length is not 39 is a coverage error" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    const one = [_][]const u8{"src/cat.zig"};

    try testing.expectError(
        Error.ListedCountMismatch,
        verifyTable(testing.allocator, testing.io, ".", &one, &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verifyTable: more files than files_max is a coverage error" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    var table: [files_max + 1][]const u8 = undefined;
    for (&table) |*p| p.* = "src/cat.zig";

    try testing.expectError(
        Error.TooManyFiles,
        verifyTable(testing.allocator, testing.io, ".", &table, &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verify: a missing listed file is a coverage error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "common", .default_dir);

    var path_buf: [128]u8 = undefined;
    const parent = try tmpPath(&path_buf, &tmp);
    var common_buf: [160]u8 = undefined;
    const common_path = try std.fmt.bufPrint(
        &common_buf,
        "{s}/common",
        .{parent},
    );

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    try testing.expectError(
        Error.ListedPathMissing,
        verify(testing.allocator, testing.io, common_path, &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verify: a missing source directory is an error, never a silent pass" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    try testing.expectError(
        Error.SrcRootUnavailable,
        verify(
            testing.allocator,
            testing.io,
            "no/such/dir/testdir-lint",
            &report.writer,
        ),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verify: dirname of a bare name is SrcRootUnavailable" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    try testing.expectError(
        Error.SrcRootUnavailable,
        verify(testing.allocator, testing.io, "common", &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "scan: a tmpDir hit only in the last listed path is RED" {
    const clean = "const x = 1;\n";
    const dirty =
        \\test "only last path" {
        \\    var tmp = testing.tmpDir(.{});
        \\    _ = tmp;
        \\}
        \\
    ;
    var inputs: [listed_files_min]ScanInput = undefined;
    for (&inputs, listed_paths) |*slot, path| {
        slot.* = .{ .path = path, .source = clean };
    }
    inputs[listed_files_min - 1] = .{
        .path = listed_paths[listed_files_min - 1],
        .source = dirty,
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);
    const n = try scanInputs(testing.allocator, &inputs, &report);

    try testing.expect(n >= 1);
    try testing.expect(std.mem.find(u8, report.items, "src/ls/types.zig") != null);
    try testing.expect(std.mem.find(u8, report.items, "testing.tmpDir(") != null);
    try testing.expect(std.mem.find(u8, report.items, "src/cat.zig") == null);
    try testing.expect(std.mem.find(u8, report.items, "allowlisted") == null);
}

const grep_allowlisted_name =
    "walker-migration: recursive search with no operands searches the current directory";
const grep_test_prefix = "test \"" ++ grep_allowlisted_name ++ "\" {\n";

test "chdirToBase in an allowlisted body is clean" {
    const source = grep_test_prefix ++
        \\    const saved = try test_dir.chdirToBase();
        \\    _ = saved;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/grep.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
    try testing.expect(std.mem.find(u8, source, grep_allowlisted_name) != null);
}

test "chdirToBase outside an allowlisted body is RED" {
    const source = grep_test_prefix ++
        \\    const saved = try test_dir.chdirToBase();
        \\    _ = saved;
        \\}
        \\test "unrelated sandbox" {
        \\    const saved = try other.chdirToBase();
        \\    _ = saved;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/grep.zig", source, &report);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.find(u8, report.items, "outside allowlist") != null);
}

test "allowlisted body missing chdirToBase is RED" {
    const source = grep_test_prefix ++
        \\    const x = 1;
        \\    _ = x;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/grep.zig", source, &report);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.find(u8, report.items, "missing chdirToBase(") != null);
}

test "chdirToBase in rmdir remove-with-parents body is clean" {
    const source =
        \\test "rmdir: remove with parents" {
        \\    const saved = try test_dir.chdirToBase();
        \\    _ = saved;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/rmdir.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "rmdir remove-with-parents missing chdirToBase is RED" {
    const source =
        \\test "rmdir: remove with parents" {
        \\    const x = 1;
        \\    _ = x;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/rmdir.zig", source, &report);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.find(u8, report.items, "missing chdirToBase(") != null);
}

test "AclFixture.init with chdirToBase is clean" {
    const source =
        \\const AclFixture = struct {
        \\    fn init() !AclFixture {
        \\        const saved = try dir.chdirToBase();
        \\        _ = saved;
        \\        return undefined;
        \\    }
        \\};
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/ls/main.zig", source, &report);
    try testing.expectEqual(@as(u32, 0), n);
    try testing.expectEqualStrings("", report.items);
}

test "tmpDir hits skip the chdirToBase allowlist check" {
    const source = grep_test_prefix ++
        \\    var tmp = testing.tmpDir(.{});
        \\    _ = tmp;
        \\}
        \\
    ;
    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const n = try scanOne(testing.allocator, "src/grep.zig", source, &report);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expect(std.mem.find(u8, report.items, "testing.tmpDir(") != null);
    try testing.expect(std.mem.find(u8, report.items, "allowlisted") == null);
}

test "listed_paths last entry is src/ls/types.zig" {
    try testing.expectEqual(@as(usize, listed_files_min), listed_paths.len);
    try testing.expectEqualStrings("src/ls/types.zig", listed_paths[listed_paths.len - 1]);
}

test "every chdir allowlist path is in the listed table" {
    try testing.expectEqual(@as(usize, allowlist_len), chdir_allowlist.len);
    for (chdir_allowlist) |entry| {
        try testing.expect(hasListedPath(entry.path));
    }
}
