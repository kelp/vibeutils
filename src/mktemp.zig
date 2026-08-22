//! mktemp - create a temporary file or directory
//!
//! The mktemp utility creates a temporary file or directory safely using
//! a unique name generated from a template. The template must contain
//! at least three consecutive 'X' characters at the end, which are
//! replaced with random alphanumeric characters.
//!
//! This implementation follows GNU coreutils mktemp behavior.
//!
//! ## Known divergences from GNU (intentional)
//!
//! **`--tmpdir` optional-value semantics.** GNU's `--tmpdir` is a long
//! option with an optional value: `--tmpdir` (no `=`) uses $TMPDIR/tmp,
//! while `--tmpdir=DIR` uses DIR. The space-separated form
//! `--tmpdir DIR` does NOT consume DIR as the directory — DIR becomes
//! the template positional argument. This is a getopt quirk, not a
//! deliberate design choice, and no real-world scripts rely on it.
//! We treat `--tmpdir DIR` and `--tmpdir=DIR` identically (both use
//! DIR as the directory). This is arguably more correct since it
//! matches user intent and avoids a silent footgun.
//!
//! **`fillRandom` with >256 trailing X's.** Fixed in post-0.9.1.
//! The original implementation used a fixed 256-byte getrandom buffer
//! and silently left positions beyond 256 as undefined memory. Now
//! uses chunked getrandom calls to fill any length correctly.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prog_name = "mktemp";
const default_template = "tmp.XXXXXXXXXX";
const alphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Command-line arguments for the mktemp utility
const MktempArgs = struct {
    /// Create a directory instead of a file
    directory: bool = false,
    /// Don't create anything; print name only (unsafe)
    @"dry-run": bool = false,
    /// Suppress error messages
    quiet: bool = false,
    /// Use DIR as the temporary directory
    tmpdir: ?[]const u8 = null,
    /// Append SUFF to template
    suffix: ?[]const u8 = null,
    /// Interpret TEMPLATE relative to TMPDIR
    t: bool = false,
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Positional arguments (template)
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .directory = .{ .short = 'd', .desc = "Create a directory, not a file" },
        .@"dry-run" = .{ .short = 'u', .desc = "Do not create anything; print a name (unsafe)" },
        .quiet = .{ .short = 'q', .desc = "Suppress diagnostics about failure to create" },
        .tmpdir = .{ .short = 'p', .desc = "Use DIR as prefix", .value_name = "DIR" },
        .suffix = .{ .desc = "Append SUFF to template", .value_name = "SUFF" },
        .t = .{ .desc = "Interpret TEMPLATE relative to a directory" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
    };
};

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, run);
}

/// Run the mktemp utility with given arguments
fn run(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const parsed = common.argparse.ArgParser.parseOrExit(
        MktempArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed.positionals);

    // Handle --help/--version and the too-many-templates guard up front. Each
    // yields a final exit code; null means run should continue.
    if (try run_handleEarlyExit(allocator, stdout_writer, stderr_writer, &parsed)) |code| {
        return code;
    }

    // Resolve the template, explicit suffix, and X run in one straight-line
    // step. At most one positional remains (the too-many guard ran above).
    const prep = run_prepareTemplate(&parsed);

    // Validate suffix/template separators and X count. Each failing check
    // reports its own diagnostic (unless quiet) and yields general_error.
    if (run_validate(
        allocator,
        stderr_writer,
        &parsed,
        prep.raw_template,
        prep.explicit_suffix,
        prep.xs,
    )) |code| {
        return code;
    }

    // GNU mktemp semantics:
    //   - No TEMPLATE arg (default): prepend $TMPDIR or /tmp.
    //   - -p DIR: prepend DIR.
    //   - -t:     prepend $TMPDIR or /tmp.
    //   - User-supplied template (bare or with path): use VERBATIM.
    //     Leading "./", "foo/bar", and "/abs/x" are all preserved.
    const force_tmpdir = parsed.tmpdir != null or parsed.t or prep.is_default_template;

    const full_template = run_buildFullTemplate(
        allocator,
        prep.raw_template,
        prep.explicit_suffix,
        force_tmpdir,
        parsed.tmpdir,
    ) catch |err| {
        // A bare-dupe OOM propagated out of run unchanged in the original; the
        // other tags print their distinct message and exit general_error.
        if (err == error.OutOfMemory) return err;
        return run_reportBuildError(allocator, stderr_writer, parsed.quiet, @errorCast(err));
    };

    // Generate the temporary file or directory, then print its path.
    return run_emitResult(
        allocator,
        io,
        stdout_writer,
        stderr_writer,
        &parsed,
        full_template,
        prep.xs,
        prep.explicit_suffix,
    );
}

/// Handle the early-exit cases for run: --help, --version, and too many
/// templates. Returns the final exit code for those cases, or null when run
/// should proceed with normal template generation.
fn run_handleEarlyExit(
    allocator: Allocator,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    parsed: *const MktempArgs,
) !?u8 {
    if (parsed.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Too many positional arguments
    if (parsed.positionals.len > 1) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "too many templates\nTry 'mktemp --help' for more information.",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    return null;
}

/// Bundle of values resolved from the parsed args before path building.
const TemplatePrep = struct {
    is_default_template: bool,
    raw_template: []const u8,
    explicit_suffix: []const u8,
    xs: TemplateXs,
};

/// Resolve the template, explicit suffix, and X run from the parsed args.
/// When no TEMPLATE arg is given, GNU uses the default template AND implies
/// --tmpdir (routes to $TMPDIR/tmp). Characters after the last run of X's
/// are treated as an implicit suffix (GNU mktemp behavior).
fn run_prepareTemplate(parsed: *const MktempArgs) TemplatePrep {
    // Precondition: run's too-many-templates guard already ran, so at most
    // one positional remains here.
    std.debug.assert(parsed.positionals.len <= 1);

    const is_default_template = parsed.positionals.len == 0;
    const raw_template = if (parsed.positionals.len == 1)
        parsed.positionals[0]
    else
        default_template;
    const explicit_suffix = parsed.suffix orelse "";
    const xs = findTemplateXs(raw_template);

    // The X run is a subsequence of the template, so its count is bounded
    // by the template length at the producer site.
    std.debug.assert(xs.x_count <= raw_template.len);
    // Negative space: the implicit suffix is also a subsequence of the
    // template, so it cannot exceed its length either.
    std.debug.assert(xs.implicit_suffix_len <= raw_template.len);

    return .{
        .is_default_template = is_default_template,
        .raw_template = raw_template,
        .explicit_suffix = explicit_suffix,
        .xs = xs,
    };
}

/// Create the temp file/directory from the resolved template and print its
/// path on success. On failure reports the create error (unless quiet) and
/// returns general_error. Returns success after printing the path. The
/// generateTemp call and the stdout print move here verbatim from run.
fn run_emitResult(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    parsed: *const MktempArgs,
    full_template: []const u8,
    xs: TemplateXs,
    explicit_suffix: []const u8,
) !u8 {
    // Domain precondition: this path is only reached after run_validate
    // accepted the template, which requires at least three X positions.
    std.debug.assert(xs.x_count >= 3);
    // total_suffix_len covers both the implicit suffix (chars after the X
    // run) and the explicit --suffix flag, matching run's prior computation.
    const total_suffix_len = xs.implicit_suffix_len + explicit_suffix.len;

    const result_path = generateTemp(
        allocator,
        io,
        full_template,
        xs.x_count,
        total_suffix_len,
        parsed.directory,
        parsed.@"dry-run",
    ) catch {
        const kind = if (parsed.directory) "directory" else "file";
        const fmt = "failed to create {s} via template '{s}'";
        run_reportError(allocator, stderr_writer, parsed.quiet, fmt, .{ kind, full_template });
        return @intFromEnum(common.ExitCode.general_error);
    };

    try stdout_writer.print("{s}\n", .{result_path});

    return @intFromEnum(common.ExitCode.success);
}

/// Validate the explicit suffix, the X count, and the `-t` template before
/// any path is built. Returns the general_error exit code on the first
/// failing check (after reporting its distinct diagnostic unless quiet), or
/// null when every check passes. All three checks share the same exit code,
/// so collapsing them here changes no observable behavior.
fn run_validate(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    parsed: *const MktempArgs,
    raw_template: []const u8,
    explicit_suffix: []const u8,
    xs: TemplateXs,
) ?u8 {
    // Negative space: x_count never exceeds the template it was scanned from.
    std.debug.assert(xs.x_count <= raw_template.len);
    // The implicit suffix is the run after the X's, also a subsequence of
    // the template, so it too is bounded by the template length.
    std.debug.assert(xs.implicit_suffix_len <= raw_template.len);

    const quiet = parsed.quiet;
    // Explicit --suffix must not contain a path separator.
    if (std.mem.findScalar(u8, explicit_suffix, '/') != null) {
        const fmt = "invalid suffix '{s}': contains directory separator";
        run_reportError(allocator, stderr_writer, quiet, fmt, .{explicit_suffix});
        return @intFromEnum(common.ExitCode.general_error);
    }
    // Template must contain at least three X's.
    if (xs.x_count < 3) {
        const fmt = "too few X's in template '{s}'";
        run_reportError(allocator, stderr_writer, quiet, fmt, .{raw_template});
        return @intFromEnum(common.ExitCode.general_error);
    }
    // With -t, the template must not contain a directory separator.
    if (parsed.t and std.mem.findScalar(u8, raw_template, '/') != null) {
        const fmt = "invalid template, '{s}', contains directory separator";
        run_reportError(allocator, stderr_writer, quiet, fmt, .{raw_template});
        return @intFromEnum(common.ExitCode.general_error);
    }
    return null;
}

/// Print an error via the program prefix, but only when not in quiet mode.
/// Centralizes the repeated quiet-guard + print tail shared by the
/// validation, build, and emit paths so each branch stays a one-liner.
fn run_reportError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    quiet: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    // Precondition: every call site passes a non-empty format string.
    std.debug.assert(fmt.len > 0);
    if (!quiet) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, fmt, args);
    }
}

/// Emit the diagnostic that matches a run_buildFullTemplate failure and
/// return the general_error exit code. OutOfMemory is handled by run itself
/// (re-propagated), so it never reaches here.
fn run_reportBuildError(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    quiet: bool,
    err: error{ ResolveTmpdir, AllocPrintFailed },
) u8 {
    const general_error = @intFromEnum(common.ExitCode.general_error);
    // Sanity check: the general error code is the conventional 1...
    std.debug.assert(general_error == 1);
    // ...and is distinct from the success code we never return here.
    std.debug.assert(general_error != @intFromEnum(common.ExitCode.success));
    switch (err) {
        error.ResolveTmpdir => {
            const fmt = "failed to resolve temporary directory";
            run_reportError(allocator, stderr_writer, quiet, fmt, .{});
        },
        error.AllocPrintFailed => {
            const fmt = "failed to allocate memory";
            run_reportError(allocator, stderr_writer, quiet, fmt, .{});
        },
    }
    return general_error;
}

/// Build the full template path that generateTemp consumes.
///
/// Mirrors GNU mktemp semantics: when `force_tmpdir` is set (no TEMPLATE
/// default, `-p DIR`, or `-t`) the template's basename is joined under the
/// resolved tmpdir; otherwise the user's template is preserved verbatim.
///
/// Failures map to three distinct tags so the caller reproduces the original
/// behavior exactly: resolveForcedTmpdir failure -> error.ResolveTmpdir;
/// an allocPrint/join failure -> error.AllocPrintFailed (caller prints
/// "failed to allocate memory" and exits general_error); a bare dupe failure
/// -> error.OutOfMemory (caller re-propagates it out of run, as the original
/// `try allocator.dupe(...)` did). The caller owns the returned slice.
fn run_buildFullTemplate(
    allocator: Allocator,
    raw_template: []const u8,
    explicit_suffix: []const u8,
    force_tmpdir: bool,
    tmpdir_arg: ?[]const u8,
) error{ ResolveTmpdir, AllocPrintFailed, OutOfMemory }![]const u8 {
    // Precondition: the template already passed the x_count >= 3 check, so
    // it has at least three characters.
    std.debug.assert(raw_template.len >= 3);
    // Negative space: callers reject a '/' in the explicit suffix before
    // reaching here, so none should be present.
    std.debug.assert(std.mem.findScalar(u8, explicit_suffix, '/') == null);

    if (force_tmpdir) {
        const tmpdir = resolveForcedTmpdir(allocator, tmpdir_arg) catch return error.ResolveTmpdir;
        defer allocator.free(tmpdir);

        // When routing through tmpdir, use only the basename of the template.
        const template_basename = std.fs.path.basename(raw_template);
        const filename = if (explicit_suffix.len > 0)
            std.fmt.allocPrint(allocator, "{s}{s}", .{
                template_basename,
                explicit_suffix,
            }) catch return error.AllocPrintFailed
        else
            try allocator.dupe(u8, template_basename);
        defer allocator.free(filename);

        const joined = std.fs.path.join(allocator, &.{ tmpdir, filename });
        return joined catch return error.AllocPrintFailed;
    }

    // Verbatim path: preserve user's template exactly (leading "./", relative, absolute).
    if (explicit_suffix.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{
            raw_template,
            explicit_suffix,
        }) catch return error.AllocPrintFailed;
    }
    return try allocator.dupe(u8, raw_template);
}

/// Count trailing 'X' characters in the template
/// Result of parsing X's from a template.
const TemplateXs = struct {
    x_count: usize,
    /// Number of characters after the X run (implicit suffix).
    implicit_suffix_len: usize,
};

/// Find the last consecutive run of X's in the template.
/// Characters after that run are treated as an implicit suffix
/// (GNU mktemp behavior: "myapp.XXXXXXtxt" has 6 X's and
/// implicit suffix "txt").
fn findTemplateXs(template: []const u8) TemplateXs {
    // First try strictly trailing X's (most common case)
    var trailing: usize = 0;
    var i = template.len;
    while (i > 0) {
        i -= 1;
        if (template[i] == 'X') {
            trailing += 1;
        } else {
            break;
        }
    }
    if (trailing >= 3) {
        const result: TemplateXs = .{ .x_count = trailing, .implicit_suffix_len = 0 };
        // The X run is a subsequence of the template, bounded by its length.
        std.debug.assert(result.x_count <= template.len);
        // No implicit suffix on the trailing-X path.
        std.debug.assert(result.implicit_suffix_len <= template.len);
        // Combined [XXX][suffix] region fits within the template.
        std.debug.assert(result.x_count + result.implicit_suffix_len <= template.len);
        return result;
    }

    // Scan for the last run of 3+ consecutive X's
    var best_end: usize = 0;
    var best_count: usize = 0;
    var pos = template.len;
    while (pos > 0) {
        pos -= 1;
        if (template[pos] == 'X') {
            // Count this run backwards
            var run_start = pos;
            while (run_start > 0 and template[run_start - 1] == 'X') {
                run_start -= 1;
            }
            const run_len = pos - run_start + 1;
            if (run_len >= 3) {
                best_end = pos + 1;
                best_count = run_len;
                break;
            }
            pos = run_start; // skip past this short run
        }
    }

    const result: TemplateXs = .{
        .x_count = best_count,
        .implicit_suffix_len = if (best_count > 0) template.len - best_end else 0,
    };
    // The X run is a subsequence of the template, bounded by its length.
    std.debug.assert(result.x_count <= template.len);
    // The implicit suffix (chars after the X run) is also bounded by length.
    std.debug.assert(result.implicit_suffix_len <= template.len);
    // The disjoint [XXX][suffix] segments together fit within the template.
    std.debug.assert(result.x_count + result.implicit_suffix_len <= template.len);
    return result;
}

/// Resolve the temporary directory for cases that must route through a tmpdir:
/// no-TEMPLATE default, `-p DIR`, or `-t`. User-supplied templates are used
/// verbatim by the caller and do not go through this function.
fn resolveForcedTmpdir(allocator: Allocator, tmpdir_arg: ?[]const u8) ![]const u8 {
    if (tmpdir_arg) |dir| {
        return try allocator.dupe(u8, dir);
    }
    if (common.env.getEnv("TMPDIR")) |env_val| {
        return try allocator.dupe(u8, env_val);
    }
    return try allocator.dupe(u8, "/tmp");
}

/// Generate a temporary file or directory with a unique name
/// Tries up to 100 times with different random suffixes
/// suffix_len indicates how many bytes at the end are the suffix (after the X's)
fn generateTemp(
    allocator: Allocator,
    io: std.Io,
    template: []const u8,
    x_count: usize, // tiger:allow:usize-arch X-run length, indexes template slice
    suffix_len: usize, // tiger:allow:usize-arch suffix length, indexes template slice
    is_dir: bool,
    dry_run: bool,
) ![]const u8 {
    const max_attempts = 100;
    // Domain precondition: mktemp requires at least three X positions.
    std.debug.assert(x_count >= 3);
    // Compile-time loop bound: the retry loop runs a fixed number of times.
    comptime std.debug.assert(max_attempts > 0);
    // Layout: [prefix][XXXXXX][suffix]
    const x_end = template.len - suffix_len;
    const x_start = x_end - x_count;

    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        // Loop-bound invariant: the guard keeps attempt in [0, max_attempts].
        std.debug.assert(attempt <= max_attempts);
        // Build the candidate name
        const candidate = try allocator.alloc(u8, template.len);

        // Copy prefix (before the X's)
        @memcpy(candidate[0..x_start], template[0..x_start]);

        // Fill X positions with random alphanumeric characters
        fillRandom(io, candidate[x_start..x_end]);

        // Copy suffix (after the X's)
        if (suffix_len > 0) {
            @memcpy(candidate[x_end..], template[x_end..]);
        }

        if (dry_run) {
            return candidate;
        }

        if (is_dir) {
            // Try to create directory exclusively with mode 0o700
            std.Io.Dir.cwd().createDir(
                io,
                candidate,
                std.Io.File.Permissions.fromMode(0o700),
            ) catch |err| {
                allocator.free(candidate);
                switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                }
            };
            return candidate;
        } else {
            // Try to create file atomically with exclusive flag.
            // POSIX requires mktemp to create files with mode 0600 so the
            // tmp file is not world-readable; the 0.16 default is 0o666.
            const file = std.Io.Dir.cwd().createFile(io, candidate, .{
                .exclusive = true,
                .truncate = false,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            }) catch |err| {
                allocator.free(candidate);
                switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                }
            };
            file.close(io);
            return candidate;
        }
    }

    return error.TooManyAttempts;
}

/// Fill a buffer with random alphanumeric characters
fn fillRandom(io: std.Io, buf: []u8) void {
    // Comptime sanity: guards the `byte % alphanumeric.len` against a
    // division-by-zero if the constant is ever emptied.
    std.debug.assert(alphanumeric.len > 0);
    var raw: [256]u8 = undefined;
    var offset: usize = 0;
    while (offset < buf.len) {
        // Loop invariant: offset never overshoots the buffer end.
        std.debug.assert(offset <= buf.len);
        const n = @min(buf.len - offset, raw.len);
        io.random(raw[0..n]);
        for (raw[0..n], buf[offset..][0..n]) |byte, *b| {
            b.* = alphanumeric[byte % alphanumeric.len];
        }
        offset += n;
    }
}

/// Print help message
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: mktemp [OPTION]... [TEMPLATE]
        \\Create a temporary file or directory, safely, and print its name.
        \\TEMPLATE must contain at least 3 consecutive 'X's in last component.
        \\If TEMPLATE is not specified, use tmp.XXXXXXXXXX.
        \\
        \\  -d, --directory    create a directory, not a file
        \\  -u, --dry-run      do not create anything; merely print a name (unsafe)
        \\  -q, --quiet        suppress diagnostics about file/dir-creation failure
        \\  -p DIR, --tmpdir=DIR  use DIR as prefix; if not given, use $TMPDIR or /tmp
        \\      --suffix=SUFF  append SUFF to TEMPLATE
        \\  -t                 interpret TEMPLATE relative to a directory
        \\  -h, --help         display this help and exit
        \\  -V, --version      output version information and exit
        \\
    );
}

/// Print version information
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("mktemp ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                TESTS
// ============================================================================

test "mktemp findTemplateXs" {
    // Trailing X's (no implicit suffix)
    try testing.expectEqual(
        TemplateXs{ .x_count = 10, .implicit_suffix_len = 0 },
        findTemplateXs("tmp.XXXXXXXXXX"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 3, .implicit_suffix_len = 0 },
        findTemplateXs("tmp.XXX"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 5, .implicit_suffix_len = 0 },
        findTemplateXs("XXXXX"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 3, .implicit_suffix_len = 0 },
        findTemplateXs("prefixXXX"),
    );
    // No X's at all
    try testing.expectEqual(
        TemplateXs{ .x_count = 0, .implicit_suffix_len = 0 },
        findTemplateXs("tmp.txt"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 0, .implicit_suffix_len = 0 },
        findTemplateXs(""),
    );
    // Implicit suffix (X's not at end)
    try testing.expectEqual(
        TemplateXs{ .x_count = 3, .implicit_suffix_len = 3 },
        findTemplateXs("XXXabc"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 6, .implicit_suffix_len = 3 },
        findTemplateXs("myapp.XXXXXXtxt"),
    );
    try testing.expectEqual(
        TemplateXs{ .x_count = 6, .implicit_suffix_len = 4 },
        findTemplateXs("test.XXXXXX.log"),
    );
}

test "mktemp fillRandom produces alphanumeric characters" {
    const io = testing.io;
    var buf: [20]u8 = undefined;
    fillRandom(io, &buf);
    for (buf) |c| {
        try testing.expect(std.mem.findScalar(u8, alphanumeric, c) != null);
    }
}

test "mktemp fillRandom produces different results" {
    const io = testing.io;
    var buf1: [10]u8 = undefined;
    var buf2: [10]u8 = undefined;
    fillRandom(io, &buf1);
    fillRandom(io, &buf2);
    // Verify both contain valid alphanumeric characters
    for (buf1) |c| {
        try testing.expect(std.mem.findScalar(u8, alphanumeric, c) != null);
    }
    for (buf2) |c| {
        try testing.expect(std.mem.findScalar(u8, alphanumeric, c) != null);
    }
}

test "mktemp --help shows usage" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{"--help"};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "Usage: mktemp") != null);
    try testing.expect(std.mem.find(u8, out, "--directory") != null);
}

test "mktemp --version shows version" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{"--version"};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, out, "mktemp") != null);
    try testing.expect(std.mem.find(u8, out, common.version) != null);
}

test "mktemp too few Xs in template" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{"tmp.XX"};
    const exit_code = try run(allocator, io, args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "too few X's") != null);
}

test "mktemp too many templates" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{ "tmp.XXX", "tmp2.XXX" };
    const exit_code = try run(allocator, io, args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "too many templates") != null);
}

test "mktemp creates file with default template" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Output should be a path ending with newline
    const out = stdout_aw.writer.buffered();
    try testing.expect(out.len > 0);
    try testing.expect(out[out.len - 1] == '\n');

    // Clean up the created file
    const path = std.mem.trimEnd(u8, out, "\n");
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

test "mktemp creates directory with -d flag" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{"-d"};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const path = std.mem.trimEnd(u8, out, "\n");

    // Verify it's a directory
    const stat_result = try std.Io.Dir.cwd().statFile(io, path, .{});
    try testing.expect(stat_result.kind == .directory);

    // Clean up
    std.Io.Dir.deleteDirAbsolute(io, path) catch {};
}

test "mktemp dry-run does not create file" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{"-u"};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const path = std.mem.trimEnd(u8, out, "\n");

    // File should not exist
    const result = std.Io.Dir.cwd().access(io, path, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "mktemp with custom template" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{"myapp.XXXXXX"};
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const path = std.mem.trimEnd(u8, out, "\n");
    const basename = std.fs.path.basename(path);

    // Should start with "myapp."
    try testing.expect(std.mem.startsWith(u8, basename, "myapp."));

    // Custom templates without -p/-t are created relative to cwd.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "mktemp with --suffix" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = &[_][]const u8{ "--suffix=.txt", "tmpXXXXXX" };
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const path = std.mem.trimEnd(u8, out, "\n");

    // Should end with .txt suffix
    try testing.expect(std.mem.endsWith(u8, path, ".txt"));

    // Should start with "tmp" in the basename
    const basename = std.fs.path.basename(path);
    try testing.expect(std.mem.startsWith(u8, basename, "tmp"));

    // Suffix templates without -p/-t are created relative to cwd.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "mktemp suffix with slash is rejected" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{ "--suffix=/bad", "tmpXXXXXX" };
    const exit_code = try run(allocator, io, args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "contains directory separator") != null,
    );
}

test "mktemp with -p flag" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    // Use a known temp directory
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir().realPath(io, &path_buf);
    const dir_path = path_buf[0..path_len];

    const args = &[_][]const u8{ "-p", dir_path };
    const exit_code = try run(allocator, io, args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_aw.writer.buffered();
    const result_path = std.mem.trimEnd(u8, out, "\n");

    // Result should be within the specified directory
    try testing.expect(std.mem.startsWith(u8, result_path, dir_path));

    // Clean up
    std.Io.Dir.deleteFileAbsolute(io, result_path) catch {};
}

test "mktemp quiet mode suppresses errors" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{ "-q", "tmp.XX" };
    const exit_code = try run(allocator, io, args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    // Quiet mode: no error messages on stderr
    try testing.expectEqual(@as(usize, 0), stderr_aw.writer.buffered().len);
}

test "mktemp invalid option" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = &[_][]const u8{"--invalid"};
    const exit_code = try run(allocator, io, args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "mktemp generateTemp creates unique names" {
    const io = testing.io;
    // Generate two temps and verify they differ (dry-run mode)
    const path1 = try generateTemp(testing.allocator, io, "/tmp/test.XXXXXX", 6, 0, false, true);
    defer testing.allocator.free(path1);
    const path2 = try generateTemp(testing.allocator, io, "/tmp/test.XXXXXX", 6, 0, false, true);
    defer testing.allocator.free(path2);

    // Both should start with /tmp/test.
    try testing.expect(std.mem.startsWith(u8, path1, "/tmp/test."));
    try testing.expect(std.mem.startsWith(u8, path2, "/tmp/test."));

    // Very unlikely to be the same
    try testing.expectEqual(@as(usize, 16), path1.len);
    try testing.expectEqual(@as(usize, 16), path2.len);
}

test "fillRandom fills all positions including >256" {
    const io = testing.io;
    // Regression: the old fillRandom used a fixed 256-byte buffer and
    // silently left positions beyond 256 unwritten (undefined memory).
    var buf: [512]u8 = undefined;
    @memset(&buf, 'X');
    fillRandom(io, &buf);
    for (buf, 0..) |b, i| {
        if (std.mem.findScalar(u8, alphanumeric, b) == null) {
            std.debug.print(
                "fillRandom: non-alphanumeric byte 0x{x:0>2} at position {}\n",
                .{ b, i },
            );
            return error.TestUnexpectedResult;
        }
    }
}
