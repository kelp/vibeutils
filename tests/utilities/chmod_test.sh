#!/usr/bin/env bash
# Comprehensive tests for chmod utility
# Tests all flags, mode formats, and recursive operations

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_chmod() {
    local util="chmod"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic octal mode functionality...${NC}"
    
    # Create test files with known permissions
    local test_file1=$(create_temp_file "test content")
    local test_file2=$(create_temp_file "more content")
    local test_dir=$(create_temp_dir)
    local test_file_in_dir=$(create_temp_file "content" "$test_dir/subfile")
    
    # Test basic octal modes
    test_command_succeeds "chmod 644 basic" "$binary" 644 "$test_file1"
    test_command_succeeds "chmod 755 executable" "$binary" 755 "$test_file2"
    test_command_succeeds "chmod 600 restricted" "$binary" 600 "$test_file1"
    
    # Verify permissions were actually set
    local perms=$(get_file_permissions "$test_file1")
    if [[ "$perms" == "600" ]]; then
        print_test_result "chmod 600 verification" "PASS"
    else
        print_test_result "chmod 600 verification" "FAIL" "Got permissions: $perms"
    fi
    
    perms=$(get_file_permissions "$test_file2")
    if [[ "$perms" == "755" ]]; then
        print_test_result "chmod 755 verification" "PASS"
    else
        print_test_result "chmod 755 verification" "FAIL" "Got permissions: $perms"
    fi
    
    echo -e "${CYAN}Testing symbolic mode functionality...${NC}"
    
    # Test symbolic modes - absolute
    test_command_succeeds "chmod u=rw basic" "$binary" u=rw "$test_file1"
    test_command_succeeds "chmod g=r basic" "$binary" g=r "$test_file1"
    test_command_succeeds "chmod o= basic" "$binary" o= "$test_file1"
    test_command_succeeds "chmod a=rwx all" "$binary" a=rwx "$test_file2"
    
    # Test symbolic modes - add permissions
    test_command_succeeds "chmod u+x add execute" "$binary" u+x "$test_file1"
    test_command_succeeds "chmod g+w add write" "$binary" g+w "$test_file1"
    test_command_succeeds "chmod o+r add read" "$binary" o+r "$test_file1"
    test_command_succeeds "chmod a+x add all execute" "$binary" a+x "$test_file1"
    
    # Test symbolic modes - remove permissions
    chmod 777 "$test_file1"  # Set known state
    test_command_succeeds "chmod u-w remove write" "$binary" u-w "$test_file1"
    test_command_succeeds "chmod g-x remove execute" "$binary" g-x "$test_file1"
    test_command_succeeds "chmod o-r remove read" "$binary" o-r "$test_file1"
    test_command_succeeds "chmod a-w remove all write" "$binary" a-w "$test_file1"
    
    # Test special permission bits
    test_command_succeeds "chmod u+s setuid" "$binary" u+s "$test_file1"
    test_command_succeeds "chmod g+s setgid" "$binary" g+s "$test_file1"
    test_command_succeeds "chmod +t sticky" "$binary" +t "$test_dir"
    
    echo -e "${CYAN}Testing multiple mode specifications...${NC}"
    
    # Test comma-separated modes
    test_command_succeeds "chmod multiple modes" "$binary" u=rw,g=r,o=r "$test_file1"
    test_command_succeeds "chmod mixed operations" "$binary" u+x,g-w,o=r "$test_file1"
    test_command_succeeds "chmod complex modes" "$binary" u=rwx,g=rx,o=x "$test_file1"
    
    echo -e "${CYAN}Testing recursive functionality (-R)...${NC}"
    
    # Create directory structure for recursive tests
    local test_tree=$(create_temp_dir)
    mkdir -p "$test_tree/subdir1/subdir2"
    local file1="$test_tree/file1"
    local file2="$test_tree/subdir1/file2"
    local file3="$test_tree/subdir1/subdir2/file3"
    create_temp_file "content1" "$file1"
    create_temp_file "content2" "$file2"
    create_temp_file "content3" "$file3"
    
    # Test recursive mode change
    test_command_succeeds "chmod -R 644 recursive" "$binary" -R 644 "$test_tree"
    
    # Verify recursive changes
    for file in "$file1" "$file2" "$file3"; do
        local perms=$(get_file_permissions "$file")
        if [[ "$perms" == "644" ]]; then
            print_test_result "chmod -R verification $(basename "$file")" "PASS"
        else
            print_test_result "chmod -R verification $(basename "$file")" "FAIL" "Got: $perms"
        fi
    done
    
    # Test recursive with symbolic modes
    test_command_succeeds "chmod -R u+x recursive symbolic" "$binary" -R u+x "$test_tree"
    
    # Test recursive on single file (should work)
    test_command_succeeds "chmod -R single file" "$binary" -R 600 "$test_file1"
    
    echo -e "${CYAN}Testing reference mode (--reference)...${NC}"
    
    # Set up reference file with specific permissions
    local ref_file=$(create_temp_file "reference")
    chmod 754 "$ref_file"
    
    # Test reference mode
    test_command_succeeds "chmod --reference basic" "$binary" --reference="$ref_file" "$test_file1"
    
    # Verify reference mode worked
    local ref_perms=$(get_file_permissions "$ref_file")
    local target_perms=$(get_file_permissions "$test_file1")
    if [[ "$ref_perms" == "$target_perms" ]]; then
        print_test_result "chmod --reference verification" "PASS"
    else
        print_test_result "chmod --reference verification" "FAIL" "Ref: $ref_perms, Target: $target_perms"
    fi
    
    # Test reference with multiple files
    test_command_succeeds "chmod --reference multiple" "$binary" --reference="$ref_file" "$test_file1" "$test_file2"
    
    echo -e "${CYAN}Testing verbose output (-v, --verbose)...${NC}"
    
    # Test verbose mode
    local verbose_output
    verbose_output=$("$binary" -v 644 "$test_file1" 2>&1)
    if [[ -n "$verbose_output" ]]; then
        print_test_result "chmod -v produces output" "PASS"
    else
        print_test_result "chmod -v produces output" "FAIL" "No verbose output"
    fi
    
    # Test verbose with no changes
    chmod 644 "$test_file1"  # Set to same mode
    verbose_output=$("$binary" -v 644 "$test_file1" 2>&1)
    if [[ -n "$verbose_output" ]]; then
        print_test_result "chmod -v no change output" "PASS"
    else
        print_test_result "chmod -v no change output" "FAIL" "No output for no-change"
    fi
    
    echo -e "${CYAN}Testing changes mode (-c, --changes)...${NC}"
    
    # Test changes mode (only show when changes are made)
    chmod 755 "$test_file1"  # Set different mode
    local changes_output
    changes_output=$("$binary" -c 644 "$test_file1" 2>&1)
    if [[ -n "$changes_output" ]]; then
        print_test_result "chmod -c shows changes" "PASS"
    else
        print_test_result "chmod -c shows changes" "FAIL" "No output for change"
    fi
    
    # Test changes mode with no changes
    changes_output=$("$binary" -c 644 "$test_file1" 2>&1)
    if [[ -z "$changes_output" ]]; then
        print_test_result "chmod -c no output for no change" "PASS"
    else
        print_test_result "chmod -c no output for no change" "FAIL" "Unexpected output: $changes_output"
    fi
    
    echo -e "${CYAN}Testing silent mode (-f, --silent)...${NC}"
    
    # Test silent mode with error (non-existent file)
    local silent_output
    silent_output=$("$binary" -f 644 "/nonexistent/file" 2>&1)
    if [[ -z "$silent_output" ]]; then
        print_test_result "chmod -f suppresses errors" "PASS"
    else
        print_test_result "chmod -f suppresses errors" "FAIL" "Got output: $silent_output"
    fi
    
    # Test that silent mode still reports success
    test_command_succeeds "chmod -f successful operation" "$binary" -f 644 "$test_file1"
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Test multiple flags together
    test_command_succeeds "chmod -Rv combination" "$binary" -R -v 755 "$test_tree"
    test_command_succeeds "chmod -cf combination" "$binary" -c -f 644 "$test_file1"
    
    echo -e "${CYAN}Testing edge cases and error conditions...${NC}"
    
    # Test invalid octal modes
    test_command_fails "chmod invalid octal 999" "$binary" 999 "$test_file1"
    test_command_fails "chmod invalid octal 888" "$binary" 888 "$test_file1"
    
    # Test invalid symbolic modes
    test_command_fails "chmod invalid symbolic xyz" "$binary" xyz "$test_file1"
    test_command_fails "chmod invalid operator u%r" "$binary" "u%r" "$test_file1"
    
    # Test non-existent files
    test_command_fails "chmod non-existent file" "$binary" 644 "/path/that/does/not/exist"
    
    # Test permission denied (create unwritable directory)
    local unwritable_dir=$(create_temp_dir)
    local protected_file="$unwritable_dir/protected"
    create_temp_file "protected" "$protected_file"
    chmod 555 "$unwritable_dir"  # Remove write permission from directory
    
    # This should succeed (changing file mode, not directory)
    test_command_succeeds "chmod in readonly dir" "$binary" 644 "$protected_file"
    
    chmod 755 "$unwritable_dir"  # Restore for cleanup
    
    # Test with no arguments
    test_command_fails "chmod no arguments" "$binary"
    
    # Test with mode but no files
    test_command_fails "chmod mode only" "$binary" 644
    
    echo -e "${CYAN}Testing special mode formats...${NC}"
    
    # Test 4-digit octal modes (with special bits)
    test_command_succeeds "chmod 4755 setuid" "$binary" 4755 "$test_file1"
    test_command_succeeds "chmod 2755 setgid" "$binary" 2755 "$test_file1"
    test_command_succeeds "chmod 1755 sticky" "$binary" 1755 "$test_file1"
    test_command_succeeds "chmod 6755 setuid+setgid" "$binary" 6755 "$test_file1"
    
    # Test relative symbolic modes with special bits
    test_command_succeeds "chmod u+s,g+s special" "$binary" u+s,g+s "$test_file1"
    test_command_succeeds "chmod =rwx,+t special" "$binary" =rwx,+t "$test_dir"
    
    echo -e "${CYAN}Testing mode copying between users...${NC}"
    
    # Test copying permissions between user/group/other
    chmod 754 "$test_file1"  # Set known state: rwx r-x r--
    test_command_succeeds "chmod g=u copy user to group" "$binary" g=u "$test_file1"
    test_command_succeeds "chmod o=g copy group to other" "$binary" o=g "$test_file1"
    test_command_succeeds "chmod u=o copy other to user" "$binary" u=o "$test_file1"
    
    echo -e "${CYAN}Testing multiple file operations...${NC}"
    
    # Test changing multiple files at once
    test_command_succeeds "chmod multiple files" "$binary" 644 "$test_file1" "$test_file2"
    
    # Verify both files changed
    for file in "$test_file1" "$test_file2"; do
        local perms=$(get_file_permissions "$file")
        if [[ "$perms" == "644" ]]; then
            print_test_result "chmod multiple files verification $(basename "$file")" "PASS"
        else
            print_test_result "chmod multiple files verification $(basename "$file")" "FAIL" "Got: $perms"
        fi
    done
    
    # Test partial failure (some files succeed, some fail)
    test_command_fails "chmod partial failure" "$binary" 644 "$test_file1" "/nonexistent" "$test_file2"
    
    echo -e "${CYAN}Testing GNU compatibility...${NC}"
    
    # Test long options
    test_command_succeeds "chmod --recursive" "$binary" --recursive 755 "$test_tree"
    test_command_succeeds "chmod --verbose" "$binary" --verbose 644 "$test_file1"
    test_command_succeeds "chmod --changes" "$binary" --changes 755 "$test_file1"
    test_command_succeeds "chmod --silent" "$binary" --silent 644 "$test_file1"
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX-required functionality
    test_command_succeeds "POSIX: octal mode" "$binary" 644 "$test_file1"
    test_command_succeeds "POSIX: symbolic mode" "$binary" u=rw,g=r,o=r "$test_file1"
    test_command_succeeds "POSIX: recursive" "$binary" -R 755 "$test_tree"
    
    # Test exit codes
    test_command_exit_code "chmod success exit code" 0 "$binary" 644 "$test_file1"
    test_command_exit_code "chmod failure exit code" 1 "$binary" 644 "/nonexistent" 2>/dev/null || true
    
    echo -e "${CYAN}Testing performance with large directory trees...${NC}"
    
    # Create a moderately large directory tree
    local large_tree=$(create_temp_dir)
    for i in {1..10}; do
        mkdir -p "$large_tree/dir$i"
        for j in {1..5}; do
            create_temp_file "content$i$j" "$large_tree/dir$i/file$j"
        done
    done
    
    # Test recursive operation on large tree
    test_command_succeeds "chmod -R large tree" "$binary" -R 644 "$large_tree"
    
    # Verify a sampling of the files
    local sample_file="$large_tree/dir5/file3"
    local perms=$(get_file_permissions "$sample_file")
    if [[ "$perms" == "644" ]]; then
        print_test_result "chmod -R large tree verification" "PASS"
    else
        print_test_result "chmod -R large tree verification" "FAIL" "Sample file has: $perms"
    fi
}