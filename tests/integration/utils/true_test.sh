#!/usr/bin/env bash
# Comprehensive integration tests for true utility
# Tests invariant behavior: always exit code 0, never any output, ignores all arguments

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
TRUE_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_true_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# =============================================================================
# Basic Behavior Tests
# =============================================================================

test_true_basic_invariant_behavior() {
    setup_true_test
    
    # Test basic true behavior - always exits with code 0
    exec_utility true --timeout="$TRUE_TIMEOUT"
    
    assert_success "true should always succeed with exit code 0"
    assert_output_equals "" "true should never produce any output"
}

test_true_no_arguments() {
    setup_true_test
    
    # Test true with no arguments
    exec_utility true --timeout="$TRUE_TIMEOUT"
    
    assert_success "true should succeed with no arguments"
    assert_exit_code 0 "true should exit with code 0"
    assert_output_equals "" "true should produce no output with no arguments"
}

test_true_empty_output_verification() {
    setup_true_test
    
    # Test that true truly produces no output at all
    exec_utility true --timeout="$TRUE_TIMEOUT"
    
    assert_success "true should succeed"
    assert_output_empty "stdout should be completely empty"
    assert_equals "${EXEC_OUTPUT:-}" "" "output should be empty string"
    
    # Verify character count is zero
    local char_count="${#EXEC_OUTPUT}"
    assert_equals 0 "$char_count" "output should have zero characters"
}

# =============================================================================
# Argument Handling Tests
# =============================================================================

test_true_ignores_single_argument() {
    setup_true_test
    
    # Test true ignores single argument
    exec_utility true --timeout="$TRUE_TIMEOUT" "argument"
    
    assert_success "true should succeed regardless of arguments"
    assert_output_equals "" "true should produce no output with arguments"
}

test_true_ignores_multiple_arguments() {
    setup_true_test
    
    # Test true ignores multiple arguments
    exec_utility true --timeout="$TRUE_TIMEOUT" "arg1" "arg2" "arg3"
    
    assert_success "true should succeed with multiple arguments"
    assert_output_equals "" "true should produce no output with multiple arguments"
}

test_true_ignores_numeric_arguments() {
    setup_true_test
    
    # Test true ignores numeric arguments
    exec_utility true --timeout="$TRUE_TIMEOUT" "123" "456" "789"
    
    assert_success "true should succeed with numeric arguments"
    assert_output_equals "" "true should produce no output with numeric arguments"
}

test_true_ignores_mixed_arguments() {
    setup_true_test
    
    # Test true ignores mixed argument types
    exec_utility true --timeout="$TRUE_TIMEOUT" "text" "123" "special@chars" "path/to/file"
    
    assert_success "true should succeed with mixed arguments"
    assert_output_equals "" "true should produce no output with mixed arguments"
}

# =============================================================================
# Flag Handling Tests
# =============================================================================

test_true_ignores_help_flag() {
    setup_true_test
    
    # Test true ignores --help flag (unlike most utilities)
    exec_utility true --timeout="$TRUE_TIMEOUT" --help
    
    assert_success "true should succeed even with --help"
    assert_output_equals "" "true should produce no help output"
}

test_true_ignores_version_flag() {
    setup_true_test
    
    # Test true ignores --version flag
    exec_utility true --timeout="$TRUE_TIMEOUT" --version
    
    assert_success "true should succeed even with --version"
    assert_output_equals "" "true should produce no version output"
}

test_true_ignores_short_help() {
    setup_true_test
    
    # Test true ignores -h flag
    exec_utility true --timeout="$TRUE_TIMEOUT" -h
    
    assert_success "true should succeed even with -h"
    assert_output_equals "" "true should produce no output with -h"
}

test_true_ignores_short_version() {
    setup_true_test
    
    # Test true ignores -V flag
    exec_utility true --timeout="$TRUE_TIMEOUT" -V
    
    assert_success "true should succeed even with -V"
    assert_output_equals "" "true should produce no output with -V"
}

test_true_ignores_combined_flags() {
    setup_true_test
    
    # Test true ignores combined flags
    exec_utility true --timeout="$TRUE_TIMEOUT" -hV --help --version
    
    assert_success "true should succeed with combined flags"
    assert_output_equals "" "true should produce no output with combined flags"
}

test_true_ignores_invalid_flags() {
    setup_true_test
    
    # Test true ignores even invalid flags (doesn't validate)
    exec_utility true --timeout="$TRUE_TIMEOUT" --invalid-flag -z --nonexistent
    
    assert_success "true should succeed with invalid flags"
    assert_output_equals "" "true should produce no output even with invalid flags"
}

test_true_ignores_double_dash() {
    setup_true_test
    
    # Test true ignores -- end-of-options marker
    exec_utility true --timeout="$TRUE_TIMEOUT" -- --help --version "args"
    
    assert_success "true should succeed even with -- separator"
    assert_output_equals "" "true should produce no output with -- separator"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_true_with_empty_string_argument() {
    setup_true_test
    
    # Test true with empty string argument
    exec_utility true --timeout="$TRUE_TIMEOUT" ""
    
    assert_success "true should succeed with empty string argument"
    assert_output_equals "" "true should produce no output with empty string argument"
}

test_true_with_whitespace_arguments() {
    setup_true_test
    
    # Test true with whitespace-only arguments
    exec_utility true --timeout="$TRUE_TIMEOUT" "   " $'\t' $'\n' "  \t\n  "
    
    assert_success "true should succeed with whitespace arguments"
    assert_output_equals "" "true should produce no output with whitespace arguments"
}

test_true_with_special_characters() {
    setup_true_test
    
    # Test true with special characters and symbols
    exec_utility true --timeout="$TRUE_TIMEOUT" "!@#\$%^&*()" "[];',./<>?" '`~'
    
    assert_success "true should succeed with special characters"
    assert_output_equals "" "true should produce no output with special characters"
}

test_true_with_unicode_arguments() {
    setup_true_test
    
    # Test true with unicode characters
    exec_utility true --timeout="$TRUE_TIMEOUT" "café" "résumé" "𝕋𝕖𝕤𝕥" "🌟🚀💻"
    
    assert_success "true should succeed with unicode arguments"
    assert_output_equals "" "true should produce no output with unicode arguments"
}

test_true_with_binary_data() {
    setup_true_test
    
    # Test true with binary-like arguments (using hex escapes)
    local binary_arg=$'\x00\x01\x02\x7f\x80\xff'
    exec_utility true --timeout="$TRUE_TIMEOUT" "$binary_arg"
    
    assert_success "true should succeed with binary data arguments"
    assert_output_equals "" "true should produce no output with binary data arguments"
}

test_true_with_very_long_arguments() {
    setup_true_test
    
    # Test true with very long arguments
    local long_arg=""
    for i in {1..1000}; do
        long_arg="${long_arg}a"
    done
    
    exec_utility true --timeout="$TRUE_TIMEOUT" "$long_arg"
    
    assert_success "true should succeed with very long arguments"
    assert_output_equals "" "true should produce no output with very long arguments"
}

test_true_with_path_like_arguments() {
    setup_true_test
    
    # Test true with path-like arguments
    exec_utility true --timeout="$TRUE_TIMEOUT" "/usr/bin/true" "./true" "../true" "~/true"
    
    assert_success "true should succeed with path-like arguments"
    assert_output_equals "" "true should produce no output with path-like arguments"
}

test_true_with_quoted_arguments() {
    setup_true_test
    
    # Test true with various quoted arguments
    exec_utility true --timeout="$TRUE_TIMEOUT" '"quoted"' "'single'" '`backtick`'
    
    assert_success "true should succeed with quoted arguments"
    assert_output_equals "" "true should produce no output with quoted arguments"
}

# =============================================================================
# Output Verification Tests
# =============================================================================

test_true_stdout_completely_empty() {
    setup_true_test
    
    # Verify stdout is completely empty using temp file
    local temp_file="${TEST_TEMP_DIR}/true_stdout_test.out"
    local binary_path="$(get_utility_path "true")"
    
    # Redirect only stdout to temp file
    "$binary_path" > "$temp_file" 2>/dev/null || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "output file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "stdout should be completely empty (0 bytes)"
}

test_true_stderr_completely_empty() {
    setup_true_test
    
    # Verify stderr is completely empty using temp file
    local temp_file="${TEST_TEMP_DIR}/true_stderr_test.out"
    local binary_path="$(get_utility_path "true")"
    
    # Redirect only stderr to temp file
    "$binary_path" 2> "$temp_file" >/dev/null || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "error file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "stderr should be completely empty (0 bytes)"
}

test_true_combined_output_empty() {
    setup_true_test
    
    # Verify both stdout and stderr are empty
    local temp_file="${TEST_TEMP_DIR}/true_combined_test.out"
    local binary_path="$(get_utility_path "true")"
    
    # Redirect both stdout and stderr to temp file
    "$binary_path" "arg1" "arg2" --help --version > "$temp_file" 2>&1 || true
    
    # Verify file is empty
    assert_file_exists "$temp_file" "combined output file should be created"
    local file_size
    file_size=$(wc -c < "$temp_file" | tr -d ' ')
    assert_equals "0" "$file_size" "combined output should be completely empty (0 bytes)"
}

test_true_no_newlines_produced() {
    setup_true_test
    
    # Verify true doesn't even produce newlines
    local temp_file="${TEST_TEMP_DIR}/true_newline_test.out"
    local binary_path="$(get_utility_path "true")"
    
    "$binary_path" > "$temp_file" 2>&1 || true
    
    # Check for any newline characters
    local newline_count
    newline_count=$(tr -cd '\n' < "$temp_file" | wc -c | tr -d ' ')
    assert_equals "0" "$newline_count" "should produce no newline characters"
}

# =============================================================================
# Performance Tests
# =============================================================================

test_true_rapid_execution() {
    setup_true_test
    
    # Test rapid successive executions
    for i in {1..20}; do
        exec_utility true --timeout="$TRUE_TIMEOUT" "test$i"
        assert_success "rapid execution $i should succeed"
        assert_output_equals "" "rapid execution $i should produce no output"
    done
}

test_true_with_many_arguments() {
    setup_true_test
    
    # Test true with many arguments (should still be fast)
    local args=()
    for i in {1..100}; do
        args+=("arg$i")
    done
    
    exec_utility true --timeout="$PERFORMANCE_TIMEOUT" "${args[@]}"
    
    assert_success "true should succeed with many arguments"
    assert_output_equals "" "true should produce no output with many arguments"
}

test_true_deterministic_behavior() {
    setup_true_test
    
    # Test that true behavior is completely deterministic
    local results=()
    local outputs=()
    
    for i in {1..5}; do
        exec_utility true --timeout="$TRUE_TIMEOUT" "test$i"
        results+=("$EXEC_EXIT_CODE")
        outputs+=("$EXEC_OUTPUT")
    done
    
    # All results should be identical (exit code 0, empty output)
    for i in "${!results[@]}"; do
        assert_equals "0" "${results[$i]}" "execution $((i+1)) should have exit code 0"
        assert_equals "" "${outputs[$i]}" "execution $((i+1)) should have empty output"
    done
}

test_true_execution_speed() {
    setup_true_test
    
    # Test that true executes very quickly
    local start_time end_time duration
    start_time=$(date +%s%N)
    
    exec_utility true --timeout="$TRUE_TIMEOUT"
    
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
    
    assert_success "true should succeed quickly"
    assert_output_equals "" "true should produce no output quickly"
    
    # true should execute in under 100ms (very generous threshold)
    if [[ $duration -lt 100 ]]; then
        true # Execution was fast enough
    else
        fail "true should execute very quickly (took ${duration}ms)"
    fi
}

# =============================================================================
# Consistency Tests
# =============================================================================

test_true_consistent_across_invocations() {
    setup_true_test
    
    # Test that true is perfectly consistent across different argument patterns
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
            exec_utility true --timeout="$TRUE_TIMEOUT"
        else
            # Use eval to properly handle the argument patterns
            eval "exec_utility true --timeout=\"$TRUE_TIMEOUT\" $pattern"
        fi
        
        assert_success "true should succeed consistently with pattern: '$pattern'"
        assert_output_equals "" "true should produce no output with pattern: '$pattern'"
        assert_exit_code 0 "true should have exit code 0 with pattern: '$pattern'"
    done
}

test_true_ignores_environment_variables() {
    setup_true_test
    
    # Test that true ignores environment variables
    # Set various environment variables that might affect other utilities
    export NO_COLOR=1
    export HELP=1
    export VERSION=1
    export VERBOSE=1
    export DEBUG=1
    export QUIET=1
    
    exec_utility true --timeout="$TRUE_TIMEOUT" --help --version
    
    # Unset environment variables
    unset NO_COLOR HELP VERSION VERBOSE DEBUG QUIET
    
    assert_success "true should ignore environment variables and still exit with 0"
    assert_output_equals "" "true should produce no output regardless of environment"
}

# =============================================================================
# Edge Case Stress Tests
# =============================================================================

test_true_with_extremely_long_single_argument() {
    setup_true_test
    
    # Test true with extremely long single argument (10KB)
    local huge_arg=""
    for i in {1..10000}; do
        huge_arg="${huge_arg}x"
    done
    
    exec_utility true --timeout="$PERFORMANCE_TIMEOUT" "$huge_arg"
    
    assert_success "true should succeed with extremely long argument"
    assert_output_equals "" "true should produce no output with extremely long argument"
}

test_true_with_mixed_argument_types_stress() {
    setup_true_test
    
    # Test true with a mix of all previously tested argument types
    local binary_data=$'\x00\x01\x02\xff'
    local unicode_text="café🌟"
    local long_text=""
    for i in {1..100}; do
        long_text="${long_text}test"
    done
    
    exec_utility true --timeout="$PERFORMANCE_TIMEOUT" \
        --help --version -h -V \
        "$binary_data" "$unicode_text" "$long_text" \
        "" "   " $'\t' $'\n' \
        "normal" "123" "special@#$" \
        "/path/to/file" "./relative" "../parent" \
        '"quoted"' "'single'" '`backtick`'
    
    assert_success "true should succeed with mixed argument stress test"
    assert_output_equals "" "true should produce no output with mixed argument stress test"
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    # Initialize the testing framework first
    init_framework
    
    if ! has_utility "true"; then
        print_error "true utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    # Define all test specifications
    local -a test_specs=()
    
    # Basic Behavior Tests
    test_specs+=("$(make_test_spec "Basic Invariant Behavior" "test_true_basic_invariant_behavior" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Arguments" "test_true_no_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty Output Verification" "test_true_empty_output_verification" "$TRUE_TIMEOUT")")
    
    # Argument Handling Tests
    test_specs+=("$(make_test_spec "Ignores Single Argument" "test_true_ignores_single_argument" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Multiple Arguments" "test_true_ignores_multiple_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Numeric Arguments" "test_true_ignores_numeric_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Mixed Arguments" "test_true_ignores_mixed_arguments" "$TRUE_TIMEOUT")")
    
    # Flag Handling Tests
    test_specs+=("$(make_test_spec "Ignores Help Flag" "test_true_ignores_help_flag" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Version Flag" "test_true_ignores_version_flag" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Short Help" "test_true_ignores_short_help" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Short Version" "test_true_ignores_short_version" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Combined Flags" "test_true_ignores_combined_flags" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Invalid Flags" "test_true_ignores_invalid_flags" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Double Dash" "test_true_ignores_double_dash" "$TRUE_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Empty String Argument" "test_true_with_empty_string_argument" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Whitespace Arguments" "test_true_with_whitespace_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Characters" "test_true_with_special_characters" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unicode Arguments" "test_true_with_unicode_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Binary Data" "test_true_with_binary_data" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Arguments" "test_true_with_very_long_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Path-like Arguments" "test_true_with_path_like_arguments" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Quoted Arguments" "test_true_with_quoted_arguments" "$TRUE_TIMEOUT")")
    
    # Output Verification Tests
    test_specs+=("$(make_test_spec "Stdout Completely Empty" "test_true_stdout_completely_empty" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stderr Completely Empty" "test_true_stderr_completely_empty" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Output Empty" "test_true_combined_output_empty" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Newlines Produced" "test_true_no_newlines_produced" "$TRUE_TIMEOUT")")
    
    # Performance Tests
    test_specs+=("$(make_test_spec "Rapid Execution" "test_true_rapid_execution" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Many Arguments" "test_true_with_many_arguments" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Deterministic Behavior" "test_true_deterministic_behavior" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Execution Speed" "test_true_execution_speed" "$TRUE_TIMEOUT")")
    
    # Consistency Tests
    test_specs+=("$(make_test_spec "Consistent Across Invocations" "test_true_consistent_across_invocations" "$TRUE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignores Environment Variables" "test_true_ignores_environment_variables" "$TRUE_TIMEOUT")")
    
    # Edge Case Stress Tests
    test_specs+=("$(make_test_spec "Extremely Long Single Argument" "test_true_with_extremely_long_single_argument" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Argument Types Stress" "test_true_with_mixed_argument_types_stress" "$PERFORMANCE_TIMEOUT")")
    
    # Initialize test runner with parallel execution (original)
    init_test_runner --jobs 2 --timeout "$TRUE_TIMEOUT"
    
    # Set the test file for the runner
    set_test_file "${BASH_SOURCE[0]}"
    
    # Run all tests
    run_test_suite "${test_specs[@]}"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi