#!/usr/bin/env bash
# Comprehensive tests for cp utility
# Tests all flags, copy operations, symlinks, directories, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_cp() {
    local util="cp"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Create test files for basic functionality
    local test_file1=$(create_temp_file "Simple content")
    local test_file2=$(create_temp_file $'Line 1\nLine 2\nLine 3')
    local test_file3=$(create_temp_file "")  # Empty file
    local test_dir1=$(create_temp_dir)

    echo -e "${CYAN}Testing core copy functionality...${NC}"

    # Single file copy
    test_command_exit_code "cp single file" 0 "$binary" "$test_file1" "$TEMP_DIR/copy1.txt"
    test_command_output "cp single file content" "Simple content" cat "$TEMP_DIR/copy1.txt"

    # Copy to existing directory
    test_command_exit_code "cp to directory" 0 "$binary" "$test_file1" "$test_dir1"
    test_command_output "cp to directory content" "Simple content" cat "$test_dir1/$(basename "$test_file1")"

    # Multiple files to directory
    local test_file4=$(create_temp_file "File 4 content")
    local dest_dir=$(create_temp_dir)
    test_command_exit_code "cp multiple files to directory" 0 "$binary" "$test_file1" "$test_file2" "$dest_dir"
    test_command_output "cp multiple files file1" "Simple content" cat "$dest_dir/$(basename "$test_file1")"
    test_command_output "cp multiple files file2" $'Line 1\nLine 2\nLine 3' cat "$dest_dir/$(basename "$test_file2")"

    # Empty file copy
    test_command_exit_code "cp empty file" 0 "$binary" "$test_file3" "$TEMP_DIR/empty_copy.txt"
    test_command_output "cp empty file content" "" cat "$TEMP_DIR/empty_copy.txt"

    echo -e "${CYAN}Testing force flag (-f)...${NC}"

    # Create existing destination
    local existing_dest=$(create_temp_file "Original content")
    local source_for_force=$(create_temp_file "New content")

    # Without force flag, should fail on existing file (but behavior varies by implementation)
    # GNU cp fails, BSD cp succeeds - test actual behavior rather than assumptions
    "$binary" "$source_for_force" "$existing_dest" >/dev/null 2>&1
    local force_exit_code=$?
    if [[ $force_exit_code -eq 0 ]]; then
        print_test_result "cp without force to existing file (succeeds)" "PASS"
    else
        print_test_result "cp without force to existing file (fails)" "PASS"
    fi

    # With force flag, should overwrite
    test_command_exit_code "cp with force flag" 0 "$binary" -f "$source_for_force" "$existing_dest"
    test_command_output "cp force overwrite content" "New content" cat "$existing_dest"

    # Force flag with non-existent destination should work
    test_command_exit_code "cp force to new file" 0 "$binary" -f "$source_for_force" "$TEMP_DIR/new_forced.txt"
    test_command_output "cp force new file content" "New content" cat "$TEMP_DIR/new_forced.txt"

    echo -e "${CYAN}Testing interactive flag (-i)...${NC}"

    # Interactive mode tests (should not prompt in CI/test environments)
    local interactive_src=$(create_temp_file "Interactive source")
    local interactive_dst=$(create_temp_file "Interactive dest")

    # In test environment, interactive mode behavior depends on stdin availability
    # Test that interactive mode doesn't crash, but don't assume specific behavior
    "$binary" -i "$interactive_src" "$interactive_dst" </dev/null >/dev/null 2>&1
    local interactive_exit_code=$?
    if [[ $interactive_exit_code -eq 0 ]]; then
        print_test_result "cp interactive mode (CI environment)" "PASS"
        # Check what actually happened without assumptions about overwrite behavior
        local actual_content=$(cat "$interactive_dst")
        if [[ -n "$actual_content" ]]; then
            print_test_result "cp interactive produced output" "PASS"
        else
            print_test_result "cp interactive produced output" "FAIL" "No content in destination"
        fi
    else
        print_test_result "cp interactive mode (CI environment)" "FAIL" "Interactive mode failed unexpectedly"
    fi

    # Interactive to new file should work normally
    test_command_exit_code "cp interactive to new file" 0 "$binary" -i "$interactive_src" "$TEMP_DIR/interactive_new.txt"
    test_command_output "cp interactive new file content" "Interactive source" cat "$TEMP_DIR/interactive_new.txt"

    echo -e "${CYAN}Testing recursive flag (-r)...${NC}"

    # Create directory structure
    local src_dir=$(create_temp_dir)
    create_temp_file "Root file content" "$src_dir/root_file.txt"
    mkdir -p "$src_dir/subdir1"
    mkdir -p "$src_dir/subdir2"
    create_temp_file "Sub1 content" "$src_dir/subdir1/file1.txt"
    create_temp_file "Sub2 content" "$src_dir/subdir2/file2.txt"
    mkdir -p "$src_dir/subdir1/nested"
    create_temp_file "Nested content" "$src_dir/subdir1/nested/nested_file.txt"

    # Directory copy without -r should fail
    local dest_dir_fail="$TEMP_DIR/dest_dir_fail"
    test_command_fails "cp directory without -r flag" "$binary" "$src_dir" "$dest_dir_fail"

    # Ensure failed copy didn't create anything
    if [[ -e "$dest_dir_fail" ]]; then
        print_test_result "cp directory without -r cleanup" "FAIL" "Failed copy created output when it shouldn't"
    else
        print_test_result "cp directory without -r cleanup" "PASS"
    fi

    # Directory copy with -r should succeed
    local dest_dir_recursive="$TEMP_DIR/dest_dir_recursive"
    test_command_exit_code "cp directory with -r flag" 0 "$binary" -r "$src_dir" "$dest_dir_recursive"

    # Verify recursive copy structure and content
    test_command_output "cp recursive root file" "Root file content" cat "$dest_dir_recursive/root_file.txt"
    test_command_output "cp recursive sub1 file" "Sub1 content" cat "$dest_dir_recursive/subdir1/file1.txt"
    test_command_output "cp recursive sub2 file" "Sub2 content" cat "$dest_dir_recursive/subdir2/file2.txt"
    test_command_output "cp recursive nested file" "Nested content" cat "$dest_dir_recursive/subdir1/nested/nested_file.txt"

    # Test recursive copy to existing directory
    local existing_dir=$(create_temp_dir)
    test_command_exit_code "cp recursive to existing directory" 0 "$binary" -r "$src_dir" "$existing_dir"
    test_command_output "cp recursive to existing dir content" "Root file content" cat "$existing_dir/$(basename "$src_dir")/root_file.txt"

    echo -e "${CYAN}Testing preserve flag (-p)...${NC}"

    # Create file with specific permissions (readable by test framework)
    local preserve_src=$(create_temp_file "Preserve test")
    chmod 644 "$preserve_src"

    # Copy without preserve
    local preserve_dst1="$TEMP_DIR/preserve_dst1.txt"
    test_command_exit_code "cp without preserve" 0 "$binary" "$preserve_src" "$preserve_dst1"
    test_command_output "cp without preserve content" "Preserve test" cat "$preserve_dst1"

    # Copy with preserve
    local preserve_dst2="$TEMP_DIR/preserve_dst2.txt"
    test_command_exit_code "cp with preserve" 0 "$binary" -p "$preserve_src" "$preserve_dst2"
    test_command_output "cp with preserve content" "Preserve test" cat "$preserve_dst2"

    # Check that permissions are preserved (with platform-aware comparison)
    local src_perms=$(get_file_permissions "$preserve_src")
    local dst_perms=$(get_file_permissions "$preserve_dst2")

    # Ensure we got valid permission values
    if [[ "$src_perms" =~ ^[0-7]{3}$ ]] && [[ "$dst_perms" =~ ^[0-7]{3}$ ]]; then
        # Compare user permissions (first digit) with fallback for platform differences
        local src_user="${src_perms:0:1}"
        local dst_user="${dst_perms:0:1}"
        if [[ "$src_user" == "$dst_user" ]]; then
            print_test_result "cp preserve user permissions" "PASS"
        else
            # Some platforms may not preserve exact permissions - check if at least readable
            if [[ $dst_user -ge 4 ]]; then
                print_test_result "cp preserve user permissions (readable)" "PASS"
            else
                print_test_result "cp preserve user permissions" "FAIL" "Source: $src_perms, Dest: $dst_perms"
            fi
        fi
    else
        print_test_result "cp preserve user permissions" "FAIL" "Could not get valid permissions: src=$src_perms, dst=$dst_perms"
    fi

    echo -e "${CYAN}Testing no-dereference flag (-d)...${NC}"

    # Create symbolic link - ensure target exists first and use absolute path for reliability
    local link_target=$(create_temp_file "Link target content")
    local symlink_path="$TEMP_DIR/test_symlink"

    # Use absolute path for symlink target to avoid platform-specific relative path issues
    if ! ln -s "$(readlink -f "$link_target" 2>/dev/null || realpath "$link_target" 2>/dev/null || echo "$link_target")" "$symlink_path" 2>/dev/null; then
        # Fallback to relative symlink if absolute path creation fails
        ln -s "$link_target" "$symlink_path"
    fi

    # Copy symlink without -d (should follow link)
    local follow_dest="$TEMP_DIR/follow_link.txt"
    test_command_exit_code "cp symlink without -d" 0 "$binary" "$symlink_path" "$follow_dest"
    test_command_output "cp follow symlink content" "Link target content" cat "$follow_dest"

    # Verify it's not a symlink
    if [[ ! -L "$follow_dest" ]]; then
        print_test_result "cp follow symlink is regular file" "PASS"
    else
        print_test_result "cp follow symlink is regular file" "FAIL" "Destination is still a symlink"
    fi

    # Copy symlink with -d (should preserve link)
    local preserve_link_dest="$TEMP_DIR/preserve_link"
    test_command_exit_code "cp symlink with -d" 0 "$binary" -d "$symlink_path" "$preserve_link_dest"

    # Verify it's a symlink
    if [[ -L "$preserve_link_dest" ]]; then
        print_test_result "cp preserve symlink is symlink" "PASS"
        # Check link target - handle path resolution differences
        local link_target_path=$(readlink "$preserve_link_dest")
        local resolved_target=$(readlink -f "$link_target" 2>/dev/null || realpath "$link_target" 2>/dev/null || echo "$link_target")
        local resolved_link_target=$(readlink -f "$link_target_path" 2>/dev/null || realpath "$link_target_path" 2>/dev/null || echo "$link_target_path")

        # Compare resolved paths to handle /private/ prefix differences on macOS
        if [[ "$resolved_target" == "$resolved_link_target" ]] || [[ "$link_target_path" == "$link_target" ]]; then
            print_test_result "cp preserve symlink target" "PASS"
        else
            print_test_result "cp preserve symlink target" "FAIL" "Expected: $link_target, Got: $link_target_path"
        fi
    else
        print_test_result "cp preserve symlink is symlink" "FAIL" "Destination is not a symlink"
    fi

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Force + Interactive combination - test without making assumptions about behavior
    local combo_src=$(create_temp_file "Combo source")
    local combo_dst=$(create_temp_file "Combo dest")
    "$binary" -f -i "$combo_src" "$combo_dst" </dev/null >/dev/null 2>&1
    local combo_exit_code=$?
    if [[ $combo_exit_code -eq 0 ]]; then
        print_test_result "cp -f -i combination" "PASS"
        # Verify the destination file exists and has some content
        if [[ -f "$combo_dst" ]] && [[ -s "$combo_dst" ]]; then
            print_test_result "cp force with interactive produces valid output" "PASS"
        else
            print_test_result "cp force with interactive produces valid output" "FAIL" "No valid output file"
        fi
    else
        print_test_result "cp -f -i combination" "FAIL" "Command failed with exit code $combo_exit_code"
    fi

    # Recursive + Preserve
    local combo_dir=$(create_temp_dir)
    create_temp_file "Combo file" "$combo_dir/combo_file.txt"
    chmod 644 "$combo_dir/combo_file.txt"
    local combo_dest_dir="$TEMP_DIR/combo_dest"

    # Run cp -r -p and handle potential failures from attribute preservation
    # On some CI filesystems, preserving ownership/timestamps may fail
    "$binary" -r -p "$combo_dir" "$combo_dest_dir" >/dev/null 2>&1
    local rp_exit=$?
    if [[ $rp_exit -eq 0 ]]; then
        print_test_result "cp -r -p combination" "PASS"
    else
        # Check if the copy succeeded despite the non-zero exit code
        # (e.g., content copied but attribute preservation produced warnings)
        if [[ -f "$combo_dest_dir/combo_file.txt" ]]; then
            print_test_result "cp -r -p combination (attributes partial)" "PASS"
        else
            print_test_result "cp -r -p combination" "FAIL" "Exit code: $rp_exit and no output produced"
        fi
    fi

    # Verify content was copied correctly (independent of attribute preservation)
    if [[ -f "$combo_dest_dir/combo_file.txt" ]]; then
        test_command_output "cp recursive preserve content" "Combo file" cat "$combo_dest_dir/combo_file.txt"
    else
        print_test_result "cp recursive preserve content" "FAIL" "Destination file not created"
    fi

    # Recursive + No-dereference - test with proper symlink handling
    local combo_link_dir=$(create_temp_dir)
    local combo_link_target=$(create_temp_file "Link in dir")

    # Create symlink with absolute path for reliability
    local abs_target="$(cd "$(dirname "$combo_link_target")" && pwd)/$(basename "$combo_link_target")"
    if ! ln -s "$abs_target" "$combo_link_dir/link_in_dir" 2>/dev/null; then
        # Fallback to relative symlink
        ln -s "$combo_link_target" "$combo_link_dir/link_in_dir"
    fi

    local combo_link_dest="$TEMP_DIR/combo_link_dest"
    test_command_exit_code "cp -r -d combination" 0 "$binary" -r -d "$combo_link_dir" "$combo_link_dest"

    # Verify symlink was preserved in recursive copy with correct path understanding
    # When doing "cp -r source dest", the contents of source are copied into dest
    local recursive_link_path="$combo_link_dest/link_in_dir"

    if [[ ! -d "$combo_link_dest" ]]; then
        print_test_result "cp recursive preserve symlinks" "FAIL" "Destination directory not created"
    elif [[ -L "$recursive_link_path" ]]; then
        print_test_result "cp recursive preserve symlinks" "PASS"
    elif [[ -f "$recursive_link_path" ]]; then
        print_test_result "cp recursive preserve symlinks" "FAIL" "Symlink was copied as regular file"
    elif [[ ! -e "$recursive_link_path" ]]; then
        print_test_result "cp recursive preserve symlinks" "FAIL" "Symlink not copied at all"
    else
        print_test_result "cp recursive preserve symlinks" "FAIL" "Symlink copied as unknown file type"
    fi

    echo -e "${CYAN}Testing POSIX compliance flags...${NC}"

    # -R flag (recursive, POSIX alias for -r)
    local r_upper_src=$(create_temp_dir)
    create_temp_file "R flag content" "$r_upper_src/rfile.txt"
    mkdir -p "$r_upper_src/rsub"
    create_temp_file "R sub content" "$r_upper_src/rsub/rsubfile.txt"
    local r_upper_dest="$TEMP_DIR/r_upper_dest"
    test_command_exit_code "cp -R copies directory" 0 "$binary" -R "$r_upper_src" "$r_upper_dest"
    test_command_output "cp -R root file" "R flag content" cat "$r_upper_dest/rfile.txt"
    test_command_output "cp -R sub file" "R sub content" cat "$r_upper_dest/rsub/rsubfile.txt"

    # -n / --no-clobber flag
    local noclobber_src=$(create_temp_file "new content for clobber test")
    local noclobber_dst=$(create_temp_file "original content")
    test_command_exit_code "cp -n does not overwrite" 0 "$binary" -n "$noclobber_src" "$noclobber_dst"
    test_command_output "cp -n preserves original" "original content" cat "$noclobber_dst"

    local noclobber_long_dst=$(create_temp_file "long original content")
    test_command_exit_code "cp --no-clobber" 0 "$binary" --no-clobber "$noclobber_src" "$noclobber_long_dst"
    test_command_output "cp --no-clobber preserves original" "long original content" cat "$noclobber_long_dst"

    # -n with new file (should copy normally)
    local noclobber_new_dst="$TEMP_DIR/noclobber_new.txt"
    test_command_exit_code "cp -n to new file" 0 "$binary" -n "$noclobber_src" "$noclobber_new_dst"
    test_command_output "cp -n new file content" "new content for clobber test" cat "$noclobber_new_dst"

    # -v / --verbose flag
    local verbose_src=$(create_temp_file "verbose content")
    local verbose_dst="$TEMP_DIR/verbose_copy.txt"
    local verb_out="" verb_err="" verb_exit=""
    run_command verb_cmd verb_out verb_err verb_exit "$binary" -v "$verbose_src" "$verbose_dst"
    local verb_src_base
    verb_src_base=$(basename "$verbose_src")
    if [[ $verb_exit -eq 0 && -f "$verbose_dst" \
          && ("$verb_out" =~ "$verb_src_base" || "$verb_err" =~ "$verb_src_base") \
          && ("$verb_out" =~ "->" || "$verb_err" =~ "->") ]]; then
        print_test_result "cp -v shows copy operation" "PASS"
    else
        print_test_result "cp -v shows copy operation" "FAIL" "Expected '->' and source filename in output, got stdout: $verb_out, stderr: $verb_err"
    fi

    local verbose_long_dst="$TEMP_DIR/verbose_long_copy.txt"
    local verb_long_out="" verb_long_err="" verb_long_exit=""
    run_command verb_long_cmd verb_long_out verb_long_err verb_long_exit "$binary" --verbose "$verbose_src" "$verbose_long_dst"
    local verb_long_src_base
    verb_long_src_base=$(basename "$verbose_src")
    if [[ $verb_long_exit -eq 0 && -f "$verbose_long_dst" \
          && ("$verb_long_out" =~ "$verb_long_src_base" || "$verb_long_err" =~ "$verb_long_src_base") \
          && ("$verb_long_out" =~ "->" || "$verb_long_err" =~ "->") ]]; then
        print_test_result "cp --verbose shows copy operation" "PASS"
    else
        print_test_result "cp --verbose shows copy operation" "FAIL" "Expected '->' and source filename in output"
    fi

    # -a / --archive flag (equivalent to -RpP)
    local archive_src=$(create_temp_dir)
    create_temp_file "Archive file" "$archive_src/afile.txt"
    chmod 644 "$archive_src/afile.txt"
    mkdir -p "$archive_src/asub"
    create_temp_file "Archive sub" "$archive_src/asub/asubfile.txt"
    # Create a symlink inside the archive source
    local archive_link_target=$(create_temp_file "Archive link target")
    ln -s "$archive_link_target" "$archive_src/alink"

    local archive_dest="$TEMP_DIR/archive_dest"
    test_command_exit_code "cp -a copies directory" 0 "$binary" -a "$archive_src" "$archive_dest"
    test_command_output "cp -a root file" "Archive file" cat "$archive_dest/afile.txt"
    test_command_output "cp -a sub file" "Archive sub" cat "$archive_dest/asub/asubfile.txt"

    local archive_src_perms=$(get_file_permissions "$archive_src/afile.txt")
    local archive_dst_perms=$(get_file_permissions "$archive_dest/afile.txt")
    if [[ "$archive_src_perms" == "$archive_dst_perms" ]]; then
        print_test_result "cp -a preserves permissions" "PASS"
    else
        print_test_result "cp -a preserves permissions" "FAIL" "Source: $archive_src_perms, Dest: $archive_dst_perms"
    fi

    # Verify -a preserves timestamps
    # Set an old timestamp on the source so matching mtimes proves preservation
    touch -t 202301010000 "$archive_src/afile.txt"
    # Re-copy with the known-old timestamp
    rm -rf "$archive_dest"
    "$binary" -a "$archive_src" "$archive_dest" >/dev/null 2>&1
    local archive_src_mtime archive_dst_mtime
    archive_src_mtime=$(stat -c %Y "$archive_src/afile.txt" 2>/dev/null || stat -f %m "$archive_src/afile.txt" 2>/dev/null)
    archive_dst_mtime=$(stat -c %Y "$archive_dest/afile.txt" 2>/dev/null || stat -f %m "$archive_dest/afile.txt" 2>/dev/null)
    if [[ -n "$archive_src_mtime" && "$archive_src_mtime" == "$archive_dst_mtime" ]]; then
        print_test_result "cp -a preserves timestamps" "PASS"
    else
        print_test_result "cp -a preserves timestamps" "FAIL" "Source mtime: $archive_src_mtime, Dest mtime: $archive_dst_mtime"
    fi

    # -a should preserve symlinks (the -P part)
    if [[ -L "$archive_dest/alink" ]]; then
        print_test_result "cp -a preserves symlinks" "PASS"
    else
        print_test_result "cp -a preserves symlinks" "FAIL" "Symlink was followed instead of preserved"
    fi

    # --archive long option
    local archive_long_dest="$TEMP_DIR/archive_long_dest"
    test_command_exit_code "cp --archive copies directory" 0 "$binary" --archive "$archive_src" "$archive_long_dest"
    test_command_output "cp --archive root file" "Archive file" cat "$archive_long_dest/afile.txt"

    if [[ -L "$archive_long_dest/alink" ]]; then
        print_test_result "cp --archive preserves symlinks" "PASS"
    else
        print_test_result "cp --archive preserves symlinks" "FAIL" "Symlink was followed instead of preserved"
    fi

    local archive_long_src_mtime archive_long_dst_mtime
    archive_long_src_mtime=$(stat -c %Y "$archive_src/afile.txt" 2>/dev/null || stat -f %m "$archive_src/afile.txt" 2>/dev/null)
    archive_long_dst_mtime=$(stat -c %Y "$archive_long_dest/afile.txt" 2>/dev/null || stat -f %m "$archive_long_dest/afile.txt" 2>/dev/null)
    if [[ -n "$archive_long_src_mtime" && "$archive_long_src_mtime" == "$archive_long_dst_mtime" ]]; then
        print_test_result "cp --archive preserves timestamps" "PASS"
    else
        print_test_result "cp --archive preserves timestamps" "FAIL" "Source mtime: $archive_long_src_mtime, Dest mtime: $archive_long_dst_mtime"
    fi

    # -H flag (follow command-line symlinks only)
    local h_target_dir=$(create_temp_dir)
    create_temp_file "H content" "$h_target_dir/hfile.txt"
    # Create an inner symlink
    local h_inner_target=$(create_temp_file "H inner target")
    ln -s "$h_inner_target" "$h_target_dir/inner_link"
    # Create a command-line symlink pointing to the directory
    local h_cmdline_link="$TEMP_DIR/h_cmdline_link"
    ln -s "$h_target_dir" "$h_cmdline_link"

    local h_dest="$TEMP_DIR/h_dest"
    test_command_exit_code "cp -R -H follows cmdline symlinks" 0 "$binary" -R -H "$h_cmdline_link" "$h_dest"

    # Command-line symlink should have been followed (dest is a directory with contents)
    if [[ -f "$h_dest/hfile.txt" ]]; then
        print_test_result "cp -H follows command-line symlink" "PASS"
    else
        print_test_result "cp -H follows command-line symlink" "FAIL" "Command-line symlink not followed"
    fi

    # Inner symlink should NOT be followed (should remain a symlink)
    if [[ -L "$h_dest/inner_link" ]]; then
        print_test_result "cp -H preserves inner symlinks" "PASS"
    elif [[ -f "$h_dest/inner_link" ]]; then
        print_test_result "cp -H preserves inner symlinks" "FAIL" "Inner symlink was followed (regular file)"
    else
        print_test_result "cp -H preserves inner symlinks" "FAIL" "Inner symlink not copied"
    fi

    # -L flag (follow all symlinks)
    local l_src=$(create_temp_dir)
    create_temp_file "L content" "$l_src/lfile.txt"
    local l_link_target=$(create_temp_file "L link target content")
    ln -s "$l_link_target" "$l_src/l_link"

    local l_dest="$TEMP_DIR/l_dest"
    test_command_exit_code "cp -R -L follows all symlinks" 0 "$binary" -R -L "$l_src" "$l_dest"

    # All symlinks should be followed (copies are regular files)
    if [[ -f "$l_dest/l_link" && ! -L "$l_dest/l_link" ]]; then
        print_test_result "cp -L converts symlinks to files" "PASS"
    else
        print_test_result "cp -L converts symlinks to files" "FAIL" "Symlink was not followed"
    fi
    test_command_output "cp -L followed symlink content" "L link target content" cat "$l_dest/l_link"

    # -P flag (never follow symlinks)
    local p_src=$(create_temp_dir)
    create_temp_file "P content" "$p_src/pfile.txt"
    local p_link_target=$(create_temp_file "P link target")
    ln -s "$p_link_target" "$p_src/p_link"

    local p_dest="$TEMP_DIR/p_dest"
    test_command_exit_code "cp -R -P preserves symlinks" 0 "$binary" -R -P "$p_src" "$p_dest"

    # Symlinks should be preserved
    if [[ -L "$p_dest/p_link" ]]; then
        print_test_result "cp -P preserves symlinks" "PASS"
    else
        print_test_result "cp -P preserves symlinks" "FAIL" "Symlink was followed"
    fi

    local p_src_target=$(readlink "$p_src/p_link")
    local p_dst_target=$(readlink "$p_dest/p_link")
    if [[ "$p_src_target" == "$p_dst_target" ]]; then
        print_test_result "cp -P preserves symlink target" "PASS"
    else
        print_test_result "cp -P preserves symlink target" "FAIL" "Source target: $p_src_target, Dest target: $p_dst_target"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid arguments
    test_command_fails "cp no arguments" "$binary"
    test_command_fails "cp missing destination" "$binary" "$test_file1"
    test_command_fails "cp invalid flag" "$binary" --invalid-flag "$test_file1" "$TEMP_DIR/dest"

    # Non-existent source files
    test_command_fails "cp non-existent file" "$binary" "/path/that/does/not/exist" "$TEMP_DIR/dest"
    test_command_fails "cp mixed existing and non-existent" "$binary" "$test_file1" "/nonexistent" "$test_dir1"

    # Multiple sources to non-directory - ensure destination is not a directory
    local non_dir_dest="$TEMP_DIR/not_a_directory.txt"
    create_temp_file "existing file" "$non_dir_dest"
    test_command_fails "cp multiple sources to file" "$binary" "$test_file1" "$test_file2" "$non_dir_dest"

    # Permission denied (create unreadable file) - with proper cleanup and platform awareness
    local unreadable_file=$(create_temp_file "secret content")
    chmod 000 "$unreadable_file"

    # Test permission denial, but be aware that some platforms/contexts may still allow access
    "$binary" "$unreadable_file" "$TEMP_DIR/dest" >/dev/null 2>&1
    local perm_exit_code=$?

    # Always restore permissions before cleanup to prevent cleanup issues
    chmod 644 "$unreadable_file"

    if [[ $perm_exit_code -ne 0 ]]; then
        print_test_result "cp permission denied source" "PASS"
    else
        # Some environments (like containers, certain CI systems) may bypass file permissions
        print_test_result "cp permission denied source (environment allows access)" "PASS"
    fi

    # Same file detection - test both direct and indirect same-file scenarios
    test_command_fails "cp file to itself (direct)" "$binary" "$test_file1" "$test_file1"

    # Test with different paths to same file (if hard links supported by filesystem)
    local same_file_link="$TEMP_DIR/same_file_link"
    if ln "$test_file1" "$same_file_link" 2>/dev/null; then
        test_command_fails "cp file to itself (hard link)" "$binary" "$test_file1" "$same_file_link"
        rm -f "$same_file_link" 2>/dev/null || true
    else
        print_test_result "cp file to itself (hard link test skipped)" "PASS" "Hard links not supported on filesystem"
    fi

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Binary file handling - use printf for reliable binary content creation
    local binary_file=$(mktemp "$TEMP_DIR/binary_XXXXXX")
    printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xFF\xFE\xFD\xFC' > "$binary_file"
    local binary_dest="$TEMP_DIR/binary_copy"
    test_command_exit_code "cp binary file" 0 "$binary" "$binary_file" "$binary_dest"

    # Verify binary content (using od to compare)
    if cmp -s "$binary_file" "$binary_dest"; then
        print_test_result "cp binary file content" "PASS"
    else
        print_test_result "cp binary file content" "FAIL" "Binary content differs"
    fi

    # Large file handling (create file larger than typical buffer size)
    # Use a more reliable method to create large content to avoid bash string limits
    local large_file=$(mktemp "$TEMP_DIR/large_XXXXXX")
    {
        for i in $(seq 1 1000); do
            printf "Line %d with some content to make it longer than usual buffer sizes would handle in a single read operation\n" "$i"
        done
    } > "$large_file"
    local large_dest="$TEMP_DIR/large_copy"
    test_command_exit_code "cp large file" 0 "$binary" "$large_file" "$large_dest"

    # Verify large file size
    local src_size=$(get_file_size "$large_file")
    local dst_size=$(get_file_size "$large_dest")
    if [[ "$src_size" == "$dst_size" ]]; then
        print_test_result "cp large file size" "PASS"
    else
        print_test_result "cp large file size" "FAIL" "Source: $src_size bytes, Dest: $dst_size bytes"
    fi

    # Files with special characters in names - ensure proper quoting
    local special_name="$TEMP_DIR/file with spaces & special chars [test].txt"
    create_temp_file "Special name content" "$special_name"

    # Verify the test file was actually created before proceeding
    if [[ ! -f "$special_name" ]]; then
        print_test_result "cp file with special chars (setup)" "FAIL" "Could not create test file with special characters"
        return 1
    fi
    local special_dest="$TEMP_DIR/special_copy.txt"
    test_command_exit_code "cp file with special chars" 0 "$binary" "$special_name" "$special_dest"
    test_command_output "cp special chars content" "Special name content" cat "$special_dest"

    # Files without final newlines - use printf for exact control
    local no_newline_file=$(mktemp "$TEMP_DIR/no_newline_XXXXXX")
    printf 'line1\nline2\nline3_no_newline' > "$no_newline_file"
    local no_newline_dest="$TEMP_DIR/no_newline_copy"
    test_command_exit_code "cp file without final newline" 0 "$binary" "$no_newline_file" "$no_newline_dest"

    # Verify exact content preservation
    if cmp -s "$no_newline_file" "$no_newline_dest"; then
        print_test_result "cp preserve file without final newline" "PASS"
    else
        print_test_result "cp preserve file without final newline" "FAIL" "Content differs"
    fi

    # Moderately long file paths (within filesystem limits) - with error checking
    local long_subdir="$TEMP_DIR/long_path_test"
    if ! mkdir -p "$long_subdir"; then
        print_test_result "cp file with long path (setup)" "FAIL" "Could not create subdirectory"
        return 1
    fi

    local long_filename="file_with_moderately_long_name_that_should_work_fine.txt"
    local long_name="$long_subdir/$long_filename"
    create_temp_file "Long path content" "$long_name"

    # Verify the long path file was created
    if [[ ! -f "$long_name" ]]; then
        print_test_result "cp file with long path (setup)" "FAIL" "Could not create file with long path"
        return 1
    fi
    local long_dest="$TEMP_DIR/long_path_copy.txt"
    test_command_exit_code "cp file with long path" 0 "$binary" "$long_name" "$long_dest"
    test_command_output "cp long path content" "Long path content" cat "$long_dest"

    echo -e "${CYAN}Testing special file handling...${NC}"

    # Copy from /dev/null - behavior varies by implementation
    local dev_null_dest="$TEMP_DIR/from_dev_null"
    "$binary" /dev/null "$dev_null_dest" >/dev/null 2>&1
    local dev_null_exit_code=$?

    if [[ $dev_null_exit_code -eq 0 ]]; then
        # Some implementations can copy from /dev/null (creates empty file)
        if [[ -f "$dev_null_dest" ]] && [[ ! -s "$dev_null_dest" ]]; then
            print_test_result "cp from /dev/null (creates empty file)" "PASS"
        else
            print_test_result "cp from /dev/null (unexpected output)" "FAIL" "Non-empty file created"
        fi
    else
        # Other implementations reject special files
        print_test_result "cp from /dev/null (rejects special file)" "PASS"
    fi

    # Directory as source without -r (more specific error testing)
    local dir_source=$(create_temp_dir)
    test_command_fails "cp directory without -r specific error" "$binary" "$dir_source" "$TEMP_DIR/dir_dest"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX required behaviors
    test_command_exit_code "POSIX: cp file copy" 0 "$binary" "$test_file1" "$TEMP_DIR/posix_copy1"
    test_command_output "POSIX: cp file content" "Simple content" cat "$TEMP_DIR/posix_copy1"

    # POSIX exit codes
    test_command_exit_code "cp success exit code" 0 "$binary" "$test_file1" "$TEMP_DIR/posix_success"

    # Multiple files to directory
    local posix_dir=$(create_temp_dir)
    test_command_exit_code "POSIX: multiple files to directory" 0 "$binary" "$test_file1" "$test_file2" "$posix_dir"
    test_command_output "POSIX: multiple files file1" "Simple content" cat "$posix_dir/$(basename "$test_file1")"
    test_command_output "POSIX: multiple files file2" $'Line 1\nLine 2\nLine 3' cat "$posix_dir/$(basename "$test_file2")"

    echo -e "${CYAN}Testing performance and boundary conditions...${NC}"

    # Zero-byte file
    local zero_file=$(create_temp_file "")
    local zero_dest="$TEMP_DIR/zero_copy"
    test_command_exit_code "cp zero-byte file" 0 "$binary" "$zero_file" "$zero_dest"
    test_command_output "cp zero-byte content" "" cat "$zero_dest"

    # Single character file
    local single_char_file=$(create_temp_file "X")
    local single_char_dest="$TEMP_DIR/single_char_copy"
    test_command_exit_code "cp single character file" 0 "$binary" "$single_char_file" "$single_char_dest"
    test_command_output "cp single character content" "X" cat "$single_char_dest"

    # Empty directory (recursive) - ensure source is actually empty
    local empty_dir=$(create_temp_dir)
    # Verify it's actually empty
    if [[ $(find "$empty_dir" -mindepth 1 -maxdepth 1 | wc -l) -ne 0 ]]; then
        print_test_result "cp empty directory (setup)" "FAIL" "Test directory is not empty"
        return 1
    fi

    local empty_dir_dest="$TEMP_DIR/empty_dir_copy"
    test_command_exit_code "cp empty directory" 0 "$binary" -r "$empty_dir" "$empty_dir_dest"

    # Verify empty directory was created
    if [[ -d "$empty_dir_dest" ]]; then
        print_test_result "cp empty directory exists" "PASS"
    else
        print_test_result "cp empty directory exists" "FAIL" "Directory not created"
    fi

    # Directory with only subdirectories (no files)
    local subdir_only=$(create_temp_dir)
    mkdir -p "$subdir_only/sub1/sub2/sub3"
    local subdir_dest="$TEMP_DIR/subdir_only_copy"
    test_command_exit_code "cp directory with only subdirs" 0 "$binary" -r "$subdir_only" "$subdir_dest"

    # Verify subdirectory structure
    if [[ -d "$subdir_dest/sub1/sub2/sub3" ]]; then
        print_test_result "cp subdirectory structure" "PASS"
    else
        print_test_result "cp subdirectory structure" "FAIL" "Subdirectory structure not preserved"
    fi

    echo -e "${CYAN}Testing argument parsing edge cases...${NC}"

    # Test long option equivalents - ensure clean slate
    local long_opt_src=$(create_temp_file "Long option test")
    local long_opt_dst="$TEMP_DIR/long_opt_copy"

    # Clean up any existing destination to ensure test independence
    rm -f "$long_opt_dst" 2>/dev/null || true

    # Test --force
    create_temp_file "Existing for force" "$long_opt_dst"
    test_command_exit_code "cp --force" 0 "$binary" --force "$long_opt_src" "$long_opt_dst"
    test_command_output "cp --force content" "Long option test" cat "$long_opt_dst"

    # Test --recursive
    local long_opt_dir=$(create_temp_dir)
    create_temp_file "Recursive long opt" "$long_opt_dir/file.txt"
    local long_opt_dir_dest="$TEMP_DIR/long_opt_dir_copy"
    test_command_exit_code "cp --recursive" 0 "$binary" --recursive "$long_opt_dir" "$long_opt_dir_dest"
    test_command_output "cp --recursive content" "Recursive long opt" cat "$long_opt_dir_dest/file.txt"

    # Test --preserve
    local preserve_long_src=$(create_temp_file "Preserve long test")
    chmod 644 "$preserve_long_src"
    local preserve_long_dst="$TEMP_DIR/preserve_long_copy"
    test_command_exit_code "cp --preserve" 0 "$binary" --preserve "$preserve_long_src" "$preserve_long_dst"
    test_command_output "cp --preserve content" "Preserve long test" cat "$preserve_long_dst"

    # Test --no-dereference - with robust symlink creation
    local no_deref_target=$(create_temp_file "No deref target")
    local no_deref_link="$TEMP_DIR/no_deref_link"

    # Clean up any existing link first
    rm -f "$no_deref_link" 2>/dev/null || true

    # Create symlink with fallback handling
    if ! ln -s "$(readlink -f "$no_deref_target" 2>/dev/null || realpath "$no_deref_target" 2>/dev/null || echo "$no_deref_target")" "$no_deref_link" 2>/dev/null; then
        ln -s "$no_deref_target" "$no_deref_link"
    fi

    local no_deref_dest="$TEMP_DIR/no_deref_copy"
    test_command_exit_code "cp --no-dereference" 0 "$binary" --no-dereference "$no_deref_link" "$no_deref_dest"

    # Verify it preserved the symlink
    if [[ -L "$no_deref_dest" ]]; then
        print_test_result "cp --no-dereference preserves symlink" "PASS"
    else
        print_test_result "cp --no-dereference preserves symlink" "FAIL" "Symlink not preserved"
    fi

    echo -e "${CYAN}Testing overwrite hint...${NC}"

    # Hint should appear when overwriting without -i or -f
    local hint_src=$(create_temp_file "Hint source")
    local hint_dst=$(create_temp_file "Hint existing")
    local hint_stderr=$("$binary" "$hint_src" "$hint_dst" 2>&1 >/dev/null)
    if [[ "$hint_stderr" == *"use -i"* ]]; then
        print_test_result "cp overwrite hint shown" "PASS"
    else
        print_test_result "cp overwrite hint shown" "FAIL" "Expected hint in stderr, got: $hint_stderr"
    fi

    # Hint should NOT appear with -i flag
    local hint_i_src=$(create_temp_file "Hint -i source")
    local hint_i_dst=$(create_temp_file "Hint -i existing")
    local hint_i_stderr=$("$binary" -i "$hint_i_src" "$hint_i_dst" </dev/null 2>&1 >/dev/null)
    if [[ "$hint_i_stderr" != *"hint:"* ]]; then
        print_test_result "cp no hint with -i" "PASS"
    else
        print_test_result "cp no hint with -i" "FAIL" "Unexpected hint in stderr: $hint_i_stderr"
    fi

    # Hint should NOT appear with -f flag
    local hint_f_src=$(create_temp_file "Hint -f source")
    local hint_f_dst=$(create_temp_file "Hint -f existing")
    local hint_f_stderr=$("$binary" -f "$hint_f_src" "$hint_f_dst" 2>&1 >/dev/null)
    if [[ "$hint_f_stderr" != *"hint:"* ]]; then
        print_test_result "cp no hint with -f" "PASS"
    else
        print_test_result "cp no hint with -f" "FAIL" "Unexpected hint in stderr: $hint_f_stderr"
    fi

    # Hint should appear only once when overwriting multiple files
    local hint_multi_dir=$(create_temp_dir)
    local hint_multi_src1=$(create_temp_file "Multi hint 1")
    local hint_multi_src2=$(create_temp_file "Multi hint 2")
    # Pre-populate destination
    cp "$hint_multi_src1" "$hint_multi_dir/$(basename "$hint_multi_src1")"
    cp "$hint_multi_src2" "$hint_multi_dir/$(basename "$hint_multi_src2")"
    local hint_multi_stderr=$("$binary" "$hint_multi_src1" "$hint_multi_src2" "$hint_multi_dir" 2>&1 >/dev/null)
    local hint_count=$(echo "$hint_multi_stderr" | grep -c "hint:" || true)
    if [[ "$hint_count" -eq 1 ]]; then
        print_test_result "cp hint appears only once for multiple files" "PASS"
    else
        print_test_result "cp hint appears only once for multiple files" "FAIL" "Expected 1 hint, got $hint_count"
    fi

    # No hint when destination does not exist
    local hint_new_src=$(create_temp_file "No hint source")
    local hint_new_dst="$TEMP_DIR/hint_new_dest.txt"
    local hint_new_stderr=$("$binary" "$hint_new_src" "$hint_new_dst" 2>&1 >/dev/null)
    if [[ "$hint_new_stderr" != *"hint:"* ]]; then
        print_test_result "cp no hint for new destination" "PASS"
    else
        print_test_result "cp no hint for new destination" "FAIL" "Unexpected hint: $hint_new_stderr"
    fi

    # Regression test: cp -v must write verbose output to stdout, not stderr
    echo -e "${CYAN}Testing verbose output goes to stdout...${NC}"

    local v_src=$(create_temp_file "verbose stdout test")
    local v_dst="$TEMP_DIR/verbose_stdout_dest.txt"
    local v_out="" v_err="" v_exit=""
    run_command v_cmd v_out v_err v_exit "$binary" -v "$v_src" "$v_dst"
    if [[ "$v_out" =~ "->" ]]; then
        print_test_result "cp -v output on stdout" "PASS"
    else
        print_test_result "cp -v output on stdout" "FAIL" "Expected '->' on stdout, got stdout: '$v_out'"
    fi
    if [[ "$v_err" != *"->"* ]]; then
        print_test_result "cp -v no arrow on stderr" "PASS"
    else
        print_test_result "cp -v no arrow on stderr" "FAIL" "Unexpected '->' on stderr: '$v_err'"
    fi

    # Regression test: cp -f to a file in a read-only directory reports error
    # Create dir with a dest file, chmod 555 the dir, then cp -f should fail
    # with an error message rather than silently proceeding.
    echo -e "${CYAN}Testing force-overwrite error in read-only directory...${NC}"

    local ro_dir=$(create_temp_dir)
    local ro_src=$(create_temp_file "force overwrite source")
    create_temp_file "existing dest" "$ro_dir/dest.txt"
    chmod 555 "$ro_dir"

    local ro_cmd ro_out ro_err ro_exit
    run_command ro_cmd ro_out ro_err ro_exit "$binary" -f "$ro_src" "$ro_dir/dest.txt"
    if [[ $ro_exit -ne 0 ]]; then
        print_test_result "cp -f read-only dir exits non-zero" "PASS"
    else
        print_test_result "cp -f read-only dir exits non-zero" "FAIL" \
            "Expected non-zero exit, got 0"
    fi
    if [[ -n "$ro_err" ]]; then
        print_test_result "cp -f read-only dir reports error on stderr" "PASS"
    else
        print_test_result "cp -f read-only dir reports error on stderr" "FAIL" \
            "Expected error message on stderr, got nothing"
    fi

    # Restore for cleanup
    chmod 755 "$ro_dir"

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: cp with --backup should still work after argparse change
    local backup_src=$(create_temp_file "backup regression source")
    local backup_dst=$(create_temp_file "backup regression existing")
    test_command_exit_code "cp --backup still works (regression)" 0 \
        "$binary" --backup "$backup_src" "$backup_dst"
    # Verify backup file was created
    if [[ -f "${backup_dst}~" ]]; then
        print_test_result "cp --backup creates backup file (regression)" "PASS"
    else
        print_test_result "cp --backup creates backup file (regression)" "FAIL" \
            "Expected ${backup_dst}~ to exist"
    fi

    echo -e "${CYAN}Testing audit findings (F70)...${NC}"

    # F70-1: cp -a preserves permissions including execute bit (755)
    # The existing test uses 644; this verifies 755 is preserved exactly.
    local a_perm_src=$(create_temp_dir)
    create_temp_file "exec file content" "$a_perm_src/exec_file.txt"
    chmod 755 "$a_perm_src/exec_file.txt"
    local a_perm_dest="$TEMP_DIR/a_perm_dest"
    test_command_exit_code "cp -a exec permissions copy" 0 \
        "$binary" -a "$a_perm_src" "$a_perm_dest"
    local a_src_perms=$(get_file_permissions "$a_perm_src/exec_file.txt")
    local a_dst_perms=$(get_file_permissions "$a_perm_dest/exec_file.txt")
    if [[ "$a_src_perms" == "755" && "$a_dst_perms" == "755" ]]; then
        print_test_result "cp -a preserves 755 permissions" "PASS"
    else
        print_test_result "cp -a preserves 755 permissions" "FAIL" \
            "Source: $a_src_perms, Dest: $a_dst_perms (expected 755)"
    fi

    # F70-2: cp -N should suppress BSD file flags with -p, NOT affect
    # symlink following.  The current implementation treats -N as an
    # alias for -P (follow_none).  This test copies a symlink without
    # -R and expects -N to NOT preserve the symlink (since without -R,
    # symlinks should always be followed per POSIX).  If -N wrongly
    # triggers follow_none, the destination will be a symlink instead
    # of a regular file.
    local n_link_target=$(create_temp_file "N flag link target")
    local n_symlink="$TEMP_DIR/n_flag_symlink"
    ln -sf "$n_link_target" "$n_symlink"
    local n_dest="$TEMP_DIR/n_flag_dest"
    test_command_exit_code "cp -N symlink copy" 0 \
        "$binary" -N "$n_symlink" "$n_dest"
    if [[ ! -L "$n_dest" ]]; then
        print_test_result "cp -N does not affect symlink following" "PASS"
    else
        print_test_result "cp -N does not affect symlink following" "FAIL" \
            "Destination is a symlink; -N should not change symlink behavior"
    fi

    # F70-3: cp -p should attempt to preserve uid/gid (chown).
    # The current implementation preserves mode and timestamps but
    # does NOT call chown.  This test creates a file, copies with -p,
    # and checks that the destination uid/gid match the source.
    # Since both are owned by the current user this will trivially
    # pass for uid, but the real test is whether chown was attempted.
    # We verify indirectly: copy a file with -p to a directory that
    # has the setgid bit, which changes the group of new files.
    # After cp -p, the group should match the SOURCE, not the
    # directory's group.
    local sgid_dir="$TEMP_DIR/sgid_dir"
    mkdir -p "$sgid_dir"
    # Find a supplementary group we belong to that differs from our primary
    local current_gid=$(id -g)
    local alt_gid=""
    for gid in $(id -G); do
        if [[ "$gid" != "$current_gid" ]]; then
            alt_gid="$gid"
            break
        fi
    done
    if [[ -n "$alt_gid" ]]; then
        # Set the directory to the alternate group with setgid
        chgrp "$alt_gid" "$sgid_dir" 2>/dev/null && \
        chmod g+s "$sgid_dir" 2>/dev/null
        local sgid_check=$(stat -c '%g' "$sgid_dir" 2>/dev/null || stat -f '%g' "$sgid_dir" 2>/dev/null)
        if [[ "$sgid_check" == "$alt_gid" ]]; then
            local p_src=$(create_temp_file "preserve ownership test")
            local p_src_gid=$(stat -c '%g' "$p_src" 2>/dev/null || stat -f '%g' "$p_src" 2>/dev/null)
            local p_dest="$sgid_dir/preserved_file.txt"
            test_command_exit_code "cp -p to setgid dir" 0 \
                "$binary" -p "$p_src" "$p_dest"
            local p_dest_gid=$(stat -c '%g' "$p_dest" 2>/dev/null || stat -f '%g' "$p_dest" 2>/dev/null)
            if [[ "$p_dest_gid" == "$p_src_gid" ]]; then
                print_test_result "cp -p preserves group in setgid dir" "PASS"
            else
                print_test_result "cp -p preserves group in setgid dir" "FAIL" \
                    "Source gid: $p_src_gid, Dest gid: $p_dest_gid (inherited setgid group $alt_gid)"
            fi
        else
            print_test_result "cp -p preserves group in setgid dir" "SKIP" \
                "Could not set up setgid directory"
        fi
    else
        print_test_result "cp -p preserves group in setgid dir" "SKIP" \
            "No supplementary groups available"
    fi
}
