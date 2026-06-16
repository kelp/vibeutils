const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");

/// Color capability of the terminal.
///
/// Defined at file scope (not nested inside the `Style` factory) so the
/// generic `Style(Writer)` body stays under Tiger Style's 70-line limit.
/// `Style(Writer).ColorMode` aliases this type, so call sites referencing
/// `Style(W).ColorMode` and `Style(W).ColorMode.detect` are unchanged. The
/// file-scope name is `TerminalColorMode` (not `ColorMode`) so the struct's
/// own `pub const ColorMode` alias does not collide with it inside the
/// generic body.
pub const TerminalColorMode = enum {
    none, // NO_COLOR or dumb terminal
    basic, // 16 colors
    extended, // 256 colors
    truecolor, // 24-bit RGB

    /// Detect color mode from environment
    pub fn detect(_: std.mem.Allocator) !TerminalColorMode {
        // Check NO_COLOR standard (just check existence)
        if (env.getEnv("NO_COLOR") != null) {
            return .none;
        }

        // Check TERM
        if (env.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) return .none;
            if (std.mem.find(u8, term, "256color") != null) return .extended;
            if (std.mem.find(u8, term, "truecolor") != null) return .truecolor;

            // Check COLORTERM for true color
            if (env.getEnv("COLORTERM")) |colorterm| {
                if (std.mem.eql(u8, colorterm, "truecolor") or
                    std.mem.eql(u8, colorterm, "24bit"))
                {
                    return .truecolor;
                }
            }

            return .basic;
        } else {
            return .none;
        }
    }
};

/// ANSI color codes.
///
/// Defined at file scope for the same reason as `TerminalColorMode`;
/// `Style(Writer).Color` aliases this type so call sites are unchanged.
pub const TerminalColor = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    default = 39,

    // Bright colors
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

/// Terminal capability detection and styling
pub fn Style(comptime Writer: type) type {
    return struct {
        const Self = @This();

        /// Color capability of the terminal (file-scope alias).
        pub const ColorMode = TerminalColorMode;

        color_mode: ColorMode,
        writer: Writer,

        /// ANSI color codes (file-scope alias).
        pub const Color = TerminalColor;

        /// Initialize with auto-detection
        pub fn init(allocator: std.mem.Allocator, writer: Writer) !Self {
            const color_mode = ColorMode.detect(allocator) catch .none;

            return .{
                .color_mode = color_mode,
                .writer = writer,
            };
        }

        /// Set foreground color
        pub fn setColor(self: Self, color: Color) !void {
            if (self.color_mode == .none) return;
            try self.writer.print("\x1b[{d}m", .{@intFromEnum(color)});
        }

        /// Set bold text
        pub fn setBold(self: Self) !void {
            if (self.color_mode == .none) return;
            try self.writer.writeAll("\x1b[1m");
        }

        /// Set foreground to RGB color (truecolor only, no-op otherwise)
        pub fn setRgb(self: Self, r: u8, g: u8, b: u8) !void {
            if (self.color_mode != .truecolor) return;
            try self.writer.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
        }

        /// Set foreground to 256-color palette (extended+ only, no-op otherwise)
        pub fn set256(self: Self, index: u8) !void {
            if (@intFromEnum(self.color_mode) < @intFromEnum(ColorMode.extended)) return;
            try self.writer.print("\x1b[38;5;{d}m", .{index});
        }

        /// Reset all styling
        pub fn reset(self: Self) !void {
            if (self.color_mode == .none) return;
            try self.writer.writeAll("\x1b[0m");
        }
    };
}

test "Style color detection" {
    const TestStyle = Style(*std.Io.Writer);
    const mode = try TestStyle.ColorMode.detect(std.testing.allocator);
    try std.testing.expect(@intFromEnum(mode) >= 0);
}

test "Style setRgb truecolor" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const TestStyle = Style(*std.Io.Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = &aw.writer };
    try s.setRgb(100, 200, 50);
    try std.testing.expectEqualStrings("\x1b[38;2;100;200;50m", aw.writer.buffered());
}

test "Style setRgb no-op on basic" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const TestStyle = Style(*std.Io.Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = &aw.writer };
    try s.setRgb(100, 200, 50);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}

test "Style set256 extended" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const TestStyle = Style(*std.Io.Writer);
    const s = TestStyle{ .color_mode = .extended, .writer = &aw.writer };
    try s.set256(142);
    try std.testing.expectEqualStrings("\x1b[38;5;142m", aw.writer.buffered());
}

test "Style set256 works on truecolor too" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const TestStyle = Style(*std.Io.Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = &aw.writer };
    try s.set256(42);
    try std.testing.expectEqualStrings("\x1b[38;5;42m", aw.writer.buffered());
}

test "Style set256 no-op on basic" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const TestStyle = Style(*std.Io.Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = &aw.writer };
    try s.set256(42);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}
