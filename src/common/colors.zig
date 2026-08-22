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

/// Color `size_bytes` relative to the listing's largest printed size.
///
/// Tiers match `df`'s `applyUsageColor`: green below 70% of max, yellow
/// below 90%, red at or above 90%. Percent is `@divFloor(size * 100, max)`
/// on `u128`; `max == 0` is 0%.
///
/// This stub ignores `max_bytes` and forwards to `applySizeColor` so the
/// guarding tests compile and fail on the absolute `>= 10M` swatch rather
/// than a missing symbol. The implementer replaces the body.
pub fn applyRelativeSizeColor(s: anytype, size_bytes: u64, max_bytes: u64) !void {
    _ = max_bytes;
    std.debug.assert(@TypeOf(size_bytes) == u64);
    try applySizeColor(s, size_bytes);
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

// Relative color: df applyUsageColor 70/90-of-max. Absolute applySizeColor
// paints every size >= 10 MiB with one swatch, so 10 MiB of 20 MiB (50%)
// is the tooth: relative wants df-green, the stub emits the >=10M swatch.
const rel_mib: u64 = 1024 * 1024;
const rel_size_10m: u64 = 10 * rel_mib;
const rel_size_15m: u64 = 15 * rel_mib;
const rel_size_20m: u64 = 20 * rel_mib;
const rel_max_20m: u64 = 20 * rel_mib;
// 10 MiB is 0% of 2 GiB under `@divFloor(size * 100, max)` on u128.
const rel_max_2g: u64 = 2 * 1024 * rel_mib;
// Smallest sizes that are 69% and 89% of 20 MiB under that percent.
const rel_size_69_of_20m: u64 = 14_470_349;
const rel_size_89_of_20m: u64 = 18_664_653;
const rel_size_70_of_20m: u64 = 14 * rel_mib;
const rel_size_90_of_20m: u64 = 18 * rel_mib;

const csi_rgb_green = "\x1b[38;2;115;195;120m";
const csi_rgb_yellow = "\x1b[38;2;210;185;90m";
const csi_rgb_red = "\x1b[38;2;210;95;90m";
const csi_rgb_abs_10m = "\x1b[38;2;210;115;100m";
const csi_256_green = "\x1b[38;5;114m";
const csi_256_yellow = "\x1b[38;5;220m";
const csi_256_red = "\x1b[38;5;196m";
const csi_256_abs_10m = "\x1b[38;5;209m";
const csi_basic_green = "\x1b[32m";
const csi_basic_yellow = "\x1b[33m";
const csi_basic_red = "\x1b[31m";

fn expectRelativeColor(
    color_mode: TestStyle.ColorMode,
    size_bytes: u64,
    max_bytes: u64,
    want: []const u8,
    not_want: []const u8,
) !void {
    std.debug.assert(!std.mem.eql(u8, want, not_want));
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, color_mode);
    try applyRelativeSizeColor(s, size_bytes, max_bytes);
    const got = aw.writer.buffered();
    try std.testing.expectEqualSlices(u8, want, got);
    try std.testing.expect(std.mem.find(u8, got, not_want) == null);
}

test "applyRelativeSizeColor none writes nothing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = makeTestStyle(&aw.writer, .none);
    try applyRelativeSizeColor(s, rel_size_10m, rel_max_20m);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "\x1b") == null);
}

test "applyRelativeSizeColor truecolor 0% is df green not the >=10M swatch" {
    try expectRelativeColor(
        .truecolor,
        rel_size_10m,
        rel_max_2g,
        csi_rgb_green,
        csi_rgb_abs_10m,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_10m,
        rel_max_2g,
        csi_rgb_green,
        csi_rgb_red,
    );
}

test "applyRelativeSizeColor truecolor 50% is df green not the >=10M swatch" {
    try expectRelativeColor(
        .truecolor,
        rel_size_10m,
        rel_max_20m,
        csi_rgb_green,
        csi_rgb_abs_10m,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_10m,
        rel_max_20m,
        csi_rgb_green,
        csi_rgb_yellow,
    );
}

test "applyRelativeSizeColor truecolor 69% is df green" {
    try expectRelativeColor(
        .truecolor,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_rgb_green,
        csi_rgb_yellow,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_rgb_green,
        csi_rgb_abs_10m,
    );
}

test "applyRelativeSizeColor truecolor 70% is df yellow" {
    try expectRelativeColor(
        .truecolor,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_rgb_yellow,
        csi_rgb_green,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_rgb_yellow,
        csi_rgb_abs_10m,
    );
}

test "applyRelativeSizeColor truecolor 89% is df yellow" {
    try expectRelativeColor(
        .truecolor,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_rgb_yellow,
        csi_rgb_red,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_rgb_yellow,
        csi_rgb_abs_10m,
    );
}

test "applyRelativeSizeColor truecolor 90% is df red" {
    try expectRelativeColor(
        .truecolor,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_rgb_red,
        csi_rgb_yellow,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_rgb_red,
        csi_rgb_abs_10m,
    );
}

test "applyRelativeSizeColor truecolor 100% is df red" {
    try expectRelativeColor(
        .truecolor,
        rel_size_20m,
        rel_max_20m,
        csi_rgb_red,
        csi_rgb_green,
    );
    try expectRelativeColor(
        .truecolor,
        rel_size_20m,
        rel_max_20m,
        csi_rgb_red,
        csi_rgb_abs_10m,
    );
}

test "applyRelativeSizeColor extended 0% is df green" {
    try expectRelativeColor(
        .extended,
        rel_size_10m,
        rel_max_2g,
        csi_256_green,
        csi_256_abs_10m,
    );
    try expectRelativeColor(
        .extended,
        rel_size_10m,
        rel_max_2g,
        csi_256_green,
        csi_256_red,
    );
}

test "applyRelativeSizeColor extended 50% is df green" {
    try expectRelativeColor(
        .extended,
        rel_size_10m,
        rel_max_20m,
        csi_256_green,
        csi_256_abs_10m,
    );
    try expectRelativeColor(
        .extended,
        rel_size_10m,
        rel_max_20m,
        csi_256_green,
        csi_256_yellow,
    );
}

test "applyRelativeSizeColor extended 69% is df green" {
    try expectRelativeColor(
        .extended,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_256_green,
        csi_256_yellow,
    );
    try expectRelativeColor(
        .extended,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_256_green,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor extended 70% is df yellow" {
    try expectRelativeColor(
        .extended,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_256_yellow,
        csi_256_green,
    );
    try expectRelativeColor(
        .extended,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_256_yellow,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor extended 89% is df yellow" {
    try expectRelativeColor(
        .extended,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_256_yellow,
        csi_256_red,
    );
    try expectRelativeColor(
        .extended,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_256_yellow,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor extended 90% is df red" {
    try expectRelativeColor(
        .extended,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_256_red,
        csi_256_yellow,
    );
    try expectRelativeColor(
        .extended,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_256_red,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor extended 100% is df red" {
    try expectRelativeColor(
        .extended,
        rel_size_20m,
        rel_max_20m,
        csi_256_red,
        csi_256_green,
    );
    try expectRelativeColor(
        .extended,
        rel_size_20m,
        rel_max_20m,
        csi_256_red,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor basic 0% is green" {
    try expectRelativeColor(
        .basic,
        rel_size_10m,
        rel_max_2g,
        csi_basic_green,
        csi_basic_red,
    );
    try expectRelativeColor(
        .basic,
        rel_size_10m,
        rel_max_2g,
        csi_basic_green,
        csi_basic_yellow,
    );
}

test "applyRelativeSizeColor basic 50% is green" {
    try expectRelativeColor(
        .basic,
        rel_size_10m,
        rel_max_20m,
        csi_basic_green,
        csi_basic_yellow,
    );
    try expectRelativeColor(
        .basic,
        rel_size_10m,
        rel_max_20m,
        csi_basic_green,
        csi_basic_red,
    );
}

test "applyRelativeSizeColor basic 69% is green" {
    try expectRelativeColor(
        .basic,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_basic_green,
        csi_basic_yellow,
    );
    try expectRelativeColor(
        .basic,
        rel_size_69_of_20m,
        rel_max_20m,
        csi_basic_green,
        csi_basic_red,
    );
}

test "applyRelativeSizeColor basic 70% is yellow" {
    try expectRelativeColor(
        .basic,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_green,
    );
    try expectRelativeColor(
        .basic,
        rel_size_70_of_20m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_red,
    );
}

test "applyRelativeSizeColor basic 75% is yellow" {
    try expectRelativeColor(
        .basic,
        rel_size_15m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_green,
    );
    try expectRelativeColor(
        .basic,
        rel_size_15m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_red,
    );
}

test "applyRelativeSizeColor basic 89% is yellow" {
    try expectRelativeColor(
        .basic,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_green,
    );
    try expectRelativeColor(
        .basic,
        rel_size_89_of_20m,
        rel_max_20m,
        csi_basic_yellow,
        csi_basic_red,
    );
}

test "applyRelativeSizeColor basic 90% is red" {
    try expectRelativeColor(
        .basic,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_basic_red,
        csi_basic_yellow,
    );
    try expectRelativeColor(
        .basic,
        rel_size_90_of_20m,
        rel_max_20m,
        csi_basic_red,
        csi_basic_green,
    );
}

test "applyRelativeSizeColor basic 100% is red" {
    try expectRelativeColor(
        .basic,
        rel_size_20m,
        rel_max_20m,
        csi_basic_red,
        csi_basic_green,
    );
    try expectRelativeColor(
        .basic,
        rel_size_20m,
        rel_max_20m,
        csi_basic_red,
        csi_basic_yellow,
    );
}

test "applyRelativeSizeColor max==0 is 0% green not the size's absolute swatch" {
    try expectRelativeColor(
        .truecolor,
        rel_size_10m,
        0,
        csi_rgb_green,
        csi_rgb_abs_10m,
    );
    try expectRelativeColor(
        .extended,
        rel_size_10m,
        0,
        csi_256_green,
        csi_256_abs_10m,
    );
}

test "applyRelativeSizeColor near u64-max is 100% red (u128 percent)" {
    const max_u64 = std.math.maxInt(u64);
    try expectRelativeColor(
        .truecolor,
        max_u64,
        max_u64,
        csi_rgb_red,
        csi_rgb_abs_10m,
    );
    try expectRelativeColor(
        .truecolor,
        max_u64,
        max_u64,
        csi_rgb_red,
        csi_rgb_green,
    );
}
