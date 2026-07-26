//! Shared color functions for size-based coloring.
//!
//! Provides reusable color gradients that multiple utilities (ls, du, df, wc)
//! can use to consistently color output based on file sizes.

const std = @import("std");
const style = @import("style.zig");

/// Apply a 5-tier color gradient based on file size.
///
/// Colors range from green (small) through yellow to red-orange (large).
/// Adapts to the terminal's color capability:
/// - Truecolor: smooth RGB gradient
/// - 256-color: approximate palette indices
/// - 16-color: green
/// - None: no-op
pub fn applySizeColor(s: anytype, size_bytes: u64) !void {
    // The size-tier ladder used by both the .truecolor and .extended branches
    // assumes each threshold is strictly larger than the previous one. Assert
    // the compile-time ordering of those magnitudes as a sanity check.
    comptime std.debug.assert(1024 < 100 * 1024);
    comptime std.debug.assert(100 * 1024 < 1024 * 1024);
    comptime std.debug.assert(1024 * 1024 < 10 * 1024 * 1024);

    switch (s.color_mode) {
        .truecolor => {
            if (size_bytes < 1024) {
                try s.setRgb(115, 195, 120);
            } else if (size_bytes < 100 * 1024) {
                try s.setRgb(150, 195, 110);
            } else if (size_bytes < 1024 * 1024) {
                try s.setRgb(195, 185, 100);
            } else if (size_bytes < 10 * 1024 * 1024) {
                try s.setRgb(210, 155, 90);
            } else {
                try s.setRgb(210, 115, 100);
            }
        },
        .extended => {
            if (size_bytes < 1024) {
                try s.set256(114);
            } else if (size_bytes < 100 * 1024) {
                try s.set256(149);
            } else if (size_bytes < 1024 * 1024) {
                try s.set256(185);
            } else if (size_bytes < 10 * 1024 * 1024) {
                try s.set256(215);
            } else {
                try s.set256(209);
            }
        },
        .basic => {
            try s.setColor(.green);
        },
        .none => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestStyle = style.Style(*std.Io.Writer);

fn makeTestStyle(
    writer: *std.Io.Writer,
    color_mode: TestStyle.ColorMode,
) TestStyle {
    return TestStyle{
        .color_mode = color_mode,
        .writer = writer,
    };
}

test "applySizeColor none writes nothing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .none);
    try applySizeColor(s, 500);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}

test "applySizeColor truecolor < 1KB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .truecolor);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;115;195;120m", aw.writer.buffered());
}

test "applySizeColor truecolor < 100KB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .truecolor);
    try applySizeColor(s, 50 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;150;195;110m", aw.writer.buffered());
}

test "applySizeColor truecolor < 1MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .truecolor);
    try applySizeColor(s, 500 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;195;185;100m", aw.writer.buffered());
}

test "applySizeColor truecolor < 10MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .truecolor);
    try applySizeColor(s, 5 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;210;155;90m", aw.writer.buffered());
}

test "applySizeColor truecolor >= 10MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .truecolor);
    try applySizeColor(s, 50 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;210;115;100m", aw.writer.buffered());
}

test "applySizeColor extended < 1KB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .extended);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;114m", aw.writer.buffered());
}

test "applySizeColor extended < 100KB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .extended);
    try applySizeColor(s, 50 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;149m", aw.writer.buffered());
}

test "applySizeColor extended < 1MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .extended);
    try applySizeColor(s, 500 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;185m", aw.writer.buffered());
}

test "applySizeColor extended < 10MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .extended);
    try applySizeColor(s, 5 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;215m", aw.writer.buffered());
}

test "applySizeColor extended >= 10MB" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .extended);
    try applySizeColor(s, 50 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;209m", aw.writer.buffered());
}

test "applySizeColor basic writes green" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .basic);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[32m", aw.writer.buffered());
}
