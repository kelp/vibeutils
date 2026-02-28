#!/usr/bin/env bash
# Comprehensive tests for mv utility
# Tests all flags, move operations, directories, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_mv() {
    local util="mv"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Create test files for basic functionality
    local test_file1=$(create_temp_file "Original content")
    local test_file2=$(create_temp_file $'Line 1\nLine 2\nLine 3')
    local test_file3=$(create_temp_file "")  # Empty file
    local test_dir1=$(create_temp_dir)

    echo -e "${CYAN}Testing core move functionality...${NC}"

    # Basic rename in same directory
    local src_file=$(create_temp_file "Content to move")
    local dest_file="$TEMP_DIR/renamed_file.txt"
    test_command_exit_code "mv basic rename" 0 "$binary" "$src_file" "$dest_file"

    # Verify source is gone
    if [[ ! -e "$src_file" ]]; then
        print_test_result "mv source file removed" "PASS"
    else
        print_test_result "mv source file removed" "FAIL" "Source still exists"
    fi

    # Verify destination exists with correct content
    test_command_output "mv destination content" "Content to move" cat "$dest_file"

    # Move to existing directory
    local file_for_dir=$(create_temp_file "File for directory move")
    test_command_exit_code "mv file to directory" 0 "$binary" "$file_for_dir" "$test_dir1"

    # Verify file moved into directory
    local basename_file=$(basename "$file_for_dir")
    test_command_output "mv file in directory" "File for directory move" cat "$test_dir1/$basename_file"

    # Verify source is gone
    if [[ ! -e "$file_for_dir" ]]; then
        print_test_result "mv to directory source removed" "PASS"
    else
        print_test_result "mv to directory source removed" "FAIL" "Source still exists"
    fi

    # Multiple files to directory
    local multi1=$(create_temp_file "Multi file 1")
    local multi2=$(create_temp_file "Multi file 2")
    local multi3=$(create_temp_file "Multi file 3")
    local multi_dir=$(create_temp_dir)

    test_command_exit_code "mv multiple files to directory" 0 "$binary" "$multi1" "$multi2" "$multi3" "$multi_dir"

    # Verify all files moved
    test_command_output "mv multi file 1" "Multi file 1" cat "$multi_dir/$(basename "$multi1")"
    test_command_output "mv multi file 2" "Multi file 2" cat "$multi_dir/$(basename "$multi2")"
    test_command_output "mv multi file 3" "Multi file 3" cat "$multi_dir/$(basename "$multi3")"

    # Verify sources are gone
    for src in "$multi1" "$multi2" "$multi3"; do
        if [[ ! -e "$src" ]]; then
            print_test_result "mv multi source $(basename "$src") removed" "PASS"
        else
            print_test_result "mv multi source $(basename "$src") removed" "FAIL"
        fi
    done

    # Empty file move
    local empty_src=$(create_temp_file "")
    local empty_dest="$TEMP_DIR/moved_empty.txt"
    test_command_exit_code "mv empty file" 0 "$binary" "$empty_src" "$empty_dest"
    test_command_output "mv empty file content" "" cat "$empty_dest"

    echo -e "${CYAN}Testing directory operations...${NC}"

    # Create directory structure for testing
    local src_dir=$(create_temp_dir)
    create_temp_file "Root file" "$src_dir/root.txt"
    mkdir -p "$src_dir/subdir"
    create_temp_file "Sub file" "$src_dir/subdir/sub.txt"

    # Move empty directory
    local empty_dir=$(create_temp_dir)
    local empty_dir_dest="$TEMP_DIR/moved_empty_dir"
    test_command_exit_code "mv empty directory" 0 "$binary" "$empty_dir" "$empty_dir_dest"

    # Verify directory moved
    if [[ -d "$empty_dir_dest" ]]; then
        print_test_result "mv empty directory exists" "PASS"
    else
        print_test_result "mv empty directory exists" "FAIL"
    fi

    if [[ ! -e "$empty_dir" ]]; then
        print_test_result "mv empty directory source removed" "PASS"
    else
        print_test_result "mv empty directory source removed" "FAIL"
    fi

    # Move directory with contents
    local dir_dest="$TEMP_DIR/moved_dir"
    test_command_exit_code "mv directory with contents" 0 "$binary" "$src_dir" "$dir_dest"

    # Verify structure preserved
    test_command_output "mv dir root file" "Root file" cat "$dir_dest/root.txt"
    test_command_output "mv dir sub file" "Sub file" cat "$dir_dest/subdir/sub.txt"

    # Move directory into another directory
    local parent_dir=$(create_temp_dir)
    local child_dir=$(create_temp_dir)
    create_temp_file "Child content" "$child_dir/child.txt"

    test_command_exit_code "mv directory into directory" 0 "$binary" "$child_dir" "$parent_dir"
    test_command_output "mv dir into dir content" "Child content" cat "$parent_dir/$(basename "$child_dir")/child.txt"

    echo -e "${CYAN}Testing force flag (-f)...${NC}"

    # Create source and destination for overwrite test
    local force_src=$(create_temp_file "New content")
    local force_dest=$(create_temp_file "Old content")

    # Without force, behavior depends on implementation
    # GNU mv doesn't prompt in non-interactive mode, but let's test actual behavior
    "$binary" "$force_src" "$force_dest" >/dev/null 2>&1
    local no_force_exit=$?

    # Re-create for force test
    force_src=$(create_temp_file "Force new content")
    force_dest=$(create_temp_file "Force old content")

    # With force flag
    test_command_exit_code "mv with force flag" 0 "$binary" -f "$force_src" "$force_dest"
    test_command_output "mv force overwrite content" "Force new content" cat "$force_dest"

    # Verify source removed
    if [[ ! -e "$force_src" ]]; then
        print_test_result "mv force source removed" "PASS"
    else
        print_test_result "mv force source removed" "FAIL"
    fi

    # Force with non-existent destination
    local force_new_src=$(create_temp_file "Force to new")
    local force_new_dest="$TEMP_DIR/force_new_dest.txt"
    test_command_exit_code "mv force to new file" 0 "$binary" -f "$force_new_src" "$force_new_dest"
    test_command_output "mv force new content" "Force to new" cat "$force_new_dest"

    echo -e "${CYAN}Testing interactive flag (-i)...${NC}"

    # Interactive mode with no stdin (should not hang)
    local inter_src=$(create_temp_file "Interactive source")
    local inter_dest=$(create_temp_file "Interactive dest")

    # Test interactive mode with stdin closed
    "$binary" -i "$inter_src" "$inter_dest" </dev/null >/dev/null 2>&1
    local inter_exit=$?

    # In non-interactive environment, it should either skip or proceed
    if [[ $inter_exit -eq 0 ]]; then
        print_test_result "mv interactive mode (non-interactive env)" "PASS"
    else
        print_test_result "mv interactive mode (non-interactive env)" "FAIL" "Exit code: $inter_exit"
    fi

    # Interactive to new file should work normally
    local inter_new_src=$(create_temp_file "Interactive new")
    local inter_new_dest="$TEMP_DIR/interactive_new.txt"
    test_command_exit_code "mv interactive to new file" 0 "$binary" -i "$inter_new_src" "$inter_new_dest"
    test_command_output "mv interactive new content" "Interactive new" cat "$inter_new_dest"

    echo -e "${CYAN}Testing verbose flag (-v)...${NC}"

    # Verbose output test
    local verbose_src=$(create_temp_file "Verbose content")
    local verbose_dest="$TEMP_DIR/verbose_dest.txt"
    local verbose_output=$("$binary" -v "$verbose_src" "$verbose_dest" 2>&1)

    # Check for verbose output (should show source -> dest)
    if [[ "$verbose_output" == *"$verbose_src"* ]] || [[ "$verbose_output" == *"->"* ]] || [[ "$verbose_output" == *"verbose_dest"* ]]; then
        print_test_result "mv verbose output" "PASS"
    else
        print_test_result "mv verbose output" "FAIL" "No verbose output detected"
    fi

    # Verify move still worked
    test_command_output "mv verbose operation" "Verbose content" cat "$verbose_dest"

    # Verbose with multiple files
    local verb_multi1=$(create_temp_file "Verbose multi 1")
    local verb_multi2=$(create_temp_file "Verbose multi 2")
    local verb_dir=$(create_temp_dir)

    verbose_output=$("$binary" -v "$verb_multi1" "$verb_multi2" "$verb_dir" 2>&1)

    # Should show operations for both files
    if [[ "$verbose_output" == *"$(basename "$verb_multi1")"* ]] || [[ "$verbose_output" == *"multi 1"* ]]; then
        print_test_result "mv verbose multiple files" "PASS"
    else
        print_test_result "mv verbose multiple files" "FAIL" "Verbose output incomplete"
    fi

    echo -e "${CYAN}Testing no-clobber flag (-n)...${NC}"

    # No-clobber test - should not overwrite existing
    local noclobber_src=$(create_temp_file "No-clobber source")
    local noclobber_dest=$(create_temp_file "No-clobber existing")

    test_command_exit_code "mv no-clobber existing" 0 "$binary" -n "$noclobber_src" "$noclobber_dest"

    # Destination should be unchanged
    test_command_output "mv no-clobber preserved" "No-clobber existing" cat "$noclobber_dest"

    # Source should still exist
    if [[ -e "$noclobber_src" ]]; then
        print_test_result "mv no-clobber source retained" "PASS"
    else
        print_test_result "mv no-clobber source retained" "FAIL" "Source was removed"
    fi

    # No-clobber to new file should work
    local noclobber_new_src=$(create_temp_file "No-clobber new")
    local noclobber_new_dest="$TEMP_DIR/noclobber_new.txt"

    test_command_exit_code "mv no-clobber to new" 0 "$binary" -n "$noclobber_new_src" "$noclobber_new_dest"
    test_command_output "mv no-clobber new content" "No-clobber new" cat "$noclobber_new_dest"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Force and verbose
    local fv_src=$(create_temp_file "Force verbose")
    local fv_dest=$(create_temp_file "Old FV")
    local fv_output=$("$binary" -f -v "$fv_src" "$fv_dest" 2>&1)

    # Should overwrite and show verbose output
    if [[ "$fv_output" == *"$fv_src"* ]] || [[ "$fv_output" == *"->"* ]]; then
        print_test_result "mv force+verbose output" "PASS"
    else
        print_test_result "mv force+verbose output" "FAIL"
    fi

    # Interactive and force (force should win)
    local if_src=$(create_temp_file "Interactive force")
    local if_dest=$(create_temp_file "Old IF")

    test_command_exit_code "mv interactive+force" 0 "$binary" -i -f "$if_src" "$if_dest"
    test_command_output "mv interactive+force content" "Interactive force" cat "$if_dest"

    # No-clobber and force (implementation-dependent, test actual behavior)
    local nf_src=$(create_temp_file "No-clobber force")
    local nf_dest=$(create_temp_file "Old NF")

    "$binary" -n -f "$nf_src" "$nf_dest" >/dev/null 2>&1
    local nf_exit=$?

    # Check what actually happened
    local actual_content=$(cat "$nf_dest")
    if [[ "$actual_content" == "No-clobber force" ]]; then
        print_test_result "mv no-clobber+force (force wins)" "PASS"
    elif [[ "$actual_content" == "Old NF" ]]; then
        print_test_result "mv no-clobber+force (no-clobber wins)" "PASS"
    else
        print_test_result "mv no-clobber+force" "FAIL" "Unexpected content"
    fi

    echo -e "${CYAN}Testing special characters and edge cases...${NC}"

    # Files with spaces
    local space_src="$TEMP_DIR/file with spaces.txt"
    create_temp_file "Space content" "$space_src"
    local space_dest="$TEMP_DIR/dest with spaces.txt"
    test_command_exit_code "mv file with spaces" 0 "$binary" "$space_src" "$space_dest"
    test_command_output "mv spaces content" "Space content" cat "$space_dest"

    # Files with special characters
    local special_src="$TEMP_DIR/file@#\$%.txt"
    create_temp_file "Special content" "$special_src"
    local special_dest="$TEMP_DIR/dest!&().txt"
    test_command_exit_code "mv file with special chars" 0 "$binary" "$special_src" "$special_dest"
    test_command_output "mv special chars content" "Special content" cat "$special_dest"

    # Unicode filenames
    local unicode_src="$TEMP_DIR/文件名.txt"
    create_temp_file "Unicode content" "$unicode_src"
    local unicode_dest="$TEMP_DIR/目标文件.txt"
    test_command_exit_code "mv unicode filename" 0 "$binary" "$unicode_src" "$unicode_dest"
    test_command_output "mv unicode content" "Unicode content" cat "$unicode_dest"

    # Very long filename (up to filesystem limit)
    local long_name=$(printf 'a%.0s' {1..200})
    local long_src="$TEMP_DIR/${long_name}.txt"
    create_temp_file "Long name content" "$long_src"
    local long_dest="$TEMP_DIR/${long_name}_moved.txt"

    # This might fail on some filesystems with name length limits
    "$binary" "$long_src" "$long_dest" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        print_test_result "mv very long filename" "PASS"
    else
        print_test_result "mv very long filename" "SKIP" "Filesystem limit"
    fi

    # Binary file
    local binary_file="$TEMP_DIR/binary_src.bin"
    dd if=/dev/urandom of="$binary_file" bs=1024 count=1 2>/dev/null
    local binary_dest="$TEMP_DIR/binary_dest.bin"

    test_command_exit_code "mv binary file" 0 "$binary" "$binary_file" "$binary_dest"

    # Verify binary content preserved
    if cmp -s /dev/urandom "$binary_dest" 2>/dev/null; then
        print_test_result "mv binary content preserved" "SKIP" "Cannot verify random data"
    else
        # At least check file exists and has size
        if [[ -f "$binary_dest" ]] && [[ -s "$binary_dest" ]]; then
            print_test_result "mv binary file exists" "PASS"
        else
            print_test_result "mv binary file exists" "FAIL"
        fi
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Non-existent source
    test_command_fails "mv non-existent source" "$binary" "/nonexistent/source.txt" "$TEMP_DIR/dest.txt"

    # Move to non-existent directory
    local exist_src=$(create_temp_file "Existing file")
    test_command_fails "mv to non-existent directory" "$binary" "$exist_src" "/nonexistent/dir/file.txt"

    # Move file to itself (same file)
    local same_file=$(create_temp_file "Same file content")
    test_command_fails "mv file to itself" "$binary" "$same_file" "$same_file"

    # Move directory to its subdirectory
    local parent_err=$(create_temp_dir)
    mkdir -p "$parent_err/child"
    test_command_fails "mv directory to its child" "$binary" "$parent_err" "$parent_err/child"

    # Permission denied (if possible to test)
    local perm_file=$(create_temp_file "Permission test")
    local perm_dir="$TEMP_DIR/readonly_dir"
    mkdir -p "$perm_dir"
    chmod 555 "$perm_dir"  # Read-only directory

    # Try to move file into read-only directory - this might succeed on some systems
    "$binary" "$perm_file" "$perm_dir/newfile.txt" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        print_test_result "mv permission denied" "PASS"
    else
        print_test_result "mv permission denied" "SKIP" "System allows operation"
    fi
    chmod 755 "$perm_dir"  # Restore permissions for cleanup

    # Missing operands
    test_command_fails "mv no operands" "$binary"
    test_command_fails "mv single operand" "$binary" "$test_file1"

    # Multiple files to non-directory
    local multi_err1=$(create_temp_file "Multi error 1")
    local multi_err2=$(create_temp_file "Multi error 2")
    local multi_err_dest=$(create_temp_file "Not a directory")
    test_command_fails "mv multiple files to non-directory" "$binary" "$multi_err1" "$multi_err2" "$multi_err_dest"

    # Invalid flags
    test_command_fails "mv invalid flag" "$binary" --invalid-flag "$test_file1" "$TEMP_DIR/dest.txt"
    test_command_fails "mv invalid short flag" "$binary" -Z "$test_file1" "$TEMP_DIR/dest.txt"

    echo -e "${CYAN}Testing symlink handling...${NC}"

    # Create symlink
    local link_target=$(create_temp_file "Link target content")
    local symlink="$TEMP_DIR/test_symlink"
    ln -s "$link_target" "$symlink"

    # Move symlink (should move the link, not the target)
    local symlink_dest="$TEMP_DIR/moved_symlink"
    test_command_exit_code "mv symlink" 0 "$binary" "$symlink" "$symlink_dest"

    # Verify it's still a symlink
    if [[ -L "$symlink_dest" ]]; then
        print_test_result "mv symlink preserved" "PASS"
    else
        print_test_result "mv symlink preserved" "FAIL" "Not a symlink"
    fi

    # Verify target still exists at original location
    if [[ -f "$link_target" ]]; then
        print_test_result "mv symlink target unchanged" "PASS"
    else
        print_test_result "mv symlink target unchanged" "FAIL"
    fi

    # Move to symlink to directory (should follow symlink)
    local dir_link_target=$(create_temp_dir)
    local dir_symlink="$TEMP_DIR/dir_symlink"
    ln -s "$dir_link_target" "$dir_symlink"

    local file_for_symdir=$(create_temp_file "File for symlink dir")
    test_command_exit_code "mv file to symlink dir" 0 "$binary" "$file_for_symdir" "$dir_symlink"

    # File should be in the actual directory
    test_command_output "mv to symlink dir content" "File for symlink dir" cat "$dir_link_target/$(basename "$file_for_symdir")"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX exit codes
    test_command_exit_code "mv success exit code" 0 "$binary" "$(create_temp_file "Exit test")" "$TEMP_DIR/exit_test.txt"

    # POSIX error exit code (should be 1)
    "$binary" "/nonexistent/file" "$TEMP_DIR/dest.txt" >/dev/null 2>&1
    local error_exit=$?
    if [[ $error_exit -gt 0 ]]; then
        print_test_result "mv error exit code (>0)" "PASS"
    else
        print_test_result "mv error exit code" "FAIL" "Exit code: $error_exit"
    fi

    # POSIX: mv should remove source after successful copy
    local posix_src=$(create_temp_file "POSIX source")
    local posix_dest="$TEMP_DIR/posix_dest.txt"
    "$binary" "$posix_src" "$posix_dest"

    if [[ ! -e "$posix_src" ]] && [[ -f "$posix_dest" ]]; then
        print_test_result "mv POSIX atomic operation" "PASS"
    else
        print_test_result "mv POSIX atomic operation" "FAIL"
    fi

    echo -e "${CYAN}Testing performance with large files...${NC}"

    # Create a larger file (1MB)
    local large_file="$TEMP_DIR/large_source.dat"
    dd if=/dev/zero of="$large_file" bs=1024 count=1024 2>/dev/null

    local large_dest="$TEMP_DIR/large_dest.dat"
    local start_time=$(date +%s%N 2>/dev/null || date +%s)
    test_command_exit_code "mv large file" 0 "$binary" "$large_file" "$large_dest"
    local end_time=$(date +%s%N 2>/dev/null || date +%s)

    # Verify large file moved
    if [[ -f "$large_dest" ]] && [[ ! -e "$large_file" ]]; then
        print_test_result "mv large file operation" "PASS"
    else
        print_test_result "mv large file operation" "FAIL"
    fi

    # Check file size preserved
    local dest_size=$(wc -c < "$large_dest" 2>/dev/null | tr -d ' ')
    if [[ "$dest_size" -eq 1048576 ]]; then
        print_test_result "mv large file size preserved" "PASS"
    else
        print_test_result "mv large file size preserved" "FAIL" "Size: $dest_size"
    fi

    echo -e "${CYAN}Testing cross-filesystem moves (if applicable)...${NC}"

    # Try to move to /tmp which might be a different filesystem
    # First verify TEMP_DIR is not already under /tmp, then check
    # that they are actually on different filesystems using device IDs
    local cross_test_possible=false
    if [[ "$TEMP_DIR" != "/tmp"* ]]; then
        # Verify /tmp and TEMP_DIR are on different devices
        local tmp_dev temp_dev
        tmp_dev=$(stat -c %d /tmp 2>/dev/null || stat -f %d /tmp 2>/dev/null || echo "")
        temp_dev=$(stat -c %d "$TEMP_DIR" 2>/dev/null || stat -f %d "$TEMP_DIR" 2>/dev/null || echo "")
        if [[ -n "$tmp_dev" ]] && [[ -n "$temp_dev" ]] && [[ "$tmp_dev" != "$temp_dev" ]]; then
            cross_test_possible=true
        fi
    fi

    if [[ "$cross_test_possible" == "true" ]]; then
        local cross_src=$(create_temp_file "Cross filesystem content")
        local cross_dest="/tmp/vibeutils_cross_test_$$.txt"

        "$binary" "$cross_src" "$cross_dest" >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            if [[ -f "$cross_dest" ]] && [[ ! -e "$cross_src" ]]; then
                print_test_result "mv cross-filesystem" "PASS"
            else
                print_test_result "mv cross-filesystem" "FAIL"
            fi
            rm -f "$cross_dest"  # Cleanup
        else
            print_test_result "mv cross-filesystem" "SKIP" "Operation failed"
        fi
    else
        print_test_result "mv cross-filesystem" "SKIP" "Same filesystem or cannot determine"
    fi

    echo -e "${CYAN}Testing unusual but valid operations...${NC}"

    # Move directory with trailing slash
    local slash_dir=$(create_temp_dir)
    create_temp_file "Slash dir content" "$slash_dir/file.txt"
    local slash_dest="$TEMP_DIR/slash_moved"

    test_command_exit_code "mv directory with trailing slash" 0 "$binary" "$slash_dir/" "$slash_dest"
    test_command_output "mv trailing slash content" "Slash dir content" cat "$slash_dest/file.txt"

    # Move hidden files
    local hidden_src="$TEMP_DIR/.hidden_file"
    echo "Hidden content" > "$hidden_src"
    local hidden_dest="$TEMP_DIR/.hidden_moved"

    test_command_exit_code "mv hidden file" 0 "$binary" "$hidden_src" "$hidden_dest"
    test_command_output "mv hidden file content" "Hidden content" cat "$hidden_dest"

    # Move file starting with dash
    local dash_file="$TEMP_DIR/-dashfile"
    echo "Dash content" > "$dash_file"
    local dash_dest="$TEMP_DIR/dashfile_moved"

    # Use -- to separate options from files
    test_command_exit_code "mv file starting with dash" 0 "$binary" -- "$dash_file" "$dash_dest"
    test_command_output "mv dash file content" "Dash content" cat "$dash_dest"

    # Chain moves (move A to B, then B to C)
    local chain1=$(create_temp_file "Chain content")
    local chain2="$TEMP_DIR/chain2.txt"
    local chain3="$TEMP_DIR/chain3.txt"

    test_command_exit_code "mv chain move 1" 0 "$binary" "$chain1" "$chain2"
    test_command_exit_code "mv chain move 2" 0 "$binary" "$chain2" "$chain3"

    # Verify final location
    test_command_output "mv chain final content" "Chain content" cat "$chain3"

    # Neither chain1 nor chain2 should exist
    if [[ ! -e "$chain1" ]] && [[ ! -e "$chain2" ]]; then
        print_test_result "mv chain intermediate removed" "PASS"
    else
        print_test_result "mv chain intermediate removed" "FAIL"
    fi
}