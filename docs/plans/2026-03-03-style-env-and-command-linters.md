# VIBEUTILS_STYLE and Command Linter Warnings

Date: 2026-03-03

## VIBEUTILS_STYLE Environment Variable

Control help output styling with three levels:

| Value   | Colors | Glyphs | Description           |
|---------|--------|--------|-----------------------|
| `full`  | yes    | yes    | default               |
| `color` | yes    | no     | colors, no nerd-fonts |
| `plain` | no     | no     | plain text            |

### Precedence

1. Non-TTY output: always plain (highest priority)
2. `NO_COLOR`: disables color regardless of VIBEUTILS_STYLE
3. `VIBEUTILS_STYLE`: controls both color and glyphs
4. Terminal/locale detection: fallback default behavior

### Implementation

Modify `detectHelpStyle()` in `src/common/help.zig` to
check `VIBEUTILS_STYLE` after TTY detection but before
locale detection.

## Command Linter Warnings

Non-fatal warnings on stderr using existing
`printWarningWithProgram()`. The command still executes.
Inline in each utility, no shared module.

### 1. chown octal confusion

Location: `src/common/user_group.zig`, in `parseUser()`

After parsing a numeric UID, check if the string is 3-4
digits with all chars 0-7. Warn:

    chown: warning: '700' looks like a permission mode;
    did you mean 'chmod 700'?

### 2. chmod invalid octal digits

Location: `src/chmod.zig`, in `parseMode()`

When numeric mode contains 8 or 9. Warn:

    chmod: warning: '899' contains non-octal digits;
    numeric modes use octal (0-7)

### 3. rm root protection

Location: `src/rm.zig`

Before executing, check if any positional arg resolves to
`/`. Add `--no-preserve-root` flag to override. Warn:

    rm: refusing to remove '/'; use --no-preserve-root
    to override

### 4. cp/mv overwrite hint

Location: `src/cp.zig`, `src/mv.zig`

When destination exists and `-i` is not set, print once
per invocation:

    cp: hint: use -i for interactive prompts before
    overwriting

### 5. ln dangling symlink warning

Location: `src/ln.zig`

After creating a symlink, check if target exists. Warn:

    ln: warning: creating dangling symlink: target 'foo'
    does not exist
