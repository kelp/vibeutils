# vibeutils Design Philosophy

## Core Principles

### OpenBSD-Inspired Engineering
- **Correctness first** - Get it right before making it fast
- **Security by default** - Safe defaults, explicit unsafe operations
- **Simplicity** - Clear, concise code that's easy to audit
- **Minimalism** - Do one thing well, avoid feature creep
- **Documentation** - Concise, accurate man pages with examples

### Modern User Experience
- **Smart defaults** - Detect terminal capabilities and adapt
- **Visual clarity** - Use color and symbols to enhance readability
- **Performance** - Leverage modern hardware (parallelism, SIMD)
- **Accessibility** - Respect NO_COLOR, provide high-contrast modes
- **Discoverability** - Helpful error messages, intuitive behavior

## Implementation Guidelines

### Color and Visual Design
```zig
// Example: ls with modern visuals
const FileIcon = enum {
    directory = "📁",     // With fallback to colored "d"
    executable = "⚡",    // With fallback to colored "*"
    symlink = "🔗",      // With fallback to colored "@"
    regular = "📄",      // With fallback to no symbol
};

// Adaptive color schemes
const ColorScheme = enum {
    auto,        // Detect from terminal
    modern,      // 24-bit true color
    classic,     // 16 colors
    none,        // NO_COLOR or dumb terminal
    high_contrast, // Accessibility mode
};
```

### Error Handling
- Clear, actionable error messages
- Suggest fixes when possible
- Use color to highlight problems (when available)
- Never hide errors for aesthetics

### Performance Features
- Parallel directory traversal (ls, du, find)
- Memory-mapped I/O for large files
- Smart buffering based on file size
- Progress indicators for long operations

### Modern Enhancements Examples

#### ls
- File type icons (with text fallbacks)
- Git status integration (optional)
- Human-readable sizes by default
- Smart column layout
- File preview on hover (if terminal supports)

#### grep
- Syntax highlighting for matches
- Context preview with fade effect
- Performance hints for large searches
- Parallel search with progress bar

#### cp/mv
- Progress bars with ETA
- Parallel copying for multiple files
- Smart resume on interruption
- Visual confirmation of operations

### Configuration
- Respect XDG base directories
- Environment variables for preferences
- NO_COLOR standard compliance
- Optional config file (~/.config/vibeutils/config.toml)

### Spec Reference Hierarchy

GNU coreutils is the primary behavioral reference.
When a flag exists in GNU, match GNU semantics. For
flags that exist only in macOS/OpenBSD (not GNU),
follow that spec's semantics.

Each utility has a flag matrix in
`docs/specs/<util>-flags.md` that maps every flag
across POSIX, macOS, OpenBSD, and GNU, with a tier:

- **MUST** — present across multiple specs
- **SHOULD** — useful flag from any single spec
- **WONT** — explicitly declined
- **KEEP** — vibeutils-specific additions

The matrices are the authoritative source for which
flags to implement and which spec governs behavior.

### Compatibility
- GNU coreutils behavioral compatibility for scripts
- macOS/OpenBSD-only flags added as SHOULD tier
- Additional flags don't break POSIX compliance
- Modern features are opt-in via flags or auto-detected
- Graceful degradation on limited terminals

### Per-Utility Spec Exceptions

#### stat
BSD and GNU `stat` have incompatible flag semantics
(`-f`, `-t`, `-n`, `-q`, `-r`, `-s`, `-x` all differ).
We follow the GNU interface.

The sharpest edge is `-f`: GNU `-f` is `--file-system`,
while BSD `-f FORMAT` is the format flag. A BSD script does
not error out under GNU semantics — it silently asks for the
file-system status of a file named `%Sm`. We resolve this
with documentation plus a non-fatal diagnostic, never with
platform-adaptive behavior:

- `-f` means `--file-system` on every platform. A flag whose
  meaning depends on the host is worse than one that is
  merely different from BSD's.
- We do not turn the misuse into an exit-2 error. That would
  break GNU parity for anyone legitimately running
  `stat -f` on a path that does not exist.
- When `-f` is given without `-c`/`--printf` and a
  format-looking operand names nothing on disk, `stat` adds
  one `stat: hint:` line on stderr suggesting
  `stat -c FORMAT`. It is purely additive: stdout and the
  exit status are byte-for-byte unchanged.

This is the general shape for spec collisions: keep the
reference behavior exact, and spend stderr — never stdout,
never the exit status — on explaining the surprise (#79).

#### test and [
The `test` and `[` utilities follow strict POSIX
compliance rather than GNU:
- **No options** — per POSIX.1-2024, `test` does not
  recognize `--` or any options
- **All arguments are expressions** — including
  `--help` and `--version`
- `test --help` returns 0 (true) because `--help`
  is a non-empty string
- This differs from GNU where `[` may honor `--help`

## What We DON'T Do
- Unnecessary animations
- Emoji in error messages
- Features that compromise correctness
- Non-standard behavior by default
- Complexity for the sake of features

## Examples of the Philosophy

### Bad (feature creep)
```bash
$ rm file.txt
🗑️  Moving file.txt to trash... ✨
[████████████] 100% Complete! 🎉
File safely deleted! Check trash to recover. 💾
```

### Good (our approach)
```bash
$ rm file.txt
rm: remove 'file.txt'? y
# Clear, simple, with optional color highlighting
```

### Bad (hiding information)
```bash
$ ls
Projects  Documents  Downloads
```

### Good (our approach)
```bash
$ ls
📁 Projects/   📁 Documents/   📁 Downloads/   📄 README.md   ⚡ script.sh*
# Icons enhance but don't replace information
# Falls back gracefully: drwxr-xr-x Projects/
```

## Testing Philosophy
- Test the OpenBSD-quality correctness first
- Test modern features separately
- Test graceful degradation
- Benchmark against GNU coreutils
- Fuzz testing for security

## Release Standards
- No known bugs
- 90%+ test coverage
- Man page complete and reviewed
- Performance within 10% of GNU (or faster)
- Works correctly in minimal environments