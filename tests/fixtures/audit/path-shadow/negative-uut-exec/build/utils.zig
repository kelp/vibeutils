//! Fixture manifest. Same shape as the repo's build/utils.zig so the real
//! unit enumerator can parse it without special-casing fixtures.
//!
//! `chmod` is listed so UTILS contains a peer name the shell scanner can
//! match. Both names share one source: Pass 1 deduplicates by path.

const std = @import("std");

pub const UtilityMeta = struct {
    name: []const u8,
    path: []const u8,
    needs_libc: bool,
    description: []const u8,
};

pub const utilities = [_]UtilityMeta{
    .{ .name = "shadowly", .path = "src/shadowly.zig", .needs_libc = true, .description = "Fixture utility for path-shadow" },
    .{ .name = "chmod", .path = "src/shadowly.zig", .needs_libc = true, .description = "Peer name that PATH prepend would shadow" },
    // find -exec operands that are shipped names. The scanner must not
    // treat `"$binary" -exec true` as a fixture PATH lookup.
    .{ .name = "true", .path = "src/shadowly.zig", .needs_libc = true, .description = "Peer -exec operand" },
    .{ .name = "echo", .path = "src/shadowly.zig", .needs_libc = true, .description = "Peer -exec operand" },
    .{ .name = "ls", .path = "src/shadowly.zig", .needs_libc = true, .description = "Peer -exec operand" },
};
