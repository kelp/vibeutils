//! Common constants used throughout the vibeutils project.
//!
//! This module provides well-documented constants organized by functional area:
//! - Terminal and display settings
//! - File I/O buffer sizes
//! - File system block sizes and formatting
//! - File permission bit masks
//! - Time calculations
//!
//! All constants include comprehensive documentation and are tested for
//! reasonable values to prevent configuration errors.

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Terminal and Display Constants
// =============================================================================

/// Default terminal width in columns when terminal size cannot be detected.
/// Used as fallback when ioctl(TIOCGWINSZ) fails or when output is redirected.
/// Value of 80 matches historic VT100 standard and remains widely compatible.
pub const DEFAULT_TERMINAL_WIDTH: u16 = 80;

/// Default terminal height in rows when terminal size cannot be detected.
/// Used as fallback when ioctl(TIOCGWINSZ) fails or when output is redirected.
/// Value of 24 matches historic VT100 standard and common terminal defaults.
pub const DEFAULT_TERMINAL_HEIGHT: u16 = 24;

// =============================================================================
// File I/O Constants
// =============================================================================

/// Buffer size for line-oriented file operations.
/// Used by utilities like cat that process files line by line.
/// 8KB provides good performance while keeping memory usage reasonable.
pub const LINE_BUFFER_SIZE: usize = 8192;

// =============================================================================
// File System and Formatting Constants
// =============================================================================

/// Minimum spacing between columns in tabular output formats.
/// Used by ls and other utilities that display columnar data.
/// 2 spaces provides clear visual separation without excessive whitespace.
pub const COLUMN_PADDING: usize = 2;

/// Standard block size for file system operations and size calculations.
/// 512 bytes is the traditional Unix block size used by utilities like du.
/// Matches the st_blksize field in struct stat on most systems.
pub const BLOCK_SIZE: usize = 512;

// =============================================================================
// File Permission Constants
// =============================================================================

/// Set-user-ID bit mask for file permissions.
/// When set on executable files, the program runs with the owner's privileges.
/// Octal value 04000 corresponds to the S_ISUID mode bit.
pub const SETUID_BIT: u32 = 0o4000;

/// Set-group-ID bit mask for file permissions.
/// When set on executable files, the program runs with the group's privileges.
/// When set on directories, new files inherit the directory's group.
/// Octal value 02000 corresponds to the S_ISGID mode bit.
pub const SETGID_BIT: u32 = 0o2000;

/// Sticky bit mask for file permissions.
/// When set on directories, only the owner can delete files within.
/// Commonly used on /tmp to prevent users from deleting others' files.
/// Octal value 01000 corresponds to the S_ISVTX mode bit.
pub const STICKY_BIT: u32 = 0o1000;

/// Execute permission bits for owner, group, and other.
/// Combines owner execute (0o100), group execute (0o010), and other execute (0o001).
/// Used to check if any execute permission is set on a file.
pub const EXECUTE_BIT: u32 = 0o111;

// =============================================================================
// Time Constants
// =============================================================================

/// Number of seconds in six months, used for timestamp age calculations.
/// Files modified more than six months ago show year instead of time in ls.
/// Uses 30.44 days per month (365.25/12) for astronomical accuracy.
/// Accounts for leap years in the Gregorian calendar system.
pub const SIX_MONTHS_SECONDS: i64 = @as(i64, @intFromFloat(6.0 * 30.44 * 24.0 * 60.0 * 60.0));

// =============================================================================
// Tests
// =============================================================================

test "terminal dimensions are reasonable" {
    // Terminal width should be at least 40 columns for basic usability
    try testing.expect(DEFAULT_TERMINAL_WIDTH >= 40);
    try testing.expect(DEFAULT_TERMINAL_WIDTH <= 300); // Sanity check upper bound

    // Terminal height should be at least 10 rows for basic usability
    try testing.expect(DEFAULT_TERMINAL_HEIGHT >= 10);
    try testing.expect(DEFAULT_TERMINAL_HEIGHT <= 100); // Sanity check upper bound
}

test "buffer sizes are powers of 2" {
    // Buffer sizes should be powers of 2 for optimal memory alignment
    try testing.expect(std.math.isPowerOfTwo(LINE_BUFFER_SIZE));

    // Buffer should be at least 1KB but not unreasonably large
    try testing.expect(LINE_BUFFER_SIZE >= 1024);
    try testing.expect(LINE_BUFFER_SIZE <= 64 * 1024);
}

test "formatting constants are reasonable" {
    // Column padding should provide clear separation without waste
    try testing.expect(COLUMN_PADDING >= 1);
    try testing.expect(COLUMN_PADDING <= 8);

    // Block size should match traditional Unix value
    try testing.expectEqual(@as(usize, 512), BLOCK_SIZE);
    try testing.expect(std.math.isPowerOfTwo(BLOCK_SIZE));
}

test "permission bits are valid octal values" {
    // Verify permission bits match expected octal values
    try testing.expectEqual(@as(u32, 0o4000), SETUID_BIT);
    try testing.expectEqual(@as(u32, 0o2000), SETGID_BIT);
    try testing.expectEqual(@as(u32, 0o1000), STICKY_BIT);
    try testing.expectEqual(@as(u32, 0o111), EXECUTE_BIT);

    // Verify bits don't overlap (each should have unique bit positions)
    try testing.expectEqual(@as(u32, 0), SETUID_BIT & SETGID_BIT);
    try testing.expectEqual(@as(u32, 0), SETUID_BIT & STICKY_BIT);
    try testing.expectEqual(@as(u32, 0), SETGID_BIT & STICKY_BIT);

    // Execute bit should be separate from special permission bits
    try testing.expectEqual(@as(u32, 0), EXECUTE_BIT & SETUID_BIT);
    try testing.expectEqual(@as(u32, 0), EXECUTE_BIT & SETGID_BIT);
    try testing.expectEqual(@as(u32, 0), EXECUTE_BIT & STICKY_BIT);
}

test "time constants are mathematically correct" {
    // Six months should be approximately 183 days (365.25/2)
    const expected_days = 6.0 * 30.44; // About 182.64 days
    const expected_seconds = expected_days * 24.0 * 60.0 * 60.0;

    // Allow small floating point differences in the calculation
    const difference = @abs(@as(f64, @floatFromInt(SIX_MONTHS_SECONDS)) - expected_seconds);
    try testing.expect(difference < 1.0); // Within 1 second is acceptable

    // Verify the value is in reasonable range
    try testing.expect(SIX_MONTHS_SECONDS > 180 * 24 * 60 * 60); // At least 180 days
    try testing.expect(SIX_MONTHS_SECONDS < 185 * 24 * 60 * 60); // At most 185 days
}

test "constants have consistent types" {
    // Verify terminal dimensions use u16 (reasonable for terminal sizes)
    try testing.expectEqual(u16, @TypeOf(DEFAULT_TERMINAL_WIDTH));
    try testing.expectEqual(u16, @TypeOf(DEFAULT_TERMINAL_HEIGHT));

    // Verify size constants use usize (for memory operations)
    try testing.expectEqual(usize, @TypeOf(LINE_BUFFER_SIZE));
    try testing.expectEqual(usize, @TypeOf(COLUMN_PADDING));
    try testing.expectEqual(usize, @TypeOf(BLOCK_SIZE));

    // Verify permission bits use u32 (to match mode_t)
    try testing.expectEqual(u32, @TypeOf(SETUID_BIT));
    try testing.expectEqual(u32, @TypeOf(SETGID_BIT));
    try testing.expectEqual(u32, @TypeOf(STICKY_BIT));
    try testing.expectEqual(u32, @TypeOf(EXECUTE_BIT));

    // Verify time constants use i64 (to match timestamp types)
    try testing.expectEqual(i64, @TypeOf(SIX_MONTHS_SECONDS));
}
