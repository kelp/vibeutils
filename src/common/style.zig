const std = @import("std");
const builtin = @import("builtin");

/// Terminal capability detection and styling
pub fn Style(comptime Writer: type) type {
    return struct {
        const Self = @This();
        /// Color capability of the terminal
        pub const ColorMode = enum {
            none, // NO_COLOR or dumb terminal
            basic, // 16 colors
            extended, // 256 colors
            truecolor, // 24-bit RGB

            /// Detect color mode from environment
            pub fn detect(allocator: std.mem.Allocator) !ColorMode {
                // Check NO_COLOR standard (just check existence)
                if (std.process.hasEnvVar(allocator, "NO_COLOR") catch false) {
                    return .none;
                }

                // Check TERM
                if (std.process.getEnvVarOwned(allocator, "TERM")) |term| {
                    defer allocator.free(term);

                    if (std.mem.eql(u8, term, "dumb")) return .none;
                    if (std.mem.indexOf(u8, term, "256color") != null) return .extended;
                    if (std.mem.indexOf(u8, term, "truecolor") != null) return .truecolor;

                    // Check COLORTERM for true color
                    if (std.process.getEnvVarOwned(allocator, "COLORTERM")) |colorterm| {
                        defer allocator.free(colorterm);
                        if (std.mem.eql(u8, colorterm, "truecolor") or
                            std.mem.eql(u8, colorterm, "24bit"))
                        {
                            return .truecolor;
                        }
                    } else |_| {}

                    return .basic;
                } else |_| {
                    return .none;
                }
            }
        };

        color_mode: ColorMode,
        writer: Writer,

        /// ANSI color codes
        pub const Color = enum(u8) {
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
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const mode = try TestStyle.ColorMode.detect(std.testing.allocator);
    try std.testing.expect(@intFromEnum(mode) >= 0);
}

test "Style setRgb truecolor" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(std.testing.allocator) };
    try s.setRgb(100, 200, 50);
    try std.testing.expectEqualSlices(u8, "\x1b[38;2;100;200;50m", buffer.items);
}

test "Style setRgb no-op on basic" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(std.testing.allocator) };
    try s.setRgb(100, 200, 50);
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "Style set256 extended" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .extended, .writer = buffer.writer(std.testing.allocator) };
    try s.set256(142);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;142m", buffer.items);
}

test "Style set256 works on truecolor too" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .truecolor, .writer = buffer.writer(std.testing.allocator) };
    try s.set256(42);
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;42m", buffer.items);
}

test "Style set256 no-op on basic" {
    var buffer = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buffer.deinit(std.testing.allocator);
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const s = TestStyle{ .color_mode = .basic, .writer = buffer.writer(std.testing.allocator) };
    try s.set256(42);
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
}
