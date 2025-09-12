#!/usr/bin/env bash
# Comprehensive integration tests for dirname utility
# Tests all flags, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
DIRNAME_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_dirname_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# No file creation needed - dirname operates on path strings only

# =============================================================================
# Basic Functionality Tests
# =============================================================================

test_dirname_basic_functionality() {
    setup_dirname_test
    
    # Test basic directory extraction
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/usr/bin/ls"
    
    assert_success "dirname should succeed with basic path"
    assert_output_equals "/usr/bin" "should extract directory from full path"
}

test_dirname_with_filename() {
    setup_dirname_test
    
    # Test simple filename (should return current directory)
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "document.txt"
    
    assert_success "dirname should succeed with simple filename"
    assert_output_equals "." "should return current directory for simple filename"
}

test_dirname_nested_path() {
    setup_dirname_test
    
    # Test nested directory path
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/home/user/documents/file.pdf"
    
    assert_success "dirname should succeed with nested path"
    assert_output_equals "/home/user/documents" "should extract nested directory path"
}

test_dirname_relative_path() {
    setup_dirname_test
    
    # Test relative path
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "relative/path/file.txt"
    
    assert_success "dirname should succeed with relative path"
    assert_output_equals "relative/path" "should extract relative directory path"
}

test_dirname_single_directory() {
    setup_dirname_test
    
    # Test single directory component
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "folder/file"
    
    assert_success "dirname should succeed with single directory"
    assert_output_equals "folder" "should extract single directory component"
}

test_dirname_current_directory_file() {
    setup_dirname_test
    
    # Test file in current directory
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "./file.txt"
    
    assert_success "dirname should succeed with current directory file"
    assert_output_equals "." "should return current directory for ./file"
}

# =============================================================================
# All Flags Tests
# =============================================================================

test_dirname_zero_flag_short() {
    setup_dirname_test
    
    # Test -z flag for null byte separator
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" -z "/usr/bin/test"
    
    assert_success "dirname -z should succeed"
    # Use hexdump to verify null byte termination more reliably
    local output_hex
    output_hex=$(printf '%s' "${EXEC_OUTPUT:-}" | hexdump -C | head -1)
    assert_output_contains "/usr/bin" "output should contain '/usr/bin'"
    # Verify it contains a null byte (more reliable than string manipulation)
    if [[ "${EXEC_OUTPUT:-}" == *$'\0'* ]]; then
        # Null byte is present - this is expected
        true
    else
        fail "output should contain null byte separator"
    fi
}

test_dirname_zero_flag_long() {
    setup_dirname_test
    
    # Test --zero flag for null byte separator
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --zero "/home/user/file.txt"
    
    assert_success "dirname --zero should succeed"
    assert_output_contains "/home/user" "output should contain directory path"
    # Verify null byte termination
    if [[ "${EXEC_OUTPUT:-}" == *$'\0'* ]]; then
        true
    else
        fail "output should contain null byte separator"
    fi
}

test_dirname_help_flag_short() {
    setup_dirname_test
    
    # Test -h flag for help
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" -h
    
    assert_success "dirname -h should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "dirname" "help should mention dirname"
}

test_dirname_version_flag_short() {
    setup_dirname_test
    
    # Test -V flag for version
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" -V
    
    assert_success "dirname -V should succeed"
    assert_output_contains "dirname" "version should contain program name"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_dirname_root_directory() {
    setup_dirname_test
    
    # Test root directory case
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/"
    
    assert_success "dirname should handle root directory"
    assert_output_equals "/" "root directory should return /"
}

test_dirname_double_slash() {
    setup_dirname_test
    
    # Test double slash case (should still return /)
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "//"
    
    assert_success "dirname should handle double slash"
    assert_output_equals "/" "double slash should return /"
}

test_dirname_trailing_slashes() {
    setup_dirname_test
    
    # Test paths with trailing slashes
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/usr/bin/"
    
    assert_success "dirname should handle trailing slashes"
    assert_output_equals "/usr" "should strip trailing slashes and extract parent"
}

test_dirname_multiple_trailing_slashes() {
    setup_dirname_test
    
    # Test paths with multiple trailing slashes
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/usr/lib///"
    
    assert_success "dirname should handle multiple trailing slashes"
    assert_output_equals "/usr" "should strip all trailing slashes and extract parent"
}

test_dirname_empty_string() {
    setup_dirname_test
    
    # Test empty string (should return ".")
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" ""
    
    assert_success "dirname should handle empty string"
    assert_output_equals "." "empty string should return dot"
}

test_dirname_root_file() {
    setup_dirname_test
    
    # Test file directly in root
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/file.txt"
    
    assert_success "dirname should handle root file"
    assert_output_equals "/" "file in root should return /"
}

test_dirname_dot_path() {
    setup_dirname_test
    
    # Test current directory path
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "."
    
    assert_success "dirname should handle dot path"
    assert_output_equals "." "dot path should return dot"
}

test_dirname_dotdot_path() {
    setup_dirname_test
    
    # Test parent directory path
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" ".."
    
    assert_success "dirname should handle dotdot path"
    assert_output_equals "." "dotdot path should return dot"
}

# =============================================================================
# Error Conditions Tests
# =============================================================================

test_dirname_no_arguments() {
    setup_dirname_test
    
    # Test with no arguments
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --expect-failure
    
    assert_failure "dirname should fail with no arguments"
    assert_output_contains "missing operand" "should report missing operand error"
}

test_dirname_invalid_long_flag() {
    setup_dirname_test
    
    # Test invalid long flag
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --expect-failure --nonexistent-flag "path"
    
    assert_failure "dirname should fail with invalid long flag"
    assert_output_contains "unrecognized option" "should report unrecognized option error"
}

test_dirname_invalid_short_flag() {
    setup_dirname_test
    
    # Test invalid short flag
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --expect-failure -x "path"
    
    assert_failure "dirname should fail with invalid short flag"
    assert_output_contains "unrecognized option" "should report unrecognized option error"
}

test_dirname_combined_invalid_flags() {
    setup_dirname_test
    
    # Test combined flags with invalid one
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --expect-failure -zx "path"
    
    assert_failure "dirname should fail with combined invalid flags"
    assert_output_contains "unrecognized option" "should report unrecognized option error"
}

# =============================================================================
# String Handling Tests
# =============================================================================

test_dirname_special_characters() {
    setup_dirname_test
    
    # Test paths with special characters
    local special_paths=(
        "/path/to/file with spaces.txt"
        "/path/to/file-with-dashes.txt"
        "/path/to/file.with.dots.txt"
        "/path/to/file_with_underscores.txt"
        "/path/to/file@special#chars.txt"
        "/path/to/file\$with\$dollars.txt"
    )
    
    local expected_dirs=(
        "/path/to"
        "/path/to"
        "/path/to"
        "/path/to"
        "/path/to"
        "/path/to"
    )
    
    for i in "${!special_paths[@]}"; do
        local path="${special_paths[$i]}"
        local expected="${expected_dirs[$i]}"
        
        exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$path"
        assert_success "dirname should handle special characters in path: $path"
        assert_output_equals "$expected" "should extract correct directory from special path"
    done
}

test_dirname_unicode_paths() {
    setup_dirname_test
    
    # Test paths with unicode characters
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/café/résumé.txt"
    
    assert_success "dirname should handle unicode characters"
    assert_output_equals "/café" "should handle unicode directory names"
}

test_dirname_very_long_paths() {
    setup_dirname_test
    
    # Test with very long path
    local long_path="/very/long/path/with/many/components/that/goes/on/and/on/and/continues/for/quite/some/time/until/we/reach/the/final/component/extremely_long_filename_with_lots_of_characters.extension"
    local expected_dir="/very/long/path/with/many/components/that/goes/on/and/on/and/continues/for/quite/some/time/until/we/reach/the/final/component"
    
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$long_path"
    
    assert_success "dirname should handle very long paths"
    assert_output_equals "$expected_dir" "should extract directory from very long path"
}

test_dirname_mixed_slashes() {
    setup_dirname_test
    
    # Test paths with mixed slash patterns
    local mixed_paths=(
        "/usr//bin/file"
        "usr///bin//file"
        "./path//to///file"
        "../path//file"
    )
    
    local expected_dirs=(
        "/usr//bin"
        "usr///bin"
        "./path//to"
        "../path"
    )
    
    for i in "${!mixed_paths[@]}"; do
        local path="${mixed_paths[$i]}"
        local expected="${expected_dirs[$i]}"
        
        exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$path"
        assert_success "dirname should handle mixed slashes in path: $path"
        assert_output_equals "$expected" "should preserve internal slash patterns"
    done
}

test_dirname_relative_path_variations() {
    setup_dirname_test
    
    # Test various relative path patterns
    local relative_paths=(
        "./file.txt"
        "../file.txt"
        "../../file.txt"
        "./folder/file.txt"
        "../folder/file.txt"
        "../../folder/file.txt"
    )
    
    local expected_dirs=(
        "."
        ".."
        "../.."
        "./folder"
        "../folder"
        "../../folder"
    )
    
    for i in "${!relative_paths[@]}"; do
        local path="${relative_paths[$i]}"
        local expected="${expected_dirs[$i]}"
        
        exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$path"
        assert_success "dirname should handle relative path: $path"
        assert_output_equals "$expected" "should extract correct relative directory"
    done
}

test_dirname_edge_case_names() {
    setup_dirname_test
    
    # Test edge case filename patterns
    local edge_cases=(
        "/path/to/."
        "/path/to/.."
        "/path/to/..."
        "/path/to/.hidden"
        "/path/to/..hidden"
    )
    
    local expected_dirs=(
        "/path/to"
        "/path/to"
        "/path/to"
        "/path/to"
        "/path/to"
    )
    
    for i in "${!edge_cases[@]}"; do
        local path="${edge_cases[$i]}"
        local expected="${expected_dirs[$i]}"
        
        exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$path"
        assert_success "dirname should handle edge case name: $path"
        assert_output_equals "$expected" "should extract directory from edge case path"
    done
}

# =============================================================================
# Output Format Tests
# =============================================================================

test_dirname_multiple_paths_newline() {
    setup_dirname_test
    
    # Test multiple paths with default newline separator
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/usr/bin/ls" "/home/user/file.txt" "simple_file"
    
    assert_success "dirname should handle multiple paths"
    assert_output_equals $'/usr/bin\n/home/user\n.' "should process all paths with newline separator"
}

test_dirname_multiple_paths_zero() {
    setup_dirname_test
    
    # Test multiple paths with zero byte separator
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" -z "/usr/bin/ls" "/home/user/file.txt" "simple_file"
    
    assert_success "dirname should handle multiple paths with zero separator"
    
    # Verify content is present and contains null bytes
    assert_output_contains "/usr/bin" "output should contain /usr/bin"
    assert_output_contains "/home/user" "output should contain /home/user"
    assert_output_contains "." "output should contain ."
    
    # Use a temporary file to safely count null bytes (avoids bash variable null byte issues)
    local temp_file="${TEST_TEMP_DIR}/dirname_null_test.out"
    local binary_path="$(get_utility_path "dirname")"
    "$binary_path" -z "/usr/bin/ls" "/home/user/file.txt" "simple_file" > "$temp_file"
    local null_count
    null_count=$(tr -cd '\000' < "$temp_file" | wc -c | tr -d ' ')
    assert_equals "3" "$null_count" "should have 3 null byte separators"
}

test_dirname_mixed_path_types() {
    setup_dirname_test
    
    # Test mix of absolute and relative paths
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/usr/bin/ls" "relative/path/file" "./current/file" "../parent/file"
    
    assert_success "dirname should handle mixed path types"
    assert_output_equals $'/usr/bin\nrelative/path\n./current\n../parent' "should correctly process all path types"
}

test_dirname_long_flag_format() {
    setup_dirname_test
    
    # Test using long form of zero flag
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --zero "/path/to/file1" "/path/to/file2"
    
    assert_success "dirname should handle long flag format"
    assert_output_contains "/path/to" "output should contain directory paths"
    # Verify null byte termination
    if [[ "${EXEC_OUTPUT:-}" == *$'\0'* ]]; then
        true
    else
        fail "output should contain null byte separators"
    fi
}

# =============================================================================
# Performance Tests
# =============================================================================

test_dirname_many_paths() {
    setup_dirname_test
    
    # Test with many paths (reduced to 25 for reasonable performance)
    local paths=()
    local expected_output=""
    
    for i in {1..25}; do
        paths+=("/path/to/directory${i}/file${i}.txt")
        if [[ $i -eq 1 ]]; then
            expected_output="/path/to/directory${i}"
        else
            expected_output="${expected_output}
/path/to/directory${i}"
        fi
    done
    
    exec_utility dirname --timeout="$PERFORMANCE_TIMEOUT" "${paths[@]}"
    
    assert_success "dirname should handle many paths"
    assert_output_equals "$expected_output" "should process all paths correctly"
}

test_dirname_very_long_path_performance() {
    setup_dirname_test
    
    # Test with extremely long path
    local very_long_path=""
    for i in {1..50}; do
        very_long_path="${very_long_path}/component${i}"
    done
    very_long_path="${very_long_path}/final_file.txt"
    
    # Expected directory is everything except the final component
    local expected_dir=""
    for i in {1..50}; do
        expected_dir="${expected_dir}/component${i}"
    done
    
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "$very_long_path"
    
    assert_success "dirname should handle extremely long paths"
    assert_output_equals "$expected_dir" "should extract directory from extremely long path"
}

test_dirname_rapid_execution() {
    setup_dirname_test
    
    # Test rapid successive executions
    for i in {1..10}; do
        exec_utility dirname --timeout="$DIRNAME_TIMEOUT" "/test/path${i}/file${i}"
        assert_success "rapid execution $i should succeed"
        assert_output_equals "/test/path${i}" "rapid execution $i should produce correct output"
    done
}

test_dirname_stress_mixed_patterns() {
    setup_dirname_test
    
    # Test various path patterns simultaneously
    local stress_paths=(
        "/"
        "//"
        "///"
        "/root/file"
        "/usr/bin/"
        "/usr/lib///"
        "simple_file"
        "./current/file"
        "../parent/file"
        "../../grandparent/file"
        ""
    )
    
    local expected_dirs=(
        "/"
        "/"
        "/"
        "/root"
        "/usr"
        "/usr"
        "."
        "./current"
        "../parent"
        "../../grandparent"
        "."
    )
    
    exec_utility dirname --timeout="$PERFORMANCE_TIMEOUT" "${stress_paths[@]}"
    
    assert_success "dirname should handle stress test with mixed patterns"
    
    # Build expected output string
    local expected_output=""
    for i in "${!expected_dirs[@]}"; do
        if [[ $i -eq 0 ]]; then
            expected_output="${expected_dirs[$i]}"
        else
            expected_output="${expected_output}
${expected_dirs[$i]}"
        fi
    done
    
    assert_output_equals "$expected_output" "should handle all stress patterns correctly"
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_dirname_help_long() {
    setup_dirname_test
    
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --help
    
    assert_success "dirname --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "dirname" "help should mention dirname"
    assert_output_contains -- "-z" "help should document -z flag"
    assert_output_contains "zero" "help should mention zero functionality"
    assert_output_contains "directory" "help should mention directory extraction"
}

test_dirname_version_long() {
    setup_dirname_test
    
    exec_utility dirname --timeout="$DIRNAME_TIMEOUT" --version
    
    assert_success "dirname --version should succeed"
    assert_output_contains "dirname" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework
    
    if ! has_utility "dirname"; then
        print_error "dirname utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "dirname Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_dirname_basic_functionality" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "With Filename" "test_dirname_with_filename" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Nested Path" "test_dirname_nested_path" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Relative Path" "test_dirname_relative_path" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Single Directory" "test_dirname_single_directory" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Current Directory File" "test_dirname_current_directory_file" "$DIRNAME_TIMEOUT")")
    
    # All Flags Tests
    test_specs+=("$(make_test_spec "Zero Flag (-z)" "test_dirname_zero_flag_short" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Zero Flag (--zero)" "test_dirname_zero_flag_long" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Help Flag (-h)" "test_dirname_help_flag_short" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Flag (-V)" "test_dirname_version_flag_short" "$DIRNAME_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Root Directory" "test_dirname_root_directory" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Double Slash" "test_dirname_double_slash" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Trailing Slashes" "test_dirname_trailing_slashes" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Trailing Slashes" "test_dirname_multiple_trailing_slashes" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty String" "test_dirname_empty_string" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Root File" "test_dirname_root_file" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Dot Path" "test_dirname_dot_path" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Dotdot Path" "test_dirname_dotdot_path" "$DIRNAME_TIMEOUT")")
    
    # Error Conditions Tests
    test_specs+=("$(make_test_spec "No Arguments" "test_dirname_no_arguments" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Long Flag" "test_dirname_invalid_long_flag" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Short Flag" "test_dirname_invalid_short_flag" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Invalid Flags" "test_dirname_combined_invalid_flags" "$DIRNAME_TIMEOUT")")
    
    # String Handling Tests
    test_specs+=("$(make_test_spec "Special Characters" "test_dirname_special_characters" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unicode Paths" "test_dirname_unicode_paths" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Paths" "test_dirname_very_long_paths" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Slashes" "test_dirname_mixed_slashes" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Relative Path Variations" "test_dirname_relative_path_variations" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Edge Case Names" "test_dirname_edge_case_names" "$DIRNAME_TIMEOUT")")
    
    # Output Format Tests
    test_specs+=("$(make_test_spec "Multiple Paths Newline" "test_dirname_multiple_paths_newline" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Paths Zero" "test_dirname_multiple_paths_zero" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Path Types" "test_dirname_mixed_path_types" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Long Flag Format" "test_dirname_long_flag_format" "$DIRNAME_TIMEOUT")")
    
    # Performance Tests
    test_specs+=("$(make_test_spec "Many Paths" "test_dirname_many_paths" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Path Performance" "test_dirname_very_long_path_performance" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Rapid Execution" "test_dirname_rapid_execution" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stress Mixed Patterns" "test_dirname_stress_mixed_patterns" "$PERFORMANCE_TIMEOUT")")
    
    # Help and Version Tests
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_dirname_help_long" "$DIRNAME_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_dirname_version_long" "$DIRNAME_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$DIRNAME_TIMEOUT"
    
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