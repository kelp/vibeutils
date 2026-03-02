const std = @import("std");
const style = @import("style.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// ANSI escape sequences for help text colorization.
const esc_bold = "\x1b[1m";
const esc_cyan = "\x1b[36m";
const esc_yellow = "\x1b[33m";
const esc_reset = "\x1b[0m";

/// Print help text with ANSI colors when the terminal supports it.
///
/// Detects whether stdout is a TTY with color support and delegates
/// to colorizeHelp with the appropriate flag.
pub fn printColorized(
    allocator: Allocator,
    writer: anytype,
    help_text: []const u8,
) !void {
    const use_color = shouldColorize(allocator);
    try colorizeHelp(writer, help_text, use_color);
}

/// Determine whether color output is appropriate.
///
/// Returns true only when stdout is a TTY and the terminal supports
/// at least basic color (NO_COLOR is not set, TERM is not "dumb").
pub fn shouldColorize(allocator: Allocator) bool {
    if (!std.posix.isatty(std.fs.File.stdout().handle)) return false;
    // Use any Writer type to access ColorMode — detect() does not
    // use the Writer type parameter at all.
    const DummyWriter = @TypeOf(std.io.null_writer);
    const ColorMode = style.Style(DummyWriter).ColorMode;
    const mode = ColorMode.detect(allocator) catch return false;
    return mode != .none;
}

/// Write help text to writer, applying ANSI color when use_color is true.
///
/// Classifies each line and applies colors:
/// - Usage lines: bold utility name, cyan flags, yellow UPPERCASE args
/// - Section headers: bold entire line
/// - Flag lines: cyan flags, yellow =VALUE and UPPERCASE placeholders
/// - DD-style operand lines: cyan name, yellow value placeholder
/// - Everything else: unchanged
///
/// No heap allocation. Purely streaming output.
pub fn colorizeHelp(writer: anytype, help_text: []const u8, use_color: bool) !void {
    if (!use_color) {
        try writer.writeAll(help_text);
        return;
    }

    var pos: usize = 0;
    while (pos < help_text.len) {
        // Find end of current line
        const line_end = std.mem.indexOfScalar(u8, help_text[pos..], '\n');
        const line = if (line_end) |end| help_text[pos .. pos + end] else help_text[pos..];

        try colorizeLine(writer, line);

        if (line_end) |end| {
            try writer.writeAll("\n");
            pos += end + 1;
        } else {
            pos = help_text.len;
        }
    }
}

/// Classify and colorize a single line (without trailing newline).
fn colorizeLine(writer: anytype, line: []const u8) !void {
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
        try colorizeUsageLine(writer, line, indent_len, trimmed);
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
        try writer.writeAll(esc_bold);
        try writer.writeAll(line);
        try writer.writeAll(esc_reset);
        return;
    }

    // Default: write unchanged
    try writer.writeAll(line);
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
fn colorizeUsageLine(writer: anytype, line: []const u8, indent_len: usize, trimmed: []const u8) !void {
    // Write leading whitespace
    try writer.writeAll(line[0..indent_len]);

    // Write the prefix ("Usage:" or "or:")
    const prefix_end = if (std.mem.startsWith(u8, trimmed, "Usage:"))
        @as(usize, 6)
    else
        @as(usize, 3);

    try writer.writeAll(trimmed[0..prefix_end]);

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
fn colorizeDescriptionTokens(writer: anytype, desc: []const u8) !void {
    var i: usize = 0;
    while (i < desc.len) {
        if (desc[i] == ' ') {
            try writer.writeByte(' ');
            i += 1;
            continue;
        }

        var end = i;
        while (end < desc.len and desc[end] != ' ') : (end += 1) {}
        const token = desc[i..end];

        if (isUppercasePlaceholder(token)) {
            try writer.writeAll(esc_yellow);
            try writer.writeAll(token);
            try writer.writeAll(esc_reset);
        } else {
            try writer.writeAll(token);
        }

        i = end;
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
/// like [] and ...).
fn isUppercasePlaceholder(token: []const u8) bool {
    if (token.len < 2) return false;

    // Strip surrounding brackets/parens/ellipsis for checking
    var start: usize = 0;
    var end: usize = token.len;

    // Strip leading punctuation
    while (start < end and (token[start] == '[' or token[start] == '(')) : (start += 1) {}
    // Strip trailing punctuation
    while (end > start and (token[end - 1] == ']' or token[end - 1] == ')' or token[end - 1] == '.')) : (end -= 1) {}

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

    // Utility name "echo" should be bold
    try testing.expect(std.mem.indexOf(u8, result, esc_bold ++ "echo" ++ esc_reset) != null);
    // [OPTION]... should be yellow (uppercase placeholder)
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "[OPTION]..." ++ esc_reset) != null);
    // [STRING]... should be yellow
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "[STRING]..." ++ esc_reset) != null);
}

test "section header bold" {
    const text = "Options:\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);
    try testing.expectEqualStrings(esc_bold ++ "Options:" ++ esc_reset ++ "\n", buffer.items);
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
    // Description text should not have color codes around it
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

test "continuation lines unchanged" {
    const text = "                  LEVEL is one of: none, noxfer, progress\n";
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try colorizeHelp(buffer.writer(testing.allocator), text, true);

    // Continuation/description lines with no leading '-' or '=' pattern
    // should still get UPPERCASE placeholder treatment for LEVEL
    const result = buffer.items;
    try testing.expect(std.mem.indexOf(u8, result, esc_yellow ++ "LEVEL" ++ esc_reset) != null);
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

test "shouldColorize returns false in test" {
    // Test stdout is not a TTY, so this should always return false
    const result = shouldColorize(testing.allocator);
    try testing.expect(!result);
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
