const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const format = @import("format.zig");
const assert = std.debug.assert;

pub const Kind = enum {
    copy_line,
    gnu_xfer,
};

/// Upper bound on one rendered status line, including the leading '\r'.
/// This is the loop bound for every formatting path below; the label is
/// truncated to fit, the counters never are.
const line_bytes_max: usize = 256;

pub const Tracker = struct {
    writer: *std.Io.Writer,
    program: []const u8,
    label: []const u8,
    total: ?u64,
    delay_ns: i128,
    interval_ns: i128,
    start_ns: i128,
    last_emit_ns: i128,
    bytes_done: u64,
    shown: bool,
    last_width: u32,
    enabled: bool,
    kind: Kind,

    pub fn update(self: *Tracker, now_ns: i128, copied: u64) void {
        // Delay and interval are durations: non-negative by construction,
        // never i128-negative, or the comparisons below would always pass.
        assert(self.delay_ns >= 0);
        assert(self.interval_ns >= 0);

        // Record the observable byte count even when the line is disabled
        // or still inside the delay, so callers can always read progress.
        self.bytes_done = copied;
        if (!self.enabled) return;
        if (now_ns - self.start_ns < self.delay_ns) return;
        // An interval of 0 means every update emits (tight test loops);
        // otherwise refresh only after the interval has elapsed.
        if (self.shown and self.interval_ns > 0 and
            now_ns - self.last_emit_ns < self.interval_ns) return;
        switch (self.kind) {
            .copy_line => self.emitCopyLine(now_ns),
            .gnu_xfer => self.emitGnuLine(now_ns, false),
        }
    }

    pub fn finish(self: *Tracker, now_ns: i128) void {
        // A cleared width always fits the clear buffer, and a tracker that
        // never emitted has nothing on screen to clean up.
        assert(self.last_width <= line_bytes_max);
        assert(self.shown or self.last_width == 0 or !self.enabled);

        if (!self.enabled or !self.shown) return;
        switch (self.kind) {
            .copy_line => self.clearCopyLine(),
            .gnu_xfer => self.emitGnuLine(now_ns, true),
        }
        // Idempotence: a second finish (or one after a diagnostic) is a
        // no-op because the line is no longer considered shown.
        self.shown = false;
    }

    pub fn now(self: *const Tracker, io: std.Io) i128 {
        _ = self;
        if (builtin.is_test) {
            if (test_now_ns) |value| return value;
        }
        return std.Io.Timestamp.now(io, .real).nanoseconds;
    }

    /// Render the cp/mv status line: '\r' + "prog: copying label  done/total  pct%".
    /// The label is basename'd, control-sanitized, and truncated so the
    /// whole line fits line_bytes_max; the counters are never truncated.
    fn emitCopyLine(self: *Tracker, now_ns: i128) void {
        assert(self.enabled);
        assert(self.kind == .copy_line);

        var counters_buf: [96]u8 = undefined;
        const counters = formatCopyCounters(&counters_buf, self.bytes_done, self.total);

        var line_buf: [line_bytes_max]u8 = undefined;
        line_buf[0] = '\r';
        var pos: usize = 1;
        pos += copyBounded(line_buf[pos..], self.program);
        pos += copyBounded(line_buf[pos..], ": copying ");
        // Reserve the counter bytes before placing the label so a long
        // path can never push the counters off the line.
        const label = std.fs.path.basename(self.label);
        const label_space = line_buf.len -| pos -| counters.len;
        const label_len = @min(label.len, label_space);
        for (label[0..label_len]) |byte| {
            // A '\r', '\n', or '\t' in a hostile file name would break the
            // single-line redraw; degrade those bytes to '?'.
            line_buf[pos] = if (byte == '\r' or byte == '\n' or byte == '\t') '?' else byte;
            pos += 1;
        }
        pos += copyBounded(line_buf[pos..], counters);
        assert(pos <= line_buf.len);
        assert(pos >= 1 + counters.len);

        // A shorter refresh must overwrite the previous glyphs; GNU
        // pads to the prior width so leftover label/counter text dies.
        const padded = padToLastWidth(line_buf[1..], pos - 1, self.last_width);
        pos = 1 + padded;

        // Progress must never fail the copy: swallow write errors, and
        // flush so a buffered stderr shows the line immediately.
        self.writer.writeAll(line_buf[0..pos]) catch {};
        self.writer.flush() catch {};
        self.shown = true;
        self.last_emit_ns = now_ns;
        self.last_width = @intCast(pos - 1);
    }

    /// Erase a shown copy line: '\r', spaces over the previous width, '\r'.
    /// No newline — the cursor returns to column 0 on a blank line.
    fn clearCopyLine(self: *Tracker) void {
        assert(self.kind == .copy_line);
        assert(self.shown);

        var buf: [line_bytes_max + 2]u8 = undefined;
        const width: usize = @min(self.last_width, line_bytes_max);
        buf[0] = '\r';
        @memset(buf[1 .. 1 + width], ' ');
        buf[1 + width] = '\r';
        self.writer.writeAll(buf[0 .. width + 2]) catch {};
        self.writer.flush() catch {};
    }

    /// Render the GNU dd transfer line, live ('\r', no newline) or final
    /// ('\r' + line + '\n'), using the shared printStats formatter.
    fn emitGnuLine(self: *Tracker, now_ns: i128, final: bool) void {
        assert(self.enabled);
        assert(self.kind == .gnu_xfer);

        var body_buf: [line_bytes_max]u8 = undefined;
        const body = formatGnuTransfer(&body_buf, self.bytes_done, now_ns - self.start_ns);
        const padded = padToLastWidth(body_buf[0..], body.len, self.last_width);
        self.writer.writeAll("\r") catch {};
        self.writer.writeAll(body_buf[0..padded]) catch {};
        if (final) self.writer.writeAll("\n") catch {};
        self.writer.flush() catch {};
        self.shown = true;
        self.last_emit_ns = now_ns;
        self.last_width = @intCast(padded);
    }
};

/// Pad a freshly rendered status body out to `last_width` with spaces.
/// `\r` redraws do not erase leftover glyphs; GNU dd pads for this.
fn padToLastWidth(buf: []u8, content_len: usize, last_width: u32) usize {
    assert(content_len <= buf.len);
    const prev: usize = @min(last_width, buf.len);
    const padded = if (content_len >= prev) content_len else blk: {
        @memset(buf[content_len..prev], ' ');
        break :blk prev;
    };
    assert(padded >= content_len);
    assert(padded <= buf.len);
    return padded;
}

/// Copy as much of src as fits into dst and return the bytes copied.
/// Bounded truncation is the point: callers budget the 256-byte line.
fn copyBounded(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    assert(n <= dst.len);
    assert(n <= src.len);
    return n;
}

/// Format the "  done/total  pct%" tail of a copy line. Unknown (null)
/// or zero totals omit the "/total" and the percent entirely. Sizes are
/// SI-humanized with unit suffixes (design mock "248MB/1.2GB").
fn formatCopyCounters(buf: []u8, done: u64, total: ?u64) []const u8 {
    // Two humanized sizes plus percent need well under 48 bytes; a
    // smaller buffer would silently truncate the counters.
    assert(buf.len >= 48);

    const human_opts: format.FormatOptions = .{ .si = true, .suffix = .iec };
    var done_buf: [32]u8 = undefined;
    const done_str = format.formatHumanReadable(&done_buf, done, human_opts);
    const total_bytes = total orelse 0;
    if (total_bytes == 0) {
        return std.fmt.bufPrint(buf, "  {s}", .{done_str}) catch buf[0..0];
    }
    var total_buf: [32]u8 = undefined;
    const total_str = format.formatHumanReadable(&total_buf, total_bytes, human_opts);
    // Widen to u128 so a near-maxInt(u64) done cannot wrap in the
    // multiply; cap at 100 when done overshoots the stat-time total.
    const pct_wide = @divFloor(@as(u128, done) * 100, @as(u128, total_bytes));
    const pct = @min(pct_wide, 100);
    assert(pct <= 100);
    return std.fmt.bufPrint(buf, "  {s}/{s}  {d}%", .{ done_str, total_str, pct }) catch buf[0..0];
}

/// Format the GNU dd transfer line body: "N bytes (SI, IEC) copied, T s,
/// RATE". Shared by dd's printStats and the .gnu_xfer live line so the
/// two renderings can never drift apart. Elapsed time is clamped to
/// >= 0.0001 s (clock skew) so the rate division cannot divide by zero.
pub fn formatGnuTransfer(buf: []u8, bytes_copied: u64, elapsed_ns: i128) []const u8 {
    assert(buf.len >= line_bytes_max);

    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const elapsed_display = if (elapsed_s < 0.0001) 0.0001 else elapsed_s;
    assert(elapsed_display > 0.0);

    var size_buf: [128]u8 = undefined;
    const size_str = formatGnuBytes(&size_buf, bytes_copied);
    const fb: f64 = @floatFromInt(bytes_copied);
    var rate_buf: [64]u8 = undefined;
    const rate_str = formatGnuRate(&rate_buf, fb / elapsed_display);
    return std.fmt.bufPrint(buf, "{d} bytes ({s}) copied, {d:.4} s, {s}", .{
        bytes_copied,
        size_str,
        elapsed_display,
        rate_str,
    }) catch "?";
}

/// Format a byte count the way GNU dd's stats do: "1.5 MB, 1.4 MiB",
/// or "N bytes" below one kB. Moved here from dd so the live line and
/// the final stats share one renderer.
pub fn formatGnuBytes(buf: []u8, bytes: u64) []const u8 {
    assert(buf.len >= 64);

    const fb: f64 = @floatFromInt(bytes);
    assert(fb >= 0.0);
    if (bytes >= 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1} GB, {d:.1} GiB", .{
            fb / 1_000_000_000.0,
            fb / 1_073_741_824.0,
        }) catch "?";
    } else if (bytes >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1} MB, {d:.1} MiB", .{
            fb / 1_000_000.0,
            fb / 1_048_576.0,
        }) catch "?";
    } else if (bytes >= 1000) {
        return std.fmt.bufPrint(buf, "{d:.1} kB, {d:.1} KiB", .{
            fb / 1000.0,
            fb / 1024.0,
        }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    }
}

/// Format a transfer rate the way GNU dd's stats do ("12.3 MB/s").
pub fn formatGnuRate(buf: []u8, rate: f64) []const u8 {
    assert(buf.len >= 32);
    assert(rate >= 0.0);

    if (rate >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} GB/s", .{rate / 1_000_000_000.0}) catch "?";
    } else if (rate >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{rate / 1_000_000.0}) catch "?";
    } else if (rate >= 1000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} kB/s", .{rate / 1000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0} bytes/s", .{rate}) catch "?";
    }
}

/// Current wall-clock nanoseconds, honoring the test overlay so unit
/// tests can drive time without sleeping.
pub fn nowNs(io: std.Io) i128 {
    if (builtin.is_test) {
        if (test_now_ns) |value| return value;
    }
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

/// Build the cp/mv KEEP auto-progress tracker for one regular-file copy,
/// or null when progress is disabled: stderr is not a TTY, or the test
/// overlay forces it off. The gate is evaluated here, once per file
/// (macOS isatty class). The caller passes the wall-clock start so tests
/// can drive time explicitly.
pub fn forCopy(
    writer: *std.Io.Writer,
    program: []const u8,
    source_path: []const u8,
    total: ?u64,
    start_ns: i128,
) ?Tracker {
    // Both name the status line; empty values would render a broken
    // prefix and can never come from the cp/mv call sites.
    assert(program.len > 0);
    assert(source_path.len > 0);

    if (!copyEnabled()) return null;
    return .{
        .writer = writer,
        .program = program,
        .label = source_path,
        .total = total,
        .delay_ns = copyDelayNs(),
        .interval_ns = copy_interval_ns,
        .start_ns = start_ns,
        .last_emit_ns = start_ns,
        .bytes_done = 0,
        .shown = false,
        .last_width = 0,
        .enabled = true,
        .kind = .copy_line,
    };
}

fn copyEnabled() bool {
    if (builtin.is_test) {
        if (test_enabled) |value| return value;
    }
    return env.isTty(std.Io.File.stderr().handle);
}

fn copyDelayNs() i128 {
    if (builtin.is_test) {
        if (test_delay_ns) |value| return value;
    }
    return copy_delay_ns;
}

pub var test_enabled: ?bool = null;
pub var test_delay_ns: ?i128 = null;
pub var test_now_ns: ?i128 = null;

const ns_per_s: i128 = std.time.ns_per_s;
const copy_delay_ns: i128 = 2 * ns_per_s;
const copy_interval_ns: i128 = @divExact(ns_per_s, 2);
const gnu_interval_ns: i128 = ns_per_s;

fn testTracker(
    writer: *std.Io.Writer,
    kind: Kind,
    label: []const u8,
    total: ?u64,
) Tracker {
    const delay_ns = switch (kind) {
        .copy_line => copy_delay_ns,
        .gnu_xfer => ns_per_s,
    };
    const interval_ns = switch (kind) {
        .copy_line => copy_interval_ns,
        .gnu_xfer => gnu_interval_ns,
    };
    return .{
        .writer = writer,
        .program = "cp",
        .label = label,
        .total = total,
        .delay_ns = delay_ns,
        .interval_ns = interval_ns,
        .start_ns = 1_000,
        .last_emit_ns = 1_000,
        .bytes_done = 0,
        .shown = false,
        .last_width = 0,
        .enabled = true,
        .kind = kind,
    };
}

test "copy line stays hidden at its start time" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 100);

    tracker.update(tracker.start_ns, 25);

    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "\r") == null);
}

test "copy line after delay renders human sizes and percent" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const mib: u64 = 1024 * 1024;
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 20 * mib);

    tracker.update(tracker.start_ns + copy_delay_ns + 1, 10 * mib);
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.find(u8, rendered, "\r") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "copying") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "10MB/21MB") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "50%") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "70%") == null);
}

test "copy line unknown and zero totals omit percent" {
    var unknown_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unknown_output.deinit();
    var zero_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer zero_output.deinit();
    var unknown = testTracker(&unknown_output.writer, .copy_line, "unknown", null);
    var zero = testTracker(&zero_output.writer, .copy_line, "zero", 0);
    const now_ns = unknown.start_ns + copy_delay_ns + 1;

    unknown.update(now_ns, 10);
    zero.update(now_ns, 10);

    try std.testing.expect(std.mem.find(u8, unknown_output.writer.buffered(), "copying") != null);
    try std.testing.expect(std.mem.find(u8, unknown_output.writer.buffered(), "%") == null);
    try std.testing.expect(std.mem.find(u8, unknown_output.writer.buffered(), "/") == null);
    try std.testing.expect(std.mem.find(u8, zero_output.writer.buffered(), "copying") != null);
    try std.testing.expect(std.mem.find(u8, zero_output.writer.buffered(), "%") == null);
    try std.testing.expect(std.mem.find(u8, zero_output.writer.buffered(), "/") == null);
}

test "copy line caps percent when copied exceeds total" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 10);

    tracker.update(tracker.start_ns + copy_delay_ns + 1, 11);
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.find(u8, rendered, "100%") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "101%") == null);
}

test "copy line percent uses wide arithmetic near u64 maximum" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const total = std.math.maxInt(u64) - 1;
    var tracker = testTracker(&output.writer, .copy_line, "huge.bin", total);

    tracker.update(tracker.start_ns + copy_delay_ns + 1, total);
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.find(u8, rendered, "100%") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "99%") == null);
}

test "copy line observes the half-second refresh interval" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 100);
    const first_ns = tracker.start_ns + copy_delay_ns + 1;

    tracker.update(first_ns, 10);
    const first_len = output.writer.buffered().len;
    tracker.update(first_ns + copy_interval_ns - 1, 20);
    const inside_interval_len = output.writer.buffered().len;
    tracker.update(first_ns + copy_interval_ns, 30);

    try std.testing.expect(first_len > 0);
    try std.testing.expectEqual(first_len, inside_interval_len);
    try std.testing.expect(output.writer.buffered().len > inside_interval_len);
}

test "copy line finish clears the shown line without a newline" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "leftover-label", 100);
    const now_ns = tracker.start_ns + copy_delay_ns + 1;

    tracker.update(now_ns, 50);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "leftover-label") != null);
    tracker.finish(now_ns + 1);
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r"));
    try std.testing.expect(std.mem.find(u8, rendered, "\n") == null);
    const before_last = rendered[0 .. rendered.len - 1];
    const clear_start = std.mem.lastIndexOfScalar(u8, before_last, '\r').? + 1;
    try std.testing.expectEqual(@as(usize, tracker.last_width), before_last.len - clear_start);
    for (before_last[clear_start..]) |byte| {
        try std.testing.expectEqual(@as(u8, ' '), byte);
    }
}

test "copy line finish before showing remains empty" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 100);

    tracker.finish(tracker.start_ns);

    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "\r") == null);
}

test "copy line finish before a diagnostic leaves the error visible" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 100);
    tracker.delay_ns = 0;
    tracker.interval_ns = 0;

    tracker.update(tracker.start_ns + 1, 50);
    tracker.finish(tracker.start_ns + 2);
    try output.writer.print("cp: copy error\n", .{});
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.find(u8, rendered, "\r") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "cp: copy error") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "copy error\n"));
}

test "disabled copy line stays silent after delay" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "source.bin", 100);
    tracker.enabled = false;

    tracker.update(tracker.start_ns + copy_delay_ns + 1, 50);
    tracker.finish(tracker.start_ns + copy_delay_ns + 2);

    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "\r") == null);
}

test "copy line sanitizes control characters in labels" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .copy_line, "bad\rname\nfile", 100);

    tracker.update(tracker.start_ns + copy_delay_ns + 1, 50);
    const rendered = output.writer.buffered();

    try std.testing.expect(std.mem.find(u8, rendered, "copying") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\n") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\r"));
}

test "gnu transfer waits one second and finishes with newline" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .gnu_xfer, "", null);

    tracker.update(tracker.start_ns + ns_per_s - 1, 100);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "\r") == null);

    tracker.update(tracker.start_ns + ns_per_s, 200);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "\r") != null);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "bytes") != null);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "copied") != null);
    tracker.finish(tracker.start_ns + 2 * ns_per_s);
    try std.testing.expect(std.mem.endsWith(u8, output.writer.buffered(), "\n"));
}

test "gnu transfer finish a second time is a no-op" {
    // Overlay + delay_ns=0 so the first update actually paints: after a
    // successful finish, shown is false but last_width stays > 0, and a
    // second finish must not panic or emit another GNU transfer line.
    test_enabled = true;
    defer test_enabled = null;
    test_delay_ns = 0;
    defer test_delay_ns = null;
    test_now_ns = 2_000;
    defer test_now_ns = null;

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .gnu_xfer, "", null);
    tracker.delay_ns = 0;
    tracker.interval_ns = 0;

    tracker.update(2_000, 100);
    try std.testing.expect(tracker.shown);
    try std.testing.expect(tracker.last_width > 0);

    tracker.finish(2_000);
    const after_first = output.writer.buffered();
    const first_len = after_first.len;
    const first_newlines = std.mem.count(u8, after_first, "\n");
    try std.testing.expect(std.mem.endsWith(u8, after_first, "\n"));
    try std.testing.expectEqual(@as(usize, 1), first_newlines);

    tracker.finish(2_000);
    const after_second = output.writer.buffered();
    try std.testing.expectEqual(first_len, after_second.len);
    try std.testing.expectEqual(first_newlines, std.mem.count(u8, after_second, "\n"));
}

test "copy line refresh pads a shorter update to the prior width" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(
        &output.writer,
        .copy_line,
        "UNIQUE-LONG-LABEL-MARKER.bin",
        100 * 1024 * 1024,
    );
    tracker.delay_ns = 0;
    tracker.interval_ns = 0;

    tracker.update(tracker.start_ns + 1, 50 * 1024 * 1024);
    const first_width = tracker.last_width;
    const first_out = output.writer.buffered();
    try std.testing.expect(first_width > 0);
    try std.testing.expect(std.mem.find(u8, first_out, "UNIQUE-LONG-LABEL-MARKER") != null);

    tracker.label = "x";
    tracker.total = 1;
    tracker.update(tracker.start_ns + 2, 1);
    const rendered = output.writer.buffered();
    const last_cr = std.mem.lastIndexOfScalar(u8, rendered, '\r').?;
    const last_line = rendered[last_cr + 1 ..];

    try std.testing.expectEqual(@as(usize, first_width), last_line.len);
    try std.testing.expectEqual(first_width, tracker.last_width);
    try std.testing.expect(std.mem.startsWith(u8, last_line, "cp: copying x"));
    try std.testing.expect(std.mem.find(u8, last_line, "UNIQUE-LONG-LABEL-MARKER") == null);
    try std.testing.expect(std.mem.find(u8, last_line, "100%") != null);
    const pct_end = std.mem.indexOf(u8, last_line, "100%").? + "100%".len;
    try std.testing.expect(pct_end < last_line.len);
    for (last_line[pct_end..]) |byte| {
        try std.testing.expectEqual(@as(u8, ' '), byte);
    }

    tracker.finish(tracker.start_ns + 3);
    const after_finish = output.writer.buffered();
    const before_last = after_finish[0 .. after_finish.len - 1];
    const clear_start = std.mem.lastIndexOfScalar(u8, before_last, '\r').? + 1;
    try std.testing.expectEqual(@as(usize, first_width), before_last.len - clear_start);
}

test "gnu transfer refresh pads a shorter update to the prior width" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var tracker = testTracker(&output.writer, .gnu_xfer, "", null);
    tracker.delay_ns = 0;
    tracker.interval_ns = 0;

    tracker.update(tracker.start_ns + ns_per_s, 1_000_000_000);
    const first_width = tracker.last_width;
    try std.testing.expect(first_width > 0);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "1000000000") != null);

    tracker.update(tracker.start_ns + ns_per_s + 1, 0);
    const rendered = output.writer.buffered();
    const last_cr = std.mem.lastIndexOfScalar(u8, rendered, '\r').?;
    const last_line = rendered[last_cr + 1 ..];

    try std.testing.expectEqual(@as(usize, first_width), last_line.len);
    try std.testing.expectEqual(first_width, tracker.last_width);
    try std.testing.expect(std.mem.startsWith(u8, last_line, "0 bytes"));
    try std.testing.expect(std.mem.find(u8, last_line, "1000000000") == null);
    var content_end = last_line.len;
    while (content_end > 0 and last_line[content_end - 1] == ' ') content_end -= 1;
    try std.testing.expect(content_end < first_width);
    for (last_line[content_end..]) |byte| {
        try std.testing.expectEqual(@as(u8, ' '), byte);
    }

    tracker.finish(tracker.start_ns + 2 * ns_per_s);
    const after_finish = output.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, after_finish, "\n"));
    const finish_body = after_finish[0 .. after_finish.len - 1];
    const finish_cr = std.mem.lastIndexOfScalar(u8, finish_body, '\r').?;
    const finish_line = after_finish[finish_cr + 1 .. after_finish.len - 1];
    try std.testing.expectEqual(@as(usize, first_width), finish_line.len);
    try std.testing.expect(std.mem.find(u8, finish_line, "1000000000") == null);
}

test "progress writes only to the configured writer" {
    var configured: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer configured.deinit();
    var unrelated: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unrelated.deinit();
    var tracker = testTracker(&configured.writer, .copy_line, "source.bin", 100);

    tracker.update(tracker.start_ns + copy_delay_ns + 1, 50);

    try std.testing.expect(std.mem.find(u8, configured.writer.buffered(), "\r") != null);
    try std.testing.expectEqual(@as(usize, 0), unrelated.writer.buffered().len);
}

test "progress test overlays restore in defer" {
    test_delay_ns = 37;
    defer test_delay_ns = null;

    try std.testing.expectEqual(@as(?i128, 37), test_delay_ns);
    try std.testing.expect(test_enabled == null);
}
