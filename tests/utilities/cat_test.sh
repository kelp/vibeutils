#!/usr/bin/env bash
# Comprehensive tests for cat utility
# Tests all flags and multi-file concatenation bugs

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_cat() {
    local util="cat"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic functionality...${NC}"
    
    # Basic file reading
    local test_file1=$(create_temp_file "Hello World")
    local test_file2=$(create_temp_file $'Line 1\nLine 2\nLine 3')
    local test_file3=$(create_temp_file "")  # Empty file
    local test_file4=$(create_temp_file $'Tabs\tand\tspaces  here')
    
    test_command_output "cat single file" "Hello World" "$binary" "$test_file1"
    test_command_output "cat multiline file" $'Line 1\nLine 2\nLine 3' "$binary" "$test_file2"
    test_command_output "cat empty file" "" "$binary" "$test_file3"
    
    # Test multiple file concatenation (cat outputs bytes exactly as they are)
    # Files created with echo -n have no trailing newline, so content concatenates directly
    test_command_output "cat two files" $'Hello WorldLine 1\nLine 2\nLine 3' "$binary" "$test_file1" "$test_file2"
    test_command_output "cat three files" $'Hello WorldLine 1\nLine 2\nLine 3' "$binary" "$test_file1" "$test_file2" "$test_file3"
    test_command_output "cat with empty in middle" $'Hello WorldLine 1\nLine 2\nLine 3' "$binary" "$test_file1" "$test_file3" "$test_file2"
    
    # Test stdin handling
    echo -e "${CYAN}Testing stdin functionality...${NC}"
    
    test_command_output "cat from stdin" "test input" bash -c "echo 'test input' | '$binary'"
    test_command_output "cat no args (stdin)" "stdin test" bash -c "echo 'stdin test' | '$binary'"
    test_command_output "cat dash arg (stdin)" "dash test" bash -c "echo 'dash test' | '$binary' -"
    
    # Test mixing files and stdin
    # File1 has no trailing newline, so stdin content starts on same line
    test_command_output "cat file then stdin" $'Hello Worldstdin content' bash -c "echo 'stdin content' | '$binary' '$test_file1' -"
    # stdin "echo" adds trailing newline, so File1 starts on new line
    test_command_output "cat stdin then file" $'stdin content\nHello World' bash -c "echo 'stdin content' | '$binary' - '$test_file1'"
    
    echo -e "${CYAN}Testing line numbering flags...${NC}"
    
    # Test -n flag (number all lines)
    test_command_output "cat -n basic" $'     1\tLine 1\n     2\tLine 2\n     3\tLine 3' "$binary" -n "$test_file2"
    test_command_output "cat -n empty file" "" "$binary" -n "$test_file3"
    
    local blank_file=$(create_temp_file $'Line 1\n\nLine 3\n\nLine 5')
    test_command_output "cat -n with blanks" $'     1\tLine 1\n     2\t\n     3\tLine 3\n     4\t\n     5\tLine 5' "$binary" -n "$blank_file"
    
    # Test -b flag (number non-blank lines only)
    test_command_output "cat -b with blanks" $'     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5' "$binary" -b "$blank_file"
    test_command_output "cat -b all blank" "" "$binary" -b <(echo -e '\n\n\n')
    
    # Test -b overrides -n
    test_command_output "cat -n -b conflict" $'     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5' "$binary" -n -b "$blank_file"
    
    echo -e "${CYAN}Testing visual display flags...${NC}"
    
    # Test -E flag (show line ends) - $ appears before \n only, not at end of file
    test_command_output "cat -E basic" $'Line 1$\nLine 2$\nLine 3' "$binary" -E "$test_file2"
    test_command_output "cat -E with tabs" 'Tabs	and	spaces  here' "$binary" -E "$test_file4"
    
    # Test -T flag (show tabs)
    test_command_output "cat -T basic" $'Tabs^Iand^Ispaces  here' "$binary" -T "$test_file4"
    
    # Test -v flag (show non-printing chars)
    local special_file=$(create_temp_file $'Hello\x01World\x7F\x80Test')
    test_command_output_pattern "cat -v non-printing" "Hello.*World.*Test" "$binary" -v "$special_file"
    
    # Test -A flag (equivalent to -vET)
    test_command_output_pattern "cat -A combination" ".*\\^I.*\\$" "$binary" -A <(echo -e 'line1\tline2')
    
    # Test -e flag (equivalent to -vE)
    test_command_output_pattern "cat -e combination" ".*\\$" "$binary" -e <(echo "test line")
    
    # Test -t flag (equivalent to -vT)
    test_command_output_pattern "cat -t combination" ".*\\^I.*" "$binary" -t <(echo -e 'tab\there')
    
    echo -e "${CYAN}Testing blank line handling...${NC}"
    
    # Test -s flag (squeeze repeated blank lines)
    local many_blanks=$(create_temp_file $'Line 1\n\n\n\nLine 2\n\n\n\nLine 3')
    test_command_output "cat -s squeeze blanks" $'Line 1\n\nLine 2\n\nLine 3' "$binary" -s "$many_blanks"
    
    # Test -s with only blank lines
    test_command_output_exact "cat -s only blanks" $'\n' bash -c "printf '\\n\\n\\n\\n\\n' | '$binary' -s"
    
    test_command_output "cat -s no blanks" $'Line 1\nLine 2\nLine 3' "$binary" -s "$test_file2"
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Test common flag combinations
    test_command_output "cat -ns combination" $'     1\tLine 1\n     2\t\n     3\tLine 2\n     4\t\n     5\tLine 3' "$binary" -n -s "$many_blanks"
    test_command_output "cat -bs combination" $'     1\tLine 1\n\n     2\tLine 2\n\n     3\tLine 3' "$binary" -b -s "$many_blanks"
    test_command_output "cat -ET combination" 'Tabs^Iand^Ispaces  here' "$binary" -E -T "$test_file4"
    
    echo -e "${CYAN}Testing edge cases and bug scenarios...${NC}"
    
    # Test with non-existent files
    test_command_fails "cat non-existent file" "$binary" "/path/that/does/not/exist"
    
    # Test with directory (should fail)
    local test_dir=$(create_temp_dir)
    test_command_fails "cat directory" "$binary" "$test_dir"
    
    # Test with special files
    test_command_succeeds "cat /dev/null" "$binary" "/dev/null"
    
    # Test very large file handling
    local large_file=$(create_temp_file "$(printf 'line %d\n' {1..1000})")
    local large_output=$("$binary" "$large_file" 2>/dev/null)
    if [[ $(echo "$large_output" | wc -l) -eq 1000 ]]; then
        print_test_result "cat large file (1000 lines)" "PASS"
    else
        print_test_result "cat large file (1000 lines)" "FAIL" "Got $(echo "$large_output" | wc -l) lines"
    fi
    
    # Test binary file handling
    local binary_file=$(create_temp_file $'\x00\x01\x02\xFF\xFE\xFD')
    if "$binary" "$binary_file" >/dev/null 2>&1; then
        print_test_result "cat binary file" "PASS"
    else
        print_test_result "cat binary file" "FAIL" "Failed to read binary data"
    fi
    
    # Test multiple file concatenation bugs (order preservation)
    local file_a=$(create_temp_file "A")
    local file_b=$(create_temp_file "B") 
    local file_c=$(create_temp_file "C")
    # Files "A", "B", "C" have no trailing newlines, so they concatenate directly
    test_command_output "cat order preservation" "ABC" "$binary" "$file_a" "$file_b" "$file_c"
    test_command_output "cat reverse order" "CBA" "$binary" "$file_c" "$file_b" "$file_a"

    # Test that flags work with multiple files (cat renumbers at each file boundary)
    test_command_output "cat -n multiple files" $'     1\tA     2\tB     3\tC' "$binary" -n "$file_a" "$file_b" "$file_c"
    
    # Test file with final newline vs without
    local file_with_nl=$(create_temp_file $'line1\nline2\n')
    local file_without_nl=$(create_temp_file 'line3')
    test_command_output "cat files newline handling" $'line1\nline2\nline3' "$binary" "$file_with_nl" "$file_without_nl"
    
    echo -e "${CYAN}Testing performance edge cases...${NC}"
    
    # Test reading from multiple stdin references
    test_command_output "cat multiple stdin refs" "test" bash -c "echo 'test' | '$binary' - - -"
    
    # Test mixed files and stdin multiple times
    # A has no trailing newline, stdin "echo" adds \n, B has no \n, second - is empty (stdin drained)
    test_command_output "cat complex mixing" $'Astdin\nBC' bash -c "echo 'stdin' | '$binary' '$file_a' - '$file_b' - '$file_c'"
    
    echo -e "${CYAN}Testing GNU compatibility...${NC}"
    
    # Test -u flag (ignored for compatibility)
    test_command_output "cat -u ignored flag" "Hello World" "$binary" -u "$test_file1"
    
    # Test long option equivalents
    test_command_output "cat --number" $'     1\tLine 1\n     2\tLine 2\n     3\tLine 3' "$binary" --number "$test_file2"
    test_command_output "cat --number-nonblank" $'     1\tLine 1\n\n     2\tLine 3\n\n     3\tLine 5' "$binary" --number-nonblank "$blank_file"
    test_command_output "cat --show-ends" $'Line 1$\nLine 2$\nLine 3' "$binary" --show-ends "$test_file2"
    test_command_output "cat --show-tabs" $'Tabs^Iand^Ispaces  here' "$binary" --show-tabs "$test_file4"
    test_command_output "cat --squeeze-blank" $'Line 1\n\nLine 2\n\nLine 3' "$binary" --squeeze-blank "$many_blanks"
    test_command_output "cat --show-all" 'Tabs^Iand^Ispaces  here' "$binary" --show-all "$test_file4"
    
    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # Test permission denied (create unreadable file)
    local unreadable_file=$(create_temp_file "secret")
    chmod 000 "$unreadable_file"
    test_command_fails "cat permission denied" "$binary" "$unreadable_file"
    chmod 644 "$unreadable_file"  # cleanup
    
    # Test interrupted reads (simulated)
    # This is hard to test portably, so just ensure no crash
    test_command_succeeds "cat /dev/null multiple" "$binary" /dev/null /dev/null /dev/null
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX-required behaviors
    test_command_output "POSIX: cat single file" "Hello World" "$binary" "$test_file1"
    test_command_output "POSIX: cat multiple files" $'Hello WorldLine 1\nLine 2\nLine 3' "$binary" "$test_file1" "$test_file2"
    test_command_output "POSIX: cat stdin with -" "stdin test" bash -c "echo 'stdin test' | '$binary' -"
    
    # Test exit codes
    test_command_exit_code "cat success exit code" 0 "$binary" "$test_file1"
    test_command_exit_code "cat failure exit code" 1 "$binary" "/nonexistent/file" 2>/dev/null || true

    # GNU cat prints the missing-operand diagnostic unquoted:
    # "cat: /nonexistent/file: No such file or directory". Pinned against
    # GNU coreutils 9.5 (LC_ALL=C). Verify our operand stays bare (no
    # quotes) to keep parity.
    local nonexist_stderr
    nonexist_stderr=$("$binary" "/nonexistent/file" 2>&1 >/dev/null)
    if [[ "$nonexist_stderr" == *"cat: /nonexistent/file: No such file or directory"* ]]; then
        print_test_result "cat nonexistent file operand stays unquoted" "PASS"
    else
        print_test_result "cat nonexistent file operand stays unquoted" "FAIL" \
            "Expected bare 'cat: /nonexistent/file: No such file or directory', got: '$nonexist_stderr'"
    fi

    # GNU cat also prints the "Is a directory" diagnostic unquoted:
    # "cat: DIR: Is a directory". Pinned against GNU coreutils 9.5
    # (LC_ALL=C).
    local dir_arg
    dir_arg=$(create_temp_dir)
    local dir_stderr
    dir_stderr=$("$binary" "$dir_arg" 2>&1 >/dev/null)
    if [[ "$dir_stderr" == *"cat: $dir_arg: Is a directory"* ]]; then
        print_test_result "cat directory operand stays unquoted" "PASS"
    else
        print_test_result "cat directory operand stays unquoted" "FAIL" \
            "Expected bare 'cat: $dir_arg: Is a directory', got: '$dir_stderr'"
    fi

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: cat -v should show non-printing characters
    # Safety net for dead code removal in cat utility
    local reg_special_file=$(create_temp_file $'\x01\x02\x03')
    local reg_v_output
    reg_v_output=$("$binary" -v "$reg_special_file" 2>/dev/null)
    if [[ "$reg_v_output" =~ "^A" && "$reg_v_output" =~ "^B" && "$reg_v_output" =~ "^C" ]]; then
        print_test_result "cat -v shows non-printing chars (regression)" "PASS"
    else
        print_test_result "cat -v shows non-printing chars (regression)" "FAIL" \
            "Expected ^A^B^C, got: '$reg_v_output'"
    fi

    echo -e "${CYAN}Testing audit: -E with CRLF line endings...${NC}"

    # BUG: cat -E should render trailing \r before \n as "^M$" not raw "\r$".
    # GNU cat -E on "test\r\n" produces "test^M$\n".
    # Our implementation writes the raw \r byte then "$\n".
    local crlf_file="$TEMP_DIR/cat_crlf.txt"
    printf 'test\r\n' > "$crlf_file"

    local crlf_out crlf_err crlf_exit crlf_cmd
    run_command crlf_cmd crlf_out crlf_err crlf_exit "$binary" -E "$crlf_file"

    # Use od to inspect the actual bytes
    local crlf_hex
    crlf_hex=$("$binary" -E "$crlf_file" | od -c | head -1)
    # Expected bytes: t e s t ^ M $ \n
    # The "^M" is two characters: ^ and M
    if [[ "$crlf_hex" == *"^"*"M"*"$"* ]] && [[ "$crlf_hex" != *$'\r'* ]] && [[ "$crlf_hex" != *"\\r"* ]]; then
        print_test_result "cat -E CRLF shows ^M$ (od check)" "PASS"
    else
        print_test_result "cat -E CRLF shows ^M$ (od check)" "FAIL" \
            "Expected '^M$' in output. od output: $crlf_hex"
    fi

    # Direct string check: output should contain "^M$" not a raw \r
    if [[ "$crlf_out" == *"^M\$"* ]]; then
        print_test_result "cat -E CRLF ^M$ in output" "PASS"
    else
        print_test_result "cat -E CRLF ^M$ in output" "FAIL" \
            "Expected '^M\$' in output. Got: '$crlf_out'"
    fi

    # Multiple CRLF lines
    local multi_crlf="$TEMP_DIR/cat_multi_crlf.txt"
    printf 'line1\r\nline2\r\nline3\n' > "$multi_crlf"
    local multi_out multi_err multi_exit multi_cmd
    run_command multi_cmd multi_out multi_err multi_exit "$binary" -E "$multi_crlf"

    # Count how many "^M$" appear (should be 2: line1 and line2 have CRLF)
    local cr_count
    cr_count=$(echo "$multi_out" | grep -o '\^M\$' | wc -l)
    if [[ $cr_count -eq 2 ]]; then
        print_test_result "cat -E multiple CRLF lines show ^M$" "PASS"
    else
        print_test_result "cat -E multiple CRLF lines show ^M$" "FAIL" \
            "Expected 2 occurrences of ^M\$, got $cr_count. Output: '$multi_out'"
    fi
}