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
}
