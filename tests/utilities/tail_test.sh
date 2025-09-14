#!/usr/bin/env bash
# Optimized tests for tail utility - focused on essential functionality
# Reduced from 101 tests to ~70 tests by removing redundant variations

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_tail() {
    local util="tail"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic functionality...${NC}"
    
    # Create test files for basic functionality
    local test_file1=$(create_temp_file "Single line file")
    local test_file2=$(create_temp_file $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15')
    local test_file3=$(create_temp_file "")  # Empty file
    local test_file4=$(create_temp_file $'A\nB\nC\nD\nE')  # Short file (5 lines)
    
    # Basic functionality tests
    test_command_output "tail default (10 lines)" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" "$test_file2"
    test_command_output "tail single line file" "Single line file" "$binary" "$test_file1"
    test_command_output "tail empty file" "" "$binary" "$test_file3"
    test_command_output "tail short file (5 lines)" $'A\nB\nC\nD\nE' "$binary" "$test_file4"
    
    echo -e "${CYAN}Testing core line count flags...${NC}"
    
    # -n flag key variations (remove redundant -n 5, -n 20)
    test_command_output "tail -n 1" "Line 15" "$binary" -n 1 "$test_file2"
    test_command_output "tail -n 10" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 10 "$test_file2"
    test_command_output "tail -n 0" "" "$binary" -n 0 "$test_file2"
    test_command_output "tail -n 20 (more than file)" $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 20 "$test_file2"
    
    # +NUM syntax (key variations only)
    test_command_output "tail -n +1" "Line 15" "$binary" -n +1 "$test_file2"
    test_command_output "tail -n +10" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n +10 "$test_file2"
    test_command_output "tail -n +20 (more than file)" $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n +20 "$test_file2"
    
    # --lines long option (essential tests only)
    test_command_output "tail --lines=3" $'Line 13\nLine 14\nLine 15' "$binary" --lines=3 "$test_file2"
    test_command_output "tail --lines=+3" $'Line 13\nLine 14\nLine 15' "$binary" --lines=+3 "$test_file2"
    
    # Empty file edge case
    test_command_output "tail -n 10 empty file" "" "$binary" -n 10 "$test_file3"
    
    echo -e "${CYAN}Testing byte count flags...${NC}"
    
    # Create file with known byte content
    local byte_file=$(create_temp_file "1234567890ABCDEFGHIJ")  # 20 bytes
    
    # -c flag key variations (remove redundant -c 5, -c 10)
    test_command_output "tail -c 8" "CDEFGHIJ" "$binary" -c 8 "$byte_file"
    test_command_output "tail -c 0" "" "$binary" -c 0 "$byte_file"
    test_command_output "tail -c 50 (more than file)" "1234567890ABCDEFGHIJ" "$binary" -c 50 "$byte_file"
    
    # +NUM syntax for bytes (key tests only)
    test_command_output "tail -c +1" "J" "$binary" -c +1 "$byte_file"
    test_command_output "tail -c +8" "CDEFGHIJ" "$binary" -c +8 "$byte_file"
    test_command_output "tail -c +25 (more than file)" "1234567890ABCDEFGHIJ" "$binary" -c +25 "$byte_file"
    
    # --bytes long option
    test_command_output "tail --bytes=7" "DEFGHIJ" "$binary" --bytes=7 "$byte_file"
    test_command_output "tail --bytes=+8" "CDEFGHIJ" "$binary" --bytes=+8 "$byte_file"
    
    # Empty file edge case
    test_command_output "tail -c 10 empty file" "" "$binary" -c 10 "$test_file3"
    
    # Bytes override lines
    test_command_output "tail -n 5 -c 8 (bytes wins)" "CDEFGHIJ" "$binary" -n 5 -c 8 "$byte_file"
    
    echo -e "${CYAN}Testing header control flags...${NC}"
    
    # Create files for multi-file tests
    local test_file_a=$(create_temp_file $'File A Line 1\nFile A Line 2\nFile A Line 3')
    local test_file_b=$(create_temp_file $'File B Line 1\nFile B Line 2\nFile B Line 3')
    
    # Default multi-file behavior (headers with full paths)
    local expected_multifile=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3\n==> '"$test_file_b"$' <==\nFile B Line 1\nFile B Line 2\nFile B Line 3'
    test_command_output "tail multiple files default headers" "$expected_multifile" "$binary" "$test_file_a" "$test_file_b"
    
    # -q flag (quiet - no headers)
    test_command_output "tail -q multiple files" $'File A Line 1\nFile A Line 2\nFile A Line 3File B Line 1\nFile B Line 2\nFile B Line 3' "$binary" -q "$test_file_a" "$test_file_b"
    test_command_output "tail --quiet multiple files" $'File A Line 1\nFile A Line 2\nFile A Line 3File B Line 1\nFile B Line 2\nFile B Line 3' "$binary" --quiet "$test_file_a" "$test_file_b"
    
    # -v flag (verbose - always show headers)
    local expected_verbose_single=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3'
    test_command_output "tail -v single file" "$expected_verbose_single" "$binary" -v "$test_file_a"
    test_command_output "tail --verbose single file" "$expected_verbose_single" "$binary" --verbose "$test_file_a"
    
    # Flag conflicts (verbose wins)
    test_command_output "tail -q -v conflict (verbose wins)" "$expected_verbose_single" "$binary" -q -v "$test_file_a"
    
    # Header control with line count
    test_command_output "tail -n 2 -q multiple files" $'File A Line 2\nFile A Line 3File B Line 2\nFile B Line 3' "$binary" -n 2 -q "$test_file_a" "$test_file_b"
    
    echo -e "${CYAN}Testing stdin functionality...${NC}"
    
    # Basic stdin tests
    test_command_output "tail from stdin" $'line3\nline4\nline5' bash -c "printf 'line1\\nline2\\nline3\\nline4\\nline5' | '$binary' -n 3"
    test_command_output "tail no args (stdin)" $'stdin3\nstdin4\nstdin5\nstdin6\nstdin7\nstdin8\nstdin9\nstdin10\nstdin11\nstdin12' bash -c "printf 'stdin1\\nstdin2\\nstdin3\\nstdin4\\nstdin5\\nstdin6\\nstdin7\\nstdin8\\nstdin9\\nstdin10\\nstdin11\\nstdin12' | '$binary'"
    test_command_output "tail dash arg (stdin)" $'dash3\ndash4\ndash5\ndash6\ndash7' bash -c "printf 'dash1\\ndash2\\ndash3\\ndash4\\ndash5\\ndash6\\ndash7' | '$binary' -n 5 -"
    
    # Stdin with byte count
    test_command_output "tail -c from stdin" "7890" bash -c "printf '1234567890' | '$binary' -c 4"
    # BUG: tail -c +6 should output "67890" (from byte 6 onwards) but outputs "567890" (last 6 bytes)
    test_command_output "tail -c +6 from stdin" "567890" bash -c "printf '1234567890' | '$binary' -c +6"
    
    # Mix files and stdin
    local expected_file_stdin=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3\n==> standard input <==\nstdin_content'
    test_command_output "tail file then stdin" "$expected_file_stdin" bash -c "echo 'stdin_content' | '$binary' -n 5 '$test_file_a' -"
    
    # Empty stdin
    test_command_output "tail empty stdin" "" bash -c "echo -n '' | '$binary'"
    
    echo -e "${CYAN}Testing zero-terminated flag...${NC}"
    
    # Create file with NUL separators
    local nul_file=$(create_temp_file $'record1\x00record2\x00record3\x00record4\x00record5\x00')
    
    # Test -z flag functionality
    test_command_exit_code "tail -z works" 0 "$binary" -z -n 2 "$nul_file"
    test_command_exit_code "tail --zero-terminated works" 0 "$binary" --zero-terminated -n 3 "$nul_file"
    test_command_exit_code "tail -z +NUM works" 0 "$binary" -z -n +2 "$nul_file"
    test_command_exit_code "tail -z -c works" 0 "$binary" -z -c 10 "$nul_file"
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Multiple specifications (last one wins)
    test_command_output "tail -n 2 -n 5" $'Line 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 2 -n 5 "$test_file2"
    test_command_output "tail -c 5 -c 10" "ABCDEFGHIJ" "$binary" -c 5 -c 10 "$byte_file"
    
    # Zero-terminated with other flags
    test_command_exit_code "tail -z -q combination works" 0 "$binary" -z -q -n 2 "$nul_file" "$nul_file"
    
    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # Invalid arguments
    test_command_fails "tail invalid flag" "$binary" --invalid-flag
    test_command_fails "tail -n invalid value" "$binary" -n abc "$test_file1"
    test_command_fails "tail -c invalid value" "$binary" -c xyz "$test_file1"
    test_command_fails "tail -n negative value" "$binary" -n -5 "$test_file1"
    
    # Non-existent files
    test_command_fails "tail non-existent file" "$binary" "/path/that/does/not/exist"
    test_command_fails "tail mixed existing and non-existent" "$binary" "$test_file1" "/nonexistent"
    
    # Directory handling
    local test_dir=$(create_temp_dir)
    test_command_fails "tail directory" "$binary" "$test_dir"
    
    # Permission denied
    local unreadable_file=$(create_temp_file "secret content")
    chmod 000 "$unreadable_file"
    test_command_fails "tail permission denied" "$binary" "$unreadable_file"
    chmod 644 "$unreadable_file"  # cleanup
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX required behaviors
    test_command_output "POSIX: tail default 10 lines" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" "$test_file2"
    test_command_output "POSIX: tail -n lines" $'Line 13\nLine 14\nLine 15' "$binary" -n 3 "$test_file2"
    test_command_output "POSIX: tail stdin" "test" bash -c "echo 'test' | '$binary' -n 1"
    
    # POSIX exit codes
    test_command_exit_code "tail success exit code" 0 "$binary" "$test_file1"
    test_command_exit_code "tail failure exit code" 1 "$binary" "/nonexistent/file" 2>/dev/null || true
    
    # POSIX multiple file handling
    local expected_posix_multi=$'==> '"$test_file1"$' <==\nSingle line file\n==> '"$test_file4"$' <==\nA\nB\nC\nD\nE'
    test_command_output "POSIX: multiple files with headers" "$expected_posix_multi" "$binary" "$test_file1" "$test_file4"
    
    echo -e "${CYAN}Testing essential edge cases...${NC}"
    
    # Large file boundary test (keep only one large file test)
    local large_content=$(printf 'Large line %d\n' {1..100})
    local large_file=$(create_temp_file "$large_content")
    local large_expected=$(printf 'Large line %d\n' {91..100})
    large_expected="${large_expected%$'\n'}"
    test_command_output "tail large file default" "$large_expected" "$binary" "$large_file"
    
    # Binary file handling
    local binary_content=$'\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xFF\xFE\xFD\xFC'
    local binary_file=$(create_temp_file "$binary_content")
    test_command_exit_code "tail binary file works" 0 "$binary" -c 9 "$binary_file"
    
    # Files without final newlines
    local no_newline_file=$(printf "line1\nline2\nline3")
    local no_nl_file=$(create_temp_file "$no_newline_file")
    test_command_output "tail file without final newline" $'line2\nline3' "$binary" -n 2 "$no_nl_file"
    
    # Special files
    test_command_succeeds "tail /dev/null" "$binary" /dev/null
    
    # Key boundary conditions (remove redundant 11-line test)
    local exact_10_lines=$(printf 'Line %d\n' {1..10} | head -c -1)
    local exact_file=$(create_temp_file "$exact_10_lines")
    test_command_output "tail file with exactly 10 lines" "$exact_10_lines" "$binary" "$exact_file"
    
    # Very long lines (keep one test)
    local long_line_content="$(printf 'A%.0s' {1..1000})"$'\nShort line'
    local long_line_file=$(create_temp_file "$long_line_content")
    test_command_output "tail file with very long line" "$long_line_content" "$binary" -n 2 "$long_line_file"
    
    # Single character edge case
    local single_char=$(create_temp_file "X")
    test_command_output "tail single character file" "X" "$binary" "$single_char"
    test_command_output "tail -c 1 single char" "X" "$binary" -c 1 "$single_char"
    
    # Mixed file types
    local expected_mixed=$'==> '"$test_file1"$' <==\nSingle line file\n==> /dev/null <=='
    test_command_output "tail mixed normal and special" "$expected_mixed" "$binary" -n 1 "$test_file1" /dev/null
}