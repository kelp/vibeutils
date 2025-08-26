# Integration Testing Framework

## Overview

The vibeutils project includes a comprehensive shell-based integration testing framework designed to test the actual compiled binaries of our GNU coreutils implementation. This framework addresses critical challenges with testing filter utilities (like `tee`, `cat`, `sort`) that read from stdin and would otherwise block in unit tests.

## Motivation

### Why Integration Tests?

1. **Filter Utility Testing**: Many utilities block on stdin in unit tests, causing test hangs
2. **Binary Behavior**: Tests the actual compiled binary, not just Zig functions
3. **Signal Handling**: Can properly test signal handling (SIGINT, SIGPIPE)
4. **Binary Data**: Tests with real binary files and large inputs
5. **Platform Differences**: Handles macOS/Linux command variations
6. **Permission Testing**: Can test permission errors and edge cases

## Architecture

### Directory Structure

```
tests/
├── integration/
│   ├── lib/                    # Framework core modules
│   │   ├── lib.sh              # Main framework entry point
│   │   ├── assertions.sh       # Assertion functions
│   │   ├── colors.sh           # Terminal output and colors
│   │   ├── platform.sh         # Platform detection
│   │   └── test_runner.sh      # Test execution engine
│   ├── utils/                  # Per-utility test scripts
│   │   └── tee_test.sh         # Example: tee integration tests
│   ├── run.sh                  # Master test runner
│   └── .tmp/                   # Temporary test files (gitignored)
├── fixtures/                   # Test data files
│   ├── binary.bin              # Binary test data
│   ├── utf8.txt                # UTF-8 with emoji
│   ├── multiline.txt           # Multi-line content
│   ├── large.txt               # Large file for performance
│   └── empty.txt               # Empty file
```

## Framework Components

### Core Library (`lib/lib.sh`)

The main framework provides:
- Test initialization and cleanup
- Utility execution helpers
- File and directory management
- Cross-platform compatibility

Key functions:
- `init_framework()` - Initialize test environment
- `exec_utility()` - Execute a utility with input
- `cleanup_test_files()` - Clean up temporary files
- `has_utility()` - Check if utility is built

### Assertions (`lib/assertions.sh`)

Comprehensive assertion library with 30+ assertion types:

```bash
# Basic assertions
assert_equals "expected" "$actual" "Values should match"
assert_contains "$output" "substring" "Should contain text"

# File assertions
assert_file_exists "$file" "File should exist"
assert_file_contents "$file" "expected content"

# Exit code assertions
assert_exit_code 0 $? "Should succeed"
assert_success "Command should succeed"

# Output assertions
assert_output_contains "$output" "pattern"
assert_output_matches "$output" "regex.*pattern"
```

### Platform Detection (`lib/platform.sh`)

Handles cross-platform compatibility:
- Detects Linux, macOS, BSD, Windows WSL
- Identifies GNU vs BSD coreutils
- Adapts commands for platform differences
- Checks for tool availability

### Test Runner (`lib/test_runner.sh`)

Manages test execution:
- Parallel test execution support
- Timeout handling for each test
- Test filtering and exclusion
- Progress tracking and reporting
- Signal handling and cleanup

### Color Output (`lib/colors.sh`)

Professional test output:
- Respects `NO_COLOR` environment variable
- Terminal capability detection
- Colored pass/fail indicators
- Progress bars and spinners

## Writing Integration Tests

### Basic Test Structure

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source the framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test function
test_utility_basic() {
    # Setup
    local temp_file="${TEST_TEMP_DIR}/output.txt"
    
    # Execute utility
    local output=$(echo "input" | exec_utility "utility" "-flag")
    local exit_code=$?
    
    # Assertions
    assert_exit_code 0 $exit_code "Should succeed"
    assert_output_contains "$output" "expected"
    
    # Cleanup
    cleanup_test_files "$temp_file"
}

# Main test execution
main() {
    init_framework
    
    # Check utility exists
    if ! has_utility "utility"; then
        print_error "Utility not found. Run 'make build' first"
        return 1
    fi
    
    start_suite "Utility Integration Tests"
    
    # Define tests
    local -a test_specs=(
        $(make_test_spec "Basic Test" "test_utility_basic" "10")
        $(make_test_spec "Advanced Test" "test_utility_advanced" "30")
    )
    
    # Run tests
    init_test_runner --jobs 2 --timeout 10
    run_test_suite "${test_specs[@]}"
    
    end_suite
    print_final_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### Testing Filter Utilities

For utilities that read from stdin:

```bash
test_filter_stdin() {
    # Provide input via pipe
    local output=$(echo "test data" | exec_utility "filter")
    assert_output_equals "$output" "test data"
    
    # Or from file
    local output=$(exec_utility "filter" < "${FIXTURES_DIR}/input.txt")
    assert_output_contains "$output" "expected"
    
    # Multiple inputs
    local output=$(cat file1.txt file2.txt | exec_utility "filter" "-n")
    assert_line_count "$output" 10
}
```

### Testing Signal Handling

```bash
test_signal_handling() {
    # Start utility in background
    (sleep 0.1; echo "data") | exec_utility "utility" "-i" &
    local pid=$!
    
    # Send signal
    sleep 0.05
    kill -INT $pid 2>/dev/null || true
    
    # Wait and check it continued
    wait $pid
    local exit_code=$?
    
    assert_exit_code 0 $exit_code "Should ignore SIGINT with -i flag"
}
```

### Testing Binary Data

```bash
test_binary_data() {
    # Generate binary data
    dd if=/dev/urandom of="${TEST_TEMP_DIR}/binary.bin" bs=1024 count=1 2>/dev/null
    
    # Process through utility
    exec_utility "utility" < "${TEST_TEMP_DIR}/binary.bin" > "${TEST_TEMP_DIR}/output.bin"
    
    # Compare files
    cmp -s "${TEST_TEMP_DIR}/binary.bin" "${TEST_TEMP_DIR}/output.bin"
    assert_exit_code 0 $? "Binary data should be preserved"
}
```

## Running Tests

### Make Targets

```bash
# Run all integration tests
make test-integration

# Run tests for specific utility
make test-integration-util UTIL=tee

# Validate framework setup
make test-integration-validate

# List available test utilities
make test-integration-list
```

### Direct Execution

```bash
# Run all tests
./tests/integration/run.sh

# Run specific utility tests
./tests/integration/run.sh tee

# Run with options
./tests/integration/run.sh --verbose --jobs 4 --timeout 60

# Run filtered tests
./tests/integration/run.sh --filter "basic" --exclude "slow"

# Dry run to see what would execute
./tests/integration/run.sh --dry-run
```

### Environment Variables

```bash
# Enable verbose output
INTEGRATION_VERBOSE=1 make test-integration

# Disable colors
NO_COLOR=1 make test-integration

# Set parallel jobs
INTEGRATION_JOBS=8 make test-integration

# Set default timeout
INTEGRATION_TIMEOUT=60 make test-integration
```

## Test Coverage Guidelines

Each utility should have integration tests covering:

### Required Coverage

1. **Basic Functionality**
   - Primary use case
   - Reading from stdin
   - Writing to stdout
   - Basic flag combinations

2. **All Flags**
   - Each flag individually
   - Short and long forms
   - Flag combinations
   - Conflicting flags

3. **Edge Cases**
   - Empty input
   - Very large input
   - Binary data
   - Special characters
   - Unicode/UTF-8

4. **Error Conditions**
   - Invalid flags (exit code 2)
   - Permission errors (exit code 1)
   - Missing files
   - Write errors

5. **Help/Version**
   - `--help` output
   - `--version` output
   - `-h` short form

### Optional Coverage

- Signal handling (if applicable)
- Performance with large files
- Concurrent access
- Symbolic links
- Special file types

## Platform Compatibility

The framework handles platform differences automatically:

### macOS vs Linux

```bash
# Framework detects platform
if is_macos; then
    # Use BSD commands
    local size=$(stat -f%z "$file")
else
    # Use GNU commands
    local size=$(stat -c%s "$file")
fi

# Or use helper functions
local size=$(get_file_size "$file")  # Platform-agnostic
```

### Command Variations

The framework provides platform-agnostic helpers:
- `get_stat_cmd()` - Returns appropriate stat command
- `get_date_cmd()` - Returns appropriate date command
- `get_timeout_cmd()` - Returns timeout command if available
- `get_realpath_cmd()` - Returns realpath or fallback

## Debugging Tests

### Verbose Mode

```bash
# Enable verbose output
INTEGRATION_VERBOSE=1 ./tests/integration/run.sh tee

# Or use --verbose flag
./tests/integration/run.sh --verbose tee
```

### Debug Single Test

```bash
# Source framework and run single test
cd tests/integration
bash -x utils/tee_test.sh  # -x for trace output
```

### Check Test Output

```bash
# Test outputs are saved temporarily
ls -la tests/integration/.tmp/

# View specific test output
cat tests/integration/.tmp/TestName_*.out
```

## Best Practices

### 1. Test Independence

Each test should be completely independent:
- Create own temp files
- Clean up after completion
- Don't rely on test order

### 2. Meaningful Assertions

```bash
# Bad: Generic message
assert_equals "$expected" "$actual" "Test failed"

# Good: Descriptive message
assert_equals "$expected" "$actual" "Append mode should preserve existing content"
```

### 3. Proper Cleanup

```bash
test_with_cleanup() {
    local temp_file="${TEST_TEMP_DIR}/test.txt"
    
    # Test logic here
    
    # Always cleanup, even on failure
    cleanup_test_files "$temp_file"
}
```

### 4. Timeout Management

```bash
# Set appropriate timeouts for slow operations
$(make_test_spec "Large File Test" "test_large_file" "60")  # 60 second timeout

# Default is 10 seconds
$(make_test_spec "Quick Test" "test_quick")  # Uses default timeout
```

### 5. Cross-Platform Testing

Always test on multiple platforms:
- Linux (Ubuntu, Debian, Arch)
- macOS
- Windows WSL (if supported)

Use platform detection for platform-specific tests:

```bash
test_platform_specific() {
    if is_linux; then
        # Linux-specific test
    elif is_macos; then
        # macOS-specific test
    else
        skip_test "Platform not supported"
    fi
}
```

## Troubleshooting

### Common Issues

1. **Test Hangs**
   - Check for stdin blocking
   - Verify timeout is set
   - Use `exec_utility` helper instead of direct execution

2. **Command Not Found**
   - Run `make build` first
   - Check `has_utility()` before testing
   - Verify TEST_BIN_DIR is correct

3. **Permission Errors**
   - Some tests may need special permissions
   - Use skip_test for privileged operations
   - Consider using Docker/container for isolation

4. **Platform Differences**
   - Use platform detection functions
   - Provide platform-specific implementations
   - Skip tests that don't apply to platform

## Contributing

When adding a new utility:

1. Create test file: `tests/integration/utils/<utility>_test.sh`
2. Follow the template structure
3. Cover all required test categories
4. Run locally on multiple platforms
5. Ensure tests pass in CI

When modifying the framework:

1. Update affected test utilities
2. Run full integration suite
3. Update this documentation
4. Consider backward compatibility

## Future Enhancements

Planned improvements to the framework:

- [ ] Test report generation (JSON/XML)
- [ ] Coverage tracking integration
- [ ] Benchmark/performance tests
- [ ] Compatibility tests vs GNU coreutils
- [ ] Fuzzing integration
- [ ] Docker-based testing for multiple distros
- [ ] GitHub Actions integration
- [ ] Test result caching
- [ ] Visual test result dashboard