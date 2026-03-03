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

const TestStyle = style.Style(std.ArrayList(u8).Writer);

fn makeTestStyle(
    buffer: *std.ArrayList(u8),
    color_mode: TestStyle.ColorMode,
) TestStyle {
    return TestStyle{
        .color_mode = color_mode,
        .writer = buffer.writer(std.testing.allocator),
    };
}

test "applySizeColor none writes nothing" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .none);
    try applySizeColor(s, 500);
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "applySizeColor truecolor < 1KB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .truecolor);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;115;195;120m", buffer.items);
}

test "applySizeColor truecolor < 100KB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .truecolor);
    try applySizeColor(s, 50 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;150;195;110m", buffer.items);
}

test "applySizeColor truecolor < 1MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .truecolor);
    try applySizeColor(s, 500 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;195;185;100m", buffer.items);
}

test "applySizeColor truecolor < 10MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .truecolor);
    try applySizeColor(s, 5 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;210;155;90m", buffer.items);
}

test "applySizeColor truecolor >= 10MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .truecolor);
    try applySizeColor(s, 50 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;210;115;100m", buffer.items);
}

test "applySizeColor extended < 1KB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .extended);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;114m", buffer.items);
}

test "applySizeColor extended < 100KB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .extended);
    try applySizeColor(s, 50 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;149m", buffer.items);
}

test "applySizeColor extended < 1MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .extended);
    try applySizeColor(s, 500 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;185m", buffer.items);
}

test "applySizeColor extended < 10MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .extended);
    try applySizeColor(s, 5 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;215m", buffer.items);
}

test "applySizeColor extended >= 10MB" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .extended);
    try applySizeColor(s, 50 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;209m", buffer.items);
}

test "applySizeColor basic writes green" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const s = makeTestStyle(&buffer, .basic);
    try applySizeColor(s, 500);
    try std.testing.expectEqualSlices(u8, "\x1b[32m", buffer.items);
}
