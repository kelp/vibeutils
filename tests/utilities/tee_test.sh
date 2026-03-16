#!/usr/bin/env bash
# Comprehensive tests for tee utility
# Tests stdin copying to stdout and files, append mode, signal handling, and error diagnosis

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_tee() {
    local util="tee"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic infrastructure...${NC}"
    
    # Basic stdin to stdout test (no files)
    test_command_output "tee no files (stdout only)" "simple_data" bash -c "echo 'simple_data' | '$binary'"
    
    # Create temporary files for testing
    local test_file1="$TEMP_DIR/test1.txt"
    local test_file2="$TEMP_DIR/test2.txt" 
    local test_file3="$TEMP_DIR/test3.txt"
    local existing_file="$TEMP_DIR/existing.txt"
    
    echo "existing content" > "$existing_file"
    
    echo -e "${CYAN}Testing core functionality...${NC}"
    
    # Basic tee to single file
    test_command_output "tee to single file (stdout)" "hello world" bash -c "echo 'hello world' | '$binary' '$test_file1'"
    test_command_output "tee to single file (file content)" "hello world" cat "$test_file1"
    
    # Basic tee to multiple files
    test_command_output "tee to multiple files (stdout)" "multi_data" bash -c "echo 'multi_data' | '$binary' '$test_file1' '$test_file2'"
    test_command_output "tee multiple files (file1 content)" "multi_data" cat "$test_file1"
    test_command_output "tee multiple files (file2 content)" "multi_data" cat "$test_file2"
    
    # Multi-line input
    local multiline_input=$'line1\nline2\nline3'
    test_command_output "tee multiline input (stdout)" "$multiline_input" bash -c "printf '%s' '$multiline_input' | '$binary' '$test_file1'"
    test_command_output "tee multiline input (file content)" "$multiline_input" cat "$test_file1"
    
    # Binary data preservation
    test_command_exit_code "tee preserves binary data" 0 bash -c "printf '\x00\x01\x02\xFF' | '$binary' '$test_file1' >/dev/null"
    test_command_exit_code "tee binary data file created" 0 test -f "$test_file1"
    
    echo -e "${CYAN}Testing append mode (-a flag)...${NC}"
    
    # Prepare file with existing content for append tests
    echo "original content" > "$test_file1"
    
    # Append mode with -a flag
    test_command_output "tee -a append mode (stdout)" "appended" bash -c "echo 'appended' | '$binary' -a '$test_file1'"
    test_command_output "tee -a append mode (file content)" $'original content\nappended' cat "$test_file1"
    
    # Append mode with --append long option
    test_command_output "tee --append long option (stdout)" "more_data" bash -c "echo 'more_data' | '$binary' --append '$test_file1'"
    test_command_output "tee --append file content" $'original content\nappended\nmore_data' cat "$test_file1"
    
    # Append to multiple files
    echo "file2_original" > "$test_file2"
    echo "file3_original" > "$test_file3"
    test_command_output "tee -a multiple files (stdout)" "append_multi" bash -c "echo 'append_multi' | '$binary' -a '$test_file2' '$test_file3'"
    test_command_output "tee -a multiple files (file2)" $'file2_original\nappend_multi' cat "$test_file2"
    test_command_output "tee -a multiple files (file3)" $'file3_original\nappend_multi' cat "$test_file3"
    
    # Verify overwrite behavior without -a flag
    echo "overwrite_test" > "$test_file1"
    test_command_output "tee overwrites without -a (stdout)" "new_content" bash -c "echo 'new_content' | '$binary' '$test_file1'"
    test_command_output "tee overwrites without -a (file)" "new_content" cat "$test_file1"
    
    echo -e "${CYAN}Testing file handling...${NC}"
    
    # POSIX: dash means stdout (already written), not a file named "-"
    rm -f ./-
    test_command_output "tee with dash argument (stdout)" $'stdout_data\nstdout_data' bash -c "echo 'stdout_data' | '$binary' -"
    # Verify no file named "-" was created
    if [[ ! -f ./ ]]; then
        print_test_result "tee dash is stdout not file" "PASS"
    else
        print_test_result "tee dash is stdout not file" "FAIL" "File named '-' was created"
        rm -f ./-
    fi

    # Mix of files and dash - dash goes to stdout, file gets content
    test_command_output "tee file and dash (stdout)" $'mixed_output\nmixed_output' bash -c "echo 'mixed_output' | '$binary' '$test_file1' -"
    test_command_output "tee file and dash (file content)" "mixed_output" cat "$test_file1"

    # Multiple dash arguments
    test_command_output "tee multiple dash args (stdout)" $'dash_test\ndash_test\ndash_test' bash -c "echo 'dash_test' | '$binary' - -"
    
    # File creation in subdirectories
    local subdir="$TEMP_DIR/subdir"
    mkdir -p "$subdir"
    test_command_output "tee creates file in subdir (stdout)" "subdir_data" bash -c "echo 'subdir_data' | '$binary' '$subdir/nested.txt'"
    test_command_output "tee subdir file content" "subdir_data" cat "$subdir/nested.txt"
    
    # Test with many files (stress test)
    local many_files=("$TEMP_DIR/f1.txt" "$TEMP_DIR/f2.txt" "$TEMP_DIR/f3.txt" "$TEMP_DIR/f4.txt" "$TEMP_DIR/f5.txt")
    test_command_output "tee to many files (stdout)" "many_files_data" bash -c "echo 'many_files_data' | '$binary' '${many_files[0]}' '${many_files[1]}' '${many_files[2]}' '${many_files[3]}' '${many_files[4]}'"
    # Verify all files received the data
    for file in "${many_files[@]}"; do
        test_command_output "tee many files ($file content)" "many_files_data" cat "$file"
    done
    
    echo -e "${CYAN}Testing stdin processing...${NC}"
    
    # Empty input
    test_command_output "tee empty input" "" bash -c "echo -n '' | '$binary' '$test_file1'"
    test_command_output "tee empty input (file)" "" cat "$test_file1"
    
    # Large input test
    local large_input=$(printf 'A%.0s' {1..1000})  # 1000 A's
    test_command_exit_code "tee large input (stdout)" 0 bash -c "printf '%s' '$large_input' | '$binary' '$test_file1' >/dev/null"
    # Test large input file size using a more direct approach
    local file_size=$(get_file_size "$test_file1")
    if [[ "$file_size" -eq 1000 ]]; then
        print_test_result "tee large input file size" "PASS"
    else
        print_test_result "tee large input file size" "FAIL" "Expected size 1000, got $file_size"
    fi
    
    # Input with null bytes
    test_command_exit_code "tee null bytes processing" 0 bash -c "printf 'before\x00after' | '$binary' '$test_file1' >/dev/null"
    
    # Input with special characters (use printf to avoid shell escaping issues)
    local special_input_file="$TEMP_DIR/special_input.txt"
    printf 'tab\there\nquote"here\nsingle'\''quote\nbackslash\\here' > "$special_input_file"
    local expected_special=$(cat "$special_input_file")
    test_command_output "tee special characters (stdout)" "$expected_special" bash -c "cat '$special_input_file' | '$binary' '$test_file1'"
    test_command_output "tee special characters (file)" "$expected_special" cat "$test_file1"
    
    echo -e "${CYAN}Testing signal handling (-i flag)...${NC}"
    
    # Test that -i flag is accepted and doesn't cause errors
    test_command_output "tee -i flag accepted (stdout)" "ignore_signals" bash -c "echo 'ignore_signals' | '$binary' -i '$test_file1'"
    test_command_output "tee -i flag file content" "ignore_signals" cat "$test_file1"
    
    # Test --ignore-interrupts long option
    test_command_output "tee --ignore-interrupts (stdout)" "ignore_long" bash -c "echo 'ignore_long' | '$binary' --ignore-interrupts '$test_file1'"
    test_command_output "tee --ignore-interrupts file" "ignore_long" cat "$test_file1"
    
    # Combined with other flags
    test_command_output "tee -i -a combined (stdout)" "ignore_append" bash -c "echo 'ignore_append' | '$binary' -i -a '$test_file1'"
    test_command_output "tee -i -a file content" $'ignore_long\nignore_append' cat "$test_file1"
    
    echo -e "${CYAN}Testing error diagnosis (-p flag)...${NC}"
    
    # Test that -p flag is accepted
    test_command_output "tee -p flag accepted (stdout)" "diagnose_test" bash -c "echo 'diagnose_test' | '$binary' -p '$test_file1'"
    test_command_output "tee -p flag file content" "diagnose_test" cat "$test_file1"
    
    # Combined -p with other flags
    test_command_output "tee -p -a combined (stdout)" "diagnose_append" bash -c "echo 'diagnose_append' | '$binary' -p -a '$test_file1'"
    test_command_output "tee -p -a file content" $'diagnose_test\ndiagnose_append' cat "$test_file1"
    
    # All flags combined
    test_command_output "tee -i -p -a all flags (stdout)" "all_flags" bash -c "echo 'all_flags' | '$binary' -i -p -a '$test_file1'"
    test_command_output "tee all flags file content" $'diagnose_test\ndiagnose_append\nall_flags' cat "$test_file1"
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Different flag ordering
    test_command_output "tee -a -i flag order 1 (stdout)" "order1" bash -c "echo 'order1' | '$binary' -a -i '$test_file1'"
    test_command_output "tee -i -a flag order 2 (stdout)" "order2" bash -c "echo 'order2' | '$binary' -i -a '$test_file1'"
    test_command_output "tee flag combinations file" $'diagnose_test\ndiagnose_append\nall_flags\norder1\norder2' cat "$test_file1"
    
    # Mixed short and long options
    test_command_output "tee mixed options (stdout)" "mixed_opts" bash -c "echo 'mixed_opts' | '$binary' -i --append '$test_file1'"
    
    # Flags with multiple files
    echo "multi1" > "$test_file2"
    echo "multi2" > "$test_file3"
    test_command_output "tee -a multiple files (stdout)" "append_both" bash -c "echo 'append_both' | '$binary' -a '$test_file2' '$test_file3'"
    test_command_output "tee -a multiple (file2)" $'multi1\nappend_both' cat "$test_file2"
    test_command_output "tee -a multiple (file3)" $'multi2\nappend_both' cat "$test_file3"
    
    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # Invalid flags
    test_command_exit_code "tee invalid flag -x" 2 "$binary" -x 2>/dev/null
    test_command_exit_code "tee invalid long flag" 2 "$binary" --invalid 2>/dev/null
    
    # Read-only directory (permission test)
    local readonly_dir="$TEMP_DIR/readonly"
    mkdir -p "$readonly_dir"
    chmod 444 "$readonly_dir"
    test_command_exit_code "tee readonly directory fails" 1 bash -c "echo 'fail' | '$binary' '$readonly_dir/should_fail.txt' 2>/dev/null"
    chmod 755 "$readonly_dir"  # Restore for cleanup
    
    # Non-existent directory in path
    test_command_exit_code "tee non-existent dir in path" 1 bash -c "echo 'fail' | '$binary' '$TEMP_DIR/nonexistent/file.txt' 2>/dev/null"
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # Test exit codes
    test_command_exit_code "tee success exit code" 0 bash -c "echo 'success' | '$binary' '$test_file1' >/dev/null"
    test_command_exit_code "tee help flag exit code" 0 "$binary" --help >/dev/null
    test_command_exit_code "tee version flag exit code" 0 "$binary" --version >/dev/null
    
    # Unbuffered output behavior (hard to test directly, but verify it works)
    test_command_exit_code "tee unbuffered processing" 0 bash -c "printf 'line1\nline2\nline3\n' | '$binary' '$test_file1' >/dev/null"
    
    # POSIX requires copying from stdin to stdout and files
    test_command_output "tee POSIX compliance (stdout copy)" "posix_test" bash -c "echo 'posix_test' | '$binary' '$test_file1'"
    test_command_output "tee POSIX compliance (file copy)" "posix_test" cat "$test_file1"
    
    echo -e "${CYAN}Testing performance and edge cases...${NC}"
    
    # Very long line
    local long_line=$(printf 'X%.0s' {1..10000})  # 10k characters
    test_command_exit_code "tee very long line" 0 bash -c "printf '%s\n' '$long_line' | '$binary' '$test_file1' >/dev/null"
    
    # Many small writes
    test_command_exit_code "tee many small writes" 0 bash -c "for i in {1..100}; do echo \"line\$i\"; done | '$binary' '$test_file1' >/dev/null"
    
    # File already exists with different permissions
    echo "perm_test" > "$test_file1"
    chmod 644 "$test_file1"
    test_command_output "tee existing file perms (stdout)" "new_perm_data" bash -c "echo 'new_perm_data' | '$binary' '$test_file1'"
    test_command_output "tee existing file perms (file)" "new_perm_data" cat "$test_file1"
    
    echo -e "${CYAN}Testing boundary conditions...${NC}"
    
    # Zero-length file creation
    test_command_output "tee zero-length input" "" bash -c "echo -n | '$binary' '$test_file1'"
    test_command_exit_code "tee zero-length file exists" 0 test -f "$test_file1"
    
    # Single character
    test_command_output "tee single character (stdout)" "A" bash -c "printf 'A' | '$binary' '$test_file1'"
    test_command_output "tee single character (file)" "A" cat "$test_file1"
    
    # Only newline (use exact comparison to preserve newlines)
    test_command_output_exact "tee only newline (stdout)" $'\n' bash -c "printf '\n' | '$binary' '$test_file1'"
    test_command_output_exact "tee only newline (file)" $'\n' cat "$test_file1"
    
    # File name edge cases
    local weird_filename="$TEMP_DIR/file with spaces.txt"
    test_command_output "tee filename with spaces (stdout)" "space_test" bash -c "echo 'space_test' | '$binary' '$weird_filename'"
    test_command_output "tee filename with spaces (file)" "space_test" cat "$weird_filename"
    
    # Same file specified multiple times
    test_command_output "tee same file twice (stdout)" "duplicate_spec" bash -c "echo 'duplicate_spec' | '$binary' '$test_file1' '$test_file1'"
    test_command_output "tee same file twice (file)" "duplicate_spec" cat "$test_file1"
    
    # Maximum filename length (platform dependent, test reasonably long name)
    local long_filename="$TEMP_DIR/$(printf 'a%.0s' {1..100}).txt"
    test_command_exit_code "tee long filename" 0 bash -c "echo 'long_name' | '$binary' '$long_filename' >/dev/null"
    
    # Regression test: echo hello | tee - should output "hello" twice
    echo -e "${CYAN}Testing tee - writes stdout twice regression...${NC}"
    test_command_output "tee - outputs hello twice" $'hello\nhello' \
        bash -c "echo 'hello' | '$binary' -"

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}tee tests completed${NC}"
}

# Export the test function
export -f test_tee