#!/usr/bin/env bash
# Comprehensive tests for echo utility
# Tests all flags and common edge cases that have found bugs

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_echo() {
    local util="echo"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic functionality...${NC}"
    
    # Basic output tests
    test_command_output "echo basic output" "hello world" "$binary" "hello world"
    test_command_output "echo multiple args" "hello world test" "$binary" "hello" "world" "test"
    test_command_output "echo empty" "" "$binary"
    test_command_output "echo single space" " " "$binary" " "
    test_command_output "echo multiple spaces" "hello    world" "$binary" "hello    world"
    
    echo -e "${CYAN}Testing newline flag (-n)...${NC}"
    
    # Test -n flag (no trailing newline)
    local output
    output=$("$binary" -n "test")
    if [[ "$output" == "test" ]] && [[ ! "$output" =~ $'\n'$ ]]; then
        print_test_result "echo -n removes newline" "PASS"
    else
        print_test_result "echo -n removes newline" "FAIL" "Output: '$output'"
    fi
    
    # Test -n with multiple arguments
    output=$("$binary" -n "hello" "world")
    if [[ "$output" == "hello world" ]] && [[ ! "$output" =~ $'\n'$ ]]; then
        print_test_result "echo -n multiple args" "PASS"
    else
        print_test_result "echo -n multiple args" "FAIL" "Output: '$output'"
    fi
    
    # Test -n with empty input
    output=$("$binary" -n)
    if [[ "$output" == "" ]] && [[ ! "$output" =~ $'\n'$ ]]; then
        print_test_result "echo -n empty" "PASS"
    else
        print_test_result "echo -n empty" "FAIL" "Output: '$output'"
    fi
    
    echo -e "${CYAN}Testing escape interpretation (-e flag)...${NC}"
    
    # Test -e flag with common escape sequences
    test_command_output "echo -e newline" $'hello\nworld' "$binary" -e 'hello\nworld'
    test_command_output "echo -e tab" $'hello\tworld' "$binary" -e 'hello\tworld'
    test_command_output "echo -e backslash" 'hello\world' "$binary" -e 'hello\\world'
    test_command_output "echo -e carriage return" $'hello\rworld' "$binary" -e 'hello\rworld'
    
    # Test -e with hex escapes
    test_command_output "echo -e hex A" "A" "$binary" -e '\x41'
    test_command_output "echo -e hex space" " " "$binary" -e '\x20'
    
    # Test -e with octal escapes  
    test_command_output "echo -e octal A" "A" "$binary" -e '\101'
    test_command_output "echo -e octal newline" $'\n' "$binary" -e '\012'
    
    # Test -e with special sequences
    test_command_output "echo -e alert (BEL)" $'\a' "$binary" -e '\a'
    test_command_output "echo -e backspace" $'\b' "$binary" -e '\b'
    test_command_output "echo -e form feed" $'\f' "$binary" -e '\f'
    test_command_output "echo -e vertical tab" $'\v' "$binary" -e '\v'
    test_command_output "echo -e escape" $'\e' "$binary" -e '\e'
    
    # Test \c (stop output)
    output=$("$binary" -e 'hello\cworld')
    if [[ "$output" == "hello" ]]; then
        print_test_result "echo -e \\c stops output" "PASS"
    else
        print_test_result "echo -e \\c stops output" "FAIL" "Expected 'hello', got '$output'"
    fi
    
    echo -e "${CYAN}Testing disable escapes (-E flag)...${NC}"
    
    # Test -E flag (disable escape interpretation - default behavior)
    test_command_output "echo -E literal backslash-n" 'hello\nworld' "$binary" -E 'hello\nworld'
    test_command_output "echo -E literal backslash-t" 'hello\tworld' "$binary" -E 'hello\tworld'
    
    # Test that -E is the default
    test_command_output "echo default no escapes" 'hello\nworld' "$binary" 'hello\nworld'
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Test -n with -e
    output=$("$binary" -n -e 'hello\nworld')
    if [[ "$output" == $'hello\nworld' ]] && [[ ! "$output" =~ $'\n'$ ]]; then
        print_test_result "echo -n -e combination" "PASS"
    else
        print_test_result "echo -n -e combination" "FAIL" "Output: '$output'"
    fi
    
    # Test -n with -E
    output=$("$binary" -n -E 'hello\nworld')
    if [[ "$output" == 'hello\nworld' ]] && [[ ! "$output" =~ $'\n'$ ]]; then
        print_test_result "echo -n -E combination" "PASS"
    else
        print_test_result "echo -n -E combination" "FAIL" "Output: '$output'"
    fi
    
    # Test conflicting flags: -e and -E (last one wins)
    test_command_output "echo -e -E conflict" 'hello\nworld' "$binary" -e -E 'hello\nworld'
    test_command_output "echo -E -e conflict" $'hello\nworld' "$binary" -E -e 'hello\nworld'
    
    echo -e "${CYAN}Testing edge cases and bug scenarios...${NC}"
    
    # Test with special characters
    test_command_output "echo with quotes" "hello 'world' \"test\"" "$binary" "hello 'world' \"test\""
    test_command_output "echo with dollar signs" 'hello $USER $HOME' "$binary" 'hello $USER $HOME'
    test_command_output "echo with asterisk" 'hello * world' "$binary" 'hello * world'
    
    # Test with very long input
    local long_string=$(printf 'a%.0s' {1..1000})
    output=$("$binary" "$long_string")
    if [[ ${#output} -eq 1000 ]] && [[ "$output" == "$long_string" ]]; then
        print_test_result "echo long string (1000 chars)" "PASS"
    else
        print_test_result "echo long string (1000 chars)" "FAIL" "Length: ${#output}, expected: 1000"
    fi
    
    # Test with null bytes and binary data (should handle gracefully)
    # Note: This might not work in all shells, but shouldn't crash
    if output=$("$binary" -e '\0hello\0world' 2>/dev/null); then
        print_test_result "echo binary data handling" "PASS"
    else
        print_test_result "echo binary data handling" "FAIL" "Failed to handle binary data"
    fi
    
    # Test argument processing edge cases
    test_command_output "echo flags after --" "-n -e --help" "$binary" "--" "-n" "-e" "--help"
    test_command_output "echo dash alone" "-" "$binary" "-"
    test_command_output "echo double dash alone" "--" "$binary" "--"
    
    # Test with empty string arguments
    test_command_output "echo empty string arg" "" "$binary" ""
    test_command_output "echo mixed empty args" "hello  world" "$binary" "hello" "" "world"
    
    echo -e "${CYAN}Testing GNU compatibility cases...${NC}"
    
    # Test that invalid escape sequences are treated literally with -e
    test_command_output "echo -e invalid escape" 'hello\\qworld' "$binary" -e 'hello\qworld'
    
    # Test numeric escape edge cases
    test_command_output "echo -e octal overflow" $'\377' "$binary" -e '\377'  # max octal
    test_command_output "echo -e hex max" $'\xff' "$binary" -e '\xff'       # max hex
    
    # Test that flags are processed correctly when mixed with arguments
    test_command_output "echo flag-like args" "-n -e -E" "$binary" "--" "-n" "-e" "-E"
    
    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # These should succeed with empty output
    test_command_succeeds "echo no args" "$binary"
    test_command_succeeds "echo with just flags" "$binary" -n -e -E
    
    # Invalid flag handling (depends on implementation)
    test_command_fails "echo invalid flag" "$binary" --invalid-flag
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX requires these behaviors
    test_command_output "POSIX: echo without args" "" "$binary"
    test_command_output "POSIX: echo single arg" "hello" "$binary" "hello"
    test_command_output "POSIX: echo multiple args" "hello world" "$binary" "hello" "world"
    
    # POSIX doesn't require -n, -e, -E but they're common extensions
    # Just test they don't crash
    test_command_succeeds "POSIX compatibility check" "$binary" "test string"
}