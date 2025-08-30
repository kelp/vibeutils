#!/usr/bin/env bash
# Comprehensive integration tests for echo utility
# Tests all flags, escape sequences, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
ECHO_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_echo_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

create_test_file_with_binary() {
    local filename="$1"
    local content="$2"
    printf '%s' "$content" > "$filename"
}

# =============================================================================
# Basic Functionality Tests
# =============================================================================

test_echo_basic_functionality() {
    setup_echo_test
    
    # Test basic echo with simple text
    exec_utility echo --timeout="$ECHO_TIMEOUT" "Hello, world!"
    
    assert_success "echo should succeed with basic text"
    assert_output_equals "Hello, world!" "output should match input text with trailing newline"
}

test_echo_multiple_arguments() {
    setup_echo_test
    
    # Test echo with multiple arguments
    exec_utility echo --timeout="$ECHO_TIMEOUT" "first" "second" "third"
    
    assert_success "echo should succeed with multiple arguments"
    assert_output_equals "first second third" "arguments should be separated by single spaces"
}

test_echo_no_arguments() {
    setup_echo_test
    
    # Test echo with no arguments (should output just a newline)
    exec_utility echo --timeout="$ECHO_TIMEOUT"
    
    assert_success "echo should succeed with no arguments"
    assert_output_equals "" "echo with no arguments should output just newline"
}

test_echo_empty_string() {
    setup_echo_test
    
    # Test echo with empty string argument
    exec_utility echo --timeout="$ECHO_TIMEOUT" ""
    
    assert_success "echo should succeed with empty string"
    assert_output_equals "" "echo with empty string should output just newline"
}

test_echo_spaces_and_tabs() {
    setup_echo_test
    
    # Test echo with arguments containing spaces (shell interpretation)
    exec_utility echo --timeout="$ECHO_TIMEOUT" "text with spaces" "more text"
    
    assert_success "echo should handle spaces in arguments"
    assert_output_equals "text with spaces more text" "should preserve spaces within arguments"
}

test_echo_mixed_content() {
    setup_echo_test
    
    # Test echo with mixed numbers, letters, and punctuation
    exec_utility echo --timeout="$ECHO_TIMEOUT" "Numbers: 123" "Letters: abc" "Symbols: !@#"
    
    assert_success "echo should handle mixed content"
    assert_output_equals "Numbers: 123 Letters: abc Symbols: !@#" "should handle mixed content correctly"
}

# =============================================================================
# Flag Tests
# =============================================================================

test_echo_flag_n() {
    setup_echo_test
    
    # Test -n flag (suppress trailing newline)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -n "no newline"
    
    assert_success "echo -n should succeed"
    assert_output_equals "no newline" "should suppress trailing newline"
}

test_echo_flag_e() {
    setup_echo_test
    
    # Test -e flag (enable escape sequences)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "hello\\nworld"
    
    assert_success "echo -e should succeed"
    assert_output_equals $'hello\nworld' "should interpret escape sequences"
}

test_echo_flag_E() {
    setup_echo_test
    
    # Test -E flag (disable escape sequences - default behavior)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -E "hello\\nworld"
    
    assert_success "echo -E should succeed"
    assert_output_equals "hello\\nworld" "should NOT interpret escape sequences"
}

test_echo_flag_precedence_e_then_E() {
    setup_echo_test
    
    # Test flag precedence: -e -E (last flag wins)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e -E "hello\\nworld"
    
    assert_success "echo -e -E should succeed"
    assert_output_equals "hello\\nworld" "last flag should win: -E disables escapes"
}

test_echo_flag_precedence_E_then_e() {
    setup_echo_test
    
    # Test flag precedence: -E -e (last flag wins)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -E -e "hello\\nworld"
    
    assert_success "echo -E -e should succeed"
    assert_output_equals $'hello\nworld' "last flag should win: -e enables escapes"
}

test_echo_combined_flags_ne() {
    setup_echo_test
    
    # Test combined flags -ne (no newline + escape sequences)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -ne "hello\\tworld"
    
    assert_success "echo -ne should succeed"
    assert_output_equals $'hello\tworld' "should combine -n and -e flags"
}

# =============================================================================
# Escape Sequence Tests
# =============================================================================

test_echo_escape_newline() {
    setup_echo_test
    
    # Test newline escape sequence
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "line1\\nline2"
    
    assert_success "echo should handle \\n escape"
    assert_output_equals $'line1\nline2' "should interpret \\n as newline"
}

test_echo_escape_tab() {
    setup_echo_test
    
    # Test tab escape sequence
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "column1\\tcolumn2"
    
    assert_success "echo should handle \\t escape"
    assert_output_equals $'column1\tcolumn2' "should interpret \\t as tab"
}

test_echo_escape_carriage_return() {
    setup_echo_test
    
    # Test carriage return escape sequence
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "hello\\rworld"
    
    assert_success "echo should handle \\r escape"
    assert_output_equals $'hello\rworld' "should interpret \\r as carriage return"
}

test_echo_escape_backslash() {
    setup_echo_test
    
    # Test backslash escape sequence
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "path\\\\to\\\\file"
    
    assert_success "echo should handle \\\\ escape"
    assert_output_equals "path\\to\\file" "should interpret \\\\ as single backslash"
}

test_echo_escape_alert() {
    setup_echo_test
    
    # Test alert (bell) escape sequence
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "alert\\abell"
    
    assert_success "echo should handle \\a escape"
    
    # For binary verification, also create a temp file and verify alert character
    local temp_file="${TEST_TEMP_DIR}/alert_test.out"  
    local binary_path="$(get_utility_path "echo")"
    "$binary_path" -e "alert\\abell" > "$temp_file"
    
    # Verify the alert character is present
    if grep -q $'\x07' "$temp_file"; then
        true # Alert character found
    else
        fail "output should contain alert character (\\x07)"
    fi
}

test_echo_escape_octal() {
    setup_echo_test
    
    # Test octal escape sequences
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "\\101\\040\\102"
    
    assert_success "echo should handle octal escapes"
    assert_output_equals "A B" "should interpret \\101\\040\\102 as 'A B'"
}

test_echo_escape_hex() {
    setup_echo_test
    
    # Test hexadecimal escape sequences
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "\\x41\\x20\\x42"
    
    assert_success "echo should handle hex escapes"
    assert_output_equals "A B" "should interpret \\x41\\x20\\x42 as 'A B'"
}

test_echo_escape_termination() {
    setup_echo_test
    
    # Test \\c termination behavior (stops all further output)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "before\\cafter"
    
    assert_success "echo should handle \\c escape"
    assert_output_equals "before" "should stop output at \\c, ignoring everything after"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_echo_binary_data_output() {
    setup_echo_test
    
    # Test binary data output using hex escapes - must use exec_utility
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "\\x00\\x01\\x02\\x7f\\x80\\xff"
    
    assert_success "echo should handle binary output"
    
    # For binary data verification, save output to temp file and verify with hexdump
    local temp_file="${TEST_TEMP_DIR}/binary_echo_test.out"
    local binary_path="$(get_utility_path "echo")"
    "$binary_path" -e "\\x00\\x01\\x02\\x7f\\x80\\xff" > "$temp_file"
    
    # Verify binary content using hexdump
    local hex_output
    hex_output=$(hexdump -C "$temp_file" | head -1)
    if [[ "$hex_output" == *"00 01 02 7f 80 ff 0a"* ]]; then
        true # Binary sequence found
    else
        fail "should produce correct binary sequence (got: $hex_output)"
    fi
}

test_echo_invalid_escape_sequences() {
    setup_echo_test
    
    # Test invalid escape sequences (should be passed through literally)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "\\z\\q\\9"
    
    assert_success "echo should handle invalid escapes"
    assert_output_equals "\\z\\q\\9" "should pass invalid escapes through literally"
}

test_echo_incomplete_escape_sequences() {
    setup_echo_test
    
    # Test incomplete escape sequences at end of string
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "text\\"
    
    assert_success "echo should handle incomplete escapes"
    assert_output_equals "text\\" "should output incomplete escape literally"
}

test_echo_escape_termination_with_multiple_args() {
    setup_echo_test
    
    # Test \\c termination with multiple arguments (should stop completely)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "arg1\\cignored" "arg2" "arg3"
    
    assert_success "echo should handle \\c with multiple args"
    assert_output_equals "arg1" "should stop at \\c, ignoring remaining arguments"
}

test_echo_flag_precedence_complex() {
    setup_echo_test
    
    # Test complex flag precedence with multiple flags
    exec_utility echo --timeout="$ECHO_TIMEOUT" -n -e -E -e "test\\nline"
    
    assert_success "echo should handle complex flag precedence"
    assert_output_equals $'test\nline' "should apply: no newline + escapes enabled (last -e wins)"
}

test_echo_hex_edge_cases() {
    setup_echo_test
    
    # Test hex escape edge cases
    exec_utility echo --timeout="$ECHO_TIMEOUT" -e "\\x4\\x\\xZ\\x41"
    
    assert_success "echo should handle hex edge cases"
    assert_output_equals "\\x4\\x\\xZA" "should handle incomplete/invalid hex correctly"
}

# =============================================================================
# Error Conditions Tests
# =============================================================================

test_echo_invalid_flag() {
    setup_echo_test
    
    # Test invalid long flag
    exec_utility echo --timeout="$ECHO_TIMEOUT" --expect-failure --nonexistent-flag "text"
    
    assert_failure "echo should fail with invalid flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

test_echo_unknown_short_flag() {
    setup_echo_test
    
    # Test unknown short flag
    exec_utility echo --timeout="$ECHO_TIMEOUT" --expect-failure -z "text"
    
    assert_failure "echo should fail with unknown short flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

test_echo_flag_without_argument() {
    setup_echo_test
    
    # Test flags that don't expect arguments but receive them through shell parsing
    # This should actually succeed as the shell handles argument parsing
    exec_utility echo --timeout="$ECHO_TIMEOUT" -n "text"
    
    assert_success "echo -n with text should succeed"
    assert_output_equals "text" "should process flag and text normally"
}

test_echo_double_dash_end_of_options() {
    setup_echo_test
    
    # Test -- to end option processing (echo should treat everything after as text)
    exec_utility echo --timeout="$ECHO_TIMEOUT" -- "-n" "-e" "text"
    
    assert_success "echo should handle -- end of options"
    assert_output_equals "-n -e text" "should treat everything after -- as text"
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_echo_help() {
    setup_echo_test
    
    exec_utility echo --timeout="$ECHO_TIMEOUT" --help
    
    assert_success "echo --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "echo" "help should mention echo"
    assert_output_contains -- "-n" "help should document -n flag"
    assert_output_contains -- "-e" "help should document -e flag"
    assert_output_contains -- "-E" "help should document -E flag"
    assert_output_contains "backslash" "help should mention escape sequences"
}

test_echo_version() {
    setup_echo_test
    
    exec_utility echo --timeout="$ECHO_TIMEOUT" --version
    
    assert_success "echo --version should succeed"
    assert_output_contains "echo" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

test_echo_short_help() {
    setup_echo_test
    
    exec_utility echo --timeout="$ECHO_TIMEOUT" -h
    
    assert_success "echo -h should succeed"
    assert_output_contains "Usage:" "short help should contain usage information"
}

# =============================================================================
# Performance Tests
# =============================================================================

test_echo_large_text() {
    setup_echo_test
    
    # Test echo with large text (1000 characters)
    local large_text=""
    for i in {1..100}; do
        large_text="${large_text}0123456789"
    done
    
    exec_utility echo --timeout="$PERFORMANCE_TIMEOUT" "$large_text"
    
    assert_success "echo should handle large text"
    assert_output_equals "$large_text" "should output large text correctly"
}

test_echo_many_arguments() {
    setup_echo_test
    
    # Test echo with many arguments (reduced to reasonable number)
    local args=()
    local expected_output=""
    
    for i in {1..50}; do
        args+=("arg$i")
        if [[ $i -eq 1 ]]; then
            expected_output="arg$i"
        else
            expected_output="$expected_output arg$i"
        fi
    done
    
    exec_utility echo --timeout="$PERFORMANCE_TIMEOUT" "${args[@]}"
    
    assert_success "echo should handle many arguments"
    assert_output_equals "$expected_output" "should process all arguments correctly"
}

test_echo_complex_escape_sequences() {
    setup_echo_test
    
    # Test complex combinations of escape sequences
    local complex_text="\\t\\tTab\\n\\rCR\\aAlert\\bBS\\fFF\\vVT\\\\Backslash\\x41Hex\\101Octal"
    
    exec_utility echo --timeout="$PERFORMANCE_TIMEOUT" -e "$complex_text"
    
    assert_success "echo should handle complex escape sequences"
    # Verify it contains expected characters (not exact match due to control chars)
    assert_output_contains "Tab" "should contain Tab text"
    assert_output_contains "Hex" "should contain Hex text" 
    assert_output_contains "Octal" "should contain Octal text"
}

test_echo_rapid_execution() {
    setup_echo_test
    
    # Test rapid successive executions
    for i in {1..10}; do
        exec_utility echo --timeout="$ECHO_TIMEOUT" "execution $i"
        assert_success "rapid execution $i should succeed"
        assert_output_equals "execution $i" "rapid execution $i should produce correct output"
    done
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework --verbose
    
    if ! has_utility "echo"; then
        print_error "echo utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "echo Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_echo_basic_functionality" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Arguments" "test_echo_multiple_arguments" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Arguments" "test_echo_no_arguments" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty String" "test_echo_empty_string" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Spaces and Tabs" "test_echo_spaces_and_tabs" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Content" "test_echo_mixed_content" "$ECHO_TIMEOUT")")
    
    # Flag Tests
    test_specs+=("$(make_test_spec "Flag -n (No Newline)" "test_echo_flag_n" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag -e (Enable Escapes)" "test_echo_flag_e" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag -E (Disable Escapes)" "test_echo_flag_E" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Precedence -e -E" "test_echo_flag_precedence_e_then_E" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Precedence -E -e" "test_echo_flag_precedence_E_then_e" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Flags -ne" "test_echo_combined_flags_ne" "$ECHO_TIMEOUT")")
    
    # Escape Sequence Tests
    test_specs+=("$(make_test_spec "Escape \\n (Newline)" "test_echo_escape_newline" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape \\t (Tab)" "test_echo_escape_tab" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape \\r (CR)" "test_echo_escape_carriage_return" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape \\\\ (Backslash)" "test_echo_escape_backslash" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape \\a (Alert)" "test_echo_escape_alert" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape Octal \\NNN" "test_echo_escape_octal" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape Hex \\xHH" "test_echo_escape_hex" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Escape \\c (Termination)" "test_echo_escape_termination" "$ECHO_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Binary Data Output" "test_echo_binary_data_output" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Escape Sequences" "test_echo_invalid_escape_sequences" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Incomplete Escape Sequences" "test_echo_incomplete_escape_sequences" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "\\c with Multiple Args" "test_echo_escape_termination_with_multiple_args" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Complex Flag Precedence" "test_echo_flag_precedence_complex" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Hex Edge Cases" "test_echo_hex_edge_cases" "$ECHO_TIMEOUT")")
    
    # Error Conditions Tests
    test_specs+=("$(make_test_spec "Invalid Flag" "test_echo_invalid_flag" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unknown Short Flag" "test_echo_unknown_short_flag" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Without Argument" "test_echo_flag_without_argument" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Double Dash End Options" "test_echo_double_dash_end_of_options" "$ECHO_TIMEOUT")")
    
    # Help and Version Tests
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_echo_help" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_echo_version" "$ECHO_TIMEOUT")")
    test_specs+=("$(make_test_spec "Short Help (-h)" "test_echo_short_help" "$ECHO_TIMEOUT")")
    
    # Performance Tests
    test_specs+=("$(make_test_spec "Large Text" "test_echo_large_text" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Many Arguments" "test_echo_many_arguments" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Complex Escape Sequences" "test_echo_complex_escape_sequences" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Rapid Execution" "test_echo_rapid_execution" "$PERFORMANCE_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$ECHO_TIMEOUT"
    
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