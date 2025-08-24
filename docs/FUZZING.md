# Fuzzing Guide

This document provides comprehensive guidance on fuzzing vibeutils, covering quick start commands, architecture, and advanced usage patterns.

## Quick Start

### Platform Requirements
- **Linux**: Full fuzzing support with all features
- **macOS**: Use `make fuzz-linux-*` targets (runs in Docker container) 
- **Windows**: Not supported

### Essential Commands

```bash
# Show available fuzzing options
make fuzz

# Fuzz specific utilities (RECOMMENDED)
make fuzz UTIL=cat
make fuzz UTIL=echo
make fuzz UTIL=ls

# List all available utilities
make fuzz-list

# Quick workflows
make fuzz-quick    # Quick test all utilities (30s each)
make fuzz-all      # Fuzz all utilities (5 min each)
make fuzz-rotate   # Continuous rotation (2 min each)

# For macOS users (runs in Docker)
make fuzz-linux UTIL=cat
make fuzz-linux-all
make fuzz-linux-quick
```

### Direct Build System Usage

```bash
# Individual utility targets
zig build fuzz-cat
zig build fuzz-echo
zig build fuzz-basename
# ... 22 total targets available

# Environment variable control
VIBEUTILS_FUZZ_TARGET=cat zig build test --fuzz
VIBEUTILS_FUZZ_TARGET=all zig build test --fuzz

# Using the script directly
./scripts/fuzz-utilities.sh cat          # Default 5 min timeout
./scripts/fuzz-utilities.sh -t 60 echo   # Custom 60s timeout
./scripts/fuzz-utilities.sh all          # All utilities sequentially
./scripts/fuzz-utilities.sh -r -t 120    # Rotation mode, 2 min each
```

## Selective Fuzzing System

### Problem Solved
Previously, `zig build test --fuzz` would run ALL fuzz tests and get stuck on the first one forever since Zig 0.15.1 fuzzing runs indefinitely. Our selective fuzzing system allows:
- Testing individual utilities selectively
- Rotating through multiple utilities with time limits
- Running focused fuzzing sessions on specific utilities

### How It Works

#### Environment Variable Control
The `VIBEUTILS_FUZZ_TARGET` environment variable controls which utility gets fuzzed:
- `VIBEUTILS_FUZZ_TARGET=cat` - Fuzz only the cat utility
- `VIBEUTILS_FUZZ_TARGET=all` - Fuzz all utilities  
- Unset variable - No fuzzing runs (opt-in behavior)

#### Runtime Selection
Each fuzz test includes a runtime check:
```zig
fn testUtilityWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("utility_name")) return;
    
    // ... rest of fuzz test
}
```

#### Individual Build Targets
The build system creates individual targets for each utility:
```bash
zig build fuzz-cat      # Fuzz only cat
zig build fuzz-echo     # Fuzz only echo
zig build fuzz-ls       # Fuzz only ls
```

## Architecture & Implementation

### Core Infrastructure

**`src/common/fuzz.zig`** contains the entire fuzzing infrastructure:

1. **Intelligent Fuzzer** (`createIntelligentFuzzer`)
   - Uses compile-time reflection to discover all command-line flags
   - Understands semantic relationships between flags
   - Categories: data_input, data_output, behavior_modifier, etc.
   - Generates contextually appropriate values

2. **Smart Fuzzer** (`createSmartFuzzer`)  
   - Simpler version with automatic flag discovery
   - Less sophisticated than intelligent fuzzer

3. **Unified Fuzz Test Builder** (`createUtilityFuzzTests`)
   - Eliminates code duplication across 22+ utilities
   - Generates standardized fuzz test functions
   - Reduces boilerplate from ~70% duplication to reusable components

4. **Helper Functions**
   - `generatePath()` - Path strings with edge cases
   - `generateArgs()` - Command-line arguments from fuzz input
   - `ArgStorage` - Pre-allocated storage for arguments
   - `shouldFuzzUtilityRuntime()` - Runtime fuzzing control

### Integration Pattern

Each utility has fuzz tests **directly in its source file** (not separate files):

```zig
// At the end of src/myutil.zig
const enable_fuzz_tests = builtin.os.tag == .linux;

test "myutil fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testMyUtilIntelligent, .{});
}

fn testMyUtilIntelligent(allocator: std.mem.Allocator, input: []const u8) !void {
    const Fuzzer = common.fuzz.createIntelligentFuzzer(MyUtilArgs, runMyUtil);
    try Fuzzer.testComprehensive(allocator, input, common.null_writer);
}
```

**Critical**: The wrapper function is required because `std.testing.fuzz()` only accepts functions with exactly 2 parameters: `(allocator, input)`.

### Modern Architecture Improvements

#### Unified Test Builder
**Before**:
```zig
// Repetitive in every utility file
test "utility fuzz basic" {
    try std.testing.fuzz(testing.allocator, testUtilityBasic, .{});
}

fn testUtilityBasic(allocator: std.mem.Allocator, input: []const u8) !void {
    try common.fuzz.testUtilityBasic(utility.runUtility, allocator, input);
}
```

**After**:
```zig
// Create standardized fuzz tests using the unified builder
const UtilityFuzzTests = common.fuzz.createUtilityFuzzTests(utility.runUtility);

test "utility fuzz basic" {
    try std.testing.fuzz(testing.allocator, UtilityFuzzTests.testBasic, .{});
}
```

#### Configuration Constants
All magic numbers are now documented in `FuzzConfig`:

```zig
pub const FuzzConfig = struct {
    /// Maximum argument size varies by build mode for performance
    /// Debug: 1000 bytes (fast iteration), Release: 10KB (comprehensive testing)
    /// Based on typical shell command limits and reasonable fuzz test duration
    pub const MAX_ARG_SIZE = if (builtin.mode == .Debug) 1000 else 10_000;
    
    /// Maximum path size for generated test paths
    /// 4096 bytes matches typical POSIX PATH_MAX and Linux kernel limits
    pub const MAX_PATH_SIZE = 4096;
};
```

#### Cross-Platform Path Handling
```zig
// Cross-platform temp directory selection
const temp_dir = if (builtin.os.tag == .windows) "C:\\temp\\test.txt" else "/tmp/test.txt";

// Relative paths for testing (OS handles permissions)
const test_dir = "fuzz_test_dir"; // Instead of "/tmp/fuzz_test_dir"
```

## Usage Patterns

### Development Workflow

```bash
# After implementing a new feature in cat
make fuzz UTIL=cat

# Quick test before commit
make fuzz-quick

# Comprehensive testing session
make fuzz-all  # Linux
make fuzz-linux-all  # From macOS
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Quick Fuzz Test
  run: make fuzz-quick
  
- name: Fuzz Critical Utilities
  run: |
    make fuzz UTIL=rm
    make fuzz UTIL=cp
    make fuzz UTIL=mv
```

### Debugging Fuzz Failures

```bash
# Interactive shell for manual fuzzing
make fuzz-linux-shell

# Then inside the container:
zig build fuzz-cat
# Or use the script:
./scripts/fuzz-utilities.sh -t 60 cat
```

## Available Utilities

All utilities support fuzzing:
- **File Operations**: `cat`, `cp`, `mv`, `rm`, `touch`, `ln`, `head`, `tail`
- **Directory Operations**: `ls`, `mkdir`, `rmdir`, `pwd`
- **Permissions**: `chmod`, `chown` 
- **Text Processing**: `echo`, `basename`, `dirname`, `test`
- **System**: `true`, `false`, `sleep`, `yes`

## Advanced Features

### Fuzzing Script Options

The `scripts/fuzz-utilities.sh` script provides comprehensive control:

```bash
# Basic usage
./scripts/fuzz-utilities.sh cat          # Default 5 min timeout
./scripts/fuzz-utilities.sh -t 60 echo   # Custom 60s timeout

# Batch operations
./scripts/fuzz-utilities.sh all          # All utilities sequentially
./scripts/fuzz-utilities.sh -r -t 120    # Rotation mode, 2 min each

# List and help
./scripts/fuzz-utilities.sh --list       # Show available utilities
./scripts/fuzz-utilities.sh -h           # Show help
```

### Docker/Container Usage
```bash
# Run in Docker (for macOS or custom environments)
docker run -it -v $(pwd):/workspace -w /workspace ubuntu:latest
apt update && apt install -y zig
zig build test --fuzz
```

### Web UI Access
Some fuzz configurations may start a web interface:
```bash
# Check output for actual port, usually 8000
# Browse to http://127.0.0.1:8000
```

## Troubleshooting

### Common Issues

1. **"no fuzz tests found" on macOS**
   - Expected behavior - use `make fuzz-linux-*` commands instead

2. **Tests get stuck on first utility**
   - Use selective fuzzing: `make fuzz UTIL=specific_utility`
   - Don't use `zig build test --fuzz` without `VIBEUTILS_FUZZ_TARGET`

3. **Port binding issues in Docker**
   - Check Docker port forwarding configuration
   - Use `make fuzz-linux-shell` for interactive debugging

4. **Memory allocation errors**
   - Fuzz tests use `testing.allocator` for leak detection
   - Check allocator usage in utility implementation

### Performance Tuning

- Debug builds: Faster iteration, smaller argument sizes
- Release builds: Comprehensive testing, larger test cases  
- Timeout adjustments: Use `-t` flag for custom durations
- Rotation mode: Prevents any single utility from monopolizing time

## Security Testing

The fuzzing system includes intentional security probes:
- Path traversal attempts: `../../../test/fuzz_traversal_probe`
- Edge case path handling
- Malformed argument combinations
- Buffer boundary testing

These are legitimate security tests, not malicious code.

## Technical Notes

### LibFuzzer Integration
vibeutils uses Zig 0.15.1's built-in fuzzing support based on LibFuzzer:
- Automatic test case minimization
- Coverage-guided fuzzing
- Crash reproduction capabilities
- Integration with Zig's testing framework

### Memory Safety
- All fuzz tests use explicit allocator parameters
- `testing.allocator` detects memory leaks automatically
- Cross-platform allocator handling
- Proper cleanup in error paths

### Platform Limitations
- Linux: Full support (x86_64, aarch64)
- macOS: Docker-based fuzzing only
- Windows: Not supported by Zig's LibFuzzer integration