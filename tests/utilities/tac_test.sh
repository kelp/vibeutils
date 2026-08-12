#!/usr/bin/env bash
# Comprehensive tests for tac utility
# Tests line reversal, custom separators, --before mode, and multi-file handling

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_tac() {
    local util="tac"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic line reversal...${NC}"

    # Basic reversal with trailing newline
    test_command_output "tac basic reversal" $'line3\nline2\nline1' bash -c "printf 'line1\nline2\nline3\n' | '$binary'"

    # Single line
    test_command_output "tac single line" "only line" bash -c "printf 'only line\n' | '$binary'"

    # Empty input
    test_command_output "tac empty input" "" bash -c "printf '' | '$binary'"

    # Two lines
    test_command_output "tac two lines" $'second\nfirst' bash -c "printf 'first\nsecond\n' | '$binary'"

    echo -e "${CYAN}Testing file input...${NC}"

    # Create test files
    local test_file1="$TEMP_DIR/tac1.txt"
    local test_file2="$TEMP_DIR/tac2.txt"

    printf 'alpha\nbeta\ngamma\n' > "$test_file1"
    printf 'one\ntwo\n' > "$test_file2"

    # Single file
    test_command_output "tac single file" $'gamma\nbeta\nalpha' "$binary" "$test_file1"

    # Multiple files (each reversed independently)
    test_command_output "tac multiple files" $'gamma\nbeta\nalpha\ntwo\none' "$binary" "$test_file1" "$test_file2"

    echo -e "${CYAN}Testing custom separator (-s)...${NC}"

    # Colon separator
    test_command_output "tac -s colon" "c:b:a:" bash -c "printf 'a:b:c:' | '$binary' -s ':'"

    # Multi-character separator
    test_command_output "tac -s multi-char" "z<>y<>x<>" bash -c "printf 'x<>y<>z<>' | '$binary' -s '<>'"

    # Long option form
    test_command_output "tac --separator" "c:b:a:" bash -c "printf 'a:b:c:' | '$binary' --separator=':'"

    echo -e "${CYAN}Testing --before flag...${NC}"

    # Before mode: GNU splits records with separator *before* each record.
    # GNU: printf 'line1\nline2\nline3\n' | tac -b → "\n\nline3\nline2line1"
    # Records: "line1", "\nline2", "\nline3", "\n" → reversed: "\n", "\nline3", "\nline2", "line1"
    local before_expected=$'\n\nline3\nline2line1'
    test_command_output_exact "tac -b basic" "$before_expected" bash -c "printf 'line1\nline2\nline3\n' | '$binary' -b"

    # Before mode with single-byte custom separator
    # GNU: printf 'a:b:c:' | tac -s: -b → "::c:ba"
    test_command_output_exact "tac -b -s colon" "::c:ba" bash -c "printf 'a:b:c:' | '$binary' -s ':' -b"

    # Before mode with multi-byte separator
    # GNU: printf 'a<>b<>c<>' | tac -s '<>' -b → "<><>c<>ba"
    test_command_output_exact "tac -b -s multi-byte" "<><>c<>ba" bash -c "printf 'a<>b<>c<>' | '$binary' -s '<>' -b"

    # Before mode with no trailing separator
    # GNU: printf 'a:b:c' | tac -s: -b → ":c:ba"
    test_command_output_exact "tac -b -s colon no trailing" ":c:ba" bash -c "printf 'a:b:c' | '$binary' -s ':' -b"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag
    test_command_exit_code "tac invalid flag -x" 1 "$binary" -x 2>/dev/null
    test_command_exit_code "tac invalid long flag" 1 "$binary" --invalid 2>/dev/null

    # Non-existent file
    test_command_exit_code "tac nonexistent file" 1 "$binary" /nonexistent/file.txt 2>/dev/null

    # GNU always quotes the operand for this message, regardless of content
    # (pinned on coreutils 9.5: `tac: failed to open '/nonexistent/file.txt'
    # for reading: No such file or directory`).
    local nf_err
    nf_err=$("$binary" /nonexistent/file.txt 2>&1 >/dev/null)
    if [[ "$nf_err" == *"failed to open '/nonexistent/file.txt' for reading: No such file or directory"* ]]; then
        print_test_result "tac nonexistent file error message matches GNU" "PASS"
    else
        print_test_result "tac nonexistent file error message matches GNU" "FAIL" \
            "Got: $nf_err"
    fi

    # Regex flag unsupported
    test_command_exit_code "tac -r unsupported" 1 "$binary" -r 2>/dev/null

    echo -e "${CYAN}Testing edge cases...${NC}"

    # File without trailing newline
    local no_newline_file="$TEMP_DIR/tac_nonl.txt"
    printf 'a\nb\nc' > "$no_newline_file"
    test_command_output "tac no trailing newline" $'cb\na' "$binary" "$no_newline_file"

    # Only newlines
    test_command_output_exact "tac only newlines" $'\n\n\n' bash -c "printf '\n\n\n' | '$binary'"

    # Single character no newline
    test_command_output "tac single char" "X" bash -c "printf 'X' | '$binary'"

    # Large input
    local large_file="$TEMP_DIR/tac_large.txt"
    for i in $(seq 1 100); do echo "line$i"; done > "$large_file"
    local first_line
    first_line=$("$binary" "$large_file" | head -1)
    if [[ "$first_line" == "line100" ]]; then
        print_test_result "tac large file first line" "PASS"
    else
        print_test_result "tac large file first line" "FAIL" "Expected 'line100', got '$first_line'"
    fi

    local last_line
    last_line=$("$binary" "$large_file" | tail -1)
    if [[ "$last_line" == "line1" ]]; then
        print_test_result "tac large file last line" "PASS"
    else
        print_test_result "tac large file last line" "FAIL" "Expected 'line1', got '$last_line'"
    fi

    echo -e "${CYAN}Testing POSIX exit codes...${NC}"

    test_command_exit_code "tac success exit code" 0 bash -c "echo 'test' | '$binary'"
    test_command_exit_code "tac help exit code" 0 "$binary" --help
    test_command_exit_code "tac version exit code" 0 "$binary" --version

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}tac tests completed${NC}"
}

# Export the test function
export -f test_tac
