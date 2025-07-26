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

### Compatibility
- Full GNU coreutils compatibility for scripts
- Additional flags don't break POSIX compliance
- Modern features are opt-in via flags or auto-detected
- Graceful degradation on limited terminals

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