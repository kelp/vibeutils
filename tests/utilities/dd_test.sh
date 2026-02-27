#!/usr/bin/env bash
# Comprehensive tests for dd utility
# Tests operand parsing, file copy, conversions, and statistics

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_dd() {
    local util="dd"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic copy functionality...${NC}"

    # Basic file-to-file copy
    local input_file=$(create_temp_file "Hello, dd!")
    local output_file="$TEMP_DIR/dd_output1.txt"
    "$binary" if="$input_file" of="$output_file" status=none 2>/dev/null
    local content=$(cat "$output_file")
    if [[ "$content" == "Hello, dd!" ]]; then
        print_test_result "dd basic file copy" "PASS"
    else
        print_test_result "dd basic file copy" "FAIL" "Expected 'Hello, dd!', got '$content'"
    fi

    # Copy with bs= operand
    local input_file2=$(create_temp_file "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    local output_file2="$TEMP_DIR/dd_output2.txt"
    "$binary" if="$input_file2" of="$output_file2" bs=1024 status=none 2>/dev/null
    content=$(cat "$output_file2")
    if [[ "$content" == "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ]]; then
        print_test_result "dd copy with bs=1024" "PASS"
    else
        print_test_result "dd copy with bs=1024" "FAIL" "Got '$content'"
    fi

    echo -e "${CYAN}Testing count operand...${NC}"

    # Copy with count=
    local output_file3="$TEMP_DIR/dd_output3.txt"
    "$binary" if="$input_file2" of="$output_file3" bs=5 count=2 status=none 2>/dev/null
    content=$(cat "$output_file3")
    if [[ "$content" == "ABCDEFGHIJ" ]]; then
        print_test_result "dd count=2 bs=5" "PASS"
    else
        print_test_result "dd count=2 bs=5" "FAIL" "Expected 'ABCDEFGHIJ', got '$content'"
    fi

    # count=0 copies nothing
    local output_file4="$TEMP_DIR/dd_output4.txt"
    "$binary" if="$input_file2" of="$output_file4" count=0 status=none 2>/dev/null
    if [[ ! -s "$output_file4" ]]; then
        print_test_result "dd count=0 copies nothing" "PASS"
    else
        print_test_result "dd count=0 copies nothing" "FAIL" "Output file is not empty"
    fi

    echo -e "${CYAN}Testing skip and seek operands...${NC}"

    # Test skip=
    local skip_input=$(create_temp_file "AAAABBBB")
    local skip_output="$TEMP_DIR/dd_skip.txt"
    "$binary" if="$skip_input" of="$skip_output" bs=4 skip=1 status=none 2>/dev/null
    content=$(cat "$skip_output")
    if [[ "$content" == "BBBB" ]]; then
        print_test_result "dd skip=1 bs=4" "PASS"
    else
        print_test_result "dd skip=1 bs=4" "FAIL" "Expected 'BBBB', got '$content'"
    fi

    # Test seek=
    local seek_output="$TEMP_DIR/dd_seek.txt"
    local seek_input=$(create_temp_file "DATA")
    "$binary" if="$seek_input" of="$seek_output" bs=4 seek=1 conv=notrunc status=none 2>/dev/null
    local seek_size
    if [[ "$(uname -s)" == "Darwin" ]]; then
        seek_size=$(stat -f%z "$seek_output")
    else
        seek_size=$(stat -c%s "$seek_output")
    fi
    if [[ "$seek_size" -eq 8 ]]; then
        print_test_result "dd seek=1 bs=4" "PASS"
    else
        print_test_result "dd seek=1 bs=4" "FAIL" "Expected size 8, got $seek_size"
    fi

    echo -e "${CYAN}Testing conversions...${NC}"

    # Test conv=ucase
    local lcase_input=$(create_temp_file "hello world")
    local ucase_output="$TEMP_DIR/dd_ucase.txt"
    "$binary" if="$lcase_input" of="$ucase_output" conv=ucase status=none 2>/dev/null
    content=$(cat "$ucase_output")
    if [[ "$content" == "HELLO WORLD" ]]; then
        print_test_result "dd conv=ucase" "PASS"
    else
        print_test_result "dd conv=ucase" "FAIL" "Expected 'HELLO WORLD', got '$content'"
    fi

    # Test conv=lcase
    local ucase_input=$(create_temp_file "HELLO WORLD")
    local lcase_output="$TEMP_DIR/dd_lcase.txt"
    "$binary" if="$ucase_input" of="$lcase_output" conv=lcase status=none 2>/dev/null
    content=$(cat "$lcase_output")
    if [[ "$content" == "hello world" ]]; then
        print_test_result "dd conv=lcase" "PASS"
    else
        print_test_result "dd conv=lcase" "FAIL" "Expected 'hello world', got '$content'"
    fi

    echo -e "${CYAN}Testing status levels...${NC}"

    # Test status=none suppresses output
    local status_input=$(create_temp_file "test data")
    local status_output="$TEMP_DIR/dd_status.txt"
    local stderr_output
    stderr_output=$("$binary" if="$status_input" of="$status_output" status=none 2>&1)
    if [[ -z "$stderr_output" ]]; then
        print_test_result "dd status=none" "PASS"
    else
        print_test_result "dd status=none" "FAIL" "Expected no stderr, got '$stderr_output'"
    fi

    # Test default status shows statistics
    local stat_output="$TEMP_DIR/dd_stat.txt"
    stderr_output=$("$binary" if="$status_input" of="$stat_output" 2>&1)
    if echo "$stderr_output" | grep -q "records in"; then
        print_test_result "dd default status shows records" "PASS"
    else
        print_test_result "dd default status shows records" "FAIL" "Expected 'records in' in stderr"
    fi

    # Test status=noxfer
    local noxfer_output="$TEMP_DIR/dd_noxfer.txt"
    stderr_output=$("$binary" if="$status_input" of="$noxfer_output" status=noxfer 2>&1)
    if echo "$stderr_output" | grep -q "records in" && ! echo "$stderr_output" | grep -q "bytes"; then
        print_test_result "dd status=noxfer" "PASS"
    else
        print_test_result "dd status=noxfer" "FAIL" "Unexpected stderr content"
    fi

    echo -e "${CYAN}Testing stdin/stdout...${NC}"

    # Test reading from stdin
    local stdin_result
    stdin_result=$(echo "stdin test" | "$binary" bs=1024 status=none 2>/dev/null)
    if [[ "$stdin_result" == "stdin test" ]]; then
        print_test_result "dd from stdin to stdout" "PASS"
    else
        print_test_result "dd from stdin to stdout" "FAIL" "Expected 'stdin test', got '$stdin_result'"
    fi

    echo -e "${CYAN}Testing error handling...${NC}"

    # Test nonexistent input file
    if "$binary" if=/nonexistent/file of=/dev/null status=none 2>/dev/null; then
        print_test_result "dd nonexistent input" "FAIL" "Should have failed"
    else
        print_test_result "dd nonexistent input" "PASS"
    fi

    # Test invalid operand
    if "$binary" invalid=operand status=none 2>/dev/null; then
        print_test_result "dd invalid operand" "FAIL" "Should have failed"
    else
        print_test_result "dd invalid operand" "PASS"
    fi

    # Test mutually exclusive conversions
    if "$binary" conv=lcase,ucase if=/dev/null of=/dev/null status=none 2>/dev/null; then
        print_test_result "dd lcase+ucase conflict" "FAIL" "Should have failed"
    else
        print_test_result "dd lcase+ucase conflict" "PASS"
    fi

    echo -e "${CYAN}Testing byte size suffixes...${NC}"

    # Test various size suffixes
    local suffix_input=$(create_temp_file "$(printf '%02048d' 0)")
    local suffix_output="$TEMP_DIR/dd_suffix.txt"
    "$binary" if="$suffix_input" of="$suffix_output" bs=1K count=1 status=none 2>/dev/null
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local file_size=$(stat -f%z "$suffix_output")
    else
        local file_size=$(stat -c%s "$suffix_output")
    fi
    if [[ "$file_size" -eq 1024 ]]; then
        print_test_result "dd bs=1K suffix" "PASS"
    else
        print_test_result "dd bs=1K suffix" "FAIL" "Expected 1024 bytes, got $file_size"
    fi

    echo -e "${CYAN}Testing exit codes...${NC}"

    # Success exit code
    test_command_exit_code "dd success exit code" 0 "$binary" if=/dev/null of=/dev/null status=none

    # Failure exit code for bad input
    test_command_exit_code "dd failure exit code" 1 "$binary" if=/nonexistent/path of=/dev/null status=none 2>/dev/null || true
}
