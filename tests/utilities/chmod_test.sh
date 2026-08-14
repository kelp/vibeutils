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

    # Ensure permissions allow access
    chmod 755 "$test_tree" "$test_tree/subdir1" "$test_tree/subdir1/subdir2"

    # Test recursive mode change with a sensible mode (755 works for both files and directories)
    test_command_succeeds "chmod -R 755 recursive" "$binary" -R 755 "$test_tree"

    # Verify recursive changes - 755 works for both files and directories
    for file in "$file1" "$file2" "$file3"; do
        # Debug: Check if file exists and is accessible
        if [[ ! -e "$file" ]]; then
            print_test_result "chmod -R verification $(basename "$file")" "FAIL" "File does not exist: $file"
            continue
        fi

        local perms
        perms=$(get_file_permissions "$file")

        if [[ "$perms" == "755" ]]; then
            print_test_result "chmod -R verification $(basename "$file")" "PASS"
        else
            print_test_result "chmod -R verification $(basename "$file")" "FAIL" "Got: $perms (file: $file)"
        fi
    done

    # Test the behavior when directories become inaccessible (this is correct POSIX behavior)
    echo -e "${CYAN}Testing directory accessibility with 644 permissions...${NC}"
    local test_tree_644=$(create_temp_dir)
    mkdir -p "$test_tree_644/subdir"
    create_temp_file "content" "$test_tree_644/file1"
    create_temp_file "content" "$test_tree_644/subdir/file2"
    chmod 755 "$test_tree_644" "$test_tree_644/subdir"

    # Apply 644 recursively - this SHOULD make directories inaccessible
    test_command_succeeds "chmod -R 644 makes dirs inaccessible" "$binary" -R 644 "$test_tree_644"

    # Verify that the root directory now has 644 permissions (correct behavior)
    local dir_perms
    dir_perms=$(get_file_permissions "$test_tree_644")

    if [[ "$dir_perms" == "644" ]]; then
        print_test_result "chmod -R 644 on directory" "PASS"

        # Verify that the directory lost execute permission (expected behavior)
        if [[ ! -x "$test_tree_644" ]]; then
            print_test_result "chmod -R 644 makes directory inaccessible" "PASS"
        else
            print_test_result "chmod -R 644 makes directory inaccessible" "FAIL" "Directory should not have execute permission"
        fi
    else
        print_test_result "chmod -R 644 on directory" "FAIL" "Got: $dir_perms"
    fi

    # Restore access for cleanup
    chmod u+x "$test_tree_644" "$test_tree_644/subdir" 2>/dev/null || true

    # Test recursive with symbolic modes (use fresh test tree to avoid cleanup issues)
    local test_tree_symbolic=$(create_temp_dir)
    mkdir -p "$test_tree_symbolic/subdir1/subdir2"
    create_temp_file "content1" "$test_tree_symbolic/file1"
    create_temp_file "content2" "$test_tree_symbolic/subdir1/file2"
    create_temp_file "content3" "$test_tree_symbolic/subdir1/subdir2/file3"
    chmod 755 "$test_tree_symbolic" "$test_tree_symbolic/subdir1" "$test_tree_symbolic/subdir1/subdir2"
    test_command_succeeds "chmod -R u+x recursive symbolic" "$binary" -R u+x "$test_tree_symbolic"

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

    # Test multiple flags together (create fresh test tree)
    local test_tree_2=$(create_temp_dir)
    mkdir -p "$test_tree_2/subdir"
    create_temp_file "content" "$test_tree_2/file1"
    create_temp_file "content" "$test_tree_2/subdir/file2"
    chmod 755 "$test_tree_2" "$test_tree_2/subdir"
    test_command_succeeds "chmod -Rv combination" "$binary" -R -v 755 "$test_tree_2"
    test_command_succeeds "chmod -cf combination" "$binary" -c -f 644 "$test_file1"

    echo -e "${CYAN}Testing edge cases and error conditions...${NC}"

    # Test invalid octal modes
    test_command_fails "chmod invalid octal 999" "$binary" 999 "$test_file1"
    test_command_fails "chmod invalid octal 888" "$binary" 888 "$test_file1"

    # Regression: an invalid numeric mode reports "invalid mode: '999'" once.
    # It must NOT append a second "operation failed: InvalidOctalMode" line
    # leaking the raw Zig error variant. GNU prints only "invalid mode".
    local chmod_badmode_stderr
    chmod_badmode_stderr=$("$binary" 999 "$test_file1" 2>&1 >/dev/null)
    if [[ "$chmod_badmode_stderr" == *"invalid mode: '999'"* && \
          "$chmod_badmode_stderr" != *"operation failed"* && \
          "$chmod_badmode_stderr" != *"InvalidOctalMode"* ]]; then
        print_test_result "chmod invalid numeric mode has no redundant error line" "PASS"
    else
        print_test_result "chmod invalid numeric mode has no redundant error line" "FAIL" \
            "Expected single \"invalid mode: '999'\" line without raw variant, got: '$chmod_badmode_stderr'"
    fi

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
        # Debug: Check if file exists and is accessible
        if [[ ! -e "$file" ]]; then
            print_test_result "chmod multiple files verification $(basename "$file")" "FAIL" "File does not exist: $file"
            continue
        fi

        local perms
        perms=$(get_file_permissions "$file")

        if [[ "$perms" == "644" ]]; then
            print_test_result "chmod multiple files verification $(basename "$file")" "PASS"
        else
            print_test_result "chmod multiple files verification $(basename "$file")" "FAIL" "Got: $perms (file: $file)"
        fi
    done

    # Test partial failure (some files succeed, some fail)
    test_command_fails "chmod partial failure" "$binary" 644 "$test_file1" "/nonexistent" "$test_file2"

    echo -e "${CYAN}Testing GNU compatibility...${NC}"

    # Test long options (create fresh test tree)
    local test_tree_3=$(create_temp_dir)
    mkdir -p "$test_tree_3/subdir"
    create_temp_file "content" "$test_tree_3/file1"
    create_temp_file "content" "$test_tree_3/subdir/file2"
    chmod 755 "$test_tree_3" "$test_tree_3/subdir"
    test_command_succeeds "chmod --recursive" "$binary" --recursive 755 "$test_tree_3"
    test_command_succeeds "chmod --verbose" "$binary" --verbose 644 "$test_file1"
    test_command_succeeds "chmod --changes" "$binary" --changes 755 "$test_file1"
    test_command_succeeds "chmod --silent" "$binary" --silent 644 "$test_file1"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX-required functionality
    test_command_succeeds "POSIX: octal mode" "$binary" 644 "$test_file1"
    test_command_succeeds "POSIX: symbolic mode" "$binary" u=rw,g=r,o=r "$test_file1"

    # Create a fresh tree for POSIX recursive test
    local posix_test_tree=$(create_temp_dir)
    mkdir -p "$posix_test_tree/subdir"
    create_temp_file "content" "$posix_test_tree/file1"
    create_temp_file "content" "$posix_test_tree/subdir/file2"
    chmod 755 "$posix_test_tree" "$posix_test_tree/subdir"
    test_command_succeeds "POSIX: recursive" "$binary" -R 755 "$posix_test_tree"

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

    # Test recursive operation on large tree (using 755 which works for both files and directories)
    test_command_succeeds "chmod -R large tree" "$binary" -R 755 "$large_tree"

    # Verify a sampling of the files
    local sample_file="$large_tree/dir5/file3"
    if [[ ! -e "$sample_file" ]]; then
        print_test_result "chmod -R large tree verification" "FAIL" "Sample file does not exist: $sample_file"
    else
        local perms
        perms=$(get_file_permissions "$sample_file")

        if [[ "$perms" == "755" ]]; then
            print_test_result "chmod -R large tree verification" "PASS"
        else
            print_test_result "chmod -R large tree verification" "FAIL" "Sample file has: $perms"
        fi
    fi

    # Test specific file-only recursive operation to demonstrate proper 644 usage
    echo -e "${CYAN}Testing 644 on files only (proper usage pattern)...${NC}"
    local files_only_tree=$(create_temp_dir)
    for i in {1..3}; do
        mkdir -p "$files_only_tree/dir$i"
        create_temp_file "content$i" "$files_only_tree/dir$i/file$i"
    done

    # First, ensure directories have proper permissions (755)
    find "$files_only_tree" -type d -exec "$(host_resolve chmod)" 755 {} \;
    # Then, apply 644 only to files (this is the proper way to use 644 recursively)
    find "$files_only_tree" -type f -exec "$binary" 644 {} \;

    # Verify files have 644 and directories still have 755
    local sample_file_644="$files_only_tree/dir2/file2"
    local sample_dir="$files_only_tree/dir2"

    local file_perms=""
    local dir_perms=""

    file_perms=$(get_file_permissions "$sample_file_644")
    dir_perms=$(get_file_permissions "$sample_dir")

    if [[ "$file_perms" == "644" && "$dir_perms" == "755" ]]; then
        print_test_result "files 644, directories 755 (proper pattern)" "PASS"
    else
        print_test_result "files 644, directories 755 (proper pattern)" "FAIL" "File: $file_perms, Dir: $dir_perms"
    fi

    # Regression test: sticky bit must work with any who specifier (u+t, g+t), not just o+t
    echo -e "${CYAN}Testing sticky bit with various who specifiers...${NC}"

    local sticky_file=$(create_temp_file "sticky test")
    chmod 755 "$sticky_file"

    # u+t should set the sticky bit
    test_command_succeeds "chmod u+t sets sticky bit" "$binary" u+t "$sticky_file"
    local sticky_perms=""
    sticky_perms=$(get_file_permissions "$sticky_file")
    if [[ "$sticky_perms" == "1755" ]]; then
        print_test_result "chmod u+t sticky bit verification" "PASS"
    else
        print_test_result "chmod u+t sticky bit verification" "FAIL" "Expected 1755, got: $sticky_perms"
    fi

    # Remove sticky bit for next test
    chmod 0755 "$sticky_file"

    # g+t should also set the sticky bit
    test_command_succeeds "chmod g+t sets sticky bit" "$binary" g+t "$sticky_file"
    sticky_perms=""
    sticky_perms=$(get_file_permissions "$sticky_file")
    if [[ "$sticky_perms" == "1755" ]]; then
        print_test_result "chmod g+t sticky bit verification" "PASS"
    else
        print_test_result "chmod g+t sticky bit verification" "FAIL" "Expected 1755, got: $sticky_perms"
    fi

    # a-t should remove the sticky bit
    test_command_succeeds "chmod a-t removes sticky bit" "$binary" a-t "$sticky_file"
    sticky_perms=""
    sticky_perms=$(get_file_permissions "$sticky_file")
    if [[ "$sticky_perms" == "755" ]]; then
        print_test_result "chmod a-t sticky bit removed" "PASS"
    else
        print_test_result "chmod a-t sticky bit removed" "FAIL" "Expected 755, got: $sticky_perms"
    fi

    # Regression test: AccessDenied propagated correctly
    # chmod on a file inside a directory with no execute permission
    # should report "Permission denied", not silently apply wrong mode
    echo -e "${CYAN}Testing AccessDenied propagation...${NC}"

    local ad_dir=$(create_temp_dir)
    local ad_file="$ad_dir/target"
    create_temp_file "access denied test" "$ad_file"
    chmod 644 "$ad_file"
    # Remove execute permission on the parent directory so the file
    # becomes inaccessible
    chmod 644 "$ad_dir"

    local ad_cmd ad_out ad_err ad_exit
    run_command ad_cmd ad_out ad_err ad_exit "$binary" 755 "$ad_file"
    if [[ $ad_exit -ne 0 ]]; then
        print_test_result "chmod inaccessible dir exits non-zero" "PASS"
    else
        print_test_result "chmod inaccessible dir exits non-zero" "FAIL" \
            "Expected non-zero exit, got 0"
    fi
    if [[ "$ad_err" == *"ermission denied"* || "$ad_err" == *"Permission denied"* ]]; then
        print_test_result "chmod inaccessible dir reports Permission denied" "PASS"
    else
        print_test_result "chmod inaccessible dir reports Permission denied" "FAIL" \
            "Expected 'Permission denied' in stderr, got: '$ad_err'"
    fi

    # Restore for cleanup
    chmod 755 "$ad_dir"

    # =========================================================================
    # Behavioral verification tests (audit finding F69)
    # These tests verify that chmod ACTUALLY CHANGES file permissions on disk,
    # not just that the command exits successfully.
    # =========================================================================

    echo -e "${CYAN}Testing behavioral permission changes...${NC}"

    # --- Test: chmod 755 actually produces mode 755 ---
    local btest_file=$(create_temp_file "behavioral test")
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod 755" "$binary" 755 "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "755" ]]; then
        print_test_result "behavioral: chmod 755 produces 755" "PASS"
    else
        print_test_result "behavioral: chmod 755 produces 755" "FAIL" "Expected 755, got: $perms"
    fi

    # --- Test: chmod u+x from 644 produces 744 ---
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod u+x" "$binary" u+x "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "744" ]]; then
        print_test_result "behavioral: chmod u+x from 644 produces 744" "PASS"
    else
        print_test_result "behavioral: chmod u+x from 644 produces 744" "FAIL" "Expected 744, got: $perms"
    fi

    # --- Test: chmod g+w from 644 produces 664 ---
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod g+w" "$binary" g+w "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "664" ]]; then
        print_test_result "behavioral: chmod g+w from 644 produces 664" "PASS"
    else
        print_test_result "behavioral: chmod g+w from 644 produces 664" "FAIL" "Expected 664, got: $perms"
    fi

    # --- Test: chmod o-r from 644 produces 640 ---
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod o-r" "$binary" o-r "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "640" ]]; then
        print_test_result "behavioral: chmod o-r from 644 produces 640" "PASS"
    else
        print_test_result "behavioral: chmod o-r from 644 produces 640" "FAIL" "Expected 640, got: $perms"
    fi

    # --- Test: chmod a+x from 644 produces 755 ---
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod a+x" "$binary" a+x "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "755" ]]; then
        print_test_result "behavioral: chmod a+x from 644 produces 755" "PASS"
    else
        print_test_result "behavioral: chmod a+x from 644 produces 755" "FAIL" "Expected 755, got: $perms"
    fi

    # --- Test: chmod u=rwx,g=rx,o=r produces 754 ---
    chmod 000 "$btest_file"
    test_command_succeeds "behavioral: chmod u=rwx,g=rx,o=r" "$binary" u=rwx,g=rx,o=r "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "754" ]]; then
        print_test_result "behavioral: chmod u=rwx,g=rx,o=r produces 754" "PASS"
    else
        print_test_result "behavioral: chmod u=rwx,g=rx,o=r produces 754" "FAIL" "Expected 754, got: $perms"
    fi

    # --- Test: chmod +t on directory sets sticky bit ---
    local btest_dir=$(create_temp_dir)
    chmod 755 "$btest_dir"
    test_command_succeeds "behavioral: chmod +t on dir" "$binary" +t "$btest_dir"
    perms=$(get_file_permissions "$btest_dir")
    if [[ "$perms" == "1755" ]]; then
        print_test_result "behavioral: chmod +t sets sticky bit (1755)" "PASS"
    else
        print_test_result "behavioral: chmod +t sets sticky bit (1755)" "FAIL" "Expected 1755, got: $perms"
    fi

    # --- Test: chmod 4755 sets setuid bit ---
    chmod 644 "$btest_file"
    test_command_succeeds "behavioral: chmod 4755" "$binary" 4755 "$btest_file"
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "4755" ]]; then
        print_test_result "behavioral: chmod 4755 sets setuid (4755)" "PASS"
    else
        print_test_result "behavioral: chmod 4755 sets setuid (4755)" "FAIL" "Expected 4755, got: $perms"
    fi

    # --- Test: chmod -w should remove write permission (known bug) ---
    # BUG: chmod -w file is parsed as a flag by argparse, not as a
    # symbolic mode. This test documents the bug.
    echo -e "${CYAN}Testing chmod -w bug (mode string starting with -)...${NC}"
    chmod 644 "$btest_file"
    local mw_cmd mw_out mw_err mw_exit
    run_command mw_cmd mw_out mw_err mw_exit "$binary" -w "$btest_file"
    if [[ $mw_exit -eq 0 ]]; then
        print_test_result "behavioral: chmod -w exits 0" "PASS"
    else
        print_test_result "behavioral: chmod -w exits 0" "FAIL" \
            "Expected exit 0, got: $mw_exit (stderr: $mw_err)"
    fi
    perms=$(get_file_permissions "$btest_file")
    if [[ "$perms" == "444" ]]; then
        print_test_result "behavioral: chmod -w from 644 produces 444" "PASS"
    else
        print_test_result "behavioral: chmod -w from 644 produces 444" "FAIL" \
            "Expected 444, got: $perms"
    fi

    # =========================================================================
    # Walker cycle_mode tests (issue #60).
    #
    # Reference behavior pinned against GNU coreutils 9.5 chmod -RL:
    #   - A directory reached via two distinct paths (a real directory and a
    #     sibling symlink alias pointing at it) is chmod'd through BOTH
    #     paths; there is no directory-level dedup (unlike GNU du).
    #   - A symlink that forms an ancestor cycle (points back up at one of
    #     its own ancestor directories) does not cause infinite descent, AND
    #     the cycle-forming symlink itself is still serviced as an ordinary
    #     leaf (chmod is applied to the symlink path, it just isn't
    #     descended into again).
    # Current vibeutils chmod (global visited-set cycle detection) drops the
    # second-encountered alias entirely, and never services the
    # cycle-forming symlink itself as a leaf -- both are bugs this section
    # locks in the fix for.
    # =========================================================================

    echo -e "${CYAN}Testing chmod -RL walker cycle/alias behavior (issue #60)...${NC}"

    # --- Sibling alias: both the real directory and the symlink alias must
    # receive the mode change under -RL. ---
    local alias_root=$(create_temp_dir)
    mkdir -p "$alias_root/real"
    create_temp_file "alias test" "$alias_root/real/f"
    chmod 700 "$alias_root/real"
    chmod 600 "$alias_root/real/f"
    ln -s real "$alias_root/link"

    local alias_out="$TEMP_DIR/chmod_alias_out.txt"
    local alias_err="$TEMP_DIR/chmod_alias_err.txt"
    "$binary" -v -RL 755 "$alias_root" >"$alias_out" 2>"$alias_err"
    local alias_rc=$?

    if [[ $alias_rc -eq 0 ]]; then
        print_test_result "chmod -RL sibling alias exits 0" "PASS"
    else
        print_test_result "chmod -RL sibling alias exits 0" "FAIL" \
            "Expected rc=0, got: $alias_rc (stderr: $(cat "$alias_err"))"
    fi

    # This is the assertion that actually distinguishes the alias-skip bug:
    # both "real/f" and "link/f" must be reported as chmod'd. Currently
    # only whichever alias readdir returns first is processed; the other
    # is silently dropped by the global visited-set.
    if grep -q "real/f" "$alias_out" && grep -q "link/f" "$alias_out"; then
        print_test_result "chmod -RL sibling alias processes both real and link" "PASS"
    else
        print_test_result "chmod -RL sibling alias processes both real and link" "FAIL" \
            "Expected verbose output mentioning both 'real/f' and 'link/f', got: $(cat "$alias_out")"
    fi

    # Also verify the on-disk mode through both paths. Note real/f and
    # link/f are the same underlying inode, so this is a sanity check on
    # top of (not a replacement for) the verbose-output assertion above.
    local real_f_perms=$(get_file_permissions "$alias_root/real/f")
    local link_f_perms=$(get_file_permissions "$alias_root/link/f")
    if [[ "$real_f_perms" == "755" && "$link_f_perms" == "755" ]]; then
        print_test_result "chmod -RL sibling alias: mode matches via both paths" "PASS"
    else
        print_test_result "chmod -RL sibling alias: mode matches via both paths" "FAIL" \
            "Expected 755/755, got real/f=$real_f_perms link/f=$link_f_perms"
    fi

    # --- Ancestor loop: a symlink pointing back at an ancestor directory
    # must not cause infinite descent, and GNU services the cycle-forming
    # symlink itself as an ordinary leaf (no diagnostic, rc=0). Bounded
    # with run_with_limit since the current bug walks to depth 1024 before
    # erroring out. ---
    local cyc_root=$(create_temp_dir)
    mkdir -p "$cyc_root/cyc/inner"
    ln -s .. "$cyc_root/cyc/inner/up"
    chmod 700 "$cyc_root" "$cyc_root/cyc" "$cyc_root/cyc/inner"

    local cyc_out="$TEMP_DIR/chmod_cyc_out.txt"
    local cyc_err="$TEMP_DIR/chmod_cyc_err.txt"
    run_with_limit 10 "$binary" -v -RL 755 "$cyc_root" >"$cyc_out" 2>"$cyc_err"
    local cyc_rc=$?

    if [[ $cyc_rc -eq 0 ]]; then
        print_test_result "chmod -RL ancestor loop terminates cleanly (rc=0)" "PASS"
    else
        print_test_result "chmod -RL ancestor loop terminates cleanly (rc=0)" "FAIL" \
            "Expected rc=0, got: $cyc_rc (stdout: $(cat "$cyc_out") stderr: $(cat "$cyc_err"))"
    fi

    # GNU chmod -RL services the cycle-forming symlink itself as a leaf
    # ("mode of '.../up' ..."); today's global visited-set silently drops
    # it entirely with no line at all.
    if grep -q "cyc/inner/up" "$cyc_out"; then
        print_test_result "chmod -RL ancestor loop services cycle symlink as a leaf" "PASS"
    else
        print_test_result "chmod -RL ancestor loop services cycle symlink as a leaf" "FAIL" \
            "Expected verbose output mentioning 'cyc/inner/up', got: $(cat "$cyc_out")"
    fi

    # Restore access for cleanup.
    chmod -R u+rwx "$cyc_root" 2>/dev/null || true
    chmod -R u+rwx "$alias_root" 2>/dev/null || true

    echo -e "${CYAN}Testing ambiguous-abbreviation candidate order (issue #128)...${NC}"

    # GNU orders an ambiguous option's candidates by its own longopts table,
    # not by vibeutils' Args field-declaration order. Re-pinned against real
    # GNU coreutils 9.4 on this host:
    #   $ LC_ALL=C /usr/bin/chmod --v
    #   /usr/bin/chmod: option '--v' is ambiguous; possibilities: '--verbose' '--version'
    # so '--verbose' comes FIRST; vibeutils lists '--version' first today.
    local abbrev_v_cmd="" abbrev_v_out="" abbrev_v_err="" abbrev_v_exit=""
    run_command abbrev_v_cmd abbrev_v_out abbrev_v_err abbrev_v_exit "$binary" --v
    local abbrev_v_expected="chmod: option '--v' is ambiguous; possibilities: '--verbose' '--version'"$'\n'"Try 'chmod --help' for more information."
    if [[ $abbrev_v_exit -eq 1 && "$abbrev_v_err" == "$abbrev_v_expected" ]]; then
        print_test_result "chmod --v lists candidates in GNU longopts order" "PASS"
    else
        print_test_result "chmod --v lists candidates in GNU longopts order" "FAIL" \
            "Expected: '$abbrev_v_expected', got exit=$abbrev_v_exit stderr='$abbrev_v_err'"
    fi

}
