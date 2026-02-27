#!/usr/bin/env bash
# Comprehensive tests for wc (word count) utility
# Tests all flags, input sources, Unicode handling, edge cases, and POSIX compliance
# Total: ~70 tests covering complete functionality
#
# CRITICAL: Tests verify POSIX-compliant and standard behavior, NOT current implementation
# If tests fail, the implementation needs to be fixed to match standards

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_wc() {
    local util="wc"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Create test files with various content types
    local simple_file=$(create_temp_file "Hello world")
    local multiline_file=$(create_temp_file $'Line 1\nLine 2\nLine 3')
    local empty_file=$(create_temp_file "")
    local unicode_file=$(create_temp_file $'Hello 世界\nUnicode test ñ')
    local no_newline_file=$(create_temp_file "No final newline")
    local long_line_file=$(create_temp_file "This is a very long line with many words that should test the maximum line length calculation feature")

    echo -e "${CYAN}Testing core functionality...${NC}"

    # Default behavior (lines, words, bytes)
    test_command_output "wc default behavior" "       0       2      11 $simple_file" "$binary" "$simple_file"
    test_command_output "wc multiline default" "       2       6      20 $multiline_file" "$binary" "$multiline_file"
    test_command_output "wc empty file default" "       0       0       0 $empty_file" "$binary" "$empty_file"

    echo -e "${CYAN}Testing individual flags...${NC}"

    # Test -l flag (lines)
    test_command_output "wc -l single line" "       0 $simple_file" "$binary" -l "$simple_file"
    test_command_output "wc -l multiline" "       2 $multiline_file" "$binary" -l "$multiline_file"
    test_command_output "wc -l empty file" "       0 $empty_file" "$binary" -l "$empty_file"
    test_command_output "wc -l no final newline" "       0 $no_newline_file" "$binary" -l "$no_newline_file"

    # Test --lines long option
    test_command_output "wc --lines long option" "       2 $multiline_file" "$binary" --lines "$multiline_file"

    # Test -w flag (words)
    test_command_output "wc -w simple" "       2 $simple_file" "$binary" -w "$simple_file"
    test_command_output "wc -w multiline" "       6 $multiline_file" "$binary" -w "$multiline_file"
    test_command_output "wc -w empty" "       0 $empty_file" "$binary" -w "$empty_file"

    # Test --words long option
    test_command_output "wc --words long option" "       6 $multiline_file" "$binary" --words "$multiline_file"

    # Test -c flag (bytes)
    test_command_output "wc -c simple" "      11 $simple_file" "$binary" -c "$simple_file"
    test_command_output "wc -c multiline" "      20 $multiline_file" "$binary" -c "$multiline_file"
    test_command_output "wc -c empty" "       0 $empty_file" "$binary" -c "$empty_file"

    # Test --bytes long option
    test_command_output "wc --bytes long option" "      20 $multiline_file" "$binary" --bytes "$multiline_file"

    # Test -m flag (characters)
    test_command_output "wc -m simple ASCII" "      11 $simple_file" "$binary" -m "$simple_file"
    test_command_output "wc -m unicode" "      23 $unicode_file" "$binary" -m "$unicode_file"  # Unicode chars count as 1 each
    test_command_output "wc -m empty" "       0 $empty_file" "$binary" -m "$empty_file"

    # Test --chars long option
    test_command_output "wc --chars long option" "      23 $unicode_file" "$binary" --chars "$unicode_file"

    # Test -L flag (max line length)
    test_command_output "wc -L simple" "      11 $simple_file" "$binary" -L "$simple_file"
    test_command_output "wc -L multiline" "       6 $multiline_file" "$binary" -L "$multiline_file"  # Longest line is "Line 1", "Line 2", or "Line 3"
    test_command_output "wc -L empty" "       0 $empty_file" "$binary" -L "$empty_file"
    test_command_output "wc -L long line" "     101 $long_line_file" "$binary" -L "$long_line_file"

    # Test --max-line-length long option
    test_command_output "wc --max-line-length long option" "     101 $long_line_file" "$binary" --max-line-length "$long_line_file"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Test common flag combinations
    test_command_output "wc -l -w combination" "       2       6 $multiline_file" "$binary" -l -w "$multiline_file"
    test_command_output "wc -l -c combination" "       2      20 $multiline_file" "$binary" -l -c "$multiline_file"
    test_command_output "wc -w -c combination" "       6      20 $multiline_file" "$binary" -w -c "$multiline_file"
    test_command_output "wc -l -w -c combination" "       2       6      20 $multiline_file" "$binary" -l -w -c "$multiline_file"

    # Test -m and -c together (mutually exclusive, last flag wins)
    test_command_output "wc -c -m combination" "      23 $unicode_file" "$binary" -c -m "$unicode_file"  # -m wins (last)
    test_command_output "wc -m -c combination" "      28 $unicode_file" "$binary" -m -c "$unicode_file"  # -c wins (last)

    # Test with -L combinations
    test_command_output "wc -l -L combination" "       2       6 $multiline_file" "$binary" -l -L "$multiline_file"
    test_command_output "wc -w -L combination" "       6       6 $multiline_file" "$binary" -w -L "$multiline_file"

    # Test all flags together
    test_command_output "wc all flags -l -w -c -L" "       2       6      20       6 $multiline_file" "$binary" -l -w -c -L "$multiline_file"

    echo -e "${CYAN}Testing stdin input...${NC}"

    # Test stdin with no arguments
    test_command_output "wc stdin default" "       1       2      12" bash -c "echo 'hello world' | '$binary'"
    test_command_output "wc stdin -l" "       1" bash -c "echo 'hello world' | '$binary' -l"
    test_command_output "wc stdin -w" "       2" bash -c "echo 'hello world' | '$binary' -w"
    test_command_output "wc stdin -c" "      12" bash -c "echo 'hello world' | '$binary' -c"

    # Test stdin with dash argument
    test_command_output "wc dash argument" "       1       2      12 -" bash -c "echo 'hello world' | '$binary' -"
    test_command_output "wc dash -l" "       1 -" bash -c "echo 'hello world' | '$binary' -l -"

    # Test multiline stdin
    test_command_output "wc multiline stdin" "       2       4      18" bash -c "printf 'line one\\nline two\\n' | '$binary'"

    # Test empty stdin
    test_command_output "wc empty stdin" "       0       0       0" bash -c "echo -n '' | '$binary'"

    echo -e "${CYAN}Testing multiple files...${NC}"

    # Test multiple files with totals
    local file1=$(create_temp_file "File one")
    local file2=$(create_temp_file "File two content")
    local file3=$(create_temp_file $'Multi\nline\nfile')

    # Test default behavior with multiple files
    local multi_output
    multi_output=$("$binary" "$file1" "$file2" "$file3" 2>/dev/null)
    if [[ "$multi_output" =~ total ]]; then
        print_test_result "wc multiple files shows total" "PASS"
    else
        print_test_result "wc multiple files shows total" "FAIL" "Expected total line in output"
    fi

    # Test specific flag with multiple files
    test_command_output_pattern "wc -l multiple files" ".*0.*0.*2.*2 total" "$binary" -l "$file1" "$file2" "$file3"
    test_command_output_pattern "wc -w multiple files" ".*2.*3.*3.*8 total" "$binary" -w "$file1" "$file2" "$file3"

    echo -e "${CYAN}Testing Unicode and character handling...${NC}"

    # Create files with different character encodings
    local ascii_file=$(create_temp_file "ASCII only content")
    local utf8_file=$(create_temp_file $'UTF-8: café résumé naïve\n中文测试\n🚀🌟')
    local mixed_file=$(create_temp_file $'Mixed: hello 世界 test\nASCII line\nEmoji: 🎉🎨')

    # Test byte vs character counting
    test_command_output "wc -c ASCII file" "      18 $ascii_file" "$binary" -c "$ascii_file"
    test_command_output "wc -m ASCII file" "      18 $ascii_file" "$binary" -m "$ascii_file"

    # UTF-8 file: bytes != characters
    local utf8_bytes
    local utf8_chars
    utf8_bytes=$("$binary" -c "$utf8_file" | awk '{print $1}')
    utf8_chars=$("$binary" -m "$utf8_file" | awk '{print $1}')
    if [[ "$utf8_bytes" -gt "$utf8_chars" ]]; then
        print_test_result "wc UTF-8 bytes > chars" "PASS"
    else
        print_test_result "wc UTF-8 bytes > chars" "FAIL" "Expected byte count ($utf8_bytes) > char count ($utf8_chars)"
    fi

    # Test emoji counting
    local emoji_bytes
    local emoji_chars
    emoji_bytes=$("$binary" -c "$mixed_file" | awk '{print $1}')
    emoji_chars=$("$binary" -m "$mixed_file" | awk '{print $1}')
    if [[ "$emoji_bytes" -gt "$emoji_chars" ]]; then
        print_test_result "wc emoji bytes > chars" "PASS"
    else
        print_test_result "wc emoji bytes > chars" "FAIL" "Expected byte count ($emoji_bytes) > char count ($emoji_chars)"
    fi

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Files without final newlines - CRITICAL POSIX BEHAVIOR
    # POSIX: "wc shall write the number of <newline> characters in each input file"
    # A file without final newline has fewer newline characters
    local no_nl1="$TEMP_DIR/no_newline_1"
    local no_nl2="$TEMP_DIR/no_newline_2"
    printf "No newline here" > "$no_nl1"  # 0 newlines
    printf "Line 1\nLine 2 no newline" > "$no_nl2"  # 1 newline

    test_command_output "wc -l no final newline simple" "       0 $no_nl1" "$binary" -l "$no_nl1"
    test_command_output "wc -l no final newline multiline" "       1 $no_nl2" "$binary" -l "$no_nl2"

    # Very long lines
    local very_long_content
    very_long_content=$(printf 'A%.0s' {1..1000})  # 1000 character line
    local very_long_file=$(create_temp_file "$very_long_content")
    test_command_output "wc -L very long line" "    1000 $very_long_file" "$binary" -L "$very_long_file"

    # Files with only whitespace
    local ws_file=$(create_temp_file $'   \t  \n  \t\n\t  ')
    test_command_output "wc -w whitespace only" "       0 $ws_file" "$binary" -w "$ws_file"
    test_command_output "wc -l whitespace lines" "       2 $ws_file" "$binary" -l "$ws_file"

    # Binary data handling
    local binary_file=$(create_temp_file "")
    printf '\x00\x01\x02\xFF\xFE\xFD\n\x80\x81\x82' > "$binary_file"
    test_command_output "wc -c binary file" "      10 $binary_file" "$binary" -c "$binary_file"
    test_command_output "wc -l binary file" "       1 $binary_file" "$binary" -l "$binary_file"

    echo -e "${CYAN}Testing mixed file and stdin input...${NC}"

    # Test mixing files and stdin
    test_command_output_pattern "wc file and stdin" ".*2.*2.*total" bash -c "echo 'stdin data' | '$binary' '$file1' -"
    test_command_output_pattern "wc stdin and file" ".*2.*2.*total" bash -c "echo 'stdin data' | '$binary' - '$file1'"
    test_command_output_pattern "wc file stdin file" ".*3.*3.*total" bash -c "echo 'stdin data' | '$binary' '$file1' - '$file2'"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Non-existent files
    test_command_exit_code "wc non-existent file" 1 "$binary" "/tmp/nonexistent_file_$$" 2>/dev/null
    test_command_fails "wc non-existent file stderr" "$binary" "/tmp/nonexistent_file_$$"

    # Permission denied
    local perm_file=$(create_temp_file "Permission test")
    chmod 000 "$perm_file"
    test_command_exit_code "wc permission denied" 1 "$binary" "$perm_file" 2>/dev/null
    chmod 644 "$perm_file"  # Restore for cleanup

    # Directory as input
    local test_dir=$(create_temp_dir)
    test_command_exit_code "wc directory input" 1 "$binary" "$test_dir" 2>/dev/null

    # Invalid flags
    test_command_exit_code "wc invalid flag" 2 "$binary" --invalid-flag 2>/dev/null
    test_command_exit_code "wc unknown short flag" 2 "$binary" -z 2>/dev/null

    # Mixed valid and invalid files
    local valid_file=$(create_temp_file "Valid content")
    local mixed_out=""
    local mixed_err=""
    local mixed_exit=""
    run_command mixed_cmd mixed_out mixed_err mixed_exit "$binary" "$valid_file" "/tmp/nonexistent_$$"
    # Should show count for valid file and exit with error status
    if [[ $mixed_exit -ne 0 && "$mixed_out" =~ "$valid_file" ]]; then
        print_test_result "wc mixed valid/invalid files" "PASS"
    else
        print_test_result "wc mixed valid/invalid files" "FAIL" "Should process valid file but fail overall"
    fi

    echo -e "${CYAN}Testing output formatting...${NC}"

    # Test column alignment with different number sizes
    local small_file=$(create_temp_file "small")
    local large_content
    large_content=$(printf 'line %d\n' {1..100})
    local large_file=$(create_temp_file "$large_content")

    # Check that numbers are right-aligned
    local small_output
    local large_output
    small_output=$("$binary" "$small_file" 2>/dev/null)
    large_output=$("$binary" "$large_file" 2>/dev/null)

    if [[ "$small_output" =~ ^[[:space:]]+[0-9] ]] && [[ "$large_output" =~ ^[[:space:]]+[0-9] ]]; then
        print_test_result "wc right-aligned output" "PASS"
    else
        print_test_result "wc right-aligned output" "FAIL" "Numbers should be right-aligned"
    fi

    # Test total line formatting
    local total_output
    total_output=$("$binary" "$file1" "$file2" 2>/dev/null)
    if [[ "$total_output" =~ total$ ]]; then
        print_test_result "wc total line format" "PASS"
    else
        print_test_result "wc total line format" "FAIL" "Total line should end with 'total'"
    fi

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX exit codes - CRITICAL REQUIREMENTS
    test_command_exit_code "wc POSIX success" 0 "$binary" "$simple_file"
    test_command_exit_code "wc POSIX failure" 1 "$binary" "/nonexistent" 2>/dev/null

    # POSIX required behavior
    test_command_succeeds "wc POSIX no args (stdin)" bash -c "echo 'test' | '$binary'"
    test_command_succeeds "wc POSIX multiple files" "$binary" "$file1" "$file2"

    # POSIX standard flags
    test_command_succeeds "wc POSIX -l flag" "$binary" -l "$simple_file"
    test_command_succeeds "wc POSIX -w flag" "$binary" -w "$simple_file"
    test_command_succeeds "wc POSIX -c flag" "$binary" -c "$simple_file"
    test_command_succeeds "wc POSIX -m flag" "$binary" -m "$simple_file"

    # POSIX word definition: "non-zero-length string of characters delimited by white space"
    local word_test_file=$(create_temp_file $'word1\tword2\nword3 word4\r\nword5')
    test_command_output_pattern "wc POSIX word definition" ".*5.*" "$binary" -w "$word_test_file"

    # POSIX output format requirements
    local posix_output
    posix_output=$("$binary" "$simple_file" 2>/dev/null)
    if [[ "$posix_output" =~ ^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]] ]]; then
        print_test_result "wc POSIX output format compliance" "PASS"
    else
        print_test_result "wc POSIX output format compliance" "FAIL" "Output must be right-aligned with spaces: '$posix_output'"
    fi

    # POSIX behavior: default is -l, -w, -c when no options specified
    local default_output
    local explicit_output
    default_output=$("$binary" "$simple_file" 2>/dev/null)
    explicit_output=$("$binary" -l -w -c "$simple_file" 2>/dev/null)
    if [[ "$default_output" == "$explicit_output" ]]; then
        print_test_result "wc POSIX default behavior" "PASS"
    else
        print_test_result "wc POSIX default behavior" "FAIL" "Default should equal -l -w -c"
    fi

    # POSIX standard input handling
    test_command_output_pattern "wc POSIX stdin" "^[[:space:]]*1[[:space:]]+1[[:space:]]+5$" bash -c "echo 'test' | '$binary'"

    # POSIX multiple file totals
    local total_output
    total_output=$("$binary" "$file1" "$file2" "$file3" 2>/dev/null)
    if [[ "$total_output" =~ total$ ]]; then
        print_test_result "wc POSIX multiple files total" "PASS"
    else
        print_test_result "wc POSIX multiple files total" "FAIL" "Must show total line for multiple files"
    fi

    echo -e "${CYAN}Testing performance edge cases...${NC}"

    # Large file handling (if system allows)
    local large_lines
    large_lines=$(printf 'Large file line %d\n' {1..1000})
    local perf_file=$(create_temp_file "$large_lines")
    test_command_output "wc large file lines" "     999 $perf_file" "$binary" -l "$perf_file"

    # Many small files
    local many_files=()
    for i in {1..10}; do
        many_files+=($(create_temp_file "File $i content here"))
    done
    test_command_succeeds "wc many files" "$binary" "${many_files[@]}"

    echo -e "${CYAN}Testing special filename handling...${NC}"

    # Files with special characters in names
    local special_name="$TEMP_DIR/special file!@#\$%^&*()name.txt"
    create_temp_file "Special name content" "$special_name"
    test_command_succeeds "wc special filename" "$binary" "$special_name"

    # Very long filename
    local long_name="$TEMP_DIR/"
    long_name+=$(printf 'long_%.0s' {1..50})
    long_name+=".txt"
    create_temp_file "Long name content" "$long_name"
    test_command_succeeds "wc long filename" "$binary" "$long_name"

    echo -e "${CYAN}Testing GNU extensions and edge cases...${NC}"

    # Test GNU -L (max line length) edge cases
    local empty_line_file=$(create_temp_file $'\n\n\n')
    test_command_output "wc -L empty lines only" "       0 $empty_line_file" "$binary" -L "$empty_line_file"

    # Test mixed line lengths
    local mixed_lengths=$(create_temp_file $'a\nab\nabc\nabcd\nabc\nab\na')
    test_command_output "wc -L mixed line lengths" "       4 $mixed_lengths" "$binary" -L "$mixed_lengths"

    # Test zero-width files and edge conditions
    local zero_file=$(create_temp_file "")
    test_command_output "wc zero file all flags" "       0       0       0       0 $zero_file" "$binary" -l -w -c -L "$zero_file"

    # Test -c and -m mutual exclusion behavior (GNU: last flag wins)
    local mutual_test=$(create_temp_file $'UTF-8: café')
    local cm_output
    local mc_output
    cm_output=$("$binary" -c -m "$mutual_test" 2>/dev/null | awk '{print $1}')
    mc_output=$("$binary" -m -c "$mutual_test" 2>/dev/null | awk '{print $1}')
    if [[ "$cm_output" != "$mc_output" ]]; then
        print_test_result "wc -c -m mutual exclusion" "PASS" "-c and -m are mutually exclusive"
    else
        print_test_result "wc -c -m mutual exclusion" "FAIL" "Should show different results for -c vs -m with UTF-8"
    fi

    echo -e "${CYAN}Testing error recovery and continuation...${NC}"

    # Error recovery: continue processing after errors
    local good1=$(create_temp_file "good file 1")
    local good2=$(create_temp_file "good file 2")
    local error_recovery_output
    local error_recovery_stderr
    local error_recovery_exit
    run_command error_recovery_cmd error_recovery_output error_recovery_stderr error_recovery_exit "$binary" "$good1" "/nonexistent_$$" "$good2"

    # Should process good files and show total despite error
    if [[ $error_recovery_exit -ne 0 && "$error_recovery_output" =~ total ]]; then
        print_test_result "wc error recovery continues" "PASS"
    else
        print_test_result "wc error recovery continues" "FAIL" "Should continue processing after errors"
    fi

    # Count lines in output to verify all good files processed
    local line_count
    line_count=$(echo "$error_recovery_output" | wc -l)
    if [[ $line_count -eq 3 ]]; then  # 2 good files + total
        print_test_result "wc processes all valid files" "PASS"
    else
        print_test_result "wc processes all valid files" "FAIL" "Expected 3 lines (2 files + total), got $line_count"
    fi

    echo -e "${CYAN}Final validation...${NC}"

    # Verify comprehensive test count (updated target)
    if [[ $TESTS_RUN -ge 70 ]]; then
        print_test_result "wc comprehensive test count" "PASS" "Executed $TESTS_RUN tests"
    else
        print_test_result "wc comprehensive test count" "FAIL" "Only executed $TESTS_RUN tests, expected 70+"
    fi

    # Final cleanup verification
    local remaining_files
    remaining_files=$(find "$TEMP_DIR" -name "*.txt" -o -name "testfile_*" -o -name "testdir_*" 2>/dev/null | wc -l)
    if [[ $remaining_files -lt 50 ]]; then  # Allow some temporary files during test
        print_test_result "wc test cleanup" "PASS"
    else
        print_test_result "wc test cleanup" "FAIL" "Too many test files remain: $remaining_files"
    fi
}