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
    .{ .name = "initly", .path = "src/initly/main.zig", .needs_libc = true, .description = "Fixture utility whose flag is read in a multi-line init method" },
};
