#!/usr/bin/env bash
# Integration tests for stat utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_stat() {
    local util="stat"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Create a temp file for testing
    local tmpfile
    tmpfile=$(mktemp)
    echo "hello" > "$tmpfile"

    # Default output should contain key fields
    local output
    output=$("$binary" "$tmpfile" 2>/dev/null)
    local exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "File:" && "$output" =~ "Size:" && "$output" =~ "Inode:" ]]; then
        print_test_result "stat default output has expected fields" "PASS"
    else
        print_test_result "stat default output has expected fields" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing format options...${NC}"

    # -c %s shows file size
    output=$("$binary" -c '%s' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "6" ]]; then
        print_test_result "stat -c '%s' shows file size" "PASS"
    else
        print_test_result "stat -c '%s' shows file size" "FAIL" \
            "Expected '6', got '$output'"
    fi

    # -c %F shows file type
    output=$("$binary" -c '%F' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "regular file" ]]; then
        print_test_result "stat -c '%F' shows file type" "PASS"
    else
        print_test_result "stat -c '%F' shows file type" "FAIL" \
            "Expected 'regular file', got '$output'"
    fi

    # -c %n shows file name
    output=$("$binary" -c '%n' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "$tmpfile" ]]; then
        print_test_result "stat -c '%n' shows file name" "PASS"
    else
        print_test_result "stat -c '%n' shows file name" "FAIL" \
            "Expected '$tmpfile', got '$output'"
    fi

    # --format=FMT syntax
    output=$("$binary" --format='%s' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "6" ]]; then
        print_test_result "stat --format='%s' syntax works" "PASS"
    else
        print_test_result "stat --format='%s' syntax works" "FAIL" \
            "Expected '6', got '$output'"
    fi

    echo -e "${CYAN}Testing symlink handling...${NC}"

    # Create a symlink
    local tmplink="${tmpfile}.link"
    ln -s "$tmpfile" "$tmplink"

    # Without -L: should show symbolic link
    output=$("$binary" -c '%F' "$tmplink" 2>/dev/null)
    if [[ "$output" == "symbolic link" ]]; then
        print_test_result "stat shows symbolic link type" "PASS"
    else
        print_test_result "stat shows symbolic link type" "FAIL" \
            "Expected 'symbolic link', got '$output'"
    fi

    # With -L: should show regular file
    output=$("$binary" -L -c '%F' "$tmplink" 2>/dev/null)
    if [[ "$output" == "regular file" ]]; then
        print_test_result "stat -L follows symlinks" "PASS"
    else
        print_test_result "stat -L follows symlinks" "FAIL" \
            "Expected 'regular file', got '$output'"
    fi

    echo -e "${CYAN}Testing terse output...${NC}"

    # -t produces terse output (single line)
    output=$("$binary" -t "$tmpfile" 2>/dev/null)
    local line_count
    line_count=$(echo "$output" | wc -l)
    if [[ $line_count -eq 1 && "$output" =~ "$tmpfile" ]]; then
        print_test_result "stat -t produces terse output" "PASS"
    else
        print_test_result "stat -t produces terse output" "FAIL" \
            "Expected 1 line, got $line_count"
    fi

    echo -e "${CYAN}Testing file system info...${NC}"

    # -f shows file system info
    output=$("$binary" -f "$tmpfile" 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Block" ]]; then
        print_test_result "stat -f shows file system info" "PASS"
    else
        print_test_result "stat -f shows file system info" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "stat invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    # Missing operand exits with code 2
    test_command_exit_code "stat missing operand exits 2" 2 \
        "$binary"

    # Nonexistent file exits with code 1
    test_command_exit_code "stat nonexistent file exits 1" 1 \
        "$binary" /nonexistent/path/file

    # Cleanup
    rm -f "$tmpfile" "$tmplink"
}
