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
        pub fn detect() ColorMode {
            // Check NO_COLOR standard (just check existence)
            if (std.process.hasEnvVar(std.heap.c_allocator, "NO_COLOR") catch false) {
                return .none;
            }

            // Check TERM
            if (std.process.getEnvVarOwned(std.heap.c_allocator, "TERM")) |term| {
                defer std.heap.c_allocator.free(term);

                if (std.mem.eql(u8, term, "dumb")) return .none;
                if (std.mem.indexOf(u8, term, "256color") != null) return .extended;
                if (std.mem.indexOf(u8, term, "truecolor") != null) return .truecolor;

                // Check COLORTERM for true color
                if (std.process.getEnvVarOwned(std.heap.c_allocator, "COLORTERM")) |colorterm| {
                    defer std.heap.c_allocator.free(colorterm);
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

    pub const Attribute = enum(u8) {
        reset = 0,
        bold = 1,
        dim = 2,
        italic = 3,
        underline = 4,
        blink = 5,
        reverse = 7,
        hidden = 8,
        strikethrough = 9,
    };

        /// Initialize with auto-detection
        pub fn init(writer: Writer) Self {
        const color_mode = ColorMode.detect();

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

        /// Set text attribute
        pub fn setAttribute(self: Self, attr: Attribute) !void {
        if (self.color_mode == .none) return;
        try self.writer.print("\x1b[{d}m", .{@intFromEnum(attr)});
    }

        /// Reset all styling
        pub fn reset(self: Self) !void {
        if (self.color_mode == .none) return;
        try self.writer.writeAll("\x1b[0m");
    }

        /// Set RGB color (true color mode only)
        pub fn setRGB(self: Self, r: u8, g: u8, b: u8) !void {
        if (self.color_mode != .truecolor) {
            // Fallback to nearest 256 color
            const color_256 = rgbTo256(r, g, b);
            if (self.color_mode == .extended) {
                try self.writer.print("\x1b[38;5;{d}m", .{color_256});
            }
            return;
        }
        try self.writer.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
    }

        /// Print styled text
        pub fn print(self: Self, comptime fmt: []const u8, args: anytype, color: Color) !void {
        try self.setColor(color);
        try self.writer.print(fmt, args);
        try self.reset();
    }


    /// Convert RGB to nearest 256 color
    fn rgbTo256(r: u8, g: u8, b: u8) u8 {
        // Simple 6x6x6 color cube mapping
        const r6 = @as(u16, r) * 5 / 255;
        const g6 = @as(u16, g) * 5 / 255;
        const b6 = @as(u16, b) * 5 / 255;
        return @intCast(16 + 36 * r6 + 6 * g6 + b6);
    }
    };
}

test "Style color detection" {
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const mode = TestStyle.ColorMode.detect();
    try std.testing.expect(@intFromEnum(mode) >= 0);
}

test "Style RGB to 256 color conversion" {
    const TestStyle = Style(std.ArrayList(u8).Writer);
    const white = TestStyle.rgbTo256(255, 255, 255);
    try std.testing.expect(white == 231); // Nearest white in 256 color palette

    const black = TestStyle.rgbTo256(0, 0, 0);
    try std.testing.expect(black == 16); // Nearest black in 256 color palette
}
