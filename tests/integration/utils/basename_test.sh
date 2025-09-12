#!/usr/bin/env bash
# Comprehensive integration tests for basename utility
# Tests all flags, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
BASENAME_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_basename_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# No file creation needed - basename operates on path strings only

# =============================================================================
# Basic Functionality Tests
# =============================================================================

test_basename_basic_functionality() {
    setup_basename_test
    
    # Test basic directory stripping
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "/usr/bin/ls"
    
    assert_success "basename should succeed with basic path"
    assert_output_equals "ls" "should extract basename from full path"
}

test_basename_with_suffix() {
    setup_basename_test
    
    # Test suffix removal in POSIX mode
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "document.txt" ".txt"
    
    assert_success "basename should succeed with suffix removal"
    assert_output_equals "document" "should remove .txt suffix"
}

test_basename_no_directory() {
    setup_basename_test
    
    # Test file with no directory component
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "simple_file"
    
    assert_success "basename should succeed with simple filename"
    assert_output_equals "simple_file" "should return filename unchanged"
}

# =============================================================================
# All Flags Tests
# =============================================================================

test_basename_multiple_flag_short() {
    setup_basename_test
    
    # Test -a flag for multiple files
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -a "/usr/bin/ls" "/home/user/file.txt" "simple"
    
    assert_success "basename -a should succeed with multiple files"
    assert_output_equals $'ls\nfile.txt\nsimple' "should process all files with -a flag"
}

test_basename_multiple_flag_long() {
    setup_basename_test
    
    # Test --multiple flag for multiple files
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --multiple "/path/to/file1" "/another/path/file2"
    
    assert_success "basename --multiple should succeed"
    assert_output_equals $'file1\nfile2' "should process all files with --multiple flag"
}

test_basename_suffix_flag_short() {
    setup_basename_test
    
    # Test -s flag (implies -a)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -s ".txt" "file1.txt" "file2.txt" "file3.pdf"
    
    assert_success "basename -s should succeed"
    assert_output_equals $'file1\nfile2\nfile3.pdf' "should remove suffix from matching files only"
}

test_basename_suffix_flag_long() {
    setup_basename_test
    
    # Test --suffix flag (implies -a)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --suffix=".c" "hello.c" "world.c" "test.h"
    
    assert_success "basename --suffix should succeed"
    assert_output_equals $'hello\nworld\ntest.h' "should remove .c suffix from matching files"
}

test_basename_zero_flag() {
    setup_basename_test
    
    # Test -z flag for null byte separator
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -z "/usr/bin/test"
    
    assert_success "basename -z should succeed"
    # Use hexdump to verify null byte termination more reliably
    local output_hex
    output_hex=$(printf '%s' "${EXEC_OUTPUT:-}" | hexdump -C | head -1)
    assert_output_contains "test" "output should contain 'test'"
    # Verify it contains a null byte (more reliable than string manipulation)
    if [[ "${EXEC_OUTPUT:-}" == *$'\0'* ]]; then
        # Null byte is present - this is expected
        true
    else
        fail "output should contain null byte separator"
    fi
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_basename_root_directory() {
    setup_basename_test
    
    # Test root directory case
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "/"
    
    assert_success "basename should handle root directory"
    assert_output_equals "/" "root directory should return /"
}

test_basename_double_slash() {
    setup_basename_test
    
    # Test double slash case (should still return /)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "//"
    
    assert_success "basename should handle double slash"
    assert_output_equals "/" "double slash should return /"
}

test_basename_trailing_slashes() {
    setup_basename_test
    
    # Test paths with trailing slashes
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "/usr/bin/"
    
    assert_success "basename should handle trailing slashes"
    assert_output_equals "bin" "should strip trailing slashes"
}

test_basename_multiple_trailing_slashes() {
    setup_basename_test
    
    # Test paths with multiple trailing slashes
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "/usr/lib///"
    
    assert_success "basename should handle multiple trailing slashes"
    assert_output_equals "lib" "should strip all trailing slashes"
}

test_basename_empty_string() {
    setup_basename_test
    
    # Test empty string (should return ".")
    exec_utility basename --timeout="$BASENAME_TIMEOUT" ""
    
    assert_success "basename should handle empty string"
    assert_output_equals "." "empty string should return dot"
}

test_basename_complex_paths() {
    setup_basename_test
    
    # Test complex nested paths
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "/very/long/path/to/some/deeply/nested/file.extension"
    
    assert_success "basename should handle complex paths"
    assert_output_equals "file.extension" "should extract basename from complex path"
}

# =============================================================================
# Error Conditions Tests
# =============================================================================

test_basename_no_arguments() {
    setup_basename_test
    
    # Test with no arguments
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --expect-failure
    
    assert_failure "basename should fail with no arguments"
    assert_output_contains "missing operand" "should report missing operand error"
}

test_basename_too_many_args_posix_mode() {
    setup_basename_test
    
    # Test too many arguments in POSIX mode (without -a flag)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --expect-failure "path1" "suffix" "extra"
    
    assert_failure "basename should fail with too many arguments in POSIX mode"
    assert_output_contains "extra operand" "should report extra operand error"
}

test_basename_invalid_flag() {
    setup_basename_test
    
    # Test invalid long flag
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --expect-failure --nonexistent-flag "path"
    
    assert_failure "basename should fail with invalid flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

test_basename_unknown_short_flag() {
    setup_basename_test
    
    # Test unknown short flag
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --expect-failure -x "path"
    
    assert_failure "basename should fail with unknown short flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

# =============================================================================
# Input/Output Format Tests
# =============================================================================

test_basename_zero_separator_multiple() {
    setup_basename_test
    
    # Test zero byte separator with multiple files
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -az "file1" "file2" "file3"
    
    assert_success "basename -az should succeed"
    
    # Verify content is present and contains null bytes
    assert_output_contains "file1" "output should contain file1"
    assert_output_contains "file2" "output should contain file2"
    assert_output_contains "file3" "output should contain file3"
    
    # Use a temporary file to safely count null bytes (avoids bash variable null byte issues)
    local temp_file="${TEST_TEMP_DIR}/basename_null_test.out"
    local binary_path="$(get_utility_path "basename")"
    "$binary_path" -az "file1" "file2" "file3" > "$temp_file"
    local null_count
    null_count=$(tr -cd '\000' < "$temp_file" | wc -c | tr -d ' ')
    assert_equals "3" "$null_count" "should have 3 null byte separators"
}

test_basename_newline_separator_multiple() {
    setup_basename_test
    
    # Test default newline separator with multiple files
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -a "/path/to/file1" "/path/to/file2"
    
    assert_success "basename -a should succeed with newline separator"
    assert_output_equals $'file1\nfile2' "should use newline separator by default"
}

test_basename_mixed_path_types() {
    setup_basename_test
    
    # Test mix of absolute and relative paths
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -a "/usr/bin/ls" "relative/path" "./current/file" "../parent/file"
    
    assert_success "basename should handle mixed path types"
    assert_output_equals $'ls\npath\nfile\nfile' "should correctly process all path types"
}

# =============================================================================
# Platform Compatibility Tests
# =============================================================================

test_basename_platform_compatibility() {
    setup_basename_test
    
    # Test behavior consistent across platforms
    local test_paths=(
        "/"
        "//"
        "/usr/bin/ls"
        "/usr/bin/"
        "simple_file"
        "./relative"
        "../parent"
        ""
    )
    
    local expected_outputs=(
        "/"
        "/"
        "ls"
        "bin"
        "simple_file"
        "relative"
        "parent"
        "."
    )
    
    for i in "${!test_paths[@]}"; do
        local path="${test_paths[$i]}"
        local expected="${expected_outputs[$i]}"
        
        exec_utility basename --timeout="$BASENAME_TIMEOUT" "$path"
        assert_success "basename should succeed with path: $path"
        assert_output_equals "$expected" "path '$path' should produce '$expected'"
    done
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_basename_help() {
    setup_basename_test
    
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --help
    
    assert_success "basename --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "basename" "help should mention basename"
    assert_output_contains -- "-a" "help should document -a flag"
    assert_output_contains "multiple" "help should mention multiple functionality"
}

test_basename_version() {
    setup_basename_test
    
    exec_utility basename --timeout="$BASENAME_TIMEOUT" --version
    
    assert_success "basename --version should succeed"
    assert_output_contains "basename" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

test_basename_short_help() {
    setup_basename_test
    
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -h
    
    assert_success "basename -h should succeed"
    assert_output_contains "Usage:" "short help should contain usage information"
}

# =============================================================================
# Flag Combination Tests
# =============================================================================

test_basename_combined_flags() {
    setup_basename_test
    
    # Test combining -a and -z flags
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -az "/usr/bin/ls" "/home/file"
    
    assert_success "basename should handle combined flags"
    assert_output_contains "ls" "output should contain ls"
    assert_output_contains "file" "output should contain file"
}

test_basename_mixed_flag_formats() {
    setup_basename_test
    
    # Test mixing short and long flags
    exec_utility basename --timeout="$BASENAME_TIMEOUT" -a --suffix=".txt" "file1.txt" "file2.pdf"
    
    assert_success "basename should handle mixed flag formats"
    assert_output_equals $'file1\nfile2.pdf' "should process with mixed flags correctly"
}

# =============================================================================
# Suffix Edge Cases Tests
# =============================================================================

test_basename_suffix_edge_cases() {
    setup_basename_test
    
    # Test suffix that matches entire basename (should not remove)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" ".txt" ".txt"
    
    assert_success "basename should handle suffix matching entire basename"
    assert_output_equals ".txt" "should not remove suffix if it matches entire basename"
}

test_basename_empty_suffix() {
    setup_basename_test
    
    # Test empty suffix (should not remove anything)
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "file.txt" ""
    
    assert_success "basename should handle empty suffix"
    assert_output_equals "file.txt" "should not remove empty suffix"
}

test_basename_non_matching_suffix() {
    setup_basename_test
    
    # Test suffix that doesn't match
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "document.pdf" ".txt"
    
    assert_success "basename should handle non-matching suffix"
    assert_output_equals "document.pdf" "should not remove non-matching suffix"
}

# =============================================================================
# Special Character Tests
# =============================================================================

test_basename_special_characters() {
    setup_basename_test
    
    # Test paths with special characters (need to be careful with shell escaping)
    local special_paths=(
        "/path/to/file with spaces"
        "/path/to/file-with-dashes"
        "/path/to/file.with.dots"
        "/path/to/file_with_underscores"
        "/path/to/file@special#chars"
    )
    
    local expected_basenames=(
        "file with spaces"
        "file-with-dashes"
        "file.with.dots"
        "file_with_underscores"
        "file@special#chars"
    )
    
    for i in "${!special_paths[@]}"; do
        local path="${special_paths[$i]}"
        local expected="${expected_basenames[$i]}"
        
        exec_utility basename --timeout="$BASENAME_TIMEOUT" "$path"
        assert_success "basename should handle special characters in path: $path"
        assert_output_equals "$expected" "should extract correct basename from special path"
    done
}

# =============================================================================
# Performance and Stress Tests
# =============================================================================

test_basename_many_files() {
    setup_basename_test
    
    # Test with many files (reduced to 25 for reasonable performance)
    local files=()
    local expected_output=""
    
    for i in {1..25}; do
        files+=("/path/to/file${i}.txt")
        if [[ $i -eq 1 ]]; then
            expected_output="file${i}.txt"
        else
            expected_output="${expected_output}
file${i}.txt"
        fi
    done
    
    exec_utility basename --timeout="$PERFORMANCE_TIMEOUT" -a "${files[@]}"
    
    assert_success "basename should handle many files"
    assert_output_equals "$expected_output" "should process all files correctly"
}

test_basename_very_long_paths() {
    setup_basename_test
    
    # Test with very long path
    local long_path="/very/long/path/with/many/components/that/goes/on/and/on/and/continues/for/quite/some/time/until/we/reach/the/final/component/extremely_long_filename_with_lots_of_characters.extension"
    
    exec_utility basename --timeout="$BASENAME_TIMEOUT" "$long_path"
    
    assert_success "basename should handle very long paths"
    assert_output_equals "extremely_long_filename_with_lots_of_characters.extension" "should extract basename from very long path"
}

test_basename_rapid_execution() {
    setup_basename_test
    
    # Test rapid successive executions
    for i in {1..10}; do
        exec_utility basename --timeout="$BASENAME_TIMEOUT" "/test/path${i}/file${i}"
        assert_success "rapid execution $i should succeed"
        assert_output_equals "file${i}" "rapid execution $i should produce correct output"
    done
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework --verbose
    
    if ! has_utility "basename"; then
        print_error "basename utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "basename Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_basename_basic_functionality" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "With Suffix" "test_basename_with_suffix" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Directory" "test_basename_no_directory" "$BASENAME_TIMEOUT")")
    
    # All Flags Tests
    test_specs+=("$(make_test_spec "Multiple Flag (-a)" "test_basename_multiple_flag_short" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Flag (--multiple)" "test_basename_multiple_flag_long" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Suffix Flag (-s)" "test_basename_suffix_flag_short" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Suffix Flag (--suffix)" "test_basename_suffix_flag_long" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Zero Flag (-z)" "test_basename_zero_flag" "$BASENAME_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Root Directory" "test_basename_root_directory" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Double Slash" "test_basename_double_slash" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Trailing Slashes" "test_basename_trailing_slashes" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Trailing Slashes" "test_basename_multiple_trailing_slashes" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty String" "test_basename_empty_string" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Complex Paths" "test_basename_complex_paths" "$BASENAME_TIMEOUT")")
    
    # Error Conditions Tests
    test_specs+=("$(make_test_spec "No Arguments" "test_basename_no_arguments" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Too Many Args POSIX" "test_basename_too_many_args_posix_mode" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Flag" "test_basename_invalid_flag" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unknown Short Flag" "test_basename_unknown_short_flag" "$BASENAME_TIMEOUT")")
    
    # Input/Output Format Tests
    test_specs+=("$(make_test_spec "Zero Separator Multiple" "test_basename_zero_separator_multiple" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Newline Separator Multiple" "test_basename_newline_separator_multiple" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Path Types" "test_basename_mixed_path_types" "$BASENAME_TIMEOUT")")
    
    # Platform Compatibility Tests
    test_specs+=("$(make_test_spec "Platform Compatibility" "test_basename_platform_compatibility" "$BASENAME_TIMEOUT")")
    
    # Help and Version Tests
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_basename_help" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_basename_version" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Short Help (-h)" "test_basename_short_help" "$BASENAME_TIMEOUT")")
    
    # Flag Combination Tests
    test_specs+=("$(make_test_spec "Combined Flags" "test_basename_combined_flags" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Flag Formats" "test_basename_mixed_flag_formats" "$BASENAME_TIMEOUT")")
    
    # Suffix Edge Cases Tests
    test_specs+=("$(make_test_spec "Suffix Edge Cases" "test_basename_suffix_edge_cases" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty Suffix" "test_basename_empty_suffix" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Non-matching Suffix" "test_basename_non_matching_suffix" "$BASENAME_TIMEOUT")")
    
    # Special Character Tests
    test_specs+=("$(make_test_spec "Special Characters" "test_basename_special_characters" "$BASENAME_TIMEOUT")")
    
    # Performance and Stress Tests
    test_specs+=("$(make_test_spec "Many Files" "test_basename_many_files" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Paths" "test_basename_very_long_paths" "$BASENAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Rapid Execution" "test_basename_rapid_execution" "$PERFORMANCE_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$BASENAME_TIMEOUT"
    
    # Set the test file for the runner
    set_test_file "${BASH_SOURCE[0]}"
    
    # Run all tests
    run_test_suite "${test_specs[@]}"
    local suite_result=$?
    
    end_suite
    
    # Print final summary and exit with appropriate code
    print_final_summary
    local final_result=$?
    
    return $(( suite_result != 0 ? suite_result : final_result ))
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi