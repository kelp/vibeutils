const std = @import("std");

/// Buffer sizes
pub const DEFAULT_BUFFER_SIZE: usize = 8192;
pub const MAX_PATH_SIZE = std.fs.max_path_bytes;
pub const LINE_BUFFER_SIZE: usize = 8192;

/// Terminal defaults
pub const DEFAULT_TERMINAL_WIDTH: u16 = 80;
pub const DEFAULT_TERMINAL_HEIGHT: u16 = 24;

/// Formatting constants
pub const COLUMN_PADDING: usize = 2;
pub const PROGRESS_BAR_WIDTH: usize = 30;
pub const KILOBYTE: usize = 1024;
pub const BLOCK_SIZE: usize = 512;

/// Time constants
pub const NANOSECONDS_PER_SECOND = std.time.ns_per_s;
pub const SIX_MONTHS_SECONDS: i64 = 6 * 30 * 24 * 60 * 60;
pub const PROGRESS_UPDATE_INTERVAL_MS: i64 = 100;

/// File permissions
pub const SETUID_BIT: u32 = 0o4000;
pub const SETGID_BIT: u32 = 0o2000;
pub const STICKY_BIT: u32 = 0o1000;
pub const EXECUTE_BIT: u32 = 0o111;