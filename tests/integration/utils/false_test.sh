#!/usr/bin/env bash
# Comprehensive integration tests for false utility
# Tests invariant behavior: always exit code 1, never any output, ignores all arguments

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
FALSE_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_false_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# =============================================================================
# Basic Behavior Tests
# =============================================================================

test_false_basic_invariant_behavior() {
    setup_false_test
    
    # Test basic false behavior - always exits with code 1
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure
    
    assert_failure "false should always fail with exit code 1"
    assert_output_equals "" "false should never produce any output"
}

test_false_no_arguments() {
    setup_false_test
    
    # Test false with no arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure
    
    assert_failure "false should fail with no arguments"
    assert_exit_code 1 "false should exit with code 1"
    assert_output_equals "" "false should produce no output with no arguments"
}

test_false_empty_output_verification() {
    setup_false_test
    
    # Test that false truly produces no output at all
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure
    
    assert_failure "false should fail"
    assert_output_empty "stdout should be completely empty"
    assert_equals "${EXEC_OUTPUT:-}" "" "output should be empty string"
    
    # Verify character count is zero
    local char_count="${#EXEC_OUTPUT}"
    assert_equals 0 "$char_count" "output should have zero characters"
}

# =============================================================================
# Argument Handling Tests
# =============================================================================

test_false_ignores_single_argument() {
    setup_false_test
    
    # Test false ignores single argument
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "argument"
    
    assert_failure "false should fail regardless of arguments"
    assert_output_equals "" "false should produce no output with arguments"
}

test_false_ignores_multiple_arguments() {
    setup_false_test
    
    # Test false ignores multiple arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "arg1" "arg2" "arg3"
    
    assert_failure "false should fail with multiple arguments"
    assert_output_equals "" "false should produce no output with multiple arguments"
}

test_false_ignores_numeric_arguments() {
    setup_false_test
    
    # Test false ignores numeric arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "123" "456" "789"
    
    assert_failure "false should fail with numeric arguments"
    assert_output_equals "" "false should produce no output with numeric arguments"
}

test_false_ignores_mixed_arguments() {
    setup_false_test
    
    # Test false ignores mixed argument types
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "text" "123" "special@chars" "path/to/file"
    
    assert_failure "false should fail with mixed arguments"
    assert_output_equals "" "false should produce no output with mixed arguments"
}

# =============================================================================
# Flag Handling Tests
# =============================================================================

test_false_ignores_help_flag() {
    setup_false_test
    
    # Test false ignores --help flag (unlike most utilities)
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure --help
    
    assert_failure "false should fail even with --help"
    assert_output_equals "" "false should produce no help output"
}

test_false_ignores_version_flag() {
    setup_false_test
    
    # Test false ignores --version flag
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure --version
    
    assert_failure "false should fail even with --version"
    assert_output_equals "" "false should produce no version output"
}

test_false_ignores_short_help() {
    setup_false_test
    
    # Test false ignores -h flag
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure -h
    
    assert_failure "false should fail even with -h"
    assert_output_equals "" "false should produce no output with -h"
}

test_false_ignores_short_version() {
    setup_false_test
    
    # Test false ignores -V flag
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure -V
    
    assert_failure "false should fail even with -V"
    assert_output_equals "" "false should produce no output with -V"
}

test_false_ignores_combined_flags() {
    setup_false_test
    
    # Test false ignores combined flags
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure -hV --help --version
    
    assert_failure "false should fail with combined flags"
    assert_output_equals "" "false should produce no output with combined flags"
}

test_false_ignores_invalid_flags() {
    setup_false_test
    
    # Test false ignores even invalid flags (doesn't validate)
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure --invalid-flag -z --nonexistent
    
    assert_failure "false should fail with invalid flags"
    assert_output_equals "" "false should produce no output even with invalid flags"
}

test_false_ignores_double_dash() {
    setup_false_test
    
    # Test false ignores -- end-of-options marker
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure -- --help --version "args"
    
    assert_failure "false should fail even with -- separator"
    assert_output_equals "" "false should produce no output with -- separator"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_false_with_empty_string_argument() {
    setup_false_test
    
    # Test false with empty string argument
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure ""
    
    assert_failure "false should fail with empty string argument"
    assert_output_equals "" "false should produce no output with empty string argument"
}

test_false_with_whitespace_arguments() {
    setup_false_test
    
    # Test false with whitespace-only arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "   " $'\t' $'\n' "  \t\n  "
    
    assert_failure "false should fail with whitespace arguments"
    assert_output_equals "" "false should produce no output with whitespace arguments"
}

test_false_with_special_characters() {
    setup_false_test
    
    # Test false with special characters and symbols
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "!@#\$%^&*()" "[];',./<>?" '`~'
    
    assert_failure "false should fail with special characters"
    assert_output_equals "" "false should produce no output with special characters"
}

test_false_with_unicode_arguments() {
    setup_false_test
    
    # Test false with unicode characters
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "café" "résumé" "𝕋𝕖𝕤𝕥" "🌟🚀💻"
    
    assert_failure "false should fail with unicode arguments"
    assert_output_equals "" "false should produce no output with unicode arguments"
}

test_false_with_binary_data() {
    setup_false_test
    
    # Test false with binary-like arguments (using hex escapes)
    local binary_arg=$'\x00\x01\x02\x7f\x80\xff'
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "$binary_arg"
    
    assert_failure "false should fail with binary data arguments"
    assert_output_equals "" "false should produce no output with binary data arguments"
}

test_false_with_very_long_arguments() {
    setup_false_test
    
    # Test false with very long arguments
    local long_arg=""
    for i in {1..1000}; do
        long_arg="${long_arg}a"
    done
    
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "$long_arg"
    
    assert_failure "false should fail with very long arguments"
    assert_output_equals "" "false should produce no output with very long arguments"
}

test_false_with_path_like_arguments() {
    setup_false_test
    
    # Test false with path-like arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "/usr/bin/false" "./false" "../false" "~/false"
    
    assert_failure "false should fail with path-like arguments"
    assert_output_equals "" "false should produce no output with path-like arguments"
}

test_false_with_quoted_arguments() {
    setup_false_test
    
    # Test false with various quoted arguments
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure '"quoted"' "'single'" '`backtick`'
    
    assert_failure "false should fail with quoted arguments"
    assert_output_equals "" "false should produce no output with quoted arguments"
}

# =============================================================================
# Output Verification Tests
# =============================================================================

test_false_stdout_completely_empty() {
    setup_false_test
    
    # Verify stdout is completely empty using temp file
    local temp_file="${TEST_TEMP_DIR}/false_stdout_test.out"
    local binary_path="$(get_utility_path "false")"
    
    # Redirect only stdout to temp file
    "$binary_path" > "$temp_file" 2>/dev/null || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "output file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "stdout should be completely empty (0 bytes)"
}

test_false_stderr_completely_empty() {
    setup_false_test
    
    # Verify stderr is completely empty using temp file
    local temp_file="${TEST_TEMP_DIR}/false_stderr_test.out"
    local binary_path="$(get_utility_path "false")"
    
    # Redirect only stderr to temp file
    "$binary_path" 2> "$temp_file" >/dev/null || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "error file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "stderr should be completely empty (0 bytes)"
}

test_false_combined_output_empty() {
    setup_false_test
    
    # Verify both stdout and stderr are empty
    local temp_file="${TEST_TEMP_DIR}/false_combined_test.out"
    local binary_path="$(get_utility_path "false")"
    
    # Redirect both stdout and stderr to temp file
    "$binary_path" "arg1" "arg2" --help --version > "$temp_file" 2>&1 || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "combined output file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "combined output should be completely empty (0 bytes)"
}

test_false_no_newlines_produced() {
    setup_false_test
    
    # Verify false doesn't even produce newlines
    local temp_file="${TEST_TEMP_DIR}/false_newline_test.out"
    local binary_path="$(get_utility_path "false")"
    
    "$binary_path" > "$temp_file" 2>&1 || true
    
    # Check for any newline characters
    local newline_count
    newline_count=$(tr -cd '\n' < "$temp_file" | wc -c | tr -d ' ')
    assert_equals "0" "$newline_count" "should produce no newline characters"
}

# =============================================================================
# Performance Tests
# =============================================================================

test_false_rapid_execution() {
    setup_false_test
    
    # Test rapid successive executions
    for i in {1..20}; do
        exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "test$i"
        assert_failure "rapid execution $i should fail"
        assert_output_equals "" "rapid execution $i should produce no output"
    done
}

test_false_with_many_arguments() {
    setup_false_test
    
    # Test false with many arguments (should still be fast)
    local args=()
    for i in {1..100}; do
        args+=("arg$i")
    done
    
    exec_utility false --timeout="$PERFORMANCE_TIMEOUT" --expect-failure "${args[@]}"
    
    assert_failure "false should fail with many arguments"
    assert_output_equals "" "false should produce no output with many arguments"
}

test_false_deterministic_behavior() {
    setup_false_test
    
    # Test that false behavior is completely deterministic
    local results=()
    local outputs=()
    
    for i in {1..5}; do
        exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure "test$i"
        results+=("$EXEC_EXIT_CODE")
        outputs+=("$EXEC_OUTPUT")
    done
    
    # All results should be identical (exit code 1, empty output)
    for i in "${!results[@]}"; do
        assert_equals "1" "${results[$i]}" "execution $((i+1)) should have exit code 1"
        assert_equals "" "${outputs[$i]}" "execution $((i+1)) should have empty output"
    done
}

test_false_execution_speed() {
    setup_false_test
    
    # Test that false executes very quickly
    local start_time end_time duration
    start_time=$(date +%s%N)
    
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure
    
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
    
    assert_failure "false should fail quickly"
    assert_output_equals "" "false should produce no output quickly"
    
    # false should execute in under 100ms (very generous threshold)
    if [[ $duration -lt 100 ]]; then
        true # Execution was fast enough
    else
        fail "false should execute very quickly (took ${duration}ms)"
    fi
}

# =============================================================================
# Consistency Tests
# =============================================================================

test_false_consistent_across_invocations() {
    setup_false_test
    
    # Test that false is perfectly consistent across different argument patterns
    local test_patterns=(
        ""
        "--help"
        "--version"
        "-h -V"
        "normal arguments"
        "--flag=value"
        "/path/to/file"
        "arg1 arg2 arg3"
    )
    
    for pattern in "${test_patterns[@]}"; do
        if [[ -z "$pattern" ]]; then
            exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure
        else
            # Use eval to properly handle the argument patterns
            eval "exec_utility false --timeout=\"$FALSE_TIMEOUT\" --expect-failure $pattern"
        fi
        
        assert_failure "false should fail consistently with pattern: '$pattern'"
        assert_output_equals "" "false should produce no output with pattern: '$pattern'"
        assert_exit_code 1 "false should have exit code 1 with pattern: '$pattern'"
    done
}

test_false_ignores_environment_variables() {
    setup_false_test
    
    # Test that false ignores environment variables
    # Set various environment variables that might affect other utilities
    export NO_COLOR=1
    export HELP=1
    export VERSION=1
    export VERBOSE=1
    export DEBUG=1
    export QUIET=1
    
    exec_utility false --timeout="$FALSE_TIMEOUT" --expect-failure --help --version
    
    # Unset environment variables
    unset NO_COLOR HELP VERSION VERBOSE DEBUG QUIET
    
    assert_failure "false should ignore environment variables and still exit with 1"
    assert_output_equals "" "false should produce no output regardless of environment"
}

# =============================================================================
# Edge Case Stress Tests
# =============================================================================

test_false_with_extremely_long_single_argument() {
    setup_false_test
    
    # Test false with extremely long single argument (10KB)
    local huge_arg=""
    for i in {1..10000}; do
        huge_arg="${huge_arg}x"
    done
    
    exec_utility false --timeout="$PERFORMANCE_TIMEOUT" --expect-failure "$huge_arg"
    
    assert_failure "false should fail with extremely long argument"
    assert_output_equals "" "false should produce no output with extremely long argument"
}

test_false_with_mixed_argument_types_stress() {
    setup_false_test
    
    # Test false with a mix of all previously tested argument types
    local binary_data=$'\x00\x01\x02\xff'
    local unicode_text="café🌟"
    local long_text=""
    for i in {1..100}; do
        long_text="${long_text}test"
    done
    
    exec_utility false --timeout="$PERFORMANCE_TIMEOUT" --expect-failure \
        --help --version -h -V \
        "$binary_data" "$unicode_text" "$long_text" \
        "" "   " $'\t' $'\n' \
        "normal" "123" "special@#$" \
        "/path/to/file" "./relative" "../parent" \
        '"quoted"' "'single'" '`backtick`'
    
    assert_failure "false should fail with mixed argument stress test"
    assert_output_equals "" "false should produce no output with mixed argument stress test"
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    # Initialize the testing framework first
    init_framework
    
    if ! has_utility "false"; then
        print_error "false utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    # Define all test specifications
    local -a test_specs=()
    
    # Basic Behavior Tests
    test_specs+=("$(make_test_spec "Basic Invariant Behavior" "test_false_basic_invariant_behavior" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Arguments" "test_false_no_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty Output Verification" "test_false_empty_output_verification" "$FALSE_TIMEOUT")")
    
    # Argument Handling Tests
    test_specs+=("$(make_test_spec "Ignores Single Argument" "test_false_ignores_single_argument" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Multiple Arguments" "test_false_ignores_multiple_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Numeric Arguments" "test_false_ignores_numeric_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Mixed Arguments" "test_false_ignores_mixed_arguments" "$FALSE_TIMEOUT")")
    
    # Flag Handling Tests
    test_specs+=("$(make_test_spec "Ignores Help Flag" "test_false_ignores_help_flag" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Version Flag" "test_false_ignores_version_flag" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Short Help" "test_false_ignores_short_help" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Short Version" "test_false_ignores_short_version" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Combined Flags" "test_false_ignores_combined_flags" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Invalid Flags" "test_false_ignores_invalid_flags" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Double Dash" "test_false_ignores_double_dash" "$FALSE_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Empty String Argument" "test_false_with_empty_string_argument" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Whitespace Arguments" "test_false_with_whitespace_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Characters" "test_false_with_special_characters" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unicode Arguments" "test_false_with_unicode_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Binary Data" "test_false_with_binary_data" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Arguments" "test_false_with_very_long_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Path-like Arguments" "test_false_with_path_like_arguments" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Quoted Arguments" "test_false_with_quoted_arguments" "$FALSE_TIMEOUT")")
    
    # Output Verification Tests
    test_specs+=("$(make_test_spec "Stdout Completely Empty" "test_false_stdout_completely_empty" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stderr Completely Empty" "test_false_stderr_completely_empty" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Output Empty" "test_false_combined_output_empty" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Newlines Produced" "test_false_no_newlines_produced" "$FALSE_TIMEOUT")")
    
    # Performance Tests
    test_specs+=("$(make_test_spec "Rapid Execution" "test_false_rapid_execution" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Many Arguments" "test_false_with_many_arguments" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Deterministic Behavior" "test_false_deterministic_behavior" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Execution Speed" "test_false_execution_speed" "$FALSE_TIMEOUT")")
    
    # Consistency Tests
    test_specs+=("$(make_test_spec "Consistent Across Invocations" "test_false_consistent_across_invocations" "$FALSE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Environment Variables" "test_false_ignores_environment_variables" "$FALSE_TIMEOUT")")
    
    # Edge Case Stress Tests
    test_specs+=("$(make_test_spec "Extremely Long Single Argument" "test_false_with_extremely_long_single_argument" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Argument Types Stress" "test_false_with_mixed_argument_types_stress" "$PERFORMANCE_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$FALSE_TIMEOUT"
    
    # Set the test file for the runner
    set_test_file "${BASH_SOURCE[0]}"
    
    # Run all tests
    run_test_suite "${test_specs[@]}"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi