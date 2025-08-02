//! Unicode display width calculation for terminal output
//!
//! This module provides utilities for calculating the correct display width
//! of Unicode strings in terminal applications. It handles:
//! - Fast ASCII path (most common case)
//! - East Asian Wide characters (CJK ideographs, full-width forms)
//! - Combining characters and diacritical marks
//! - Invalid UTF-8 sequences (counted as width 1)
//!
//! The implementation follows the Unicode Standard Annex #11 (East Asian Width)
//! and aims for high performance on ASCII text while correctly handling
//! international characters.

const std = @import("std");
const testing = std.testing;

/// Calculate the display width of a string in terminal columns
///
/// This function returns the number of terminal columns that the string
/// would occupy when displayed. This is different from byte length or
/// grapheme count for strings containing:
/// - East Asian Wide characters (width 2)
/// - Combining characters (width 0)
/// - Control characters (width 0)
///
/// Example:
/// ```zig
/// const width1 = displayWidth("hello");        // 5 (ASCII)
/// const width2 = displayWidth("你好");          // 4 (2 CJK chars, 2 columns each)
/// const width3 = displayWidth("café");         // 4 (4 chars including combining accent)
/// ```
pub fn displayWidth(str: []const u8) usize {
    // Fast path for ASCII-only strings without control characters
    if (isAscii(str) and !hasControlChars(str)) {
        return str.len;
    }

    // Slow path for Unicode strings or ASCII with control characters
    return calculateUnicodeWidth(str);
}

/// Check if a string contains only ASCII characters (fast path)
fn isAscii(str: []const u8) bool {
    for (str) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

/// Check if a string contains ASCII control characters
fn hasControlChars(str: []const u8) bool {
    for (str) |byte| {
        if (byte < 0x20 or byte == 0x7F) return true;
    }
    return false;
}

/// Calculate display width for strings containing Unicode characters
fn calculateUnicodeWidth(str: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;

    while (i < str.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch {
            // Invalid UTF-8 sequence - count as width 1 and advance by 1 byte
            width += 1;
            i += 1;
            continue;
        };

        if (i + cp_len > str.len) {
            // Truncated UTF-8 sequence - count as width 1
            width += 1;
            break;
        }

        const codepoint = std.unicode.utf8Decode(str[i .. i + cp_len]) catch {
            // Invalid UTF-8 sequence - count as width 1
            width += 1;
            i += cp_len;
            continue;
        };

        width += codepointWidth(codepoint);
        i += cp_len;
    }

    return width;
}

/// Get the display width of a single Unicode codepoint
fn codepointWidth(codepoint: u21) usize {
    // Control characters have zero width
    if (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) {
        return 0;
    }

    // Combining characters have zero width
    if (isCombining(codepoint)) {
        return 0;
    }

    // East Asian Wide characters have width 2
    if (isEastAsianWide(codepoint)) {
        return 2;
    }

    // Default width is 1
    return 1;
}

/// Check if a codepoint is a combining character (zero width)
fn isCombining(codepoint: u21) bool {
    // Combining Diacritical Marks (U+0300-U+036F)
    if (codepoint >= 0x0300 and codepoint <= 0x036F) return true;

    // Combining Diacritical Marks Extended (U+1AB0-U+1AFF)
    if (codepoint >= 0x1AB0 and codepoint <= 0x1AFF) return true;

    // Combining Diacritical Marks Supplement (U+1DC0-U+1DFF)
    if (codepoint >= 0x1DC0 and codepoint <= 0x1DFF) return true;

    // Combining Half Marks (U+FE20-U+FE2F)
    if (codepoint >= 0xFE20 and codepoint <= 0xFE2F) return true;

    // More comprehensive combining check would require Unicode data tables
    // For now, cover the most common cases
    return false;
}

/// Check if a codepoint is East Asian Wide (width 2)
fn isEastAsianWide(codepoint: u21) bool {
    // CJK Ideographs (most common wide characters)
    if (codepoint >= 0x4E00 and codepoint <= 0x9FFF) return true; // CJK Unified Ideographs
    if (codepoint >= 0x3400 and codepoint <= 0x4DBF) return true; // CJK Extension A
    if (codepoint >= 0x20000 and codepoint <= 0x2A6DF) return true; // CJK Extension B
    if (codepoint >= 0x2A700 and codepoint <= 0x2B73F) return true; // CJK Extension C
    if (codepoint >= 0x2B740 and codepoint <= 0x2B81F) return true; // CJK Extension D
    if (codepoint >= 0x2B820 and codepoint <= 0x2CEAF) return true; // CJK Extension E
    if (codepoint >= 0x2CEB0 and codepoint <= 0x2EBEF) return true; // CJK Extension F

    // Hangul Syllables
    if (codepoint >= 0xAC00 and codepoint <= 0xD7AF) return true;

    // Hiragana and Katakana
    if (codepoint >= 0x3040 and codepoint <= 0x309F) return true; // Hiragana
    if (codepoint >= 0x30A0 and codepoint <= 0x30FF) return true; // Katakana

    // Full-width ASCII variants
    if (codepoint >= 0xFF01 and codepoint <= 0xFF60) return true;
    if (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) return true;

    // CJK Symbols and Punctuation
    if (codepoint >= 0x3000 and codepoint <= 0x303F) return true;

    // Additional East Asian ranges (common ones)
    if (codepoint >= 0x2E80 and codepoint <= 0x2EFF) return true; // CJK Radicals Supplement
    if (codepoint >= 0x2F00 and codepoint <= 0x2FDF) return true; // Kangxi Radicals
    if (codepoint >= 0x3100 and codepoint <= 0x312F) return true; // Bopomofo
    if (codepoint >= 0x31A0 and codepoint <= 0x31BF) return true; // Bopomofo Extended

    return false;
}

// Tests

test "displayWidth: ASCII strings" {
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
    try testing.expectEqual(@as(usize, 1), displayWidth("a"));
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try testing.expectEqual(@as(usize, 13), displayWidth("hello world!!"));
    try testing.expectEqual(@as(usize, 26), displayWidth("abcdefghijklmnopqrstuvwxyz"));
}

test "displayWidth: CJK characters (width 2)" {
    try testing.expectEqual(@as(usize, 2), displayWidth("你"));
    try testing.expectEqual(@as(usize, 4), displayWidth("你好"));
    try testing.expectEqual(@as(usize, 10), displayWidth("こんにちは")); // 5 hiragana chars × 2
    try testing.expectEqual(@as(usize, 4), displayWidth("안녕"));
    try testing.expectEqual(@as(usize, 8), displayWidth("中文测试"));
}

test "displayWidth: mixed ASCII and CJK" {
    try testing.expectEqual(@as(usize, 7), displayWidth("hello你"));
    try testing.expectEqual(@as(usize, 9), displayWidth("hello你好"));
    try testing.expectEqual(@as(usize, 12), displayWidth("test中文.txt")); // 4 + 2*2 + 4 = 12
    try testing.expectEqual(@as(usize, 15), displayWidth("file-中文名.ext")); // 5 + 3×2 + 4 = 15
}

test "displayWidth: combining characters" {
    // Basic Latin + combining acute accent
    try testing.expectEqual(@as(usize, 1), displayWidth("é")); // e + combining acute
    try testing.expectEqual(@as(usize, 4), displayWidth("café")); // assuming composed form

    // Note: This test may need adjustment based on how the string is encoded
    // (composed vs decomposed form)
}

test "displayWidth: control characters" {
    try testing.expectEqual(@as(usize, 0), displayWidth("\x00"));
    try testing.expectEqual(@as(usize, 0), displayWidth("\x1F"));
    try testing.expectEqual(@as(usize, 0), displayWidth("\x7F"));
    try testing.expectEqual(@as(usize, 10), displayWidth("hello\x00world")); // control chars don't add width
}

test "displayWidth: full-width ASCII" {
    // Full-width ASCII characters (commonly used in East Asian text)
    try testing.expectEqual(@as(usize, 2), displayWidth("Ａ")); // Full-width A
    try testing.expectEqual(@as(usize, 2), displayWidth("１")); // Full-width 1
    try testing.expectEqual(@as(usize, 4), displayWidth("ＡＢ")); // Full-width AB
}

test "displayWidth: invalid UTF-8" {
    // Invalid UTF-8 sequences should be counted as width 1 per byte
    const invalid_utf8 = [_]u8{ 0xFF, 0xFE, 0xFD };
    try testing.expectEqual(@as(usize, 3), displayWidth(&invalid_utf8));

    // Mix of valid and invalid
    const mixed = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0xFF, 0xFE };
    try testing.expectEqual(@as(usize, 7), displayWidth(&mixed));
}

test "displayWidth: truncated UTF-8" {
    // Truncated multi-byte sequence should be counted as width 1
    const truncated = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0xE4, 0xB8 }; // truncated 你
    try testing.expectEqual(@as(usize, 6), displayWidth(&truncated));
}

test "displayWidth: empty and whitespace" {
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
    try testing.expectEqual(@as(usize, 1), displayWidth(" "));
    try testing.expectEqual(@as(usize, 3), displayWidth("   "));
    try testing.expectEqual(@as(usize, 0), displayWidth("\t")); // tab is control character, width 0
}

test "displayWidth: real filename examples" {
    // Common filename patterns that might contain Unicode
    try testing.expectEqual(@as(usize, 8), displayWidth("test.txt"));
    try testing.expectEqual(@as(usize, 12), displayWidth("测试文件.txt")); // 4 CJK × 2 + 4 ASCII = 12
    try testing.expectEqual(@as(usize, 15), displayWidth("プロジェクト.md")); // 6 katakana × 2 + 3 ASCII = 15
    try testing.expectEqual(@as(usize, 15), displayWidth("문서-파일명.pdf"));
    try testing.expectEqual(@as(usize, 18), displayWidth("混合-mixed-名前.js")); // 4 CJK × 2 + 10 ASCII = 18
}

test "isAscii helper function" {
    try testing.expect(isAscii(""));
    try testing.expect(isAscii("hello"));
    try testing.expect(isAscii("Hello World 123!"));
    try testing.expect(isAscii("abcdefghijklmnopqrstuvwxyz"));
    try testing.expect(!isAscii("café"));
    try testing.expect(!isAscii("你好"));
    try testing.expect(!isAscii("hello你"));
}

test "codepointWidth helper function" {
    // ASCII characters
    try testing.expectEqual(@as(usize, 1), codepointWidth('a'));
    try testing.expectEqual(@as(usize, 1), codepointWidth('Z'));
    try testing.expectEqual(@as(usize, 1), codepointWidth('0'));
    try testing.expectEqual(@as(usize, 1), codepointWidth(' '));

    // Control characters
    try testing.expectEqual(@as(usize, 0), codepointWidth(0x00));
    try testing.expectEqual(@as(usize, 0), codepointWidth(0x1F));
    try testing.expectEqual(@as(usize, 0), codepointWidth(0x7F));

    // CJK characters
    try testing.expectEqual(@as(usize, 2), codepointWidth(0x4E00)); // 一
    try testing.expectEqual(@as(usize, 2), codepointWidth(0x4F60)); // 你
    try testing.expectEqual(@as(usize, 2), codepointWidth(0x597D)); // 好

    // Hiragana/Katakana
    try testing.expectEqual(@as(usize, 2), codepointWidth(0x3042)); // あ
    try testing.expectEqual(@as(usize, 2), codepointWidth(0x30A2)); // ア

    // Hangul
    try testing.expectEqual(@as(usize, 2), codepointWidth(0xAC00)); // 가
}
