# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
# Build all utilities
zig build
make build

# Run tests
zig build test
make test

# Run tests with coverage report (uses kcov)
make coverage
# Coverage report: coverage/index.html

# Build and run specific utility
zig build run-echo -- hello world
make run-echo ARGS="hello world"

# Build with specific optimization
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=Debug
make debug      # Debug build
make release    # Optimized for size

# Clean build artifacts
make clean

# Install optimized binaries
make install

# Format source code
make fmt

# Run a single test file
zig test src/echo.zig
zig test src/common/lib.zig
```

## Git Hooks

The project includes a pre-commit hook that automatically:
- Runs `make fmt` to format code before every commit
- Adds any formatting changes to the commit
- Runs tests to ensure code integrity

The hook is located at `.git/hooks/pre-commit` and is automatically set up for this repository.

## Makefile Targets

The project includes a comprehensive Makefile with the following targets:

- `make build` - Build all utilities (default target)
- `make test` - Run all tests
- `make coverage` - Run tests with coverage analysis using kcov
- `make clean` - Remove build artifacts and coverage files
- `make install` - Build optimized binaries for production
- `make run-<utility>` - Run specific utility (e.g., `make run-echo ARGS="hello"`)
- `make debug` - Build with debug information
- `make release` - Build optimized for smallest size
- `make fmt` - Format all source code with `zig fmt`
- `make help` - Show all available targets

## Test Coverage

The project has **74 tests** covering:
- **echo.zig**: 16 tests (basic output, flags, escape sequences)
- **cat.zig**: 10 tests (file reading, numbering, formatting)
- **ls.zig**: 27 tests (listing, formatting, sorting, filtering)
- **common modules**: 21 tests (utilities, file operations, styling)

Coverage reports are generated using `kcov` and can be viewed at `coverage/index.html` after running `make coverage`.

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
   - `src/common/args.zig` - Argument parsing utilities
   - `src/common/file.zig` - File operation helpers
   - `src/common/terminal.zig` - Terminal capability detection
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
2. Add to `build.zig` following this pattern:
   - Add the executable in `b.addExecutable()`
   - Set up module dependencies (common, clap)
   - Create install and run steps
   - Add to test step
3. Write failing tests first (see echo.zig for examples)
4. Implement using common library functions
5. Create man page in `man/man1/<utility>.1` (OpenBSD style)
6. Update TODO.md to mark tasks complete

### Referencing Man Pages

When implementing a new command, always consult both OpenBSD and GNU coreutils man pages to determine the most useful set of flags to support:

1. **OpenBSD man pages**: Access online at `https://man.openbsd.org/<command>`
   - Example: `https://man.openbsd.org/mkdir` for the mkdir command
   - Focus on security, simplicity, and correctness
   - Often have cleaner, more focused flag sets

2. **GNU coreutils man pages**: Available locally via `man <command> | cat`
   - Example: `man mkdir | cat` for the mkdir command
   - More extensive feature set with many flags
   - Required for GNU compatibility

3. **Implementation strategy**:
   - Start with the core flags that appear in both implementations
   - Add GNU-specific flags that are commonly used in scripts
   - Include OpenBSD security/safety features where applicable
   - Document any intentional differences in behavior

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

## Code Style and Conventions

### Error Handling
```zig
// Use common.printError for consistent error messages
common.printError("cat", "file.txt: {s}", .{@errorName(err)});

// Exit codes from common.ExitCode enum
return common.ExitCode.Failure;
```

### Memory Management
- Always use provided allocator (usually from args)
- Use `defer` for cleanup immediately after allocation
- Test with `testing.allocator` to detect leaks

### Argument Parsing
- Use zig-clap for consistent GNU-style argument parsing
- Support both short (`-n`) and long (`--number`) options
- Include `--help` and `--version` for all utilities

### Performance Considerations
- Use buffered I/O for file operations
- Pre-allocate buffers when size is known
- Consider parallel processing for independent operations (e.g., multiple files)