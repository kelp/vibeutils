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

    # Default skips blank lines (GNU outputs width+sep spaces for blank lines)
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
    test_command_output "nl -b n numbers none" "       hello
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
    test_command_exit_code "nl invalid flag" 1 "$binary" --invalid-flag 2>/dev/null

    # Invalid numbering style
    test_command_exit_code "nl invalid body style" 1 "$binary" -b x "$simple_file" 2>/dev/null

    # Invalid number format
    test_command_exit_code "nl invalid number format" 1 "$binary" -n xx "$simple_file" 2>/dev/null

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

    echo -e "${CYAN}Testing F39: section delimiter resets counter on all transitions...${NC}"

    # F39: GNU nl resets the counter on every section transition, not just header
    local f39_body_file=$(create_temp_file $'line1\nline2\n\\:\\:\nbody1\nbody2')
    test_command_output "nl F39 body transition resets counter" "    10	line1
    11	line2

    10	body1
    11	body2" "$binary" -b a -v 10 "$f39_body_file"

    local f39_footer_file=$(create_temp_file $'line1\nline2\n\\:\nfoot1\nfoot2')
    test_command_output "nl F39 footer transition resets counter" "    10	line1
    11	line2

    10	foot1
    11	foot2" "$binary" -b a -f a -v 10 "$f39_footer_file"

    echo -e "${CYAN}Testing F40: unnumbered lines use spaces not separator...${NC}"

    # F40: GNU nl outputs width+len(sep) spaces for unnumbered lines, no separator char
    test_command_output "nl F40 unnumbered line spaces only" "       hello
       world" "$binary" -b n "$simple_file"

    test_command_output "nl F40 unnumbered line custom sep spaces" "        hello
        world" "$binary" -b n -s ": " "$simple_file"

    echo -e "${CYAN}Testing F41: skipped blank lines have indent...${NC}"

    # F41: GNU nl outputs width+len(sep) spaces then newline for blank lines
    # The blank line should have 7 spaces (width=6 + tab=1 char replaced by space)
    local f41_expected
    f41_expected=$(printf '     1\thello\n       \n     2\tworld')
    test_command_output "nl F41 blank line indent default mode" "$f41_expected" "$binary" "$blank_file"

    local f41_join_file=$(create_temp_file $'hello\n\nworld')
    local f41_join_expected
    f41_join_expected=$(printf '     1\thello\n       \n     2\tworld')
    test_command_output "nl F41 blank line indent with -b a -l 2" "$f41_join_expected" "$binary" -b a -l 2 "$f41_join_file"

    echo -e "${CYAN}Testing F42: -b pREGEX numbers matching lines...${NC}"

    # F42: GNU nl supports -b pREGEX to number lines matching regex
    local f42_file=$(create_temp_file $'foo\nbar\nfoo2\nbaz')
    test_command_output "nl F42 -b pfoo numbers matching lines" "     1	foo
       bar
     2	foo2
       baz" "$binary" -b pfoo "$f42_file"

    echo -e "${CYAN}Testing F43: -d empty disables section matching...${NC}"

    # F43: GNU nl accepts empty delimiter to disable section matching
    local f43_file=$(create_temp_file $'hello\n\\:\\:\\:\nworld')
    test_command_output "nl F43 -d empty disables sections" "     1	hello
     2	\\:\\:\\:
     3	world" "$binary" -d '' -b a "$f43_file"

    # ========== AUDIT WAVE 4: nl IMPORTANT findings ==========

    echo -e "${CYAN}Testing audit: -f footer numbering style...${NC}"

    # CRITICAL: -f flag has zero behavioral tests
    # GNU nl with -f a should number footer lines
    local aud_sec_file=$(create_temp_file $'\\:\\:\\:\nHEADER\n\\:\\:\nbody1\nbody2\n\\:\nFOOTER')

    # -f a: footer lines are numbered (counter resets per POSIX/GNU)
    test_command_output "nl audit -f a numbers footer lines" \
$'\n       HEADER\n\n     1\tbody1\n     2\tbody2\n\n     1\tFOOTER' \
        "$binary" -f a "$aud_sec_file"

    # Default: footer lines should NOT be numbered
    test_command_output "nl audit default footer not numbered" \
$'\n       HEADER\n\n     1\tbody1\n     2\tbody2\n\n       FOOTER' \
        "$binary" "$aud_sec_file"

    echo -e "${CYAN}Testing audit: -d custom section delimiter...${NC}"

    # CRITICAL: -d flag has zero behavioral tests
    # GNU nl -d '@@' treats @@@@@@ as header, @@@@ as body, @@ as footer
    local aud_dfile=$(create_temp_file $'@@@@@@\nHEADER\n@@@@\nbody1\nbody2\n@@\nFOOTER')
    test_command_output "nl audit -d @@ custom delimiter" \
$'\n       HEADER\n\n     1\tbody1\n     2\tbody2\n\n       FOOTER' \
        "$binary" -d '@@' "$aud_dfile"

    echo -e "${CYAN}Testing audit: -l join blank lines...${NC}"

    # IMPORTANT: -l N has zero tests
    # With -b a -l 2: consecutive blank lines are joined; only every Nth
    # blank in a run gets a number, others are not numbered.
    # GNU behavior: with -l 2, in a run of 3 blank lines, the 2nd gets
    # a number (it completes the first group of 2), the 3rd does not.
    local aud_lfile=$(create_temp_file $'line1\n\n\n\nline2')

    # -b a -l 2: two consecutive blanks count as one logical blank
    # GNU nl -b a -l 2 on "line1\n\n\n\nline2":
    #   1\tline1   (numbered)
    #   (7 spaces) (unnumbered blank)
    #   2\t        (numbered blank, completes group of 2)
    #   (7 spaces) (unnumbered blank)
    #   3\tline2   (numbered)
    local aud_l_expected
    aud_l_expected=$(printf '     1\tline1\n       \n     2\t\n       \n     3\tline2')
    test_command_output "nl audit -b a -l 2 join blanks" \
        "$aud_l_expected" "$binary" -b a -l 2 "$aud_lfile"

    echo -e "${CYAN}Testing audit: -p stronger behavioral test...${NC}"

    # IMPORTANT: -p test was grep-only; verify full output
    local aud_pfile=$(create_temp_file $'line1\nline2\n\\:\\:\\:\nline3\nline4')

    # Without -p: number resets to 1 at header boundary
    test_command_output "nl audit reset at header boundary" \
$'     1\tline1\n     2\tline2\n\n     1\tline3\n     2\tline4' \
        "$binary" -b a -h a "$aud_pfile"

    # With -p: number continues across page boundary
    test_command_output "nl audit -p continues numbering across pages" \
$'     1\tline1\n     2\tline2\n\n     3\tline3\n     4\tline4' \
        "$binary" -p -b a -h a "$aud_pfile"

    echo -e "${CYAN}Testing error diagnostics on bad files (issue #63 GNU parity)...${NC}"

    # Regression test: GNU nl prints a nonexistent-file operand unquoted, as
    # "prog: path: message" with no "cannot access"/"cannot open" wording.
    # Pinned against GNU coreutils 9.5 (LC_ALL=C):
    #   nl: /nonexistent/file: No such file or directory
    local nl_err_cmd nl_err_out nl_err_stderr nl_err_exit
    run_command nl_err_cmd nl_err_out nl_err_stderr nl_err_exit \
        "$binary" /nonexistent/file
    if [[ "$nl_err_stderr" == "nl: /nonexistent/file: No such file or directory" ]]; then
        print_test_result "nl nonexistent file bare operand (GNU parity)" "PASS"
    else
        print_test_result "nl nonexistent file bare operand (GNU parity)" "FAIL" \
            "Expected 'nl: /nonexistent/file: No such file or directory', got: '$nl_err_stderr'"
    fi

    echo -e "${CYAN}Testing GNU-style long-flag abbreviation (issue #128)...${NC}"

    # AMBIGUOUS: "--he" prefixes both "--help" and "--header-numbering".
    # Candidate order follows NlArgs's own field-declaration order
    # (help before header_numbering in src/nl.zig), not GNU's own longopts
    # order and not alphabetical order.
    # Redirect stdin from /dev/null: a buggy implementation that resolved
    # this prefix to a value-less flag rather than reporting ambiguity
    # would otherwise block reading the suite's inherited stdin instead of
    # failing fast.
    local he_cmd="" he_out="" he_err="" he_exit=""
    run_command he_cmd he_out he_err he_exit bash -c "'$binary' --he < /dev/null"
    if [[ $he_exit -eq 1 && "$he_err" == "nl: option '--he' is ambiguous; possibilities: '--help' '--header-numbering'"$'\n'"Try 'nl --help' for more information." ]]; then
        print_test_result "nl --he is ambiguous (help, header-numbering)" "PASS"
    else
        print_test_result "nl --he is ambiguous (help, header-numbering)" "FAIL" \
            "Expected \"nl: option '--he' is ambiguous; possibilities: '--help' '--header-numbering'\" then the hint line, got exit=$he_exit stderr='$he_err'"
    fi

    # AMBIGUOUS ORDER: "--nu" prefixes number_format, number_width, and
    # number_separator (single-letter fields like "n" are excluded: their
    # one-character long flag can never match a two-character prefix), in
    # that field-declaration order from src/nl.zig.
    local nu_cmd="" nu_out="" nu_err="" nu_exit=""
    run_command nu_cmd nu_out nu_err nu_exit bash -c "'$binary' --nu < /dev/null"
    if [[ $nu_exit -eq 1 && "$nu_err" == "nl: option '--nu' is ambiguous; possibilities: '--number-format' '--number-width' '--number-separator'"$'\n'"Try 'nl --help' for more information." ]]; then
        print_test_result "nl --nu is ambiguous in field-declaration order" "PASS"
    else
        print_test_result "nl --nu is ambiguous in field-declaration order" "FAIL" \
            "Expected \"nl: option '--nu' is ambiguous; possibilities: '--number-format' '--number-width' '--number-separator'\" then the hint line, got exit=$nu_exit stderr='$nu_err'"
    fi

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}nl tests completed${NC}"
}

# Export the test function
export -f test_nl
