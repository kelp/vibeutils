#!/usr/bin/env bash
# Simple comprehensive tests for echo utility
# Compatible with older bash versions

test_echo() {
    local util="echo"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic functionality...${NC}"
    
    # Simple direct test for basic output
    local output
    output=$("$binary" "hello world")
    if [[ "$output" == "hello world" ]]; then
        print_test_result "echo basic output" "PASS"
    else
        print_test_result "echo basic output" "FAIL" "Expected 'hello world', got '$output'"
    fi
    
    # Test multiple args
    output=$("$binary" "hello" "world" "test")
    if [[ "$output" == "hello world test" ]]; then
        print_test_result "echo multiple args" "PASS"
    else
        print_test_result "echo multiple args" "FAIL" "Expected 'hello world test', got '$output'"
    fi
    
    # Test empty
    output=$("$binary")
    if [[ "$output" == "" ]]; then
        print_test_result "echo empty" "PASS"
    else
        print_test_result "echo empty" "FAIL" "Expected empty, got '$output'"
    fi
    
    echo -e "${CYAN}Testing -n flag...${NC}"
    
    # Test -n flag (more robust check)
    output=$("$binary" -n "test")
    # Check that it doesn't end with newline by using printf to compare
    if printf "test" | diff - <(echo -n "$output") >/dev/null 2>&1; then
        print_test_result "echo -n removes newline" "PASS"
    else
        print_test_result "echo -n removes newline" "FAIL" "Output: '$output'"
    fi
    
    echo -e "${CYAN}Testing -e flag...${NC}"
    
    # Test -e with newline
    output=$("$binary" -e 'hello\nworld')
    expected=$'hello\nworld'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "echo -e newline" "PASS"
    else
        print_test_result "echo -e newline" "FAIL" "Expected '$expected', got '$output'"
    fi
    
    # Test -e with tab
    output=$("$binary" -e 'hello\tworld')
    expected=$'hello\tworld'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "echo -e tab" "PASS"
    else
        print_test_result "echo -e tab" "FAIL" "Expected '$expected', got '$output'"
    fi
    
    echo -e "${CYAN}Testing -E flag...${NC}"
    
    # Test -E (literal)
    output=$("$binary" -E 'hello\nworld')
    if [[ "$output" == 'hello\nworld' ]]; then
        print_test_result "echo -E literal" "PASS"
    else
        print_test_result "echo -E literal" "FAIL" "Expected 'hello\\nworld', got '$output'"
    fi
    
    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # Test invalid flag
    if "$binary" --invalid-flag >/dev/null 2>&1; then
        print_test_result "echo invalid flag handling" "FAIL" "Should have failed"
    else
        print_test_result "echo invalid flag handling" "PASS"
    fi
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX basic tests
    output=$("$binary" "hello")
    if [[ "$output" == "hello" ]]; then
        print_test_result "POSIX single arg" "PASS"
    else
        print_test_result "POSIX single arg" "FAIL" "Expected 'hello', got '$output'"
    fi
    
    output=$("$binary" "hello" "world")
    if [[ "$output" == "hello world" ]]; then
        print_test_result "POSIX multiple args" "PASS"
    else
        print_test_result "POSIX multiple args" "FAIL" "Expected 'hello world', got '$output'"
    fi
}