#!/usr/bin/env bash
# Comprehensive tests for uniq utility
# Tests duplicate detection, counting, field/char skipping, case handling

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_uniq() {
    local util="uniq"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Basic deduplication
    test_command_output "uniq basic dedup" $'aaa\nbbb\nccc' bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\n' | '$binary'"

    # No duplicates (pass through)
    test_command_output "uniq no duplicates" $'aaa\nbbb\nccc' bash -c "printf 'aaa\nbbb\nccc\n' | '$binary'"

    # All same lines
    test_command_output "uniq all same" "same" bash -c "printf 'same\nsame\nsame\n' | '$binary'"

    # Single line
    test_command_output "uniq single line" "hello" bash -c "printf 'hello\n' | '$binary'"

    # Empty input
    test_command_output "uniq empty input" "" bash -c "printf '' | '$binary'"

    echo -e "${CYAN}Testing -c (count) flag...${NC}"

    test_command_output "uniq -c basic" $'      3 aaa\n      1 bbb\n      2 ccc' bash -c "printf 'aaa\naaa\naaa\nbbb\nccc\nccc\n' | '$binary' -c"

    test_command_output "uniq --count long option" $'      2 hello\n      1 world' bash -c "printf 'hello\nhello\nworld\n' | '$binary' --count"

    echo -e "${CYAN}Testing -d (repeated) flag...${NC}"

    test_command_output "uniq -d basic" $'aaa\nccc' bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\n' | '$binary' -d"

    test_command_output "uniq -d no duplicates" "" bash -c "printf 'aaa\nbbb\nccc\n' | '$binary' -d"

    test_command_output "uniq --repeated long option" "hello" bash -c "printf 'hello\nhello\nworld\n' | '$binary' --repeated"

    echo -e "${CYAN}Testing -D (all-repeated) flag...${NC}"

    test_command_output "uniq -D basic" $'aaa\naaa\nccc\nccc\nccc' bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\nccc\n' | '$binary' -D"

    test_command_output "uniq -D no duplicates" "" bash -c "printf 'aaa\nbbb\nccc\n' | '$binary' -D"

    echo -e "${CYAN}Testing --all-repeated=METHOD variants...${NC}"

    # --all-repeated=none: print all duplicates, no separator between groups
    test_command_output_exact "uniq --all-repeated=none" $'a\na\n' bash -c "printf 'a\na\nb\n' | '$binary' --all-repeated=none"

    # --all-repeated=none exit code should be 0, not a crash
    test_command_exit_code "uniq --all-repeated=none exits 0" 0 bash -c "printf 'a\na\nb\n' | '$binary' --all-repeated=none"

    # --all-repeated=prepend: empty line before every group (including first)
    test_command_output_exact "uniq --all-repeated=prepend" $'\na\na\n' bash -c "printf 'a\na\nb\n' | '$binary' --all-repeated=prepend"

    # --all-repeated=separate: empty line between groups (not before first)
    test_command_output_exact "uniq --all-repeated=separate" $'a\na\n' bash -c "printf 'a\na\nb\n' | '$binary' --all-repeated=separate"

    # --all-repeated=separate with multiple duplicate groups
    test_command_output_exact "uniq --all-repeated=separate multi-group" $'a\na\n\nc\nc\n' bash -c "printf 'a\na\nb\nc\nc\n' | '$binary' --all-repeated=separate"

    # --all-repeated=prepend with multiple duplicate groups
    test_command_output_exact "uniq --all-repeated=prepend multi-group" $'\na\na\n\nc\nc\n' bash -c "printf 'a\na\nb\nc\nc\n' | '$binary' --all-repeated=prepend"

    # --all-repeated=none with multiple duplicate groups
    test_command_output_exact "uniq --all-repeated=none multi-group" $'a\na\nc\nc\n' bash -c "printf 'a\na\nb\nc\nc\n' | '$binary' --all-repeated=none"

    echo -e "${CYAN}Testing -u (unique) flag...${NC}"

    test_command_output "uniq -u basic" "bbb" bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\n' | '$binary' -u"

    test_command_output "uniq -u no unique" "" bash -c "printf 'aaa\naaa\nbbb\nbbb\n' | '$binary' -u"

    test_command_output "uniq --unique long option" "world" bash -c "printf 'hello\nhello\nworld\n' | '$binary' --unique"

    echo -e "${CYAN}Testing -i (ignore-case) flag...${NC}"

    test_command_output "uniq -i basic" "Hello" bash -c "printf 'Hello\nhello\nHELLO\n' | '$binary' -i"

    test_command_output "uniq -i mixed case" $'Hello\nworld' bash -c "printf 'Hello\nhello\nHELLO\nworld\n' | '$binary' -i"

    test_command_output "uniq --ignore-case long option" "ABC" bash -c "printf 'ABC\nabc\nABC\n' | '$binary' --ignore-case"

    echo -e "${CYAN}Testing -f (skip-fields) flag...${NC}"

    test_command_output "uniq -f 1 skip first field" $'1 foo\n3 bar' bash -c "printf '1 foo\n2 foo\n3 bar\n' | '$binary' -f 1"

    test_command_output "uniq --skip-fields long option" $'a same\nc diff' bash -c "printf 'a same\nb same\nc diff\n' | '$binary' --skip-fields=1"

    echo -e "${CYAN}Testing -s (skip-chars) flag...${NC}"

    test_command_output "uniq -s 1 skip first char" $'aXX\ncYY' bash -c "printf 'aXX\nbXX\ncYY\n' | '$binary' -s 1"

    test_command_output "uniq --skip-chars long option" $'AABB\nCCDD' bash -c "printf 'AABB\nXXBB\nCCDD\n' | '$binary' --skip-chars=2"

    echo -e "${CYAN}Testing -w (check-chars) flag...${NC}"

    test_command_output "uniq -w 3 check first 3 chars" $'abcXXX\nabdZZZ' bash -c "printf 'abcXXX\nabcYYY\nabdZZZ\n' | '$binary' -w 3"

    test_command_output "uniq --check-chars long option" $'AAbbcc\nBBccdd' bash -c "printf 'AAbbcc\nAAcccc\nBBccdd\n' | '$binary' --check-chars=2"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # -c -d: count only repeated
    test_command_output "uniq -c -d count repeated" $'      2 aaa\n      3 ccc' bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\nccc\n' | '$binary' -c -d"

    # -c -u: count only unique
    test_command_output "uniq -c -u count unique" "      1 bbb" bash -c "printf 'aaa\naaa\nbbb\nccc\nccc\n' | '$binary' -c -u"

    # -i -d: case-insensitive duplicates
    test_command_output "uniq -i -d case insensitive dupes" "Hello" bash -c "printf 'Hello\nhello\nworld\n' | '$binary' -i -d"

    echo -e "${CYAN}Testing file input/output...${NC}"

    # Input from file
    local input_file="$TEMP_DIR/uniq_input.txt"
    printf 'aaa\naaa\nbbb\nccc\nccc\n' > "$input_file"
    test_command_output "uniq from file" $'aaa\nbbb\nccc' "$binary" "$input_file"

    # Output to file
    local output_file="$TEMP_DIR/uniq_output.txt"
    test_command_exit_code "uniq output to file" 0 "$binary" "$input_file" "$output_file"
    test_command_output "uniq output file content" $'aaa\nbbb\nccc' cat "$output_file"

    echo -e "${CYAN}Testing non-adjacent duplicates...${NC}"

    # uniq only detects adjacent duplicates
    test_command_output "uniq non-adjacent kept" $'aaa\nbbb\naaa' bash -c "printf 'aaa\nbbb\naaa\n' | '$binary'"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag
    test_command_exit_code "uniq invalid flag" 2 "$binary" --invalid-flag 2>/dev/null

    # Too many operands
    test_command_exit_code "uniq too many operands" 2 "$binary" file1 file2 file3 2>/dev/null

    # Non-existent input file
    test_command_exit_code "uniq non-existent file" 1 "$binary" "/tmp/nonexistent_file_$$" 2>/dev/null

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Input without final newline
    test_command_output "uniq no final newline" $'aaa\nbbb' bash -c "printf 'aaa\naaa\nbbb' | '$binary'"

    # Lines with only whitespace
    test_command_output "uniq whitespace lines" $' \n\t' bash -c "printf ' \n \n\t\n' | '$binary'"

    # Very long lines
    local long_line
    long_line=$(printf 'A%.0s' {1..1000})
    test_command_exit_code "uniq very long line" 0 bash -c "printf '%s\n%s\n' '$long_line' '$long_line' | '$binary' >/dev/null"

    echo -e "${CYAN}Testing error diagnostics...${NC}"

    # Regression test: uniq must print error message for nonexistent files
    local uniq_err_cmd uniq_err_out uniq_err_stderr uniq_err_exit
    run_command uniq_err_cmd uniq_err_out uniq_err_stderr uniq_err_exit "$binary" /nonexistent/file
    if [[ $uniq_err_exit -ne 0 ]]; then
        print_test_result "uniq nonexistent file exits non-zero" "PASS"
    else
        print_test_result "uniq nonexistent file exits non-zero" "FAIL" \
            "Expected non-zero exit, got $uniq_err_exit"
    fi

    if [[ -n "$uniq_err_stderr" ]]; then
        print_test_result "uniq nonexistent file prints error" "PASS"
    else
        print_test_result "uniq nonexistent file prints error" "FAIL" \
            "Expected non-empty stderr"
    fi

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}uniq tests completed${NC}"
}

# Export the test function
export -f test_uniq
