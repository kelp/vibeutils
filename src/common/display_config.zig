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

        var config: DisplayConfig = .{
            .color = if (is_tty) .on else .off,
            .icons = if (is_tty) .on else .off,
            .highlight = if (is_tty) .on else .off,
            .theme = if (is_tty) .default else .none,
        };

        // Ordering preserved: defaults -> style preset -> feature
        // overrides -> kill switches, so precedence is unchanged.
        config = resolve_applyStylePreset(config, is_tty);
        config = resolve_applyFeatureOverrides(config);
        config = resolve_applyColorKillSwitches(config);

        // NO_COLOR (any value) is the highest-precedence kill switch and runs
        // last, so the resolved color must always be off when it is set.
        if (env.getEnv("NO_COLOR") != null) {
            std.debug.assert(config.color == .off);
        }
        // TERM=dumb forces color off regardless of any earlier step.
        if (env.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) {
                std.debug.assert(config.color == .off);
            }
        }
        return config;
    }

    /// Step 2: apply the VIBEUTILS_STYLE master preset.
    /// Presets set preferences but respect TTY detection; only "always"
    /// forces features on through pipes. Returns a new config so the
    /// parent never aliases the underlying fields.
    fn resolve_applyStylePreset(config: DisplayConfig, is_tty: bool) DisplayConfig {
        var result = config;
        if (env.getEnv("VIBEUTILS_STYLE")) |vibe_style| {
            if (std.mem.eql(u8, vibe_style, "plain")) {
                result.color = .off;
                result.icons = .off;
                result.highlight = .off;
                result.theme = .none;
            } else if (std.mem.eql(u8, vibe_style, "color")) {
                if (is_tty) result.color = .on;
                result.icons = .off;
                result.highlight = .off;
            } else if (std.mem.eql(u8, vibe_style, "full")) {
                if (is_tty) {
                    result.color = .on;
                    result.icons = .on;
                    result.highlight = .on;
                    result.theme = .default;
                }
            } else if (std.mem.eql(u8, vibe_style, "always")) {
                result.color = .on;
                result.icons = .on;
                result.highlight = .on;
                result.theme = .default;
            }
        }

        // Negative space: when VIBEUTILS_STYLE is unset, this helper is a pure
        // no-op, so every field must equal the input config.
        if (env.getEnv("VIBEUTILS_STYLE") == null) {
            std.debug.assert(result.color == config.color);
            std.debug.assert(result.icons == config.icons);
            std.debug.assert(result.highlight == config.highlight);
            std.debug.assert(result.theme == config.theme);
        }
        return result;
    }

    /// Step 3: apply the per-feature VIBEUTILS_* overrides. Each block is
    /// independent and outranks the style preset. Returns a new config.
    fn resolve_applyFeatureOverrides(config: DisplayConfig) DisplayConfig {
        var result = config;
        if (env.getEnv("VIBEUTILS_COLOR")) |val| {
            if (std.mem.eql(u8, val, "always")) {
                result.color = .on;
            } else if (std.mem.eql(u8, val, "never")) {
                result.color = .off;
            }
        }

        if (env.getEnv("VIBEUTILS_ICONS")) |val| {
            if (std.mem.eql(u8, val, "always")) {
                result.icons = .on;
            } else if (std.mem.eql(u8, val, "never")) {
                result.icons = .off;
            }
        }

        if (env.getEnv("VIBEUTILS_HIGHLIGHT")) |val| {
            if (std.mem.eql(u8, val, "always")) {
                result.highlight = .on;
            } else if (std.mem.eql(u8, val, "never")) {
                result.highlight = .off;
            }
        }

        if (env.getEnv("VIBEUTILS_THEME")) |val| {
            if (std.mem.eql(u8, val, "none")) {
                result.theme = .none;
            } else if (std.mem.eql(u8, val, "default")) {
                result.theme = .default;
            }
        }

        // Negative space: each override block is gated on its own env var, so
        // an unset var leaves the corresponding field untouched.
        if (env.getEnv("VIBEUTILS_COLOR") == null) {
            std.debug.assert(result.color == config.color);
        }
        if (env.getEnv("VIBEUTILS_ICONS") == null) {
            std.debug.assert(result.icons == config.icons);
        }
        if (env.getEnv("VIBEUTILS_HIGHLIGHT") == null) {
            std.debug.assert(result.highlight == config.highlight);
        }
        if (env.getEnv("VIBEUTILS_THEME") == null) {
            std.debug.assert(result.theme == config.theme);
        }
        return result;
    }

    /// Steps 4+5: NO_COLOR (any value) and TERM=dumb force color off.
    /// These kill switches win over all earlier steps. icons, highlight,
    /// and theme are never touched here; returns a new config.
    fn resolve_applyColorKillSwitches(config: DisplayConfig) DisplayConfig {
        var result = config;
        // Step 4: NO_COLOR forces color off (any value)
        if (env.getEnv("NO_COLOR") != null) {
            result.color = .off;
        }

        // Step 5: TERM=dumb forces color off
        if (env.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) {
                result.color = .off;
            }
        }

        // Negative space: this helper touches only color, never the rest.
        std.debug.assert(result.icons == config.icons);
        std.debug.assert(result.highlight == config.highlight);
        std.debug.assert(result.theme == config.theme);
        return result;
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
    // setenv/unsetenv are libc externs; skip when building without -lc.
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
