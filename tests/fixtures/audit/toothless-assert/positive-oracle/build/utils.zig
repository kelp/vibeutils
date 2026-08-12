//! Fixture manifest. Same shape as the repo's build/utils.zig so the real
//! unit enumerator can parse it without special-casing fixtures.

const std = @import("std");

pub const UtilityMeta = struct {
    name: []const u8,
    path: []const u8,
    needs_libc: bool,
    description: []const u8,
};

pub const utilities = [_]UtilityMeta{
    .{ .name = "toothy", .path = "src/toothy.zig", .needs_libc = true, .description = "Fixture utility for toothless assertions" },
};
