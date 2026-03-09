const std = @import("std");
const display_config = @import("display_config.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// ANSI escape sequences for help text colorization.
const esc_bold = "\x1b[1m";
const esc_dim = "\x1b[2m";
const esc_cyan = "\x1b[36m";
const esc_yellow = "\x1b[33m";
const esc_green = "\x1b[32m";
const esc_bright_blue = "\x1b[94m";
const esc_reset = "\x1b[0m";

/// Nerd Font glyphs for help section markers.
const glyph_usage = "\u{f0ad} "; // wrench
const glyph_options = "\u{f1de} "; // sliders
const glyph_examples = "\u{f0eb} "; // lightbulb
const glyph_flag = "\u{f024} "; // flag

/// Terminal capability flags for help rendering.
pub const HelpStyle = struct {
    use_color: bool = false,
    use_glyphs: bool = false,
};

/// Print help text with ANSI colors and optional nerd-font glyphs
/// when the terminal supports them.
///
/// Detects whether stdout is a TTY with color support and whether
/// the locale indicates unicode capability. Delegates to colorizeHelp
/// with the appropriate flags.
pub fn printColorized(
    allocator: Allocator,
    writer: anytype,
    help_text: []const u8,
) !void {
    const config = display_config.DisplayConfig.resolve(allocator);
    const help_style = HelpStyle{
        .use_color = config.color == .on,
        .use_glyphs = config.icons == .on and hasUnicodeSupport(allocator),
    };
    try colorizeHelp(writer, help_text, help_style);
}

/// Check whether the locale indicates UTF-8 / unicode support.
///
/// Inspects LC_ALL, LC_CTYPE, and LANG in priority order. Returns
/// true if any contains "UTF-8" or "utf8" (case-insensitive).
pub fn hasUnicodeSupport(allocator: Allocator) bool {
    const vars = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (vars) |name| {
        if (std.process.getEnvVarOwned(allocator, name)) |val| {
            defer allocator.free(val);
            if (containsUtf8(val)) return true;
        } else |_| {}
    }
    return false;
}

/// Return true if the string contains "UTF-8" or "utf8" (case-insensitive).
fn containsUtf8(val: []const u8) bool {
    // Check common patterns: ".UTF-8", ".utf8", ".utf-8"
    var lower_buf: [256]u8 = undefined;
    const len = @min(val.len, lower_buf.len);
    for (val[0..len], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..len];
    if (std.mem.indexOf(u8, lower, "utf-8") != null) return true;
    if (std.mem.indexOf(u8, lower, "utf8") != null) return true;
    return false;
}

/// Write help text to writer, applying ANSI color when use_color is true.
///
/// Classifies each line and applies colors:
/// - Usage lines: green label, bold utility name, cyan flags, yellow UPPERCASE args
/// - Section headers: bold with optional nerd-font glyph
/// - Flag lines: cyan flags, yellow =VALUE and UPPERCASE placeholders, dim description
/// - DD-style operand lines: cyan name, yellow value placeholder, dim description
/// - Everything else: dim text for visual hierarchy
///
/// No heap allocation. Purely streaming output.
pub fn colorizeHelp(writer: anytype, help_text: []const u8, help_style: anytype) !void {
    // Accept either HelpStyle struct or bool for backward compatibility
    const use_color, const use_glyphs = blk: {
        const T = @TypeOf(help_style);
        if (T == bool) {
            break :blk .{ help_style, false };
        } else if (T == HelpStyle) {
            break :blk .{ help_style.use_color, help_style.use_glyphs };
        } else {
            @compileError("colorizeHelp: help_style must be bool or HelpStyle");
        }
    };

    if (!use_color) {
        try writer.writeAll(help_text);
        return;
    }

    var pos: usize = 0;
    while (pos < help_text.len) {
        // Find end of current line
        const line_end = std.mem.indexOfScalar(u8, help_text[pos..], '\n');
        const line = if (line_end) |end| help_text[pos .. pos + end] else help_text[pos..];

        try colorizeLine(writer, line, use_glyphs);

        if (line_end) |end| {
            try writer.writeAll("\n");
            pos += end + 1;
        } else {
            pos = help_text.len;
        }
    }
}

/// Classify and colorize a single line (without trailing newline).
fn colorizeLine(writer: anytype, line: []const u8, use_glyphs: bool) !void {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    const indent_len = line.len - trimmed.len;

    // Empty or whitespace-only line
    if (trimmed.len == 0) {
        try writer.writeAll(line);
        return;
    }

    // Usage line: starts with "Usage:" or indented "or:"
    if (std.mem.startsWith(u8, trimmed, "Usage:") or
        (indent_len > 0 and std.mem.startsWith(u8, trimmed, "or:")))
    {
        try colorizeUsageLine(writer, line, indent_len, trimmed, use_glyphs);
        return;
    }

    // Flag line: 2+ spaces indent, first non-space is '-'
    if (indent_len >= 2 and trimmed[0] == '-') {
        try colorizeFlagLine(writer, line, indent_len, trimmed);
        return;
    }

    // DD-style operand line: 2+ spaces indent, contains '=' before
    // description text (word=VALUE pattern)
    if (indent_len >= 2 and trimmed[0] != '-') {
        if (isDdOperandLine(trimmed)) {
            try colorizeDdLine(writer, line, indent_len, trimmed);
            return;
        }
    }

    // Section header: no leading whitespace, ends with ':'
    if (indent_len == 0 and trimmed.len > 1 and trimmed[trimmed.len - 1] == ':') {
        try colorizeSectionHeader(writer, line, use_glyphs);
        return;
    }

    // Default: dim text with UPPERCASE placeholder highlighting
    try colorizeDefaultLine(writer, line);
}

/// Colorize a default (non-classified) line: dim text with UPPERCASE
/// placeholders highlighted in yellow.
fn colorizeDefaultLine(writer: anytype, line: []const u8) !void {
    var in_dim = false;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ') {
            if (!in_dim) {
                try writer.writeAll(esc_dim);
                in_dim = true;
            }
            try writer.writeByte(' ');
            i += 1;
            continue;
        }

        var end = i;
        while (end < line.len and line[end] != ' ') : (end += 1) {}
        const token = line[i..end];

        if (isUppercasePlaceholder(token)) {
            if (in_dim) {
                try writer.writeAll(esc_reset);
                in_dim = false;
            }
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else {
            if (!in_dim) {
                try writer.writeAll(esc_dim);
                in_dim = true;
            }
            try writer.writeAll(token);
        }

        i = end;
    }
    if (in_dim) {
        try writer.writeAll(esc_reset);
    }
}

/// Map well-known section header labels to nerd-font glyphs.
fn getGlyphForSection(header: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, header, "Options:")) return glyph_options;
    if (std.mem.eql(u8, header, "Examples:")) return glyph_examples;
    if (std.mem.eql(u8, header, "Flags:")) return glyph_flag;
    return null;
}

/// Colorize a section header line with optional nerd-font glyph.
fn colorizeSectionHeader(writer: anytype, line: []const u8, use_glyphs: bool) !void {
    try writer.writeAll(esc_bold);
    try writer.writeAll(esc_bright_blue);
    if (use_glyphs) {
        if (getGlyphForSection(line)) |glyph| {
            try writer.writeAll(glyph);
        }
    }
    try writer.writeAll(line);
    try writer.writeAll(esc_reset);
}

/// Check if a trimmed line looks like a DD-style operand (word=VALUE).
fn isDdOperandLine(trimmed: []const u8) bool {
    // Find first '=' — it must appear within the first "word" (no spaces
    // before it) and there must be at least one char before and after.
    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    if (eq_pos == 0) return false;
    // No spaces before the '='
    for (trimmed[0..eq_pos]) |c| {
        if (c == ' ') return false;
    }
    return true;
}

/// Colorize a Usage/or: line.
fn colorizeUsageLine(writer: anytype, line: []const u8, indent_len: usize, trimmed: []const u8, use_glyphs: bool) !void {
    // Write leading whitespace
    try writer.writeAll(line[0..indent_len]);

    // Write the prefix ("Usage:" or "or:") in green+bold
    const prefix_end = if (std.mem.startsWith(u8, trimmed, "Usage:"))
        @as(usize, 6)
    else
        @as(usize, 3);

    // Add glyph before "Usage:" label
    if (use_glyphs and std.mem.startsWith(u8, trimmed, "Usage:")) {
        try writer.writeAll(esc_green);
        try writer.writeAll(glyph_usage);
        try writer.writeAll(esc_reset);
    }

    try writer.writeAll(esc_bold);
    try writer.writeAll(esc_green);
    try writer.writeAll(trimmed[0..prefix_end]);
    try writer.writeAll(esc_reset);

    // Tokenize the rest and colorize
    const rest = trimmed[prefix_end..];
    var first = true;
    var i: usize = 0;
    while (i < rest.len) {
        // Skip spaces, writing them out
        if (rest[i] == ' ') {
            try writer.writeByte(' ');
            i += 1;
            continue;
        }

        // Find end of token
        var end = i;
        while (end < rest.len and rest[end] != ' ') : (end += 1) {}
        const token = rest[i..end];

        if (first) {
            // First word after prefix is the utility name — bold it
            try writer.writeAll(esc_bold);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
            first = false;
        } else if (token.len > 0 and token[0] == '-') {
            // Flag-like token — cyan
            try writer.writeAll(esc_cyan);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else if (isUppercasePlaceholder(token)) {
            // UPPERCASE placeholder — yellow
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else {
            try writer.writeAll(token);
        }

        i = end;
    }
}

/// Colorize a flag line (e.g. "  -n, --number    description").
fn colorizeFlagLine(writer: anytype, line: []const u8, indent_len: usize, trimmed: []const u8) !void {
    // Write leading whitespace
    try writer.writeAll(line[0..indent_len]);

    // Find where the flag cluster ends: look for a gap of 2+ spaces
    // after the flags start, or end of line.
    const desc_start = findDescriptionStart(trimmed);
    const flag_part = trimmed[0..desc_start];
    const desc_part = trimmed[desc_start..];

    // Colorize flag part: flags in cyan, =VALUE in yellow
    try colorizeFlagTokens(writer, flag_part);

    // Write description part, colorizing UPPERCASE placeholders
    try colorizeDescriptionTokens(writer, desc_part);
}

/// Find the byte offset where the description starts (after 2+ space gap).
fn findDescriptionStart(trimmed: []const u8) usize {
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == ' ') {
            // Count consecutive spaces
            var space_count: usize = 0;
            const space_start = i;
            while (i < trimmed.len and trimmed[i] == ' ') : (i += 1) {
                space_count += 1;
            }
            if (space_count >= 2) {
                return space_start;
            }
        } else {
            i += 1;
        }
    }
    return trimmed.len;
}

/// Colorize the flag portion of a flag line, handling comma-separated
/// flags and =VALUE suffixes.
fn colorizeFlagTokens(writer: anytype, flag_part: []const u8) !void {
    var i: usize = 0;
    while (i < flag_part.len) {
        if (flag_part[i] == ' ' or flag_part[i] == ',') {
            try writer.writeByte(flag_part[i]);
            i += 1;
            continue;
        }

        // Find end of this token
        var end = i;
        while (end < flag_part.len and flag_part[end] != ' ' and flag_part[end] != ',') : (end += 1) {}
        const token = flag_part[i..end];

        // Check for =VALUE within the token
        if (std.mem.indexOfScalar(u8, token, '=')) |eq_pos| {
            // Flag part before '='
            try writer.writeAll(esc_cyan);
            try writer.writeAll(token[0 .. eq_pos + 1]);
            try writer.writeAll(esc_reset);
            // Value part after '='
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token[eq_pos + 1 ..]);
            try writer.writeAll(esc_reset);
        } else if (token.len > 0 and token[0] == '-') {
            try writer.writeAll(esc_cyan);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else if (isUppercasePlaceholder(token)) {
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else {
            try writer.writeAll(token);
        }

        i = end;
    }
}

/// Colorize description text, highlighting UPPERCASE placeholders.
/// Regular description words are rendered dim for visual hierarchy.
fn colorizeDescriptionTokens(writer: anytype, desc: []const u8) !void {
    // Track whether we've started the dim region
    var in_dim = false;
    var i: usize = 0;
    while (i < desc.len) {
        if (desc[i] == ' ') {
            if (!in_dim) {
                try writer.writeAll(esc_dim);
                in_dim = true;
            }
            try writer.writeByte(' ');
            i += 1;
            continue;
        }

        var end = i;
        while (end < desc.len and desc[end] != ' ') : (end += 1) {}
        const token = desc[i..end];

        if (isUppercasePlaceholder(token)) {
            if (in_dim) {
                try writer.writeAll(esc_reset);
                in_dim = false;
            }
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else {
            if (!in_dim) {
                try writer.writeAll(esc_dim);
                in_dim = true;
            }
            try writer.writeAll(token);
        }

        i = end;
    }
    if (in_dim) {
        try writer.writeAll(esc_reset);
    }
}

/// Colorize a DD-style operand line (e.g. "  if=FILE  description").
fn colorizeDdLine(writer: anytype, line: []const u8, indent_len: usize, trimmed: []const u8) !void {
    try writer.writeAll(line[0..indent_len]);

    // Find the operand token (first token containing '=')
    const desc_start = findDescriptionStart(trimmed);
    const operand_part = trimmed[0..desc_start];
    const desc_part = trimmed[desc_start..];

    // Find '=' in the operand
    if (std.mem.indexOfScalar(u8, operand_part, '=')) |eq_pos| {
        try writer.writeAll(esc_cyan);
        try writer.writeAll(operand_part[0 .. eq_pos + 1]);
        try writer.writeAll(esc_reset);
        const value = operand_part[eq_pos + 1 ..];
        if (value.len > 0) {
            try writer.writeAll(esc_yellow);
            try writer.writeAll(value);
            try writer.writeAll(esc_reset);
        }
    } else {
        try writer.writeAll(operand_part);
    }

    try colorizeDescriptionTokens(writer, desc_part);
}

/// Return true if token is an UPPERCASE placeholder (2+ chars, all
/// uppercase letters, digits, underscores, or surrounding punctuation
/// like [], ..., trailing commas, and (s) suffixes).
fn isUppercasePlaceholder(token: []const u8) bool {
    if (token.len < 2) return false;

    // Strip surrounding punctuation for checking
    var start: usize = 0;
    var end: usize = token.len;

    // Strip leading brackets/parens
    while (start < end and (token[start] == '[' or token[start] == '(')) : (start += 1) {}
    // Strip trailing punctuation: brackets, parens, ellipsis, commas, semicolons, colons
    while (end > start and (token[end - 1] == ']' or token[end - 1] == ')' or
        token[end - 1] == '.' or token[end - 1] == ',' or
        token[end - 1] == ';' or token[end - 1] == ':')) : (end -= 1)
    {}

    // Handle (s) suffix: "SOURCE(s)" → strip "(s" from end
    if (end > start + 2 and token[end - 1] == 's' and token[end - 2] == '(') {
        end -= 2;
    }

    if (end <= start) return false;
    const inner = token[start..end];
    if (inner.len < 2) return false;

    var has_upper = false;
    for (inner) |c| {
        if (std.ascii.isUpper(c)) {
            has_upper = true;
        } else if (c != '_' and c != '-' and !std.ascii.isDigit(c)) {
            return false;
        }
    }
    return has_upper;
}

// ========== TESTS ==========

test "plain mode passthrough" {
    const text =
        \\Usage: echo [OPTION]... [STRING]...
        \\Echo the STRING(s) to standard output.
        \\
        \\  -n         do not output the trailing newline
        \\  --help     display this help and exit
        \\
    ;
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, false);
    try testing.expectEqualStrings(text, buffer.items);
}

test "usage line colorization" {
    const text = "Usage: echo [OPTION]... [STRING]...\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // "Usage:" label should be bold green
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ esc_green ++ "Usage:" ++ esc_reset) != null);
    // Utility name "echo" should be bold
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ "echo" ++ esc_reset) != null);
    // [OPTION]... should be yellow (uppercase placeholder)
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "[OPTION]..." ++ esc_reset) != null);
    // [STRING]... should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "[STRING]..." ++ esc_reset) != null);
}

test "usage line with glyphs" {
    const text = "Usage: echo [OPTION]...\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = true, .use_glyphs = true });
    const result = buffer.items;

    // Should contain the usage glyph
    try testing.expect(std.mem.indexOf(u8, result, glyph_usage) != null);
}

test "section header bold with color" {
    const text = "Options:\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    try testing.expectEqualStrings(esc_bold ++ esc_bright_blue ++ "Options:" ++ esc_reset ++ "\n", buffer.items);
}

test "section header with glyphs" {
    const text = "Options:\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = true, .use_glyphs = true });
    const result = buffer.items;

    // Should contain the options glyph
    try testing.expect(std.mem.indexOf(u8, result, glyph_options) != null);
    // Should still be bold + bright blue
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ esc_bright_blue) != null);
}

test "examples header gets glyph" {
    const text = "Examples:\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = true, .use_glyphs = true });
    const result = buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, glyph_examples) != null);
}

test "unknown section header gets no glyph" {
    const text = "Notes:\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = true, .use_glyphs = true });
    const result = buffer.items;

    // Should not contain any of the known glyphs
    try testing.expect(std.mem.indexOf(u8, result, glyph_options) == null);
    try testing.expect(std.mem.indexOf(u8, result, glyph_examples) == null);
    try testing.expect(std.mem.indexOf(u8, result, glyph_flag) == null);
    // But should still be bold + bright blue
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ esc_bright_blue) != null);
}

test "flag line colorization" {
    const text = "  -n, --number    number all output lines\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // Flags should be cyan
    try testing.expect(std.mem.indexOf(u8, result, esc_cyan ++ "-n" ++ esc_reset) != null);
    try testing.expect(std.mem.indexOf(u8, result, esc_cyan ++ "--number" ++ esc_reset) != null);
    // Description text should be dim
    try testing.expect(std.mem.indexOf(u8, result, esc_dim) != null);
    try testing.expect(std.mem.indexOf(u8, result, "number all output lines") != null);
}

test "flag line with equals value" {
    const text = "  --color=WHEN    colorize the output\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // --color= should be cyan
    try testing.expect(std.mem.indexOf(u8, result, esc_cyan ++ "--color=" ++ esc_reset) != null);
    // WHEN should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "WHEN" ++ esc_reset) != null);
}

test "continuation lines dim with uppercase highlight" {
    const text = "                  LEVEL is one of: none, noxfer, progress\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);

    // Continuation/description lines should have dim text with UPPERCASE
    // placeholders highlighted in yellow
    const result = buffer.items;
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "LEVEL" ++ esc_reset) != null);
    try testing.expect(std.mem.indexOf(u8, result, esc_dim) != null);
}

test "dd-style operand line" {
    const text = "  if=FILE         read from FILE instead of stdin\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // if= should be cyan
    try testing.expect(std.mem.indexOf(u8, result, esc_cyan ++ "if=" ++ esc_reset) != null);
    // FILE (value) should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "FILE" ++ esc_reset) != null);
}

test "roundtrip with real echo help text" {
    const text =
        \\Usage: echo [OPTION]... [STRING]...
        \\Echo the STRING(s) to standard output.
        \\
        \\  -n         do not output the trailing newline
        \\  -e         enable interpretation of backslash escapes
        \\  -E         disable interpretation of backslash escapes (default)
        \\  --help     display this help and exit
        \\  --version  output version information and exit
        \\
        \\If -e is in effect, the following sequences are recognized:
        \\  \\a  alert (BEL)            \\n  new line
        \\  \\b  backspace              \\r  carriage return
        \\  \\c  produce no further output
        \\  \\e  escape                 \\t  horizontal tab
        \\  \\f  form feed              \\v  vertical tab
        \\  \\\\  backslash              \\0NNN  byte with octal value NNN
        \\  \\xHH  byte with hex value HH
        \\
    ;

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // Should not crash with color enabled
    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    try testing.expect(buffer.items.len > 0);

    // Should not crash with color disabled
    buffer.clearRetainingCapacity();
    try colorizeHelp(buffer.writer(testing.allocator), text, false);
    try testing.expectEqualStrings(text, buffer.items);
}

test "isUppercasePlaceholder" {
    // Valid placeholders
    try testing.expect(isUppercasePlaceholder("FILE"));
    try testing.expect(isUppercasePlaceholder("BYTES"));
    try testing.expect(isUppercasePlaceholder("[OPTION]..."));
    try testing.expect(isUppercasePlaceholder("[STRING]..."));
    try testing.expect(isUppercasePlaceholder("LEVEL"));
    try testing.expect(isUppercasePlaceholder("N"));
    // N is only 1 char inner — after strip it's 1 char, need 2+
    // Actually "N" stripped is "N" which is 1 char — returns false
    try testing.expect(!isUppercasePlaceholder("N"));
    try testing.expect(isUppercasePlaceholder("NR"));

    // Trailing punctuation
    try testing.expect(isUppercasePlaceholder("DEST,"));
    try testing.expect(isUppercasePlaceholder("DEST;"));
    try testing.expect(isUppercasePlaceholder("DEST:"));
    try testing.expect(isUppercasePlaceholder("DIRECTORY."));

    // Plural suffix (s)
    try testing.expect(isUppercasePlaceholder("SOURCE(s)"));
    try testing.expect(isUppercasePlaceholder("FILE(s)"));

    // Not placeholders
    try testing.expect(!isUppercasePlaceholder("a"));
    try testing.expect(!isUppercasePlaceholder("file"));
    try testing.expect(!isUppercasePlaceholder("-n"));
    try testing.expect(!isUppercasePlaceholder("do"));
    try testing.expect(!isUppercasePlaceholder(""));
}

test "or: usage line" {
    const text = "   or: cp [OPTION]... SOURCE... DIRECTORY\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // Utility name "cp" should be bold
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ "cp" ++ esc_reset) != null);
    // [OPTION]... should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "[OPTION]..." ++ esc_reset) != null);
    // SOURCE... should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "SOURCE..." ++ esc_reset) != null);
    // DIRECTORY should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "DIRECTORY" ++ esc_reset) != null);
}

test "text without trailing newline" {
    const text = "Some line without newline";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, false);
    try testing.expectEqualStrings(text, buffer.items);
}

test "containsUtf8 detection" {
    try testing.expect(containsUtf8("en_US.UTF-8"));
    try testing.expect(containsUtf8("en_US.utf8"));
    try testing.expect(containsUtf8("C.UTF-8"));
    try testing.expect(containsUtf8("POSIX.utf-8"));
    try testing.expect(!containsUtf8("C"));
    try testing.expect(!containsUtf8("POSIX"));
    try testing.expect(!containsUtf8(""));
}

test "default line gets dim treatment" {
    const text = "Some descriptive text line.\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    const result = buffer.items;

    // Default lines should be dim
    try testing.expect(std.mem.indexOf(u8, result, esc_dim) != null);
    try testing.expect(std.mem.indexOf(u8, result, "Some descriptive text line.") != null);
}

test "HelpStyle struct with color only" {
    const text = "Options:\n  -v, --verbose    be verbose\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = true, .use_glyphs = false });
    const result = buffer.items;

    // Section header should have color
    try testing.expect(std.mem.indexOf(u8, result, esc_bold) != null);
    // No glyphs
    try testing.expect(std.mem.indexOf(u8, result, glyph_options) == null);
}

test "HelpStyle no color passthrough" {
    const text = "Options:\n  -v    be verbose\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, HelpStyle{ .use_color = false, .use_glyphs = false });
    try testing.expectEqualStrings(text, buffer.items);
}
