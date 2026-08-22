const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    copy_line,
    gnu_xfer,
};

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
        _ = self;
        _ = now_ns;
        _ = copied;
    }

    pub fn finish(self: *Tracker, now_ns: i128) void {
        _ = self;
        _ = now_ns;
    }

    pub fn now(self: *const Tracker, io: std.Io) i128 {
        _ = self;
        if (builtin.is_test) {
            if (test_now_ns) |value| return value;
        }
        return std.Io.Timestamp.now(io, .real).nanoseconds;
    }
};

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
