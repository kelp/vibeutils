#!/usr/bin/env bash
# Minimal tests for [ (bracket) command - testing ONLY bracket-specific behavior
# The comprehensive test expression logic is already covered in test_test.sh

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_bracket() {
    local util="["
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # NOTE: We intentionally DO NOT test basic flags (--help, --version)
    # because [ command explicitly rejects these flags as unrecognized options.
    # In contrast, test command treats them as expression strings (POSIX behavior).

    echo -e "${CYAN}Testing bracket-specific closing bracket requirement...${NC}"

    # Missing closing bracket (bracket-specific error)
    test_command_exit_code "[ without closing bracket" 2 "$binary" "test" 2>/dev/null
    test_command_exit_code "[ empty without closing bracket" 2 "$binary" 2>/dev/null
    test_command_exit_code "[ expression without closing bracket" 2 "$binary" "hello" "=" "hello" 2>/dev/null

    # Wrong closing bracket (bracket-specific error)
    test_command_exit_code "[ with wrong closing char" 2 "$binary" "test" "}" 2>/dev/null
    test_command_exit_code "[ with wrong closing paren" 2 "$binary" "test" ")" 2>/dev/null

    # Correct closing bracket (should work)
    test_command_exit_code "[ simple expression with ]" 0 "$binary" "hello" "]"
    test_command_exit_code "[ empty string with ]" 1 "$binary" "" "]"
    test_command_exit_code "[ comparison with ]" 0 "$binary" "hello" "=" "hello" "]"

    echo -e "${CYAN}Testing bracket handles --help/--version as expressions (POSIX)...${NC}"

    # [ command should treat --help and --version as string expressions, not flags
    # Per POSIX and BSD behavior, these are non-empty strings that evaluate to true
    test_command_exit_code "[ treats --help as string (true)" 0 "$binary" "--help" "]"
    test_command_exit_code "[ treats --version as string (true)" 0 "$binary" "--version" "]"

    # These work in expressions like any other strings
    test_command_exit_code "[ --help = --help ]" 0 "$binary" "--help" "=" "--help" "]"
    test_command_exit_code "[ --help != --version ]" 0 "$binary" "--help" "!=" "--version" "]"

    # Combined with -a operator
    test_command_exit_code "[ hello -a --help ]" 0 "$binary" "hello" "-a" "--help" "]"

    echo -e "${CYAN}Testing bracket-specific error messages...${NC}"

    # Verify error messages use "[" as program name (not "test")
    local error_output
    error_output=$("$binary" "test" 2>&1)
    if echo "$error_output" | grep -q "\\[:"; then
        print_test_result "[ error message uses bracket program name" "PASS"
    else
        print_test_result "[ error message uses bracket program name" "FAIL" "Output: $error_output"
    fi

    # Test an actual error condition (invalid expression)
    error_output=$("$binary" "-q" "]" 2>&1)
    if echo "$error_output" | grep -q "\\[:"; then
        print_test_result "[ error uses bracket name for invalid expr" "PASS"
    else
        print_test_result "[ error uses bracket name for invalid expr" "FAIL" "Output: $error_output"
    fi

    echo -e "${CYAN}Testing bracket form edge cases...${NC}"

    # Empty expression (only closing bracket)
    test_command_exit_code "[ only closing bracket" 1 "$binary" "]"

    # Multiple closing brackets (only last one should be treated as closing)
    test_command_exit_code "[ multiple closing brackets" 0 "$binary" "]" "=" "]" "]"
    test_command_exit_code "[ bracket as string content" 0 "$binary" "test" "!=" "]" "]"

    # Closing bracket in the middle (not at end)
    test_command_exit_code "[ bracket in middle requires end bracket" 2 "$binary" "]" "=" "]" 2>/dev/null

    echo -e "${CYAN}Testing minimal functional verification...${NC}"

    # Just verify a few basic expressions work (detailed testing is in test_test.sh)
    test_command_exit_code "[ basic string test" 0 "$binary" "hello" "]"
    test_command_exit_code "[ basic comparison" 0 "$binary" "a" "=" "a" "]"
    test_command_exit_code "[ basic file test" 1 "$binary" "-f" "/nonexistent" "]"
    test_command_exit_code "[ basic negation" 0 "$binary" "!" "" "]"

    echo -e "${CYAN}Testing consistency with test command expression logic...${NC}"

    # Verify that [ and test produce same results for identical expressions
    local test_binary="$BIN_DIR/test"

    # Simple string test
    "$test_binary" "hello"
    local test_exit=$?
    "$binary" "hello" "]"
    local bracket_exit=$?

    if [[ $test_exit -eq $bracket_exit ]]; then
        print_test_result "[ vs test consistency: string" "PASS"
    else
        print_test_result "[ vs test consistency: string" "FAIL" "test: $test_exit, [: $bracket_exit"
    fi

    # Comparison test
    "$test_binary" "a" "=" "b"
    test_exit=$?
    "$binary" "a" "=" "b" "]"
    bracket_exit=$?

    if [[ $test_exit -eq $bracket_exit ]]; then
        print_test_result "[ vs test consistency: comparison" "PASS"
    else
        print_test_result "[ vs test consistency: comparison" "FAIL" "test: $test_exit, [: $bracket_exit"
    fi

    # Error case consistency (invalid operator)
    "$test_binary" "-invalid" 2>/dev/null
    test_exit=$?
    "$binary" "-invalid" "]" 2>/dev/null
    bracket_exit=$?

    if [[ $test_exit -eq $bracket_exit && $test_exit -eq 2 ]]; then
        print_test_result "[ vs test consistency: error" "PASS"
    else
        print_test_result "[ vs test consistency: error" "FAIL" "test: $test_exit, [: $bracket_exit"
    fi
}

# Export the test function
export -f test_bracket