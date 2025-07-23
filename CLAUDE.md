# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
# Build all utilities
zig build

# Run tests
zig build test

# Build and run specific utility
zig build run-echo -- hello world

# Build with specific optimization
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=Debug

# Run a single test file
zig test src/echo.zig
zig test src/common/lib.zig
```

## Architecture Overview

This is a Zig implementation of GNU coreutils with modern enhancements. The project follows OpenBSD engineering principles (correctness, simplicity, security) while adding modern UX features (colors, icons, progress bars).

### Key Design Decisions

1. **Common Library Pattern**: All utilities import a shared `common` module that provides:
   - Terminal capability detection (NO_COLOR support, color modes)
   - Error handling with program name prefixes
   - Progress indicators for long operations
   - Styling abstractions with graceful degradation

2. **TDD Workflow**: Each utility follows this cycle:
   - Write failing tests first (in the same .zig file)
   - Implement minimal code to pass
   - Add more test cases for flags and edge cases
   - Target 90%+ test coverage

3. **Module Structure**:
   - `src/common/lib.zig` - Entry point for common functionality
   - `src/common/style.zig` - Terminal styling and color detection
   - `src/<utility>.zig` - Each utility with embedded tests
   - Man pages in `man/man1/` using mdoc format

### Terminal Adaptation Strategy

The styling system (`src/common/style.zig`) automatically detects:
- NO_COLOR environment variable
- Terminal type (dumb, 16-color, 256-color, truecolor)
- Unicode support via LANG/LC_ALL
- Falls back gracefully when features aren't available

### Adding a New Utility

1. Create `src/<utility>.zig` with embedded tests
2. Add to `build.zig` following the echo pattern
3. Write failing tests first (see echo.zig for examples)
4. Implement using common library functions
5. Create man page in `man/man1/<utility>.1` (OpenBSD style)
6. Update TODO.md to mark tasks complete

### Testing Patterns

```zig
// Use testing allocator to detect leaks
test "description" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    
    // Test against buffer output
    try function(&args, buffer.writer());
    try testing.expectEqualStrings("expected", buffer.items);
}
```

### Implementation Priorities

Utilities are implemented in phases (see TODO.md):
1. Phase 1: Essential utilities (echo, cat, ls, cp, mv, rm, mkdir, rmdir, touch, pwd)
2. Phase 2: Text processing (head, tail, wc, sort, uniq, cut, tr)
3. Phase 3: File information (stat, du, df)
4. Phase 4: Advanced (find, grep)

Each utility requires:
- Full GNU compatibility tests
- Man page with 2-3 practical examples
- Modern enhancements (colors, progress, parallel processing where applicable)