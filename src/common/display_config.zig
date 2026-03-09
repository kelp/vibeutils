const std = @import("std");
const Allocator = std.mem.Allocator;

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
        const is_tty = std.posix.isatty(std.fs.File.stdout().handle);

        var color: ResolvedMode = if (is_tty) .on else .off;
        var icons: ResolvedMode = if (is_tty) .on else .off;
        var highlight: ResolvedMode = if (is_tty) .on else .off;
        var theme: Theme = if (is_tty) .default else .none;

        // Step 2: Apply VIBEUTILS_STYLE shortcut
        if (std.posix.getenv("VIBEUTILS_STYLE")) |vibe_style| {
            if (std.mem.eql(u8, vibe_style, "plain")) {
                color = .off;
                icons = .off;
                highlight = .off;
                theme = .none;
            } else if (std.mem.eql(u8, vibe_style, "color")) {
                color = .on;
                icons = .off;
                highlight = .off;
            } else if (std.mem.eql(u8, vibe_style, "full")) {
                color = .on;
                icons = .on;
                highlight = .on;
                theme = .default;
            }
        }

        // Step 3: Apply individual overrides
        if (std.posix.getenv("VIBEUTILS_COLOR")) |val| {
            if (std.mem.eql(u8, val, "always")) color = .on else if (std.mem.eql(u8, val, "never")) color = .off;
        }

        if (std.posix.getenv("VIBEUTILS_ICONS")) |val| {
            if (std.mem.eql(u8, val, "always")) icons = .on else if (std.mem.eql(u8, val, "never")) icons = .off;
        }

        if (std.posix.getenv("VIBEUTILS_HIGHLIGHT")) |val| {
            if (std.mem.eql(u8, val, "always")) highlight = .on else if (std.mem.eql(u8, val, "never")) highlight = .off;
        }

        if (std.posix.getenv("VIBEUTILS_THEME")) |val| {
            if (std.mem.eql(u8, val, "none")) theme = .none else if (std.mem.eql(u8, val, "default")) theme = .default;
        }

        // Step 4: NO_COLOR forces color off (any value)
        if (std.posix.getenv("NO_COLOR") != null) {
            color = .off;
        }

        // Step 5: TERM=dumb forces color off
        if (std.posix.getenv("TERM")) |term| {
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
const env_var_names = [_][*:0]const u8{
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
    values: [env_var_names.len]?[:0]const u8,

    fn save() EnvState {
        var state: EnvState = undefined;
        for (env_var_names, 0..) |name, i| {
            state.values[i] = std.posix.getenv(std.mem.span(name));
        }
        return state;
    }

    fn restore(self: *const EnvState) void {
        for (env_var_names, 0..) |name, i| {
            if (self.values[i]) |val| {
                _ = setenv(name, val.ptr, 1);
            } else {
                _ = unsetenv(name);
            }
        }
    }

    /// Clear all tracked env vars so tests start from a known state.
    fn clearAll() void {
        for (env_var_names) |name| {
            _ = unsetenv(name);
        }
    }
};

test "resolve: VIBEUTILS_STYLE=plain sets all off" {
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

test "resolve: VIBEUTILS_STYLE=full sets all on" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
    try std.testing.expectEqual(Theme.default, cfg.theme);
}

test "resolve: VIBEUTILS_STYLE=color sets color on only" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "color", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.color);
    try std.testing.expectEqual(ResolvedMode.off, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
}

test "resolve: VIBEUTILS_COLOR=always overrides style=plain" {
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

test "resolve: VIBEUTILS_COLOR=never overrides style=full" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("VIBEUTILS_COLOR", "never", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
}

test "resolve: NO_COLOR overrides everything for color" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("NO_COLOR", "1", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
}

test "resolve: NO_COLOR overrides VIBEUTILS_COLOR=always" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_COLOR", "always", 1);
    _ = setenv("NO_COLOR", "1", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
}

test "resolve: VIBEUTILS_ICONS=always forces icons on" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_ICONS", "always", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
}

test "resolve: TERM=dumb forces color off" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("TERM", "dumb", 1);
    _ = setenv("VIBEUTILS_STYLE", "full", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.color);
    try std.testing.expectEqual(ResolvedMode.on, cfg.icons);
    try std.testing.expectEqual(ResolvedMode.on, cfg.highlight);
}

test "resolve: no env vars on non-tty defaults all off" {
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
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("VIBEUTILS_THEME", "none", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(Theme.none, cfg.theme);
}

test "resolve: VIBEUTILS_HIGHLIGHT=never overrides style=full" {
    const saved = EnvState.save();
    defer saved.restore();
    EnvState.clearAll();

    _ = setenv("VIBEUTILS_STYLE", "full", 1);
    _ = setenv("VIBEUTILS_HIGHLIGHT", "never", 1);
    _ = setenv("TERM", "xterm-256color", 1);

    const cfg = DisplayConfig.resolve(std.testing.allocator);
    try std.testing.expectEqual(ResolvedMode.off, cfg.highlight);
}
