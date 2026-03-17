#!/usr/bin/env bash
# Comprehensive tests for cut utility
# Tests byte, character, and field selection with various delimiters
# and range specifications

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_cut() {
    local util="cut"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Create test files
    local tab_file=$(create_temp_file $'one\ttwo\tthree\tfour\tfive')
    local colon_file=$(create_temp_file $'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin')
    local csv_file=$(create_temp_file $'Alice,30,Engineer\nBob,25,Designer\nCarol,35,Manager')
    local simple_file=$(create_temp_file "abcdefghij")
    local multiline_file=$(create_temp_file $'abcde\nfghij\nklmno')
    local mixed_file=$(create_temp_file $'has\tdelimiter\nno delimiter here\nalso\thas\tone')

    echo -e "${CYAN}Testing byte selection (-b)...${NC}"

    # Single byte
    test_command_output "cut -b 1" "a" bash -c "echo 'abcde' | '$binary' -b 1"

    # Byte range
    test_command_output "cut -b 1-3" "abc" bash -c "echo 'abcde' | '$binary' -b 1-3"

    # Multiple bytes
    test_command_output "cut -b 1,3,5" "ace" bash -c "echo 'abcde' | '$binary' -b 1,3,5"

    # From byte N to end
    test_command_output "cut -b 3-" "cde" bash -c "echo 'abcde' | '$binary' -b 3-"

    # From start to byte M
    test_command_output "cut -b -3" "abc" bash -c "echo 'abcde' | '$binary' -b -3"

    # Byte selection with file
    test_command_output "cut -b 1-3 file" $'abc\nfgh\nklm' "$binary" -b 1-3 "$multiline_file"

    # Long option
    test_command_output "cut --bytes=2-4" "bcd" bash -c "echo 'abcde' | '$binary' --bytes=2-4"

    echo -e "${CYAN}Testing character selection (-c)...${NC}"

    # Single character
    test_command_output "cut -c 1" "a" bash -c "echo 'abcde' | '$binary' -c 1"

    # Character range
    test_command_output "cut -c 2-4" "bcd" bash -c "echo 'abcde' | '$binary' -c 2-4"

    # Multiple characters
    test_command_output "cut -c 1,3,5" "ace" bash -c "echo 'abcde' | '$binary' -c 1,3,5"

    # Long option
    test_command_output "cut --characters=1-3" "abc" bash -c "echo 'abcde' | '$binary' --characters=1-3"

    echo -e "${CYAN}Testing field selection (-f)...${NC}"

    # Single field with tab delimiter (default)
    test_command_output "cut -f 1 tab" "one" bash -c "printf 'one\ttwo\tthree' | '$binary' -f 1"

    # Multiple fields
    test_command_output "cut -f 1,3 tab" $'one\tthree' bash -c "printf 'one\ttwo\tthree' | '$binary' -f 1,3"

    # Field range
    test_command_output "cut -f 2-3 tab" $'two\tthree' bash -c "printf 'one\ttwo\tthree' | '$binary' -f 2-3"

    # Field from N to end
    test_command_output "cut -f 2- tab" $'two\tthree' bash -c "printf 'one\ttwo\tthree' | '$binary' -f 2-"

    # Long option
    test_command_output "cut --fields=1 tab" "one" bash -c "printf 'one\ttwo\tthree' | '$binary' --fields=1"

    echo -e "${CYAN}Testing custom delimiter (-d)...${NC}"

    # Colon delimiter
    test_command_output "cut -d: -f1 passwd" $'root\nnobody' "$binary" -d: -f1 "$colon_file"

    # Colon delimiter field 3
    test_command_output "cut -d: -f3 passwd" $'0\n65534' "$binary" -d: -f3 "$colon_file"

    # Comma delimiter
    test_command_output "cut -d, -f1 csv" $'Alice\nBob\nCarol' "$binary" -d, -f1 "$csv_file"

    # Comma delimiter multiple fields
    test_command_output "cut -d, -f1,3 csv" $'Alice,Engineer\nBob,Designer\nCarol,Manager' "$binary" -d, -f1,3 "$csv_file"

    # Long delimiter option
    test_command_output "cut --delimiter=: --fields=1" $'root\nnobody' "$binary" --delimiter=: --fields=1 "$colon_file"

    echo -e "${CYAN}Testing -s (only-delimited)...${NC}"

    # Without -s: lines without delimiter are printed
    test_command_output "cut -f1 mixed (no -s)" $'has\nno delimiter here\nalso' "$binary" -f1 "$mixed_file"

    # With -s: lines without delimiter are suppressed
    test_command_output "cut -sf1 mixed" $'has\nalso' "$binary" -s -f1 "$mixed_file"

    # Long option
    test_command_output "cut --only-delimited -f1" $'has\nalso' "$binary" --only-delimited -f1 "$mixed_file"

    echo -e "${CYAN}Testing --complement...${NC}"

    # Complement bytes
    test_command_output "cut --complement -b 2,4" "ace" bash -c "echo 'abcde' | '$binary' --complement -b 2,4"

    # Complement fields
    test_command_output "cut --complement -f2 tab" $'one\tthree' bash -c "printf 'one\ttwo\tthree' | '$binary' --complement -f 2"

    echo -e "${CYAN}Testing --output-delimiter...${NC}"

    # Custom output delimiter for fields
    test_command_output "cut --output-delimiter=, -f1,3 tab" "one,three" bash -c "printf 'one\ttwo\tthree' | '$binary' --output-delimiter=, -f 1,3"

    # Output delimiter with colon input (field 6 starts with / so output has //)
    test_command_output "cut -d: --output-delimiter=/ -f1,6 passwd" $'root//root\nnobody//nonexistent' bash -c "cat '$colon_file' | '$binary' -d: --output-delimiter=/ -f1,6"

    echo -e "${CYAN}Testing range edge cases...${NC}"

    # Range beyond line length
    test_command_output "cut -b 3-100 short" "cde" bash -c "echo 'abcde' | '$binary' -b 3-100"

    # Single byte beyond line length
    test_command_output "cut -b 100 short" "" bash -c "echo 'abcde' | '$binary' -b 100"

    # Overlapping ranges
    test_command_output "cut -b 1-3,2-4" "abcd" bash -c "echo 'abcde' | '$binary' -b 1-3,2-4"

    # Adjacent ranges
    test_command_output "cut -b 1-2,3-4" "abcd" bash -c "echo 'abcde' | '$binary' -b 1-2,3-4"

    # Unsorted ranges
    test_command_output "cut -b 3,1,5" "ace" bash -c "echo 'abcde' | '$binary' -b 3,1,5"

    echo -e "${CYAN}Testing stdin input...${NC}"

    # Basic stdin
    test_command_output "cut stdin -b 1-3" "abc" bash -c "echo 'abcde' | '$binary' -b 1-3"

    # Multiline stdin
    test_command_output "cut stdin multiline" $'abc\nfgh' bash -c "printf 'abcde\nfghij\n' | '$binary' -b 1-3"

    # Empty stdin
    test_command_output "cut empty stdin" "" bash -c "echo -n '' | '$binary' -b 1"

    # Stdin with dash
    test_command_output "cut stdin dash" "abc" bash -c "echo 'abcde' | '$binary' -b 1-3 -"

    echo -e "${CYAN}Testing -n multi-byte protection...${NC}"

    # -n flag prevents splitting multi-byte characters when used with -b
    # The euro sign € is 3 bytes in UTF-8: 0xE2 0x82 0xAC

    # -n -b 1 on a multi-byte character: should output nothing
    # (byte 1 is part of a multi-byte char, -n suppresses partial chars)
    local n_out="" n_err="" n_exit=""
    run_command n_cmd n_out n_err n_exit bash -c "printf '€abc' | '$binary' -n -b 1"
    if [[ $n_exit -eq 0 && -z "$n_out" ]]; then
        print_test_result "cut -n -b 1 suppresses partial multi-byte" "PASS"
    else
        print_test_result "cut -n -b 1 suppresses partial multi-byte" "FAIL" "Exit: $n_exit, output: '$n_out' (expected empty)"
    fi

    # -n -b 1-2 on 3-byte char: should not output partial character
    run_command n_cmd n_out n_err n_exit bash -c "printf '€abc' | '$binary' -n -b 1-2"
    if [[ $n_exit -eq 0 && -z "$n_out" ]]; then
        print_test_result "cut -n -b 1-2 suppresses partial 3-byte char" "PASS"
    else
        print_test_result "cut -n -b 1-2 suppresses partial 3-byte char" "FAIL" "Exit: $n_exit, output: '$n_out' (expected empty)"
    fi

    # -n -b 1-3 on 3-byte char: should output the full character
    run_command n_cmd n_out n_err n_exit bash -c "printf '€abc' | '$binary' -n -b 1-3"
    if [[ $n_exit -eq 0 && "$n_out" == "€" ]]; then
        print_test_result "cut -n -b 1-3 outputs full multi-byte char" "PASS"
    else
        print_test_result "cut -n -b 1-3 outputs full multi-byte char" "FAIL" "Got: '$n_out'"
    fi

    # Without -n, -b 1 should output the raw first byte
    run_command n_cmd n_out n_err n_exit bash -c "printf '€abc' | '$binary' -b 1"
    local n_out_bytes
    n_out_bytes=$(printf '%s' "$n_out" | wc -c)
    n_out_bytes=$(echo "$n_out_bytes" | tr -d ' ')
    if [[ $n_exit -eq 0 && "$n_out_bytes" -eq 1 ]]; then
        print_test_result "cut -b 1 without -n outputs single raw byte" "PASS"
    else
        print_test_result "cut -b 1 without -n outputs single raw byte" "FAIL" "Exit: $n_exit, output bytes: $n_out_bytes (expected 1)"
    fi

    # -n with ASCII content should work normally (no multi-byte to protect)
    test_command_output "cut -n -b 1-3 ASCII" "abc" bash -c "echo 'abcde' | '$binary' -n -b 1-3"

    # -n -b 4-6 should get 'abc' from '€abc' (bytes 4-6 are 'a','b','c')
    run_command n_cmd n_out n_err n_exit bash -c "printf '€abc' | '$binary' -n -b 4-6"
    if [[ $n_exit -eq 0 && "$n_out" == "abc" ]]; then
        print_test_result "cut -n -b 4-6 after multi-byte char" "PASS"
    else
        print_test_result "cut -n -b 4-6 after multi-byte char" "FAIL" "Got: '$n_out'"
    fi

    # Contrast test: -n vs no-n should produce different output for partial multi-byte
    local contrast_with_n="" contrast_without_n=""
    contrast_with_n=$(printf '€abc' | "$binary" -n -b 1 2>/dev/null) || true
    contrast_without_n=$(printf '€abc' | "$binary" -b 1 2>/dev/null) || true
    if [[ -z "$contrast_with_n" && -n "$contrast_without_n" ]]; then
        print_test_result "cut -n suppresses partial char, no -n outputs raw byte" "PASS"
    else
        print_test_result "cut -n suppresses partial char, no -n outputs raw byte" "FAIL" "with -n: '$contrast_with_n', without -n: '$contrast_without_n'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No mode specified
    test_command_exit_code "cut no mode" 2 "$binary" 2>/dev/null

    # Multiple modes
    test_command_exit_code "cut -b and -f" 2 "$binary" -b 1 -f 1 2>/dev/null

    # -s without -f
    test_command_exit_code "cut -s without -f" 2 "$binary" -b 1 -s 2>/dev/null

    # -d without -f
    test_command_exit_code "cut -d without -f" 2 "$binary" -b 1 -d: 2>/dev/null

    # Invalid range
    test_command_exit_code "cut invalid range 0" 2 bash -c "echo test | '$binary' -b 0 2>/dev/null"

    # Invalid flag
    test_command_exit_code "cut invalid flag" 2 "$binary" --invalid-flag 2>/dev/null

    # Non-existent file
    test_command_exit_code "cut nonexistent file" 1 "$binary" -b 1 /nonexistent_file_$$ 2>/dev/null

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX exit codes
    test_command_exit_code "cut POSIX success" 0 bash -c "echo test | '$binary' -b 1"
    test_command_exit_code "cut POSIX misuse" 2 "$binary" 2>/dev/null

    # POSIX default delimiter is tab
    test_command_output "cut POSIX default delim" "one" bash -c "printf 'one\ttwo\tthree' | '$binary' -f 1"

    # POSIX: lines without delimiter pass through (with -f, no -s)
    test_command_output "cut POSIX no delim passthrough" "no tabs here" bash -c "echo 'no tabs here' | '$binary' -f 1"

    echo -e "${CYAN}Testing multiple files...${NC}"

    # Multiple file arguments
    local file_a=$(create_temp_file "abcde")
    local file_b=$(create_temp_file "fghij")
    test_command_output "cut multiple files" $'abc\nfgh' "$binary" -b 1-3 "$file_a" "$file_b"

    echo -e "${CYAN}Final validation...${NC}"

    if [[ $TESTS_RUN -ge 40 ]]; then
        print_test_result "cut comprehensive test count" "PASS" "Executed $TESTS_RUN tests"
    else
        print_test_result "cut comprehensive test count" "FAIL" "Only executed $TESTS_RUN tests, expected 40+"
    fi

    echo -e "${CYAN}Testing error diagnostics on bad files...${NC}"

    # Regression test: cut must print error message for nonexistent files
    local cut_err_cmd cut_err_out cut_err_stderr cut_err_exit
    run_command cut_err_cmd cut_err_out cut_err_stderr cut_err_exit "$binary" -f1 /nonexistent/file
    if [[ $cut_err_exit -ne 0 ]]; then
        print_test_result "cut nonexistent file exits non-zero" "PASS"
    else
        print_test_result "cut nonexistent file exits non-zero" "FAIL" \
            "Expected non-zero exit, got $cut_err_exit"
    fi

    if [[ -n "$cut_err_stderr" ]]; then
        print_test_result "cut nonexistent file prints error" "PASS"
    else
        print_test_result "cut nonexistent file prints error" "FAIL" \
            "Expected non-empty stderr"
    fi

    if [[ "$cut_err_stderr" == *"/nonexistent/file"* ]]; then
        print_test_result "cut error mentions filename" "PASS"
    else
        print_test_result "cut error mentions filename" "FAIL" \
            "Expected stderr to contain '/nonexistent/file', got: '$cut_err_stderr'"
    fi

    # Regression test: --version output contains project name
    local cut_ver_out="" cut_ver_err="" cut_ver_exit=""
    run_command cut_ver_cmd cut_ver_out cut_ver_err cut_ver_exit "$binary" --version
    if [[ "$cut_ver_out" == *"vibeutils"* ]]; then
        print_test_result "cut --version contains vibeutils" "PASS"
    else
        print_test_result "cut --version contains vibeutils" "FAIL" \
            "Expected 'vibeutils' in version output, got: '$cut_ver_out'"
    fi

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}cut tests completed${NC}"
}

# Export the test function
export -f test_cut
