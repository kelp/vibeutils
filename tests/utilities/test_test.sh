#!/usr/bin/env bash
# Comprehensive tests for test utility (also known as [)
# Tests all test conditions, logical operators, and both command forms

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_test() {
    local util="test"
    local binary="$BIN_DIR/$util"
    local bracket_binary="$BIN_DIR/["

    # Verify both binaries exist
    test_binary_exists "$util" || return 1
    test_binary_exists "[" || return 1

    # Test basic flags (only for test, not [)
    test_basic_flags "$util"

    echo -e "${CYAN}Testing string comparisons...${NC}"

    # String equality tests
    test_command_exit_code "test string equality (true)" 0 "$binary" "hello" = "hello"
    test_command_exit_code "test string equality (false)" 1 "$binary" "hello" = "world"
    test_command_exit_code "test string inequality (true)" 0 "$binary" "hello" != "world"
    test_command_exit_code "test string inequality (false)" 1 "$binary" "hello" != "hello"

    # String length tests
    test_command_exit_code "test -n non-empty string" 0 "$binary" -n "hello"
    test_command_exit_code "test -n empty string" 1 "$binary" -n ""
    test_command_exit_code "test -z empty string" 0 "$binary" -z ""
    test_command_exit_code "test -z non-empty string" 1 "$binary" -z "hello"

    # String existence (no operator)
    test_command_exit_code "test string exists" 0 "$binary" "hello"
    test_command_exit_code "test empty string exists" 1 "$binary" ""

    echo -e "${CYAN}Testing numeric comparisons...${NC}"

    # Integer equality
    test_command_exit_code "test -eq equal numbers" 0 "$binary" 10 -eq 10
    test_command_exit_code "test -eq unequal numbers" 1 "$binary" 10 -eq 20
    test_command_exit_code "test -ne unequal numbers" 0 "$binary" 10 -ne 20
    test_command_exit_code "test -ne equal numbers" 1 "$binary" 10 -ne 10

    # Integer comparisons
    test_command_exit_code "test -lt less than" 0 "$binary" 5 -lt 10
    test_command_exit_code "test -lt not less than" 1 "$binary" 10 -lt 5
    test_command_exit_code "test -le less than or equal (less)" 0 "$binary" 5 -le 10
    test_command_exit_code "test -le less than or equal (equal)" 0 "$binary" 10 -le 10
    test_command_exit_code "test -le not less than or equal" 1 "$binary" 15 -le 10

    test_command_exit_code "test -gt greater than" 0 "$binary" 10 -gt 5
    test_command_exit_code "test -gt not greater than" 1 "$binary" 5 -gt 10
    test_command_exit_code "test -ge greater than or equal (greater)" 0 "$binary" 10 -ge 5
    test_command_exit_code "test -ge greater than or equal (equal)" 0 "$binary" 10 -ge 10
    test_command_exit_code "test -ge not greater than or equal" 1 "$binary" 5 -ge 10

    # Edge cases with zero and negative numbers
    test_command_exit_code "test zero equality" 0 "$binary" 0 -eq 0
    test_command_exit_code "test negative numbers" 0 "$binary" -5 -lt -3
    test_command_exit_code "test negative and positive" 0 "$binary" -5 -lt 3

    echo -e "${CYAN}Testing file tests...${NC}"

    # Create test files for file tests
    local test_file=$(create_temp_file "test content")
    local test_dir=$(create_temp_dir)
    local nonexistent_file="$TEMP_DIR/nonexistent_file"
    local executable_file=$(create_temp_file "#!/bin/bash\necho test")
    local empty_file=$(create_temp_file "")

    chmod +x "$executable_file"

    # Basic file existence
    test_command_exit_code "test -e existing file" 0 "$binary" -e "$test_file"
    test_command_exit_code "test -e nonexistent file" 1 "$binary" -e "$nonexistent_file"
    test_command_exit_code "test -e directory" 0 "$binary" -e "$test_dir"

    # File type tests
    test_command_exit_code "test -f regular file" 0 "$binary" -f "$test_file"
    test_command_exit_code "test -f directory (false)" 1 "$binary" -f "$test_dir"
    test_command_exit_code "test -f nonexistent" 1 "$binary" -f "$nonexistent_file"

    test_command_exit_code "test -d directory" 0 "$binary" -d "$test_dir"
    test_command_exit_code "test -d regular file (false)" 1 "$binary" -d "$test_file"
    test_command_exit_code "test -d nonexistent" 1 "$binary" -d "$nonexistent_file"

    # Permission tests
    test_command_exit_code "test -r readable file" 0 "$binary" -r "$test_file"
    test_command_exit_code "test -w writable file" 0 "$binary" -w "$test_file"
    test_command_exit_code "test -x executable file" 0 "$binary" -x "$executable_file"
    test_command_exit_code "test -x non-executable file" 1 "$binary" -x "$test_file"

    # File size tests
    test_command_exit_code "test -s non-empty file" 0 "$binary" -s "$test_file"
    test_command_exit_code "test -s empty file" 1 "$binary" -s "$empty_file"
    test_command_exit_code "test -s nonexistent file" 1 "$binary" -s "$nonexistent_file"

    # Special file tests (may not be available on all systems)
    test_command_exit_code "test /dev/null character special" 0 "$binary" -c /dev/null || true
    test_command_exit_code "test regular file not character special" 1 "$binary" -c "$test_file"

    echo -e "${CYAN}Testing logical operators...${NC}"

    # AND operator (-a)
    test_command_exit_code "test -a both true" 0 "$binary" "hello" -a "world"
    test_command_exit_code "test -a first false" 1 "$binary" "" -a "world"
    test_command_exit_code "test -a second false" 1 "$binary" "hello" -a ""
    test_command_exit_code "test -a both false" 1 "$binary" "" -a ""

    # OR operator (-o)
    test_command_exit_code "test -o both true" 0 "$binary" "hello" -o "world"
    test_command_exit_code "test -o first true second false" 0 "$binary" "hello" -o ""
    test_command_exit_code "test -o first false second true" 0 "$binary" "" -o "world"
    test_command_exit_code "test -o both false" 1 "$binary" "" -o ""

    # NOT operator (!)
    test_command_exit_code "test ! true expression" 1 "$binary" ! "hello"
    test_command_exit_code "test ! false expression" 0 "$binary" ! ""
    test_command_exit_code "test ! file exists" 1 "$binary" ! -f "$test_file"
    test_command_exit_code "test ! file not exists" 0 "$binary" ! -f "$nonexistent_file"

    echo -e "${CYAN}Testing complex logical expressions...${NC}"

    # Parentheses and precedence
    test_command_exit_code "test parentheses grouping 1" 0 "$binary" \( "hello" -a "world" \) -o ""
    test_command_exit_code "test parentheses grouping 2" 1 "$binary" \( "" -a "world" \) -o ""
    test_command_exit_code "test parentheses with negation" 0 "$binary" ! \( "" -a "world" \)

    # Complex file and string combinations
    test_command_exit_code "test file and string" 0 "$binary" -f "$test_file" -a -n "string"
    test_command_exit_code "test file or nonexistent" 0 "$binary" -f "$test_file" -o -f "$nonexistent_file"
    test_command_exit_code "test numeric and file" 0 "$binary" 5 -lt 10 -a -s "$test_file"

    echo -e "${CYAN}Testing [ (bracket) command form...${NC}"

    # Basic bracket tests (must end with ])
    test_command_exit_code "[ string equality ]" 0 "$bracket_binary" "hello" = "hello" ]
    test_command_exit_code "[ string inequality ]" 0 "$bracket_binary" "hello" != "world" ]
    test_command_exit_code "[ file test ]" 0 "$bracket_binary" -f "$test_file" ]
    test_command_exit_code "[ numeric test ]" 0 "$bracket_binary" 10 -gt 5 ]

    # Logical operators with brackets
    test_command_exit_code "[ logical and ]" 0 "$bracket_binary" "hello" -a "world" ]
    test_command_exit_code "[ logical or ]" 0 "$bracket_binary" "hello" -o "" ]
    test_command_exit_code "[ logical not ]" 0 "$bracket_binary" ! "" ]

    # Complex bracket expressions
    test_command_exit_code "[ complex expression ]" 0 "$bracket_binary" \( -f "$test_file" -a -n "test" \) ]

    echo -e "${CYAN}Testing edge cases and error conditions...${NC}"

    # No arguments
    test_command_exit_code "test no arguments" 1 "$binary"

    # Invalid operators
    test_command_exit_code "test invalid operator" 2 "$binary" "hello" -invalid "world" 2>/dev/null || true

    # Missing operands
    test_command_exit_code "test missing operand for -eq" 2 "$binary" 5 -eq 2>/dev/null || true
    test_command_exit_code "test missing file for -f" 2 "$binary" -f 2>/dev/null || true

    # Invalid numbers for numeric comparisons
    test_command_exit_code "test non-numeric comparison" 2 "$binary" "abc" -eq 5 2>/dev/null || true
    test_command_exit_code "test non-numeric both sides" 2 "$binary" "abc" -eq "def" 2>/dev/null || true

    # Bracket without closing ]
    test_command_exit_code "[ without closing bracket" 2 "$bracket_binary" "test" 2>/dev/null || true
    test_command_exit_code "[ with wrong closing" 2 "$bracket_binary" "test" = "test" } 2>/dev/null || true

    echo -e "${CYAN}Testing special file types...${NC}"

    # Test with common system files
    test_command_exit_code "test /dev/null exists" 0 "$binary" -e /dev/null
    test_command_exit_code "test /dev/null is character special" 0 "$binary" -c /dev/null || true
    test_command_exit_code "test /tmp is directory" 0 "$binary" -d /tmp

    # Test with symlinks (create a test symlink)
    local link_target="$test_file"
    local link_name="$TEMP_DIR/test_link"
    ln -s "$link_target" "$link_name" 2>/dev/null || true
    if [[ -L "$link_name" ]]; then
        test_command_exit_code "test -L symbolic link" 0 "$binary" -L "$link_name"
        test_command_exit_code "test -L regular file" 1 "$binary" -L "$test_file"
    fi

    echo -e "${CYAN}Testing operator precedence...${NC}"

    # Test that -a has higher precedence than -o
    test_command_exit_code "test precedence -o -a" 0 "$binary" "" -o "hello" -a "world"
    test_command_exit_code "test precedence with parens" 1 "$binary" \( "" -o "hello" \) -a ""

    # Test multiple negations
    test_command_exit_code "test double negation" 0 "$binary" ! ! "hello"
    test_command_exit_code "test double negation false" 1 "$binary" ! ! ""

    echo -e "${CYAN}Testing string comparison edge cases...${NC}"

    # Empty string comparisons
    test_command_exit_code "test empty string equality" 0 "$binary" "" = ""
    test_command_exit_code "test empty vs non-empty" 1 "$binary" "" = "hello"

    # Strings that look like numbers
    test_command_exit_code "test numeric strings with =" 0 "$binary" "123" = "123"
    test_command_exit_code "test numeric strings with -eq" 0 "$binary" "123" -eq "123"
    test_command_exit_code "test different numeric strings" 1 "$binary" "123" = "124"

    # Strings with special characters
    test_command_exit_code "test strings with spaces" 0 "$binary" "hello world" = "hello world"
    test_command_exit_code "test strings with quotes" 0 "$binary" "it's working" = "it's working"
    test_command_exit_code "test strings with backslashes" 0 "$binary" "path\\to\\file" = "path\\to\\file"

    echo -e "${CYAN}Testing numeric edge cases...${NC}"

    # Large numbers
    test_command_exit_code "test large numbers" 0 "$binary" 999999 -lt 1000000

    # Leading zeros
    test_command_exit_code "test leading zeros" 0 "$binary" "007" -eq "7"
    test_command_exit_code "test octal interpretation" 0 "$binary" "010" -eq "10" || true  # May depend on implementation

    # Floating point (should fail in POSIX test)
    test_command_exit_code "test floating point (should fail)" 2 "$binary" "3.14" -eq "3.14" 2>/dev/null || true

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # Test required POSIX operators
    test_command_exit_code "POSIX: string equality" 0 "$binary" "test" = "test"
    test_command_exit_code "POSIX: string inequality" 0 "$binary" "test" != "other"
    test_command_exit_code "POSIX: string length -n" 0 "$binary" -n "test"
    test_command_exit_code "POSIX: string length -z" 0 "$binary" -z ""

    test_command_exit_code "POSIX: numeric equality" 0 "$binary" 42 -eq 42
    test_command_exit_code "POSIX: numeric inequality" 0 "$binary" 42 -ne 24
    test_command_exit_code "POSIX: numeric less than" 0 "$binary" 10 -lt 20
    test_command_exit_code "POSIX: numeric greater than" 0 "$binary" 20 -gt 10

    test_command_exit_code "POSIX: file exists" 0 "$binary" -e "$test_file"
    test_command_exit_code "POSIX: regular file" 0 "$binary" -f "$test_file"
    test_command_exit_code "POSIX: directory" 0 "$binary" -d "$test_dir"
    test_command_exit_code "POSIX: readable" 0 "$binary" -r "$test_file"
    test_command_exit_code "POSIX: writable" 0 "$binary" -w "$test_file"

    test_command_exit_code "POSIX: logical and" 0 "$binary" "hello" -a "world"
    test_command_exit_code "POSIX: logical or" 0 "$binary" "hello" -o ""
    test_command_exit_code "POSIX: logical not" 0 "$binary" ! ""

    # Test exit codes
    test_command_exit_code "test success exit code" 0 "$binary" "true_condition"
    test_command_exit_code "test failure exit code" 1 "$binary" ""
    test_command_exit_code "test error exit code" 2 "$binary" -invalid 2>/dev/null || true

    echo -e "${CYAN}Testing performance with complex expressions...${NC}"

    # Complex nested expressions
    test_command_exit_code "test complex nesting" 0 "$binary" \( \( -f "$test_file" -a -r "$test_file" \) -a \( "hello" = "hello" -o 5 -lt 10 \) \)

    # Many operands
    test_command_exit_code "test many AND operations" 0 "$binary" "a" -a "b" -a "c" -a "d" -a "e"
    test_command_exit_code "test many OR operations" 0 "$binary" "" -o "" -o "" -o "" -o "success"

    echo -e "${CYAN}Testing GNU compatibility extensions...${NC}"

    # Test help and version (POSIX: both test and [ treat these as regular string arguments)
    test_command_exit_code "test --help flag" 0 "$binary" --help >/dev/null 2>&1 || true
    test_command_exit_code "test --version flag" 0 "$binary" --version >/dev/null 2>&1 || true

    # Bracket form also treats them as string arguments (with closing bracket required)
    # Per POSIX and BSD behavior, --help is treated as a non-empty string (returns 0)
    test_command_exit_code "[ treats --help as expression" 0 "$bracket_binary" --help ]

    echo -e "${CYAN}Testing boundary conditions...${NC}"

    # Maximum argument length (platform dependent)
    local long_string=$(printf 'a%.0s' {1..1000})
    test_command_exit_code "test very long string" 0 "$binary" -n "$long_string"

    # Many arguments (test argument parsing limits)
    test_command_exit_code "test many parentheses" 0 "$binary" \( \( \( \( "hello" \) \) \) \)

    echo -e "${CYAN}Testing implementation-specific behaviors...${NC}"

    # Test that both 'test' and '[' produce the same results
    "$binary" "hello" = "hello"
    local test_exit=$?
    "$bracket_binary" "hello" = "hello" ]
    local bracket_exit=$?

    if [[ $test_exit -eq $bracket_exit ]]; then
        print_test_result "test and [ consistency" "PASS"
    else
        print_test_result "test and [ consistency" "FAIL" "test exit: $test_exit, [ exit: $bracket_exit"
    fi

    # Test error message consistency (both should handle errors similarly)
    "$binary" -invalid 2>/dev/null
    local test_error_exit=$?
    "$bracket_binary" -invalid ] 2>/dev/null
    local bracket_error_exit=$?

    if [[ $test_error_exit -eq $bracket_error_exit && $test_error_exit -eq 2 ]]; then
        print_test_result "error handling consistency" "PASS"
    else
        print_test_result "error handling consistency" "FAIL" "test: $test_error_exit, [: $bracket_error_exit"
    fi

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: test -ef compares device AND inode (same file)
    local ef_file1=$(create_temp_file "ef test content")
    local ef_file2=$(create_temp_file "different content")
    test_command_exit_code "test file1 -ef file1 same file (regression)" 0 \
        "$binary" "$ef_file1" -ef "$ef_file1"
    test_command_exit_code "test file1 -ef file2 different files (regression)" 1 \
        "$binary" "$ef_file1" -ef "$ef_file2"

    # Regression test: -o/-a left-to-right evaluation
    # 1 -eq 1 -o 1 -eq 2 should succeed (first condition true)
    test_command_exit_code "test -o left-to-right eval (regression)" 0 \
        "$binary" 1 -eq 1 -o 1 -eq 2
    # 1 -eq 2 -a 1 -eq 1 should fail (first condition false, -a requires both)
    test_command_exit_code "test -a left-to-right eval (regression)" 1 \
        "$binary" 1 -eq 2 -a 1 -eq 1
}

# Export the test function
export -f test_test