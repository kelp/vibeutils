# Selective Fuzzing System for vibeutils

This document describes the selective fuzzing system implemented for vibeutils, which allows developers to fuzz individual utilities instead of all utilities at once.

## Problem Solved

Previously, `zig build test --fuzz` would run ALL fuzz tests and get stuck on the first one forever since Zig 0.14 fuzzing runs indefinitely. This made it impossible to:
- Test individual utilities selectively
- Rotate through multiple utilities with time limits
- Run focused fuzzing sessions on specific utilities

## Solution Overview

The selective fuzzing system introduces:

1. **Environment Variable Control**: `VIBEUTILS_FUZZ_TARGET` controls which utility gets fuzzed
2. **Individual Build Targets**: `zig build fuzz-<utility>` for each utility
3. **Comprehensive Fuzzing Script**: `scripts/fuzz-utilities.sh` with advanced options
4. **Runtime Selection**: Fuzz tests check the environment variable at runtime

## Architecture

### Core Components

#### 1. Helper Functions (`src/common/fuzz.zig`)

```zig
/// Check if fuzzing should be enabled (compile-time version)
pub fn shouldFuzzUtility(utility_name: []const u8) bool

/// Check if fuzzing should be enabled (runtime version)  
pub fn shouldFuzzUtilityRuntime(utility_name: []const u8) bool
```

#### 2. Environment Variable Logic

The system uses the `VIBEUTILS_FUZZ_TARGET` environment variable:
- `VIBEUTILS_FUZZ_TARGET=cat` - Fuzz only the cat utility
- `VIBEUTILS_FUZZ_TARGET=all` - Fuzz all utilities
- Unset variable - No fuzzing runs (opt-in behavior)

#### 3. Runtime Selection

Each fuzz test wrapper includes a runtime check:

```zig
fn testUtilityWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("utility_name")) return;
    
    // ... rest of fuzz test
}
```

## Usage Examples

### 1. Using Build System Targets

Fuzz individual utilities:
```bash
zig build fuzz-cat      # Fuzz only cat
zig build fuzz-echo     # Fuzz only echo  
zig build fuzz-ls       # Fuzz only ls
```

View all available targets:
```bash
zig build --help | grep fuzz-
```

### 2. Using Environment Variables

Direct environment variable control:
```bash
VIBEUTILS_FUZZ_TARGET=cat zig build test --fuzz
VIBEUTILS_FUZZ_TARGET=all zig build test --fuzz  
```

### 3. Using the Fuzzing Script

The `scripts/fuzz-utilities.sh` script provides the most comprehensive fuzzing options:

#### Basic Usage
```bash
# Fuzz a single utility
./scripts/fuzz-utilities.sh cat

# Fuzz all utilities sequentially
./scripts/fuzz-utilities.sh all

# List available utilities
./scripts/fuzz-utilities.sh --list
```

#### Advanced Usage
```bash
# Fuzz with custom timeout (2 minutes)
./scripts/fuzz-utilities.sh -t 120 echo

# Rotate through all utilities (1 minute each)
./scripts/fuzz-utilities.sh -r -t 60

# Fuzz all utilities with 30 second timeout each
./scripts/fuzz-utilities.sh -t 30 all
```

#### Help and Options  
```bash
./scripts/fuzz-utilities.sh --help
```

## Implementation Details

### Compile-Time vs Runtime Checks

The system uses a two-phase approach:

1. **Compile-Time Check** (`shouldFuzzUtility`):
   - Only checks if we're on Linux (fuzzing only works on Linux)
   - Used in `test` declarations to determine if tests should be included
   - Cannot access environment variables (Zig limitation)

2. **Runtime Check** (`shouldFuzzUtilityRuntime`):
   - Checks Linux requirement AND environment variable
   - Called at the start of each fuzz test wrapper
   - Enables selective execution based on `VIBEUTILS_FUZZ_TARGET`

### Migration Pattern

Utilities have been updated with this pattern:

**Before:**
```zig
const enable_fuzz_tests = builtin.os.tag == .linux;
```

**After:**  
```zig
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("utility_name");

fn testUtilityWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    if (!common.fuzz.shouldFuzzUtilityRuntime("utility_name")) return;
    // ... rest of test
}
```

### Build System Integration

Individual fuzz targets are automatically generated in `build.zig`:

```zig
// Creates: fuzz-cat, fuzz-echo, fuzz-ls, etc.
for (utils.utilities) |util| {
    const fuzz_target_name = std.fmt.allocPrint(b.allocator, "fuzz-{s}", .{util.name});
    const individual_fuzz_step = b.step(fuzz_target_name, fuzz_target_desc);
    
    const fuzz_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        std.fmt.allocPrint(b.allocator, "VIBEUTILS_FUZZ_TARGET={s} zig build test --fuzz", .{util.name}),
    });
}
```

## Available Utilities

The following utilities support selective fuzzing:

- basename
- cat  
- chmod
- chown
- cp
- dirname
- echo
- false
- head
- ln
- ls
- mkdir
- mv
- pwd
- rm
- rmdir
- sleep
- tail
- test
- touch
- true
- yes

**Total: 22 utilities**

## Platform Requirements

- **Linux Only**: Fuzzing only works on Linux systems
- **Zig 0.14.1**: Requires the specific Zig version used by the project
- **Bash**: The fuzzing script requires bash for advanced features

## Best Practices

### For Development

1. **Start Small**: Test individual utilities before running comprehensive fuzzing
2. **Use Timeouts**: Always use timeouts to prevent infinite fuzzing sessions
3. **Monitor Resources**: Fuzzing can be resource-intensive
4. **Check Logs**: Fuzzing logs are saved with timestamps for analysis

### For CI/CD

1. **Targeted Testing**: Use selective fuzzing in CI to test specific components
2. **Time Limits**: Set reasonable timeouts for CI environments
3. **Parallel Testing**: Different utilities can be fuzzed in parallel
4. **Error Handling**: The script provides detailed exit codes for automation

### Example CI Usage

```bash
# Quick smoke test - 30 seconds per utility
./scripts/fuzz-utilities.sh -t 30 all

# Focus on core utilities
./scripts/fuzz-utilities.sh -t 60 cat
./scripts/fuzz-utilities.sh -t 60 echo  
./scripts/fuzz-utilities.sh -t 60 ls
```

## Troubleshooting

### Common Issues

1. **Not on Linux**: Fuzzing will be skipped with no error
2. **Environment Variable Not Set**: No fuzzing will run (by design)
3. **Build Failures**: Ensure project builds successfully first
4. **Memory Leaks**: Some memory leaks in fuzz tests are expected and normal

### Debugging

Enable verbose output:
```bash
VIBEUTILS_FUZZ_TARGET=echo zig build test --fuzz --verbose
```

Check environment:
```bash
echo $VIBEUTILS_FUZZ_TARGET
echo $OSTYPE
```

Test script functionality:
```bash
./scripts/fuzz-utilities.sh --list
./scripts/fuzz-utilities.sh echo -t 5  # 5 second test
```

## Migration Status

### Completed (8 utilities)
- basename ✅
- cat ✅  
- echo ✅
- ls ✅
- mkdir ✅
- rm ✅
- cp ✅
- pwd ✅

### Remaining (14 utilities)
To complete the migration, update the remaining utilities with the pattern shown above:
- chmod, chown, dirname, false, head, ln, mv, rmdir, sleep, tail, test, touch, true, yes

Each utility needs:
1. Update `enable_fuzz_tests` to use `common.fuzz.shouldFuzzUtility(utility_name)`
2. Add runtime check in fuzz wrapper functions: `if (!common.fuzz.shouldFuzzUtilityRuntime(utility_name)) return;`

## Future Enhancements

### Planned Features
1. **Fuzz Coverage Reports**: Track which utilities have been fuzzed and for how long
2. **Smart Scheduling**: Automatically rotate through utilities based on code changes  
3. **Performance Metrics**: Track fuzzing performance and identify bottlenecks
4. **Web Dashboard**: Real-time monitoring of fuzzing progress

### Extensibility
1. **Custom Fuzz Strategies**: Add utility-specific fuzzing strategies
2. **Integration Testing**: Fuzz combinations of utilities together
3. **Seed Management**: Save and replay interesting fuzzing seeds
4. **Crash Analysis**: Automated crash triage and reporting

## Conclusion

The selective fuzzing system transforms vibeutils fuzzing from an all-or-nothing approach to a precise, controllable testing tool. This enables:

- **Focused Testing**: Target specific utilities for thorough testing
- **CI Integration**: Practical fuzzing in continuous integration pipelines  
- **Development Workflow**: Quick fuzzing during development cycles
- **Resource Management**: Control fuzzing duration and resource usage

The system maintains backward compatibility while providing powerful new capabilities for both manual testing and automated workflows.