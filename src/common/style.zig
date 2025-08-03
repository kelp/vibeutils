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
