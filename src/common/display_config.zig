const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");

/// Resolved on/off mode for display features.
pub const ResolvedMode = enum {
    on,
    off,
};

/// Theme selection for styled output.
pub const Theme = enum {
    default,
    none,
};

/// Unified display configuration resolved from environment variables
/// and terminal capabilities. Utilities query this once at startup
/// instead of scattering env checks throughout the codebase.
pub const DisplayConfig = struct {
    color: ResolvedMode,
    icons: ResolvedMode,
    highlight: ResolvedMode,
    theme: Theme,

    /// Resolve display configuration from environment and terminal state.
    ///
    /// Precedence (highest to lowest):
    ///   1. NO_COLOR (forces color off)
    ///   2. Per-feature overrides: VIBEUTILS_COLOR, VIBEUTILS_ICONS,
    ///      VIBEUTILS_HIGHLIGHT, VIBEUTILS_THEME
    ///   3. VIBEUTILS_STYLE master preset (plain, color, full)
    ///   4. TTY auto-detection
    ///
    /// The allocator parameter is reserved for future use (e.g.,
    /// heap-allocated env var copies when needed).
    pub fn resolve(allocator: Allocator) DisplayConfig {
        _ = allocator;

        // Step 1: Defaults based on isTty(stdout)
        const is_tty = env.isTty(std.Io.File.stdout().handle);

        var color: ResolvedMode = if (is_tty) .on else .off;
        var icons: ResolvedMode = if (is_tty) .on else .off;
        var highlight: ResolvedMode = if (is_tty) .on else .off;
        var theme: Theme = if (is_tty) .default else .none;

        // Step 2: Apply VIBEUTILS_STYLE shortcut
        // Presets set preferences but respect TTY detection.
        // Only "always" forces features on through pipes.
        if (env.getEnv("VIBEUTILS_STYLE")) |vibe_style| {
            if (std.mem.eql(u8, vibe_style, "plain")) {
                color = .off;
                icons = .off;
                highlight = .off;
                theme = .none;
            } else if (std.mem.eql(u8, vibe_style, "color")) {
                if (is_tty) color = .on;
                icons = .off;
                highlight = .off;
            } else if (std.mem.eql(u8, vibe_style, "full")) {
                if (is_tty) {
                    color = .on;
                    icons = .on;
                    highlight = .on;
                    theme = .default;
                }
            } else if (std.mem.eql(u8, vibe_style, "always")) {
                color = .on;
                icons = .on;
                highlight = .on;
                theme = .default;
            }
        }

        // Step 3: Apply individual overrides
        if (env.getEnv("VIBEUTILS_COLOR")) |val| {
            if (std.mem.eql(u8, val, "always")) color = .on else if (std.mem.eql(u8, val, "never")) color = .off;
        }

        if (env.getEnv("VIBEUTILS_ICONS")) |val| {
            if (std.mem.eql(u8, val, "always")) icons = .on else if (std.mem.eql(u8, val, "never")) icons = .off;
        }

        if (env.getEnv("VIBEUTILS_HIGHLIGHT")) |val| {
            if (std.mem.eql(u8, val, "always")) highlight = .on else if (std.mem.eql(u8, val, "never")) highlight = .off;
        }

        if (env.getEnv("VIBEUTILS_THEME")) |val| {
            if (std.mem.eql(u8, val, "none")) theme = .none else if (std.mem.eql(u8, val, "default")) theme = .default;
        }

        // Step 4: NO_COLOR forces color off (any value)
        if (env.getEnv("NO_COLOR") != null) {
            color = .off;
        }

        // Step 5: TERM=dumb forces color off
        if (env.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) {
                color = .off;
            }
        }

        return .{
            .color = color,
            .icons = icons,
            .highlight = highlight,
            .theme = theme,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// C library functions for environment manipulation in tests
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

/// Names of all environment variables that affect DisplayConfig.
const env_var_names = [_][:0]const u8{
    "VIBEUTILS_STYLE",
    "VIBEUTILS_COLOR",
    "VIBEUTILS_ICONS",
    "VIBEUTILS_HIGHLIGHT",
    "VIBEUTILS_THEME",
    "NO_COLOR",
    "TERM",
};

/// Snapshot of environment variables used by DisplayConfig.
/// Create with `save()`, restore in a `defer` with `restore()`.
const EnvState = struct {
    values: [env_var_names.len]?[]const u8,

    fn save() EnvState {
        var state: EnvState = undefined;
        for (env_var_names, 0..) |name, i| {
            state.values[i] = env.getEnv(name);
        }
        return state;
    }

    fn restore(self: *const EnvState) void {
        for (env_var_names, 0..) |name, i| {
            if (self.values[i]) |val| {
                // setenv requires a null-terminated value. The value returned
                // by env.getEnv in test builds points into the test environ
                // which is already null-terminated, so casting is safe here.
                const val_z: [*:0]const u8 = @ptrCast(val.ptr);
                _ = setenv(name.ptr, val_z, 1);
            } else {
                _ = unsetenv(name.ptr);
            }
        }
    }

    /// Clear all tracked env vars so tests start from a known state.
    fn clearAll() void {
        for (env_var_names) |name| {
            _ = unsetenv(name.ptr);
        }
    }
};

test "resolve: VIBEUTILS_STYLE=plain sets all off" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "plain", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
    try std.testing.expectEqual(Theme.none, cfg.theme);
}

test "resolve: VIBEUTILS_STYLE=full respects TTY (no-op on non-TTY)" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    // Tests run without a TTY, so full is a no-op
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
    try std.testing.expectEqual(Theme.none, cfg.theme);
}

test "resolve: VIBEUTILS_STYLE=always forces all on" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
    try std.testing.expectEqual(Theme.default, cfg.theme);
}

test "resolve: VIBEUTILS_STYLE=color respects TTY" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "color", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    // Tests run without a TTY, so color stays off
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
}

test "resolve: VIBEUTILS_COLOR=always overrides style=plain" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "plain", 1);
    _ = setenv("VIBEUTILS_COLOR", "always", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
}

test "resolve: VIBEUTILS_COLOR=never overrides style=always" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("VIBEUTILS_COLOR", "never", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
}

test "resolve: NO_COLOR overrides everything for color" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("NO_COLOR", "1", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
}

test "resolve: NO_COLOR overrides VIBEUTILS_COLOR=always" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_COLOR", "always", 1);
    _ = setenv("NO_COLOR", "1", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
}

test "resolve: NO_COLOR overrides VIBEUTILS_STYLE=always" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("NO_COLOR", "1", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
}

test "resolve: VIBEUTILS_ICONS=always forces icons on" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_ICONS", "always", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
}

test "resolve: TERM=dumb forces color off" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("TERM", "dumb", 1);
    _ = setenv("VIBEUTILS_STYLE", "always", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
}

test "resolve: no env vars on non-tty defaults all off" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
    try std.testing.expectEqual(Theme.none, cfg.theme);
}

test "resolve: VIBEUTILS_THEME=none sets theme none" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("VIBEUTILS_THEME", "none", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(Theme.none, cfg.theme);
}

test "resolve: VIBEUTILS_HIGHLIGHT=never overrides style=always" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "always", 1);
    _ = setenv("VIBEUTILS_HIGHLIGHT", "never", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
}
