//! Fixture manifest listing no utilities at all. Enumerating zero units means
//! the scan proved nothing, so the contract is exit 2 rather than a
//! reassuring "0 findings".

const std = @import("std");

pub const UtilityMeta = struct {
    name: []const u8,
    path: []const u8,
    needs_libc: bool,
    description: []const u8,
};

pub const utilities = [_]UtilityMeta{};
