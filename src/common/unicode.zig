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
    // Test combining characters (zero-width) in decomposed form
    // These strings are manually constructed with base char + combining mark

    // Basic Latin + combining diacritical marks
    const e_acute = "e\u{0301}"; // e + combining acute accent → é
    try testing.expectEqual(@as(usize, 1), displayWidth(e_acute));

    const a_grave = "a\u{0300}"; // a + combining grave accent → à
    try testing.expectEqual(@as(usize, 1), displayWidth(a_grave));

    const n_tilde = "n\u{0303}"; // n + combining tilde → ñ
    try testing.expectEqual(@as(usize, 1), displayWidth(n_tilde));

    const u_diaeresis = "u\u{0308}"; // u + combining diaeresis → ü
    try testing.expectEqual(@as(usize, 1), displayWidth(u_diaeresis));

    // Multiple combining marks on single base character
    const a_grave_ring = "a\u{0300}\u{030A}"; // a + grave + ring above
    try testing.expectEqual(@as(usize, 1), displayWidth(a_grave_ring));

    // Combining marks in longer strings
    const cafe_decomposed = "cafe\u{0301}"; // "café" with decomposed é
    try testing.expectEqual(@as(usize, 4), displayWidth(cafe_decomposed));

    // Test string with only combining characters (should have zero width)
    const only_combining = "\u{0301}\u{0302}\u{0303}"; // Three combining marks
    try testing.expectEqual(@as(usize, 0), displayWidth(only_combining));

    // Mixed base characters and combining marks
    const complex = "a\u{0301}b\u{0302}c\u{0303}"; // á b̂ c̃
    try testing.expectEqual(@as(usize, 3), displayWidth(complex));

    // Note: These tests use manually constructed decomposed Unicode strings
    // to ensure we're testing the combining character detection logic.
    // In practice, text may be in composed form (NFC) where é is a single codepoint.
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

test "hasControlChars helper function" {
    // Empty string - no control chars
    try testing.expect(!hasControlChars(""));

    // Regular ASCII without control chars
    try testing.expect(!hasControlChars("hello"));
    try testing.expect(!hasControlChars("Hello World 123!"));
    try testing.expect(!hasControlChars("abcdefghijklmnopqrstuvwxyz"));
    try testing.expect(!hasControlChars("ABCDEFGHIJKLMNOPQRSTUVWXYZ"));
    try testing.expect(!hasControlChars("0123456789"));
    try testing.expect(!hasControlChars("!@#$%^&*()_+-=[]{}|;':\",./<>?"));

    // Space is not a control character (ASCII 0x20)
    try testing.expect(!hasControlChars(" "));
    try testing.expect(!hasControlChars("hello world"));

    // Boundary test: 0x1F (last control char before space)
    try testing.expect(hasControlChars("\x1F"));
    try testing.expect(hasControlChars("hello\x1F"));

    // DEL character (0x7F)
    try testing.expect(hasControlChars("\x7F"));
    try testing.expect(hasControlChars("hello\x7F"));
    try testing.expect(hasControlChars("\x7Fworld"));

    // Common control characters
    try testing.expect(hasControlChars("\x00")); // NULL
    try testing.expect(hasControlChars("\x01")); // SOH
    try testing.expect(hasControlChars("\x08")); // Backspace
    try testing.expect(hasControlChars("\x09")); // Tab
    try testing.expect(hasControlChars("\x0A")); // Line Feed
    try testing.expect(hasControlChars("\x0D")); // Carriage Return
    try testing.expect(hasControlChars("\x1B")); // Escape

    // Control chars mixed with regular text
    try testing.expect(hasControlChars("hello\x00world"));
    try testing.expect(hasControlChars("test\x09file"));
    try testing.expect(hasControlChars("line1\x0Aline2"));
    try testing.expect(hasControlChars("\x1Bstart"));

    // Range testing: all control characters 0x00-0x1F
    var i: u8 = 0x00;
    while (i <= 0x1F) : (i += 1) {
        const control_char = [_]u8{i};
        try testing.expect(hasControlChars(&control_char));
    }

    // Range testing: regular characters 0x20-0x7E (should not be control chars)
    i = 0x20;
    while (i <= 0x7E) : (i += 1) {
        const regular_char = [_]u8{i};
        try testing.expect(!hasControlChars(&regular_char));
    }
}

test "isCombining helper function" {
    // Non-combining characters
    try testing.expect(!isCombining('a'));
    try testing.expect(!isCombining('Z'));
    try testing.expect(!isCombining('0'));
    try testing.expect(!isCombining(' '));
    try testing.expect(!isCombining(0x0299)); // Just before combining range

    // Combining Diacritical Marks (U+0300-U+036F)
    try testing.expect(isCombining(0x0300)); // Combining Grave Accent
    try testing.expect(isCombining(0x0301)); // Combining Acute Accent
    try testing.expect(isCombining(0x0302)); // Combining Circumflex Accent
    try testing.expect(isCombining(0x0303)); // Combining Tilde
    try testing.expect(isCombining(0x0304)); // Combining Macron
    try testing.expect(isCombining(0x0308)); // Combining Diaeresis
    try testing.expect(isCombining(0x030A)); // Combining Ring Above
    try testing.expect(isCombining(0x0327)); // Combining Cedilla
    try testing.expect(isCombining(0x0328)); // Combining Ogonek
    try testing.expect(isCombining(0x036F)); // Last in range

    // Boundary testing around U+0300-U+036F
    try testing.expect(!isCombining(0x02FF)); // Just before range
    try testing.expect(isCombining(0x0300)); // First in range
    try testing.expect(isCombining(0x036F)); // Last in range
    try testing.expect(!isCombining(0x0370)); // Just after range

    // Combining Diacritical Marks Extended (U+1AB0-U+1AFF)
    try testing.expect(isCombining(0x1AB0)); // First in range
    try testing.expect(isCombining(0x1AB5)); // Middle of range
    try testing.expect(isCombining(0x1AFF)); // Last in range

    // Boundary testing around U+1AB0-U+1AFF
    try testing.expect(!isCombining(0x1AAF)); // Just before range
    try testing.expect(isCombining(0x1AB0)); // First in range
    try testing.expect(isCombining(0x1AFF)); // Last in range
    try testing.expect(!isCombining(0x1B00)); // Just after range

    // Combining Diacritical Marks Supplement (U+1DC0-U+1DFF)
    try testing.expect(isCombining(0x1DC0)); // First in range
    try testing.expect(isCombining(0x1DC5)); // Middle of range
    try testing.expect(isCombining(0x1DFF)); // Last in range

    // Boundary testing around U+1DC0-U+1DFF
    try testing.expect(!isCombining(0x1DBF)); // Just before range
    try testing.expect(isCombining(0x1DC0)); // First in range
    try testing.expect(isCombining(0x1DFF)); // Last in range
    try testing.expect(!isCombining(0x1E00)); // Just after range

    // Combining Half Marks (U+FE20-U+FE2F)
    try testing.expect(isCombining(0xFE20)); // First in range
    try testing.expect(isCombining(0xFE25)); // Middle of range
    try testing.expect(isCombining(0xFE2F)); // Last in range

    // Boundary testing around U+FE20-U+FE2F
    try testing.expect(!isCombining(0xFE1F)); // Just before range
    try testing.expect(isCombining(0xFE20)); // First in range
    try testing.expect(isCombining(0xFE2F)); // Last in range
    try testing.expect(!isCombining(0xFE30)); // Just after range

    // Test some characters outside all combining ranges
    try testing.expect(!isCombining(0x4E00)); // CJK ideograph
    try testing.expect(!isCombining(0x3042)); // Hiragana
    try testing.expect(!isCombining(0xFF01)); // Full-width exclamation
    try testing.expect(!isCombining(0x1F600)); // Emoji (outside ranges)
}

test "isEastAsianWide helper function" {
    // Non-wide characters
    try testing.expect(!isEastAsianWide('a'));
    try testing.expect(!isEastAsianWide('Z'));
    try testing.expect(!isEastAsianWide('0'));
    try testing.expect(!isEastAsianWide(' '));
    try testing.expect(!isEastAsianWide(0x00A0)); // Non-breaking space

    // CJK Unified Ideographs (U+4E00-U+9FFF) - most common
    try testing.expect(isEastAsianWide(0x4E00)); // 一 (first)
    try testing.expect(isEastAsianWide(0x4F60)); // 你
    try testing.expect(isEastAsianWide(0x597D)); // 好
    try testing.expect(isEastAsianWide(0x6587)); // 文
    try testing.expect(isEastAsianWide(0x7684)); // 的
    try testing.expect(isEastAsianWide(0x9FFF)); // Last in range

    // Boundary testing around CJK Unified Ideographs
    try testing.expect(!isEastAsianWide(0x4DFF)); // Just before range
    try testing.expect(isEastAsianWide(0x4E00)); // First in range
    try testing.expect(isEastAsianWide(0x9FFF)); // Last in range
    try testing.expect(!isEastAsianWide(0xA000)); // Just after range

    // CJK Extension A (U+3400-U+4DBF)
    try testing.expect(isEastAsianWide(0x3400)); // First
    try testing.expect(isEastAsianWide(0x3500)); // Middle
    try testing.expect(isEastAsianWide(0x4DBF)); // Last

    // Boundary testing around CJK Extension A
    try testing.expect(!isEastAsianWide(0x33FF)); // Just before
    try testing.expect(isEastAsianWide(0x3400)); // First
    try testing.expect(isEastAsianWide(0x4DBF)); // Last
    try testing.expect(!isEastAsianWide(0x4DC0)); // Just after

    // CJK Extension B (U+20000-U+2A6DF)
    try testing.expect(isEastAsianWide(0x20000)); // First
    try testing.expect(isEastAsianWide(0x25000)); // Middle
    try testing.expect(isEastAsianWide(0x2A6DF)); // Last

    // CJK Extension C (U+2A700-U+2B73F)
    try testing.expect(isEastAsianWide(0x2A700)); // First
    try testing.expect(isEastAsianWide(0x2B73F)); // Last

    // CJK Extension D (U+2B740-U+2B81F)
    try testing.expect(isEastAsianWide(0x2B740)); // First
    try testing.expect(isEastAsianWide(0x2B81F)); // Last

    // CJK Extension E (U+2B820-U+2CEAF)
    try testing.expect(isEastAsianWide(0x2B820)); // First
    try testing.expect(isEastAsianWide(0x2CEAF)); // Last

    // CJK Extension F (U+2CEB0-U+2EBEF)
    try testing.expect(isEastAsianWide(0x2CEB0)); // First
    try testing.expect(isEastAsianWide(0x2EBEF)); // Last

    // Hangul Syllables (U+AC00-U+D7AF)
    try testing.expect(isEastAsianWide(0xAC00)); // 가 (first)
    try testing.expect(isEastAsianWide(0xB000)); // Middle
    try testing.expect(isEastAsianWide(0xC548)); // 안
    try testing.expect(isEastAsianWide(0xB155)); // 녕
    try testing.expect(isEastAsianWide(0xD7AF)); // Last

    // Boundary testing around Hangul
    try testing.expect(!isEastAsianWide(0xABFF)); // Just before
    try testing.expect(isEastAsianWide(0xAC00)); // First
    try testing.expect(isEastAsianWide(0xD7AF)); // Last
    try testing.expect(!isEastAsianWide(0xD7B0)); // Just after

    // Hiragana (U+3040-U+309F)
    try testing.expect(isEastAsianWide(0x3040)); // First
    try testing.expect(isEastAsianWide(0x3042)); // あ
    try testing.expect(isEastAsianWide(0x3053)); // こ
    try testing.expect(isEastAsianWide(0x3093)); // ん
    try testing.expect(isEastAsianWide(0x309F)); // Last

    // Boundary testing around Hiragana (note: 0x303F is in CJK Symbols range, 0x30A0 is Katakana)
    try testing.expect(isEastAsianWide(0x303F)); // Last in CJK Symbols (still wide)
    try testing.expect(isEastAsianWide(0x3040)); // First Hiragana
    try testing.expect(isEastAsianWide(0x309F)); // Last Hiragana
    try testing.expect(isEastAsianWide(0x30A0)); // First Katakana (also wide)

    // Katakana (U+30A0-U+30FF)
    try testing.expect(isEastAsianWide(0x30A0)); // First
    try testing.expect(isEastAsianWide(0x30A2)); // ア
    try testing.expect(isEastAsianWide(0x30B3)); // コ
    try testing.expect(isEastAsianWide(0x30F3)); // ン
    try testing.expect(isEastAsianWide(0x30FF)); // Last

    // Full-width ASCII variants (U+FF01-U+FF60)
    try testing.expect(isEastAsianWide(0xFF01)); // ！ (full-width exclamation)
    try testing.expect(isEastAsianWide(0xFF21)); // Ａ (full-width A)
    try testing.expect(isEastAsianWide(0xFF41)); // ａ (full-width a)
    try testing.expect(isEastAsianWide(0xFF60)); // Last

    // Full-width currency and symbols (U+FFE0-U+FFE6)
    try testing.expect(isEastAsianWide(0xFFE0)); // ￠ (full-width cent)
    try testing.expect(isEastAsianWide(0xFFE1)); // ￡ (full-width pound)
    try testing.expect(isEastAsianWide(0xFFE6)); // ￦ (full-width won)

    // CJK Symbols and Punctuation (U+3000-U+303F)
    try testing.expect(isEastAsianWide(0x3000)); // Ideographic space
    try testing.expect(isEastAsianWide(0x3001)); // Ideographic comma
    try testing.expect(isEastAsianWide(0x3002)); // Ideographic full stop
    try testing.expect(isEastAsianWide(0x303F)); // Last

    // CJK Radicals Supplement (U+2E80-U+2EFF)
    try testing.expect(isEastAsianWide(0x2E80)); // First
    try testing.expect(isEastAsianWide(0x2EFF)); // Last

    // Kangxi Radicals (U+2F00-U+2FDF)
    try testing.expect(isEastAsianWide(0x2F00)); // First
    try testing.expect(isEastAsianWide(0x2FDF)); // Last

    // Bopomofo (U+3100-U+312F)
    try testing.expect(isEastAsianWide(0x3100)); // First
    try testing.expect(isEastAsianWide(0x312F)); // Last

    // Bopomofo Extended (U+31A0-U+31BF)
    try testing.expect(isEastAsianWide(0x31A0)); // First
    try testing.expect(isEastAsianWide(0x31BF)); // Last

    // Test gaps between ranges (should not be wide)
    try testing.expect(!isEastAsianWide(0x2FE0)); // Between Kangxi and CJK Symbols
    try testing.expect(!isEastAsianWide(0x3130)); // Between Bopomofo and Extension A
    try testing.expect(!isEastAsianWide(0x33FF)); // Between CJK Symbols and Extension A
    try testing.expect(!isEastAsianWide(0xFF61)); // Between full-width ranges
    try testing.expect(!isEastAsianWide(0xFFDF)); // Between full-width ranges
    try testing.expect(!isEastAsianWide(0xFFE7)); // After full-width currency

    // Test some common non-wide Unicode characters
    try testing.expect(!isEastAsianWide(0x00E9)); // é (Latin with acute)
    try testing.expect(!isEastAsianWide(0x1F600)); // 😀 (emoji - not East Asian)
    try testing.expect(!isEastAsianWide(0x0400)); // Cyrillic
    try testing.expect(!isEastAsianWide(0x0590)); // Hebrew
    try testing.expect(!isEastAsianWide(0x0600)); // Arabic
}
