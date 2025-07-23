const std = @import("std");
const builtin = @import("builtin");

/// Terminal capability detection and styling
pub const Style = struct {
    /// Color capability of the terminal
    pub const ColorMode = enum {
        none, // NO_COLOR or dumb terminal
        basic, // 16 colors
        extended, // 256 colors
        truecolor, // 24-bit RGB

        /// Detect color mode from environment
        pub fn detect() ColorMode {
            // Check NO_COLOR standard
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR")) |_| {
                return .none;
            } else |_| {}

            // Check TERM
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM")) |term| {
                defer std.heap.page_allocator.free(term);

                if (std.mem.eql(u8, term, "dumb")) return .none;
                if (std.mem.indexOf(u8, term, "256color") != null) return .extended;
                if (std.mem.indexOf(u8, term, "truecolor") != null) return .truecolor;

                // Check COLORTERM for true color
                if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM")) |colorterm| {
                    defer std.heap.page_allocator.free(colorterm);
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
    use_icons: bool,
    writer: std.fs.File.Writer,

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
    pub fn init(writer: std.fs.File.Writer) Style {
        const color_mode = ColorMode.detect();
        const use_icons = detectIconSupport();

        return .{
            .color_mode = color_mode,
            .use_icons = use_icons,
            .writer = writer,
        };
    }

    /// Set foreground color
    pub fn setColor(self: Style, color: Color) !void {
        if (self.color_mode == .none) return;
        try self.writer.print("\x1b[{d}m", .{@intFromEnum(color)});
    }

    /// Set text attribute
    pub fn setAttribute(self: Style, attr: Attribute) !void {
        if (self.color_mode == .none) return;
        try self.writer.print("\x1b[{d}m", .{@intFromEnum(attr)});
    }

    /// Reset all styling
    pub fn reset(self: Style) !void {
        if (self.color_mode == .none) return;
        try self.writer.writeAll("\x1b[0m");
    }

    /// Set RGB color (true color mode only)
    pub fn setRGB(self: Style, r: u8, g: u8, b: u8) !void {
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
    pub fn print(self: Style, comptime fmt: []const u8, args: anytype, color: Color) !void {
        try self.setColor(color);
        try self.writer.print(fmt, args);
        try self.reset();
    }

    /// Print with icon
    pub fn printWithIcon(self: Style, icon: []const u8, fallback: []const u8, text: []const u8, color: Color) !void {
        const prefix = if (self.use_icons) icon else fallback;
        try self.setColor(color);
        try self.writer.print("{s} {s}", .{ prefix, text });
        try self.reset();
    }

    /// File type styling
    pub fn styleFileType(_: Style, file_type: std.fs.File.Kind) struct { icon: []const u8, color: Color } {
        return switch (file_type) {
            .directory => .{ .icon = "📁", .color = .bright_blue },
            .sym_link => .{ .icon = "🔗", .color = .bright_cyan },
            .block_device => .{ .icon = "💾", .color = .bright_yellow },
            .character_device => .{ .icon = "🔌", .color = .bright_yellow },
            .named_pipe => .{ .icon = "🚰", .color = .yellow },
            .unix_domain_socket => .{ .icon = "🔌", .color = .magenta },
            else => .{ .icon = "📄", .color = .default },
        };
    }

    /// Detect if terminal likely supports Unicode icons
    fn detectIconSupport() bool {
        // Check LANG/LC_ALL for UTF-8
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "LANG")) |lang| {
            defer std.heap.page_allocator.free(lang);
            if (std.mem.indexOf(u8, lang, "UTF-8") != null or
                std.mem.indexOf(u8, lang, "utf8") != null)
            {
                return true;
            }
        } else |_| {}

        // Conservative default
        return false;
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

test "Style color detection" {
    const mode = Style.ColorMode.detect();
    try std.testing.expect(@intFromEnum(mode) >= 0);
}

test "Style RGB to 256 color conversion" {
    const white = Style.rgbTo256(255, 255, 255);
    try std.testing.expect(white == 231); // Nearest white in 256 color palette

    const black = Style.rgbTo256(0, 0, 0);
    try std.testing.expect(black == 16); // Nearest black in 256 color palette
}
