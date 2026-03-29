#!/usr/bin/env bash
# Integration tests for printf utility
# Tests format specifiers, escape sequences, width, precision, and reuse

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_printf() {
    local util="printf"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic string formatting...${NC}"

    # Basic %s
    local output
    output=$("$binary" "%s" "hello")
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf %s basic" "PASS"
    else
        print_test_result "printf %s basic" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    # Format with newline
    output=$("$binary" "%s\n" "hello")
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf %s with newline" "PASS"
    else
        print_test_result "printf %s with newline" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    echo -e "${CYAN}Testing integer formatting...${NC}"

    # %d decimal
    output=$("$binary" "%d" "42")
    if [[ "$output" == "42" ]]; then
        print_test_result "printf %d decimal" "PASS"
    else
        print_test_result "printf %d decimal" "FAIL" \
            "Expected '42', got '$output'"
    fi

    # %o octal
    output=$("$binary" "%o" "255")
    if [[ "$output" == "377" ]]; then
        print_test_result "printf %o octal" "PASS"
    else
        print_test_result "printf %o octal" "FAIL" \
            "Expected '377', got '$output'"
    fi

    # %x hex
    output=$("$binary" "%x" "255")
    if [[ "$output" == "ff" ]]; then
        print_test_result "printf %x hex" "PASS"
    else
        print_test_result "printf %x hex" "FAIL" \
            "Expected 'ff', got '$output'"
    fi

    # %X hex uppercase
    output=$("$binary" "%X" "255")
    if [[ "$output" == "FF" ]]; then
        print_test_result "printf %X hex uppercase" "PASS"
    else
        print_test_result "printf %X hex uppercase" "FAIL" \
            "Expected 'FF', got '$output'"
    fi

    echo -e "${CYAN}Testing width and padding...${NC}"

    # Right-aligned string
    output=$("$binary" "%10s" "hello")
    if [[ "$output" == "     hello" ]]; then
        print_test_result "printf %10s right-aligned" "PASS"
    else
        print_test_result "printf %10s right-aligned" "FAIL" \
            "Expected '     hello', got '$output'"
    fi

    # Left-aligned string
    output=$("$binary" "%-10s" "hello")
    if [[ "$output" == "hello     " ]]; then
        print_test_result "printf %-10s left-aligned" "PASS"
    else
        print_test_result "printf %-10s left-aligned" "FAIL" \
            "Expected 'hello     ', got '$output'"
    fi

    # Zero-padded integer
    output=$("$binary" "%05d" "42")
    if [[ "$output" == "00042" ]]; then
        print_test_result "printf %05d zero-padded" "PASS"
    else
        print_test_result "printf %05d zero-padded" "FAIL" \
            "Expected '00042', got '$output'"
    fi

    echo -e "${CYAN}Testing precision...${NC}"

    # String precision
    output=$("$binary" "%.3s" "hello")
    if [[ "$output" == "hel" ]]; then
        print_test_result "printf %.3s precision" "PASS"
    else
        print_test_result "printf %.3s precision" "FAIL" \
            "Expected 'hel', got '$output'"
    fi

    echo -e "${CYAN}Testing escape sequences...${NC}"

    # Tab
    output=$("$binary" "a\tb")
    local expected=$'a\tb'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf tab escape" "PASS"
    else
        print_test_result "printf tab escape" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    # Literal percent
    output=$("$binary" "100%%")
    if [[ "$output" == "100%" ]]; then
        print_test_result "printf literal percent" "PASS"
    else
        print_test_result "printf literal percent" "FAIL" \
            "Expected '100%', got '$output'"
    fi

    echo -e "${CYAN}Testing format string reuse...${NC}"

    # Reuse format with multiple args
    output=$("$binary" "%s\n" "a" "b" "c")
    expected=$'a\nb\nc'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf format reuse" "PASS"
    else
        print_test_result "printf format reuse" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "printf --help shows usage" "PASS"
    else
        print_test_result "printf --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ printf ]]; then
        print_test_result "printf --version shows version" "PASS"
    else
        print_test_result "printf --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments exits with code 2
    test_command_exit_code "printf no args exits 2" 2 \
        "$binary"

    # Regression test: write errors propagated (smoke test)
    # The actual write-error path is hard to exercise in shell, so verify
    # that escape sequences produce correct output end-to-end (the fix
    # ensures flush/write errors are not silently swallowed).
    echo -e "${CYAN}Testing escape sequence output end-to-end...${NC}"

    local nl_output
    nl_output=$("$binary" 'line1\nline2')
    local nl_expected=$'line1\nline2'
    if [[ "$nl_output" == "$nl_expected" ]]; then
        print_test_result "printf backslash-n produces newline" "PASS"
    else
        print_test_result "printf backslash-n produces newline" "FAIL" \
            "Expected 'line1<NL>line2', got '$nl_output'"
    fi

    # Regression test: carry propagation in float formatting
    echo -e "${CYAN}Testing float rounding carry propagation...${NC}"

    output=$("$binary" '%.2f' 9.995)
    if [[ "$output" == "10.00" ]]; then
        print_test_result "printf %.2f 9.995 rounds to 10.00" "PASS"
    else
        print_test_result "printf %.2f 9.995 rounds to 10.00" "FAIL" \
            "Expected '10.00', got '$output'"
    fi

    output=$("$binary" '%.0f' 9.5)
    if [[ "$output" == "10" ]]; then
        print_test_result "printf %.0f 9.5 rounds to 10" "PASS"
    else
        print_test_result "printf %.0f 9.5 rounds to 10" "FAIL" \
            "Expected '10', got '$output'"
    fi

    output=$("$binary" '%.2f' 99.999)
    if [[ "$output" == "100.00" ]]; then
        print_test_result "printf %.2f 99.999 rounds to 100.00" "PASS"
    else
        print_test_result "printf %.2f 99.999 rounds to 100.00" "FAIL" \
            "Expected '100.00', got '$output'"
    fi

    # ========== AUDIT FINDING TESTS ==========

    echo -e "${CYAN}Testing F31: octal escapes without leading zero...${NC}"

    # F31: \NNN octal escape without leading zero
    # GNU printf '\101\n' outputs 'A' (octal 101 = 65)
    output=$("$binary" '\101')
    if [[ "$output" == "A" ]]; then
        print_test_result "printf F31: \\101 octal = A" "PASS"
    else
        print_test_result "printf F31: \\101 octal = A" "FAIL" \
            "Expected 'A', got '$output'"
    fi

    # F31: single octal digit
    output=$("$binary" '\7')
    local expected_bel=$'\x07'
    if [[ "$output" == "$expected_bel" ]]; then
        print_test_result "printf F31: \\7 octal = BEL" "PASS"
    else
        print_test_result "printf F31: \\7 octal = BEL" "FAIL" \
            "Expected BEL (0x07), got '$output'"
    fi

    # F31: 3-digit octal
    output=$("$binary" '\110')
    if [[ "$output" == "H" ]]; then
        print_test_result "printf F31: \\110 octal = H" "PASS"
    else
        print_test_result "printf F31: \\110 octal = H" "FAIL" \
            "Expected 'H', got '$output'"
    fi

    echo -e "${CYAN}Testing F32: %b octal \\0NNN off-by-one...${NC}"

    # F32: %b \0NNN should skip the leading 0 prefix
    output=$("$binary" '%b' '\0101')
    if [[ "$output" == "A" ]]; then
        print_test_result "printf F32: %b \\0101 = A" "PASS"
    else
        print_test_result "printf F32: %b \\0101 = A" "FAIL" \
            "Expected 'A', got '$(echo -n "$output" | od -A x -t x1z)'"
    fi

    # F32: %b \0110 = 'H'
    output=$("$binary" '%b' '\0110')
    if [[ "$output" == "H" ]]; then
        print_test_result "printf F32: %b \\0110 = H" "PASS"
    else
        print_test_result "printf F32: %b \\0110 = H" "FAIL" \
            "Expected 'H', got '$(echo -n "$output" | od -A x -t x1z)'"
    fi

    echo -e "${CYAN}Testing F33: \\c in format string stops output...${NC}"

    # F33: \c halts output in format string
    output=$("$binary" 'before\cafter')
    if [[ "$output" == "before" ]]; then
        print_test_result "printf F33: \\c stops output" "PASS"
    else
        print_test_result "printf F33: \\c stops output" "FAIL" \
            "Expected 'before', got '$output'"
    fi

    # F33: \c at start
    output=$("$binary" '\chello')
    if [[ "$output" == "" ]]; then
        print_test_result "printf F33: \\c at start = empty" "PASS"
    else
        print_test_result "printf F33: \\c at start = empty" "FAIL" \
            "Expected empty, got '$output'"
    fi

    echo -e "${CYAN}Testing F34: %b \\c halts format-string reuse...${NC}"

    # F34: %b \c should stop reusing format for remaining args
    output=$("$binary" '%b\n' 'hello\c' 'world')
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf F34: %b \\c halts reuse" "PASS"
    else
        print_test_result "printf F34: %b \\c halts reuse" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    echo -e "${CYAN}Testing F35: %F, %a, %A format specifiers...${NC}"

    # F35: %F is uppercase %f
    output=$("$binary" '%F' 3.14)
    if [[ "$output" == "3.140000" ]]; then
        print_test_result "printf F35: %F 3.14 = 3.140000" "PASS"
    else
        print_test_result "printf F35: %F 3.14 = 3.140000" "FAIL" \
            "Expected '3.140000', got '$output'"
    fi

    # F35: %a hex float (just check it starts with 0x and has p)
    output=$("$binary" '%a' 1.5)
    if [[ "$output" == 0x*p* ]]; then
        print_test_result "printf F35: %a hex float format" "PASS"
    else
        print_test_result "printf F35: %a hex float format" "FAIL" \
            "Expected '0x...p...', got '$output'"
    fi

    # F35: %A hex float uppercase
    output=$("$binary" '%A' 1.5)
    if [[ "$output" == 0X*P* ]]; then
        print_test_result "printf F35: %A hex float uppercase" "PASS"
    else
        print_test_result "printf F35: %A hex float uppercase" "FAIL" \
            "Expected '0X...P...', got '$output'"
    fi
}
