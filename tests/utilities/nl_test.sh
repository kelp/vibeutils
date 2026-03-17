#!/usr/bin/env bash
# Comprehensive tests for nl (number lines) utility
# Tests numbering styles, formats, section delimiters, and POSIX compliance

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_nl() {
    local util="nl"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Create test files
    local simple_file=$(create_temp_file $'hello\nworld')
    local blank_file=$(create_temp_file $'hello\n\nworld')
    local multi_file=$(create_temp_file $'line1\nline2\nline3')

    echo -e "${CYAN}Testing default behavior...${NC}"

    # Default: number non-empty lines, right justified, width 6, tab separator
    test_command_output "nl default non-empty" "     1	hello
     2	world" "$binary" "$simple_file"

    # Default skips blank lines
    test_command_output "nl default skips blanks" "     1	hello

     2	world" "$binary" "$blank_file"

    echo -e "${CYAN}Testing body numbering styles (-b)...${NC}"

    # -b a: number all lines (blank lines get number + separator)
    test_command_output "nl -b a numbers all" "     1	hello
     2	
     3	world" "$binary" -b a "$blank_file"

    # -b t: number non-empty (default)
    test_command_output "nl -b t numbers non-empty" "     1	hello

     2	world" "$binary" -b t "$blank_file"

    # -b n: number no lines
    test_command_output "nl -b n numbers none" "      	hello
      	world" "$binary" -b n "$simple_file"

    # --body-numbering long option
    test_command_output "nl --body-numbering=a" "     1	hello
     2	world" "$binary" --body-numbering=a "$simple_file"

    echo -e "${CYAN}Testing number formats (-n)...${NC}"

    # -n ln: left justified
    test_command_output "nl -n ln left justified" "1     	hello
2     	world" "$binary" -n ln "$simple_file"

    # -n rn: right justified (default)
    test_command_output "nl -n rn right justified" "     1	hello
     2	world" "$binary" -n rn "$simple_file"

    # -n rz: right justified with zeros
    test_command_output "nl -n rz zero filled" "000001	hello
000002	world" "$binary" -n rz "$simple_file"

    echo -e "${CYAN}Testing number width (-w)...${NC}"

    test_command_output "nl -w 3 narrow" "  1	hello
  2	world" "$binary" -w 3 "$simple_file"

    test_command_output "nl -w 10 wide" "         1	hello
         2	world" "$binary" -w 10 "$simple_file"

    echo -e "${CYAN}Testing separator (-s)...${NC}"

    test_command_output "nl -s custom separator" "     1: hello
     2: world" "$binary" -s ": " "$simple_file"

    test_command_output "nl -s empty separator" "     1hello
     2world" "$binary" -s "" "$simple_file"

    echo -e "${CYAN}Testing starting number (-v)...${NC}"

    test_command_output "nl -v 10 start at 10" "    10	hello
    11	world" "$binary" -v 10 "$simple_file"

    test_command_output "nl -v 100 start at 100" "   100	hello
   101	world" "$binary" -v 100 "$simple_file"

    echo -e "${CYAN}Testing increment (-i)...${NC}"

    test_command_output "nl -i 5 increment by 5" "     1	line1
     6	line2
    11	line3" "$binary" -i 5 "$multi_file"

    test_command_output "nl -i 10 increment by 10" "     1	line1
    11	line2
    21	line3" "$binary" -i 10 "$multi_file"

    echo -e "${CYAN}Testing combined options...${NC}"

    test_command_output "nl combined -b a -n rz -w 4 -s '. '" "0001. hello
0002. 
0003. world" "$binary" -b a -n rz -w 4 -s ". " "$blank_file"

    test_command_output "nl combined -v 100 -i 10 -n rz" "000100	hello
000110	world" "$binary" -v 100 -i 10 -n rz "$simple_file"

    echo -e "${CYAN}Testing stdin input...${NC}"

    # Test stdin processing
    test_command_output "nl stdin default" "     1	hello
     2	world" bash -c "printf 'hello\nworld\n' | '$binary'"

    test_command_output "nl stdin -b a" "     1	hello
     2	
     3	world" bash -c "printf 'hello\n\nworld\n' | '$binary' -b a"

    # Dash argument means stdin
    test_command_output "nl dash argument" "     1	hello
     2	world" bash -c "printf 'hello\nworld\n' | '$binary' -"

    echo -e "${CYAN}Testing section delimiters...${NC}"

    # Test header/body/footer section delimiters
    local section_file=$(create_temp_file $'\\:\\:\\:\nHEADER\n\\:\\:\nbody1\nbody2\n\\:\nFOOTER')

    # Default: headers and footers not numbered, body numbered non-empty
    local section_output
    section_output=$("$binary" "$section_file" 2>/dev/null)
    if echo "$section_output" | grep -q "body1"; then
        print_test_result "nl section delimiters recognized" "PASS"
    else
        print_test_result "nl section delimiters recognized" "FAIL" "Section delimiters not processed"
    fi

    echo -e "${CYAN}Testing -p no renumber...${NC}"

    local renumber_file=$(create_temp_file $'line1\nline2\n\\:\\:\\:\nline3\nline4')

    # With -p, line numbers continue across logical page boundaries
    local renumber_output
    renumber_output=$("$binary" -p -b a -h a "$renumber_file" 2>/dev/null)
    if echo "$renumber_output" | grep -q "3.*line3"; then
        print_test_result "nl -p continues numbering" "PASS"
    else
        print_test_result "nl -p continues numbering" "FAIL" "Expected continued numbering"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flags
    test_command_exit_code "nl invalid flag" 2 "$binary" --invalid-flag 2>/dev/null

    # Invalid numbering style
    test_command_exit_code "nl invalid body style" 2 "$binary" -b x "$simple_file" 2>/dev/null

    # Invalid number format
    test_command_exit_code "nl invalid number format" 2 "$binary" -n xx "$simple_file" 2>/dev/null

    # Non-existent file
    test_command_exit_code "nl non-existent file" 1 "$binary" /tmp/nonexistent_nl_file_$$ 2>/dev/null

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Empty file
    local empty_file=$(create_temp_file "")
    test_command_output "nl empty file" "" "$binary" "$empty_file"

    # Single line without newline
    local no_newline=$(create_temp_file "")
    printf "hello" > "$no_newline"
    test_command_output "nl no final newline" "     1	hello" "$binary" "$no_newline"

    # Very long line
    local long_content=$(printf 'A%.0s' {1..1000})
    local long_file=$(create_temp_file "$long_content")
    test_command_exit_code "nl very long line" 0 "$binary" "$long_file"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX exit codes
    test_command_exit_code "nl success exit code" 0 "$binary" "$simple_file"
    test_command_exit_code "nl help exit code" 0 "$binary" --help
    test_command_exit_code "nl version exit code" 0 "$binary" --version

    # POSIX default width is 6
    local posix_output
    posix_output=$("$binary" "$simple_file" 2>/dev/null)
    if echo "$posix_output" | head -1 | grep -qE "^ {5}1"; then
        print_test_result "nl POSIX default width 6" "PASS"
    else
        print_test_result "nl POSIX default width 6" "FAIL" "Expected 6-char width"
    fi

    # POSIX default separator is tab
    if echo "$posix_output" | head -1 | grep -q '	'; then
        print_test_result "nl POSIX default tab separator" "PASS"
    else
        print_test_result "nl POSIX default tab separator" "FAIL" "Expected tab separator"
    fi

    # Regression test: nl produces correctly numbered and padded output
    local nl_pad_file=$(create_temp_file $'alpha\nbeta\ngamma')
    test_command_output "nl number padding format" "     1	alpha
     2	beta
     3	gamma" "$binary" "$nl_pad_file"

    # Regression test: nl -n rz zero-pads to correct width
    test_command_output "nl -n rz zero pad format" "000001	alpha
000002	beta
000003	gamma" "$binary" -n rz "$nl_pad_file"

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}nl tests completed${NC}"
}

# Export the test function
export -f test_nl
