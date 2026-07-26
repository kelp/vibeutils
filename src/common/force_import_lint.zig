//! Build-gating lint: every `src/common` module that carries tests must appear
//! in `lib.zig`'s force-import block, or its tests silently never run.
//!
//! `zig test` collects tests only from the module under test, and within a
//! module only from files reachable from the root. A `pub const x =
//! @import("x.zig")` the test binary never references is not reached, so a
//! module's tests reach the binary only via an explicit `_ = @import("x.zig")`.
//! Three separate releases shipped with that wiring broken — path.zig (#51),
//! file_ops.zig (#81), and the 21 modules measured in #95 — because a dormant
//! test reports no failure and the suite looks green.
//!
//! The *logic* lives here but the *test* that calls `verify` deliberately lives
//! in `lib.zig`, which is the test root. If this file were ever dropped from
//! the force-import block, its own fixture tests would go dormant — but the
//! caller in `lib.zig` still runs and still fails. Do not "tidy" that test into
//! this module; doing so reopens the exact hole the lint exists to close.

const std = @import("std");
const assert = std.debug.assert;

/// A module deliberately absent from the force-import block, with the reason.
pub const Exemption = struct {
    name: []const u8,
    reason: []const u8,
};

/// Kept deliberately short. Every entry is a module whose tests reach a test
/// binary by some route other than `lib.zig`'s force-import block.
pub const default_exemptions = [_]Exemption{
    .{
        .name = "lib.zig",
        .reason = "is itself the test root",
    },
    .{
        .name = "privilege_test_integration.zig",
        .reason = "has its own root: build.zig step \"test-integration\"",
    },
};

/// Delimiters around the force-import block in `lib.zig`. Parsing between
/// explicit markers rather than scanning the whole file is what keeps an
/// `@import` elsewhere in `lib.zig` from being mistaken for a force-import.
pub const marker_begin = "// force-import-block-begin";
pub const marker_end = "// force-import-block-end";

/// Below this many modules or imports the scan is not believable, so it is
/// treated as a defect in the lint rather than a clean bill of health. A check
/// that passes because it inspected nothing is the failure mode #95 is about.
const modules_with_tests_min: u32 = 20;
const force_imports_min: u32 = 20;

/// Loop bounds. Tiger Style forbids unbounded iteration.
const files_max: u32 = 256;
const imports_max: u32 = 256;

pub const Error = error{
    /// One or more modules with tests are missing from the force-import block.
    ForceImportLintFailed,
    /// `lib.zig` has no force-import block delimiters, or they are inverted.
    ForceImportMarkersMissing,
    /// An `@import("` inside the block has no closing quote.
    MalformedImport,
    /// `src/common` could not be opened. Never downgraded to a silent pass.
    CommonSourceDirUnavailable,
    /// The scan found implausibly few modules; it inspected the wrong tree.
    SuspiciouslyFewModules,
    /// The parse found implausibly few imports; the block is malformed.
    SuspiciouslyFewImports,
    /// More files than the loop bound allows.
    TooManyFiles,
};

/// True when `source` declares at least one test at the top level.
///
/// Anchoring at column zero is what keeps `test "..."` inside a string
/// literal, a doc comment, or a `\\` multiline string from counting.
///
/// Known limitation: a module whose tests live *only* inside a struct or
/// nested container is indented, so this returns false and the module is not
/// required to be force-imported — meaning its tests could go dormant
/// undetected. No `src/common` module is in that shape today. Widening the
/// rule would trade this false negative for false positives on every string
/// and comment mentioning a test, which is the worse failure for a build gate.
pub fn hasTopLevelTest(source: []const u8) bool {
    assert(source.len < 1 << 24);

    var line_start: u32 = 0;
    var checked: u32 = 0;
    while (line_start < source.len) : (checked += 1) {
        assert(checked <= source.len);
        const rest = source[line_start..];
        if (startsTopLevelTest(rest)) return true;
        const nl = std.mem.findScalar(u8, rest, '\n') orelse return false;
        line_start += @intCast(nl + 1);
    }
    return false;
}

/// True when `line` begins a top-level test declaration.
fn startsTopLevelTest(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "test")) return false;
    if (line.len <= "test".len) return false;
    assert(line.len > "test".len);
    assert(std.mem.startsWith(u8, line, "test"));

    const next = line["test".len];
    return next == ' ' or next == '"' or next == '{';
}

/// Collect the basenames force-imported between the markers in `lib_source`.
///
/// Appends to `out`; the slices borrow from `lib_source`.
pub fn parseForceImports(
    gpa: std.mem.Allocator,
    lib_source: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    assert(lib_source.len > 0);
    assert(out.items.len == 0);

    const begin = std.mem.find(u8, lib_source, marker_begin) orelse
        return Error.ForceImportMarkersMissing;
    const end = std.mem.find(u8, lib_source, marker_end) orelse
        return Error.ForceImportMarkersMissing;
    if (end <= begin) return Error.ForceImportMarkersMissing;

    const block = lib_source[begin + marker_begin.len .. end];
    const needle = "@import(\"";

    var pos: u32 = 0;
    var found: u32 = 0;
    while (found < imports_max) : (found += 1) {
        const rel = std.mem.findPos(u8, block, pos, needle) orelse break;
        const name_start = rel + needle.len;
        const name_len = std.mem.findScalarPos(u8, block, name_start, '"') orelse
            return Error.MalformedImport;
        try out.append(gpa, block[name_start..name_len]);
        pos = @intCast(name_len + 1);
    }
    assert(found <= imports_max);
}

/// True when `name` is exempt from the force-import requirement.
pub fn isExempt(exemptions: []const Exemption, name: []const u8) bool {
    assert(name.len > 0);
    assert(exemptions.len > 0);

    for (exemptions) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// True when `haystack` contains `name`.
fn containsName(haystack: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    // `<=`, not `<`: parseForceImports appends up to and including imports_max
    // entries, so a full block is valid input rather than an assertion failure.
    assert(haystack.len <= imports_max);

    for (haystack) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return false;
}

/// Compare the two sets and append one report line per violation.
///
/// Returns the violation count. A module with tests that is neither imported
/// nor exempt is dormant. An exempt module that IS imported is a stale
/// exemption — reported so a leftover entry cannot mask a real omission later.
pub fn classify(
    gpa: std.mem.Allocator,
    imports: []const []const u8,
    modules_with_tests: []const []const u8,
    exemptions: []const Exemption,
    report: *std.ArrayListUnmanaged(u8),
) !u32 {
    assert(exemptions.len > 0);
    // `<=` for the same reason as containsName: collectModulesWithTests only
    // errors above files_max, so exactly files_max entries is legal input.
    assert(modules_with_tests.len <= files_max);

    var violations: u32 = 0;
    for (modules_with_tests) |name| {
        if (isExempt(exemptions, name)) continue;
        if (containsName(imports, name)) continue;
        violations += 1;
        try report.print(gpa, "  dormant: {s} has tests but is not " ++
            "force-imported by lib.zig\n", .{name});
    }
    for (exemptions) |e| {
        if (!containsName(imports, e.name)) continue;
        violations += 1;
        try report.print(gpa, "  stale exemption: {s} is exempt ({s}) " ++
            "yet appears in the force-import block\n", .{ e.name, e.reason });
    }
    assert(violations <= modules_with_tests.len + exemptions.len);
    return violations;
}

/// Run the lint against the real tree.
///
/// `common_dir_path` is injected by the build (`build_options`) rather than
/// resolved from cwd, so the lint cannot pass merely because it was run from
/// the wrong directory.
///
/// The violation report is written to `report_writer` rather than stderr so a
/// test that deliberately exercises the failure path can assert on its content
/// without spraying an alarming "violation" block across a passing CI log.
pub fn verify(
    gpa: std.mem.Allocator,
    io: std.Io,
    common_dir_path: []const u8,
    report_writer: *std.Io.Writer,
) !void {
    assert(common_dir_path.len > 0);
    assert(default_exemptions.len > 0);

    var dir = std.Io.Dir.cwd().openDir(io, common_dir_path, .{ .iterate = true }) catch
        return Error.CommonSourceDirUnavailable;
    defer dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lib_source = try dir.readFileAlloc(io, "lib.zig", arena, .limited(1 << 22));

    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    try parseForceImports(arena, lib_source, &imports);
    if (imports.items.len < force_imports_min) return Error.SuspiciouslyFewImports;

    var with_tests: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectModulesWithTests(arena, io, dir, &with_tests);
    if (with_tests.items.len < modules_with_tests_min) return Error.SuspiciouslyFewModules;

    var report: std.ArrayListUnmanaged(u8) = .empty;
    const violations = try classify(
        arena,
        imports.items,
        with_tests.items,
        &default_exemptions,
        &report,
    );
    if (violations == 0) return;

    try report_writer.print(
        "\nIssue #95 violation - dormant tests in src/common:\n{s}\n" ++
            "Add the missing `_ = @import(\"<name>\");` to the force-import " ++
            "block in src/common/lib.zig.\n",
        .{report.items},
    );
    return Error.ForceImportLintFailed;
}

/// Append the basename of every `.zig` file under `dir` that declares tests.
fn collectModulesWithTests(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    assert(out.items.len == 0);

    var it = dir.iterate();
    var seen: u32 = 0;
    while (try it.next(io)) |entry| {
        seen += 1;
        if (seen > files_max) return Error.TooManyFiles;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const name = try arena.dupe(u8, entry.name);
        // Deliberately NOT `catch continue`: an unreadable source file must
        // fail the lint, not quietly shrink its scope.
        const source = try dir.readFileAlloc(io, name, arena, .limited(1 << 22));
        if (hasTopLevelTest(source)) try out.append(arena, name);
    }
    assert(seen <= files_max);
}

// ---------------------------------------------------------------------------
// Tests
//
// Authored separately from the implementation above, per the CLAUDE.md rule
// that the writer of a fix must never author the test that guards it.
//
// Fixture sources are built with `++` from `marker_begin` / `marker_end` so a
// rename of the markers cannot leave these tests silently testing nothing —
// the same dormancy failure mode the module itself exists to prevent.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Exemption set used by the `classify` tests. Deliberately not
/// `default_exemptions`: the tests must pin the comparison logic, not the
/// current contents of the project's exemption list.
const test_exemptions = [_]Exemption{
    .{ .name = "root.zig", .reason = "is itself the test root" },
};

test "hasTopLevelTest: accepts a named top-level test" {
    const source =
        \\const std = @import("std");
        \\
        \\test "adds two numbers" {
        \\    try std.testing.expect(true);
        \\}
        \\
    ;
    try testing.expect(hasTopLevelTest(source));
}

test "hasTopLevelTest: accepts a bare top-level test" {
    const source =
        \\const std = @import("std");
        \\
        \\test {
        \\    _ = @import("other.zig");
        \\}
        \\
    ;
    try testing.expect(hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects an indented test declaration" {
    const source =
        \\const Wrapper = struct {
        \\    test "not at the top level" {
        \\        unreachable;
        \\    }
        \\};
        \\
    ;
    try testing.expect(!hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects a test inside a string literal" {
    const source =
        \\const s = "test \"x\" {";
        \\const t = 1;
        \\
    ;
    try testing.expect(!hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects a test inside a multiline string" {
    const source =
        \\const fixture =
        \\    \\test "x" {
        \\    \\}
        \\;
        \\
    ;
    try testing.expect(!hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects a test named in a comment" {
    const source =
        \\/// test "x" {
        \\pub const a = 1;
        \\// test "y" {
        \\
    ;
    try testing.expect(!hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects sources with no tests at all" {
    try testing.expect(!hasTopLevelTest(""));
    try testing.expect(!hasTopLevelTest("\n"));
    try testing.expect(!hasTopLevelTest("\n\n\n"));
    try testing.expect(!hasTopLevelTest("pub fn f() void {}\n"));
}

test "hasTopLevelTest: finds a test at offset zero" {
    try testing.expect(hasTopLevelTest("test \"first line\" {\n}\n"));
    try testing.expect(hasTopLevelTest("test {\n}\n"));
}

test "hasTopLevelTest: finds a test on an unterminated last line" {
    const source =
        \\const a = 1;
        \\test "last line, no trailing newline" {
    ;
    try testing.expect(!std.mem.endsWith(u8, source, "\n"));
    try testing.expect(hasTopLevelTest(source));
}

test "hasTopLevelTest: rejects identifiers that merely start with test" {
    try testing.expect(!hasTopLevelTest("testing.foo();\n"));
    try testing.expect(!hasTopLevelTest("test_helper();\n"));
    try testing.expect(!hasTopLevelTest("tests();\n"));
    try testing.expect(!hasTopLevelTest("testFn();\n"));
    try testing.expect(!hasTopLevelTest("test(x);\n"));
}

test "hasTopLevelTest: keeps scanning past decoy lines" {
    const source =
        \\    test "indented" {}
        \\// test "commented out" {}
        \\const s = "test \"quoted\" {";
        \\test "the real one" {}
        \\
    ;
    try testing.expect(hasTopLevelTest(source));
}

test "parseForceImports: collects exactly the names between the markers" {
    const source = "const std = @import(\"std\");\n" ++
        marker_begin ++ "\n" ++
        "comptime {\n" ++
        "    _ = @import(\"alpha.zig\");\n" ++
        "    _ = @import(\"beta.zig\");\n" ++
        "}\n" ++
        marker_end ++ "\n";

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    try parseForceImports(testing.allocator, source, &out);

    try testing.expectEqual(2, out.items.len);
    try testing.expectEqualStrings("alpha.zig", out.items[0]);
    try testing.expectEqualStrings("beta.zig", out.items[1]);
}

test "parseForceImports: ignores @import outside the markers" {
    const source = "pub const a = @import(\"decoy_before.zig\");\n" ++
        marker_begin ++ "\n" ++
        "    _ = @import(\"alpha.zig\");\n" ++
        marker_end ++ "\n" ++
        "pub const b = @import(\"decoy_after.zig\");\n";

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    try parseForceImports(testing.allocator, source, &out);

    try testing.expectEqual(1, out.items.len);
    try testing.expect(containsName(out.items, "alpha.zig"));
    try testing.expect(!containsName(out.items, "decoy_before.zig"));
    try testing.expect(!containsName(out.items, "decoy_after.zig"));
}

test "parseForceImports: an empty block yields no imports" {
    const source = "const a = 1;\n" ++ marker_begin ++ "\n" ++ marker_end ++ "\n";

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    try parseForceImports(testing.allocator, source, &out);

    try testing.expectEqual(0, out.items.len);
}

test "parseForceImports: a missing begin marker is an error" {
    const source = "_ = @import(\"a.zig\");\n" ++ marker_end ++ "\n";
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    try testing.expectError(
        Error.ForceImportMarkersMissing,
        parseForceImports(testing.allocator, source, &out),
    );
    try testing.expectEqual(0, out.items.len);
}

test "parseForceImports: a missing end marker is an error" {
    const source = marker_begin ++ "\n_ = @import(\"a.zig\");\n";
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    try testing.expectError(
        Error.ForceImportMarkersMissing,
        parseForceImports(testing.allocator, source, &out),
    );
    try testing.expectEqual(0, out.items.len);
}

test "parseForceImports: an inverted marker order is an error" {
    const source = marker_end ++ "\n_ = @import(\"a.zig\");\n" ++ marker_begin ++ "\n";
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    try testing.expectError(
        Error.ForceImportMarkersMissing,
        parseForceImports(testing.allocator, source, &out),
    );
    try testing.expectEqual(0, out.items.len);
}

test "parseForceImports: an unterminated import name is an error" {
    const source = marker_begin ++ "\n    _ = @import(\"a.zig\n" ++ marker_end ++ "\n";
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    // Distinct from ForceImportMarkersMissing: the markers are present and
    // correctly ordered here; it is the import inside them that is malformed.
    try testing.expectError(
        Error.MalformedImport,
        parseForceImports(testing.allocator, source, &out),
    );
    try testing.expectEqual(0, out.items.len);
}

test "isExempt: matches listed names and nothing else" {
    try testing.expect(isExempt(&default_exemptions, "lib.zig"));
    try testing.expect(isExempt(&default_exemptions, "privilege_test_integration.zig"));
    try testing.expect(!isExempt(&default_exemptions, "style.zig"));
    try testing.expect(!isExempt(&default_exemptions, "lib.zig.bak"));
    try testing.expect(!isExempt(&default_exemptions, "lib"));
}

test "classify: a module with tests absent from the imports is a violation" {
    const imports = [_][]const u8{"alpha.zig"};
    const with_tests = [_][]const u8{ "alpha.zig", "beta.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const violations = try classify(
        testing.allocator,
        &imports,
        &with_tests,
        &test_exemptions,
        &report,
    );

    try testing.expectEqual(1, violations);
    try testing.expect(std.mem.find(u8, report.items, "dormant") != null);
    try testing.expect(std.mem.find(u8, report.items, "beta.zig") != null);
    try testing.expect(std.mem.find(u8, report.items, "alpha.zig") == null);
}

test "classify: a fully imported set has no violations" {
    const imports = [_][]const u8{ "alpha.zig", "beta.zig" };
    const with_tests = [_][]const u8{ "alpha.zig", "beta.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const violations = try classify(
        testing.allocator,
        &imports,
        &with_tests,
        &test_exemptions,
        &report,
    );

    try testing.expectEqual(0, violations);
    try testing.expectEqualStrings("", report.items);
}

test "classify: an exempt module correctly absent from imports is clean" {
    const imports = [_][]const u8{"alpha.zig"};
    const with_tests = [_][]const u8{ "alpha.zig", "root.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const violations = try classify(
        testing.allocator,
        &imports,
        &with_tests,
        &test_exemptions,
        &report,
    );

    try testing.expectEqual(0, violations);
    try testing.expectEqualStrings("", report.items);
}

test "classify: a stale exemption is a violation" {
    // "root.zig" is exempt, yet it appears in the force-import block. A
    // leftover exemption must not silently become a permanent blind spot.
    const imports = [_][]const u8{ "alpha.zig", "root.zig" };
    const with_tests = [_][]const u8{ "alpha.zig", "root.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const violations = try classify(
        testing.allocator,
        &imports,
        &with_tests,
        &test_exemptions,
        &report,
    );

    try testing.expectEqual(1, violations);
    try testing.expect(std.mem.find(u8, report.items, "stale exemption") != null);
    try testing.expect(std.mem.find(u8, report.items, "root.zig") != null);
    try testing.expect(std.mem.find(u8, report.items, "is itself the test root") != null);
}

test "classify: multiple violations accumulate and each is named" {
    const imports = [_][]const u8{ "alpha.zig", "root.zig" };
    const with_tests = [_][]const u8{
        "alpha.zig",
        "beta.zig",
        "gamma.zig",
        "root.zig",
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    defer report.deinit(testing.allocator);

    const violations = try classify(
        testing.allocator,
        &imports,
        &with_tests,
        &test_exemptions,
        &report,
    );

    try testing.expectEqual(3, violations);
    try testing.expect(std.mem.find(u8, report.items, "beta.zig") != null);
    try testing.expect(std.mem.find(u8, report.items, "gamma.zig") != null);
    try testing.expect(std.mem.find(u8, report.items, "stale exemption") != null);
}

/// Number of synthetic modules the `verify` fixtures write. Chosen above every
/// plausibility floor in this module so a fixture result reflects the set
/// comparison, not a too-small tree.
const fixture_modules: u32 = 25;

/// Write a fake `src/common` into `dir`: `module_count` modules that each
/// carry a top-level test, plus a `lib.zig` whose marker block force-imports
/// the first `import_count` of them.
fn writeFixtureTree(
    io: std.Io,
    dir: std.Io.Dir,
    module_count: u32,
    import_count: u32,
) !void {
    assert(module_count <= 99);
    assert(import_count <= module_count);

    var name_buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < module_count) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "m{d:0>2}.zig", .{i});
        try dir.writeFile(io, .{
            .sub_path = name,
            .data = "test \"fixture\" {}\n",
        });
    }
    assert(i == module_count);

    var lib: std.ArrayListUnmanaged(u8) = .empty;
    defer lib.deinit(testing.allocator);
    // The fixture root carries a test of its own so the "lib.zig is exempt"
    // path is exercised rather than skipped for want of a test.
    try lib.appendSlice(testing.allocator, "test \"fixture root\" {}\n");
    try lib.appendSlice(testing.allocator, marker_begin ++ "\n");
    var j: u32 = 0;
    while (j < import_count) : (j += 1) {
        try lib.print(testing.allocator, "    _ = @import(\"m{d:0>2}.zig\");\n", .{j});
    }
    assert(j == import_count);
    try lib.appendSlice(testing.allocator, marker_end ++ "\n");
    try dir.writeFile(io, .{ .sub_path = "lib.zig", .data = lib.items });
}

/// Render the cwd-relative path of a `std.testing.tmpDir` into `buf`.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    assert(buf.len >= 64);
    assert(tmp.sub_path.len > 0);
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "verify: a missing source directory is an error, never a silent pass" {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    try testing.expectError(
        Error.CommonSourceDirUnavailable,
        verify(testing.allocator, testing.io, "no/such/dir/issue-95", &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verify: a fully wired tree passes silently" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtureTree(testing.io, tmp.dir, fixture_modules, fixture_modules);

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp);
    try verify(testing.allocator, testing.io, path, &report.writer);

    // A clean run must say nothing at all. A lint that chatters on success
    // trains its readers to ignore it.
    try testing.expectEqualStrings("", report.written());
}

test "verify: a tree with a dormant module reports it by name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtureTree(testing.io, tmp.dir, fixture_modules, fixture_modules - 1);

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp);
    try testing.expectError(
        Error.ForceImportLintFailed,
        verify(testing.allocator, testing.io, path, &report.writer),
    );

    // writeFixtureTree omits exactly the highest-numbered module.
    var name_buf: [16]u8 = undefined;
    const dormant = try std.fmt.bufPrint(&name_buf, "m{d:0>2}.zig", .{fixture_modules - 1});
    const written = report.written();
    try testing.expect(std.mem.find(u8, written, "dormant") != null);
    try testing.expect(std.mem.find(u8, written, dormant) != null);
    try testing.expect(std.mem.find(u8, written, "Issue #95") != null);
    // The imported modules must not be blamed alongside the dormant one.
    try testing.expect(std.mem.find(u8, written, "m00.zig") == null);
}

test "verify: an implausibly small import block is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtureTree(testing.io, tmp.dir, 5, 5);

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp);
    try testing.expectError(
        Error.SuspiciouslyFewImports,
        verify(testing.allocator, testing.io, path, &report.writer),
    );
    try testing.expectEqualStrings("", report.written());
}

test "verify: an existing directory without lib.zig is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp);
    if (verify(testing.allocator, testing.io, path, &report.writer)) |_| {
        return error.VerifyPassedVacuously;
    } else |_| {}
    try testing.expectEqualStrings("", report.written());
}
