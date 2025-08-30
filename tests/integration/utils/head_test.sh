#!/usr/bin/env bash
# Comprehensive integration tests for head utility
# Tests all flags, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
HEAD_TIMEOUT=10
LARGE_FILE_TIMEOUT=20

# Test helper functions
setup_head_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

cleanup_head_files() {
    local files=("$@")
    for file in "${files[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
}

create_test_file_with_lines() {
    local file="$1"
    local line_count="$2"
    local prefix="${3:-line}"
    
    > "$file"  # Create empty file
    for i in $(seq 1 "$line_count"); do
        printf "%s %d\n" "$prefix" "$i" >> "$file"
    done
}

# =============================================================================
# Basic Functionality Tests  
# =============================================================================

test_head_basic_functionality() {
    setup_head_test
    
    local test_file="basic_test.txt" 
    create_test_file_with_lines "$test_file" 20
    
    # Test default head (first 10 lines)
    exec_utility head --timeout="$HEAD_TIMEOUT" "$test_file"
    
    assert_success "head should succeed with basic file reading"
    
    # Check that we get exactly 10 lines
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "10" "$line_count" "head should output exactly 10 lines by default"
    
    # Check first and last line content
    assert_contains "$EXEC_OUTPUT" "line 1" "output should contain first line"
    assert_contains "$EXEC_OUTPUT" "line 10" "output should contain tenth line"
    assert_not_contains "$EXEC_OUTPUT" "line 11" "output should not contain eleventh line"
    
    cleanup_head_files "$test_file"
}

test_head_custom_line_count() {
    setup_head_test
    
    local test_file="line_count_test.txt"
    create_test_file_with_lines "$test_file" 20
    
    # Test -n 5 flag
    exec_utility head --timeout="$HEAD_TIMEOUT" -n 5 "$test_file"
    
    assert_success "head should succeed with -n flag"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "5" "$line_count" "head -n 5 should output exactly 5 lines"
    
    assert_contains "$EXEC_OUTPUT" "line 1" "output should contain first line"
    assert_contains "$EXEC_OUTPUT" "line 5" "output should contain fifth line"
    assert_not_contains "$EXEC_OUTPUT" "line 6" "output should not contain sixth line"
    
    cleanup_head_files "$test_file"
}

test_head_zero_lines() {
    setup_head_test
    
    local test_file="zero_test.txt"
    create_test_file_with_lines "$test_file" 10
    
    # Test -n 0 flag
    exec_utility head --timeout="$HEAD_TIMEOUT" -n 0 "$test_file"
    
    assert_success "head should succeed with -n 0"
    assert_output_equals "" "head -n 0 should produce no output"
    
    cleanup_head_files "$test_file"
}

test_head_large_line_count() {
    setup_head_test
    
    local test_file="large_count_test.txt"
    create_test_file_with_lines "$test_file" 5
    
    # Test -n with count larger than file
    exec_utility head --timeout="$HEAD_TIMEOUT" -n 100 "$test_file"
    
    assert_success "head should succeed when -n is larger than file"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "5" "$line_count" "head should output all available lines when -n is larger than file"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# Multiple Files Tests
# =============================================================================

test_head_multiple_files() {
    setup_head_test
    
    local file1="file1.txt"
    local file2="file2.txt"
    create_test_file_with_lines "$file1" 15 "first"
    create_test_file_with_lines "$file2" 15 "second"
    
    # Test multiple files (should show headers)
    exec_utility head --timeout="$HEAD_TIMEOUT" -n 3 "$file1" "$file2"
    
    assert_success "head should succeed with multiple files"
    
    # Check for headers
    assert_contains "$EXEC_OUTPUT" "==> $file1 <==" "output should contain header for first file"
    assert_contains "$EXEC_OUTPUT" "==> $file2 <==" "output should contain header for second file"
    
    # Check content
    assert_contains "$EXEC_OUTPUT" "first 1" "output should contain content from first file"
    assert_contains "$EXEC_OUTPUT" "second 1" "output should contain content from second file"
    
    cleanup_head_files "$file1" "$file2"
}

test_head_quiet_flag() {
    setup_head_test
    
    local file1="file1.txt"
    local file2="file2.txt"
    create_test_file_with_lines "$file1" 10 "first"
    create_test_file_with_lines "$file2" 10 "second"
    
    # Test -q flag (quiet - no headers)
    exec_utility head --timeout="$HEAD_TIMEOUT" -q -n 2 "$file1" "$file2"
    
    assert_success "head should succeed with -q flag"
    
    # Check that headers are NOT shown
    assert_not_contains "$EXEC_OUTPUT" "==> $file1 <==" "output should not contain header with -q flag"
    assert_not_contains "$EXEC_OUTPUT" "==> $file2 <==" "output should not contain header with -q flag"
    
    # But content should still be there
    assert_contains "$EXEC_OUTPUT" "first 1" "output should contain content from first file"
    assert_contains "$EXEC_OUTPUT" "second 1" "output should contain content from second file"
    
    cleanup_head_files "$file1" "$file2"
}

test_head_verbose_flag() {
    setup_head_test
    
    local test_file="verbose_test.txt"
    create_test_file_with_lines "$test_file" 10
    
    # Test -v flag (verbose - always show headers, even for single file)
    exec_utility head --timeout="$HEAD_TIMEOUT" -v -n 3 "$test_file"
    
    assert_success "head should succeed with -v flag"
    assert_contains "$EXEC_OUTPUT" "==> $test_file <==" "output should contain header with -v flag even for single file"
    assert_contains "$EXEC_OUTPUT" "line 1" "output should contain file content"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# Stdin and Dash Tests
# =============================================================================

test_head_stdin_input() {
    setup_head_test
    
    local input="line one
line two
line three
line four
line five
line six
line seven
line eight
line nine
line ten
line eleven
line twelve"
    
    # Test reading from stdin
    exec_utility head --timeout="$HEAD_TIMEOUT" --input="$input" -n 3
    
    assert_success "head should succeed reading from stdin"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "3" "$line_count" "head should output exactly 3 lines from stdin"
    
    assert_contains "$EXEC_OUTPUT" "line one" "output should contain first line from stdin"
    assert_contains "$EXEC_OUTPUT" "line three" "output should contain third line from stdin"
    assert_not_contains "$EXEC_OUTPUT" "line four" "output should not contain fourth line from stdin"
}

test_head_dash_argument() {
    setup_head_test
    
    local input="stdin line 1
stdin line 2
stdin line 3"
    
    # Test reading from stdin using dash argument
    exec_utility head --timeout="$HEAD_TIMEOUT" --input="$input" -n 2 -
    
    assert_success "head should succeed reading from stdin with dash"
    assert_contains "$EXEC_OUTPUT" "stdin line 1" "output should contain content from stdin"
    assert_contains "$EXEC_OUTPUT" "stdin line 2" "output should contain second line from stdin"
    assert_not_contains "$EXEC_OUTPUT" "stdin line 3" "output should not contain third line with -n 2"
}

test_head_mixed_files_and_stdin() {
    setup_head_test
    
    local test_file="mixed_test.txt"
    create_test_file_with_lines "$test_file" 5 "file"
    
    local input="stdin line 1
stdin line 2
stdin line 3"
    
    # Test mixing file and stdin
    exec_utility head --timeout="$HEAD_TIMEOUT" --input="$input" -n 2 "$test_file" -
    
    assert_success "head should succeed with mixed files and stdin"
    
    # Should have headers for both
    assert_contains "$EXEC_OUTPUT" "==> $test_file <==" "output should contain header for file"
    assert_contains "$EXEC_OUTPUT" "==> standard input <==" "output should contain header for stdin"
    
    assert_contains "$EXEC_OUTPUT" "file 1" "output should contain content from file"
    assert_contains "$EXEC_OUTPUT" "stdin line 1" "output should contain content from stdin"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# Byte Count Tests
# =============================================================================

test_head_byte_count() {
    setup_head_test
    
    local test_file="byte_test.txt"
    # Create file with known byte content
    printf "1234567890abcdefghij" > "$test_file"
    
    # Test -c flag (byte count)
    exec_utility head --timeout="$HEAD_TIMEOUT" -c 10 "$test_file"
    
    assert_success "head should succeed with -c flag"
    assert_output_equals "1234567890" "head -c 10 should output exactly 10 bytes"
    
    cleanup_head_files "$test_file"
}

test_head_byte_count_with_newlines() {
    setup_head_test
    
    local test_file="byte_newline_test.txt"
    printf "line1\nline2\nline3\n" > "$test_file"
    
    # Test -c with newlines (18 bytes total: "line1\nline2\nline3\n")
    exec_utility head --timeout="$HEAD_TIMEOUT" -c 12 "$test_file"
    
    assert_success "head should succeed with -c flag including newlines"
    assert_output_equals "line1
line2" "head -c 12 should output exactly 12 bytes including newlines"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# Empty and Edge Case Tests
# =============================================================================

test_head_empty_file() {
    setup_head_test
    
    local empty_file="empty.txt"
    touch "$empty_file"
    
    exec_utility head --timeout="$HEAD_TIMEOUT" "$empty_file"
    
    assert_success "head should succeed with empty file"
    assert_output_equals "" "head should produce no output for empty file"
    
    cleanup_head_files "$empty_file"
}

test_head_single_line_file() {
    setup_head_test
    
    local single_file="single.txt"
    printf "only line" > "$single_file"
    
    exec_utility head --timeout="$HEAD_TIMEOUT" "$single_file"
    
    assert_success "head should succeed with single line file"
    assert_output_equals "only line" "head should output the single line"
    
    cleanup_head_files "$single_file"
}

test_head_binary_file() {
    setup_head_test
    
    local binary_file="binary.dat"
    local output_file="binary_output.dat"
    
    # Create binary file with some null bytes and text
    printf "\x00\x01\x02hello\x00world\xff\xfe" > "$binary_file"
    
    # Use binary_path directly to avoid framework issues with binary data
    local binary_path="$(get_utility_path "head")"
    "$binary_path" -c 5 "$binary_file" > "$output_file" 2>&1
    local exit_code=$?
    
    assert_equals "0" "$exit_code" "head should succeed with binary file"
    
    # Check output size using wc -c instead of string length
    local output_size
    output_size=$(wc -c < "$output_file" | tr -d ' ')
    assert_equals "5" "$output_size" "head -c 5 should output exactly 5 bytes from binary file"
    
    cleanup_head_files "$binary_file" "$output_file"
}

# =============================================================================
# Error Condition Tests
# =============================================================================

test_head_nonexistent_file() {
    setup_head_test
    
    exec_utility head --timeout="$HEAD_TIMEOUT" --expect-failure "nonexistent.txt"
    
    assert_failure "head should fail with nonexistent file"
    assert_contains "$EXEC_OUTPUT" "nonexistent.txt" "error message should mention the filename"
}

test_head_invalid_line_count() {
    setup_head_test
    
    local test_file="invalid_test.txt"
    create_test_file_with_lines "$test_file" 5
    
    # Test negative line count
    exec_utility head --timeout="$HEAD_TIMEOUT" --expect-failure -n -5 "$test_file"
    
    assert_failure "head should fail with negative line count"
    assert_contains "$EXEC_OUTPUT" "invalid" "error message should mention invalid argument"
    
    cleanup_head_files "$test_file"
}

test_head_invalid_argument() {
    setup_head_test
    
    exec_utility head --timeout="$HEAD_TIMEOUT" --expect-failure --unknown-flag
    
    assert_failure "head should fail with unknown flag"
    assert_contains "$EXEC_OUTPUT" "invalid" "error message should mention invalid argument"
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_head_help_flag() {
    setup_head_test
    
    exec_utility head --timeout="$HEAD_TIMEOUT" --help
    
    assert_success "head should succeed with --help flag"
    assert_contains "$EXEC_OUTPUT" "head" "help should contain utility name"
    assert_contains "$EXEC_OUTPUT" "lines" "help should mention lines option"
}

test_head_version_flag() {
    setup_head_test
    
    exec_utility head --timeout="$HEAD_TIMEOUT" --version
    
    assert_success "head should succeed with --version flag"
    assert_contains "$EXEC_OUTPUT" "head" "version should contain utility name"
}

# =============================================================================
# Large File Performance Tests
# =============================================================================

test_head_large_file() {
    setup_head_test
    
    local large_file="large.txt"
    # Create a large file (1000 lines)
    create_test_file_with_lines "$large_file" 1000 "large"
    
    exec_utility head --timeout="$LARGE_FILE_TIMEOUT" -n 5 "$large_file"
    
    assert_success "head should succeed with large file"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "5" "$line_count" "head should output exactly 5 lines from large file"
    
    assert_contains "$EXEC_OUTPUT" "large 1" "output should contain first line"
    assert_contains "$EXEC_OUTPUT" "large 5" "output should contain fifth line"
    
    cleanup_head_files "$large_file"
}

# =============================================================================
# Long Flag Tests  
# =============================================================================

test_head_long_flags() {
    setup_head_test
    
    local test_file="long_flags.txt"
    create_test_file_with_lines "$test_file" 10
    
    # Test long form of -n flag
    exec_utility head --timeout="$HEAD_TIMEOUT" --lines=3 "$test_file"
    
    assert_success "head should succeed with --lines flag"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "3" "$line_count" "head --lines=3 should output exactly 3 lines"
    
    cleanup_head_files "$test_file"
}

test_head_bytes_long_flag() {
    setup_head_test
    
    local test_file="bytes_long.txt"
    printf "0123456789abcdef" > "$test_file"
    
    # Test long form of -c flag
    exec_utility head --timeout="$HEAD_TIMEOUT" --bytes=8 "$test_file"
    
    assert_success "head should succeed with --bytes flag"
    assert_output_equals "01234567" "head --bytes=8 should output exactly 8 bytes"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# POSIX Compliance Tests
# =============================================================================

test_head_posix_compliance() {
    setup_head_test
    
    local test_file="posix_test.txt"
    create_test_file_with_lines "$test_file" 20
    
    # Test POSIX-required default behavior
    exec_utility head --timeout="$HEAD_TIMEOUT" "$test_file"
    
    assert_success "head should comply with POSIX default behavior"
    
    local line_count
    line_count=$(echo "$EXEC_OUTPUT" | wc -l | tr -d ' ')
    assert_equals "10" "$line_count" "POSIX compliance: head should default to 10 lines"
    
    cleanup_head_files "$test_file"
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    # Initialize the testing framework
    init_framework
    
    if ! has_utility "head"; then
        print_error "head utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "head Integration Tests"
    
    # Define all test specifications
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_head_basic_functionality" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Custom Line Count" "test_head_custom_line_count" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Zero Lines" "test_head_zero_lines" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Large Line Count" "test_head_large_line_count" "$HEAD_TIMEOUT")")
    
    # Multiple Files Tests
    test_specs+=("$(make_test_spec "Multiple Files" "test_head_multiple_files" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Quiet Flag" "test_head_quiet_flag" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Verbose Flag" "test_head_verbose_flag" "$HEAD_TIMEOUT")")
    
    # Stdin and Dash Tests
    test_specs+=("$(make_test_spec "Stdin Input" "test_head_stdin_input" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Dash Argument" "test_head_dash_argument" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Files and Stdin" "test_head_mixed_files_and_stdin" "$HEAD_TIMEOUT")")
    
    # Byte Count Tests
    test_specs+=("$(make_test_spec "Byte Count" "test_head_byte_count" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Byte Count with Newlines" "test_head_byte_count_with_newlines" "$HEAD_TIMEOUT")")
    
    # Empty and Edge Case Tests
    test_specs+=("$(make_test_spec "Empty File" "test_head_empty_file" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Single Line File" "test_head_single_line_file" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Binary File" "test_head_binary_file" "$HEAD_TIMEOUT")")
    
    # Error Condition Tests
    test_specs+=("$(make_test_spec "Nonexistent File" "test_head_nonexistent_file" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Line Count" "test_head_invalid_line_count" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Argument" "test_head_invalid_argument" "$HEAD_TIMEOUT")")
    
    # Help and Version Tests
    test_specs+=("$(make_test_spec "Help Flag" "test_head_help_flag" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Flag" "test_head_version_flag" "$HEAD_TIMEOUT")")
    
    # Large File Performance Tests
    test_specs+=("$(make_test_spec "Large File" "test_head_large_file" "$LARGE_FILE_TIMEOUT")")
    
    # Long Flag Tests
    test_specs+=("$(make_test_spec "Long Flags" "test_head_long_flags" "$HEAD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Bytes Long Flag" "test_head_bytes_long_flag" "$HEAD_TIMEOUT")")
    
    # POSIX Compliance Tests
    test_specs+=("$(make_test_spec "POSIX Compliance" "test_head_posix_compliance" "$HEAD_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$HEAD_TIMEOUT"
    set_test_file "${BASH_SOURCE[0]}"
    
    # Run all tests
    run_test_suite "${test_specs[@]}"
    local suite_result=$?
    
    end_suite
    print_final_summary
    local final_result=$?
    
    return $(( suite_result != 0 ? suite_result : final_result ))
}

# Execute main if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi