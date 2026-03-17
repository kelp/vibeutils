#!/usr/bin/env bash
# Comprehensive tests for sort utility
# Tests sorting, numeric modes, key definitions, check mode, and options

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_sort() {
    local util="sort"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic sorting...${NC}"

    # Basic alphabetical sort
    test_command_output "sort alphabetical" $'apple\nbanana\ncherry' bash -c "printf 'cherry\napple\nbanana\n' | '$binary'"

    # Already sorted input
    test_command_output "sort already sorted" $'a\nb\nc' bash -c "printf 'a\nb\nc\n' | '$binary'"

    # Reverse sorted input
    test_command_output "sort reverse input" $'a\nb\nc' bash -c "printf 'c\nb\na\n' | '$binary'"

    # Single line
    test_command_output "sort single line" "hello" bash -c "printf 'hello\n' | '$binary'"

    # Empty input
    test_command_output "sort empty input" "" bash -c "printf '' | '$binary'"

    echo -e "${CYAN}Testing reverse sort (-r)...${NC}"

    test_command_output "sort -r reverse" $'cherry\nbanana\napple' bash -c "printf 'cherry\napple\nbanana\n' | '$binary' -r"

    test_command_output "sort --reverse" $'cherry\nbanana\napple' bash -c "printf 'cherry\napple\nbanana\n' | '$binary' --reverse"

    echo -e "${CYAN}Testing numeric sort (-n)...${NC}"

    test_command_output "sort -n numeric" $'1\n2\n10\n20\n100' bash -c "printf '100\n10\n20\n2\n1\n' | '$binary' -n"

    test_command_output "sort -n with negatives" $'-5\n-1\n0\n3\n10' bash -c "printf '3\n-1\n10\n0\n-5\n' | '$binary' -n"

    test_command_output "sort -rn reverse numeric" $'100\n20\n10\n2\n1' bash -c "printf '100\n10\n20\n2\n1\n' | '$binary' -rn"

    echo -e "${CYAN}Testing case-insensitive sort (-f)...${NC}"

    test_command_output "sort -f case insensitive" $'Apple\nbanana\nCherry' bash -c "printf 'Cherry\nApple\nbanana\n' | '$binary' -f"

    echo -e "${CYAN}Testing unique (-u)...${NC}"

    test_command_output "sort -u unique" $'a\nb\nc' bash -c "printf 'a\nb\na\nc\nb\n' | '$binary' -u"

    test_command_output "sort -u already unique" $'a\nb\nc' bash -c "printf 'c\na\nb\n' | '$binary' -u"

    echo -e "${CYAN}Testing dictionary order (-d)...${NC}"

    test_command_output "sort -d dictionary" $'a-b\nab\nac' bash -c "printf 'ac\na-b\nab\n' | '$binary' -d"

    echo -e "${CYAN}Testing ignore leading blanks (-b)...${NC}"

    test_command_output "sort -b ignore blanks" $'  apple\nbanana\n cherry' bash -c "printf 'banana\n cherry\n  apple\n' | '$binary' -b"

    echo -e "${CYAN}Testing human numeric sort (-h)...${NC}"

    test_command_output "sort -h human numeric" $'1K\n2K\n1M\n1G' bash -c "printf '1G\n1M\n2K\n1K\n' | '$binary' -h"

    echo -e "${CYAN}Testing general numeric sort (-g)...${NC}"

    test_command_output "sort -g general numeric" $'1e1\n1e2\n1e3' bash -c "printf '1e3\n1e1\n1e2\n' | '$binary' -g"

    echo -e "${CYAN}Testing check mode (-c)...${NC}"

    # Sorted input should pass
    test_command_exit_code "sort -c sorted input" 0 bash -c "printf 'a\nb\nc\n' | '$binary' -c"

    # Unsorted input should fail
    test_command_exit_code "sort -c unsorted input" 1 bash -c "printf 'b\na\nc\n' | '$binary' -c 2>/dev/null"

    # Quiet check mode
    test_command_exit_code "sort -C quiet check sorted" 0 bash -c "printf 'a\nb\nc\n' | '$binary' -C"
    test_command_exit_code "sort -C quiet check unsorted" 1 bash -c "printf 'b\na\nc\n' | '$binary' -C"

    echo -e "${CYAN}Testing field separator (-t) and key (-k)...${NC}"

    # Sort by second field with colon separator
    test_command_output "sort -t: -k2" $'c:1\na:2\nb:3' bash -c "printf 'b:3\nc:1\na:2\n' | '$binary' -t: -k2,2"

    # Numeric sort on second field
    test_command_output "sort -t: -k2n" $'b:1\na:2\nc:10' bash -c "printf 'a:2\nc:10\nb:1\n' | '$binary' -t: -k2,2n"

    echo -e "${CYAN}Testing file input...${NC}"

    local test_file="$TEMP_DIR/sort_input.txt"
    printf 'banana\napple\ncherry\n' > "$test_file"
    test_command_output "sort file input" $'apple\nbanana\ncherry' "$binary" "$test_file"

    echo -e "${CYAN}Testing output file (-o)...${NC}"

    local output_file="$TEMP_DIR/sort_output.txt"
    printf 'cherry\napple\nbanana\n' | "$binary" -o "$output_file"
    test_command_output "sort -o output file" $'apple\nbanana\ncherry' cat "$output_file"

    echo -e "${CYAN}Testing zero-terminated (-z)...${NC}"

    # Sort with NUL delimiter
    test_command_exit_code "sort -z zero terminated" 0 bash -c "printf 'b\0a\0c\0' | '$binary' -z > /dev/null"

    echo -e "${CYAN}Testing combined flags...${NC}"

    test_command_output "sort -nru combined" $'10\n5\n1' bash -c "printf '5\n1\n10\n1\n5\n' | '$binary' -nru"

    echo -e "${CYAN}Testing stable sort (-s)...${NC}"

    test_command_exit_code "sort -s stable flag accepted" 0 bash -c "printf 'a\nb\nc\n' | '$binary' -s > /dev/null"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag
    test_command_exit_code "sort invalid flag" 2 "$binary" -x 2>/dev/null
    test_command_exit_code "sort invalid long flag" 2 "$binary" --bogus 2>/dev/null

    # Nonexistent file
    test_command_exit_code "sort nonexistent file" 2 "$binary" /nonexistent/file 2>/dev/null

    echo -e "${CYAN}Testing -- separator...${NC}"

    printf 'hello\nworld\n' > "$TEMP_DIR/-dashfile.txt"
    test_command_output "sort -- handles dash files" $'hello\nworld' "$binary" -- "$TEMP_DIR/-dashfile.txt"

    echo -e "${CYAN}Testing multiple files...${NC}"

    local file1="$TEMP_DIR/sort1.txt"
    local file2="$TEMP_DIR/sort2.txt"
    printf 'cherry\napple\n' > "$file1"
    printf 'banana\ndate\n' > "$file2"
    test_command_output "sort multiple files" $'apple\nbanana\ncherry\ndate' "$binary" "$file1" "$file2"

    echo -e "${CYAN}Testing stdin with - argument...${NC}"

    test_command_output "sort dash means stdin" $'apple\nbanana' bash -c "printf 'banana\napple\n' | '$binary' -"

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression: sort should handle multi-line files correctly
    # (Internal fix: readLines memory leak - verify sort still works end-to-end)
    test_command_output "sort multi-line file (readLines regression)" $'apple\nbanana\ncherry' \
        bash -c "printf 'banana\napple\ncherry\n' | '$binary'"

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}sort tests completed${NC}"
}

# Export the test function
export -f test_sort
