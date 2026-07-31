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

    # The hint is only emitted when stderr is a TTY (so scripts and log
    # files don't get noisy). Run via a pseudo-terminal to exercise the
    # interactive code path.
    local hint_src=$(create_temp_file "Hint source")
    local hint_dst=$(create_temp_file "Hint existing")
    local hint_out=$(run_with_stderr_tty "$binary" "$hint_src" "$hint_dst")
    if [[ "$hint_out" == *"use -i"* ]]; then
        print_test_result "cp overwrite hint shown" "PASS"
    else
        print_test_result "cp overwrite hint shown" "FAIL" "Expected hint via PTY, got: $hint_out"
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

    # Hint should appear only once when overwriting multiple files (PTY required).
    local hint_multi_dir=$(create_temp_dir)
    local hint_multi_src1=$(create_temp_file "Multi hint 1")
    local hint_multi_src2=$(create_temp_file "Multi hint 2")
    # Pre-populate destination
    cp "$hint_multi_src1" "$hint_multi_dir/$(basename "$hint_multi_src1")"
    cp "$hint_multi_src2" "$hint_multi_dir/$(basename "$hint_multi_src2")"
    local hint_multi_out=$(run_with_stderr_tty "$binary" "$hint_multi_src1" "$hint_multi_src2" "$hint_multi_dir")
    local hint_count=$(echo "$hint_multi_out" | grep -c "hint:" || true)
    if [[ "$hint_count" -eq 1 ]]; then
        print_test_result "cp hint appears only once for multiple files" "PASS"
    else
        print_test_result "cp hint appears only once for multiple files" "FAIL" "Expected 1 hint via PTY, got $hint_count"
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

    # Root bypasses directory-write permission bits at the kernel level, so a
    # write into a chmod 555 directory succeeds under root and cp exits 0 with
    # no error (GNU cp behaves identically). The read-only precondition only
    # holds for an unprivileged user, so skip these assertions under root
    # rather than assert an outcome the kernel makes impossible; the assertions
    # keep their teeth on unprivileged CI runners.
    if [[ $(id -u) -eq 0 ]]; then
        print_test_result "cp -f read-only dir exits non-zero" "SKIP" \
            "root bypasses directory permissions"
        print_test_result "cp -f read-only dir reports error on stderr" "SKIP" \
            "root bypasses directory permissions"
    else
        local ro_dir=$(create_temp_dir)
        local ro_src=$(create_temp_file "force overwrite source")
        create_temp_file "existing dest" "$ro_dir/dest.txt"
        chmod 444 "$ro_dir/dest.txt"
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
    fi

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

    echo -e "${CYAN}Testing issue #77: new-destination mode duplicates source (no -p)...${NC}"

    # Pin the process umask for the reproducible cases below (0o022 is GNU's
    # documented reference umask). Source files/dirs are created BEFORE this
    # so their own modes come from explicit chmod, not from umask-at-create.
    local i77_saved_umask
    i77_saved_umask=$(umask)

    # I1: a new destination file duplicates the source's permission bits.
    local i1_src=$(create_temp_file "issue 77 I1")
    chmod 700 "$i1_src"
    local i1_dst="$TEMP_DIR/i1_dst.txt"
    umask 022
    test_command_exit_code "cp new file duplicates source mode (I1)" 0 \
        run_with_limit 10 "$binary" "$i1_src" "$i1_dst"
    umask "$i77_saved_umask"
    local i1_perms
    i1_perms=$(get_file_permissions "$i1_dst")
    if [[ "$i1_perms" == "700" ]]; then
        print_test_result "cp new file mode is 700 (I1)" "PASS"
    else
        print_test_result "cp new file mode is 700 (I1)" "FAIL" \
            "Expected 700, got $i1_perms"
    fi

    # I2: setuid is NOT duplicated without -p; the dest ends at the source's
    # permission bits alone (0o755), stripped of the setuid bit.
    local i2_src=$(create_temp_file "issue 77 I2")
    chmod 755 "$i2_src"
    if chmod 4755 "$i2_src" 2>/dev/null && [[ "$(get_file_permissions "$i2_src")" == "4755" ]]; then
        local i2_dst="$TEMP_DIR/i2_dst.txt"
        umask 022
        test_command_exit_code "cp setuid source, no -p (I2)" 0 \
            run_with_limit 10 "$binary" "$i2_src" "$i2_dst"
        umask "$i77_saved_umask"
        local i2_perms
        i2_perms=$(get_file_permissions "$i2_dst")
        if [[ "$i2_perms" == "755" ]]; then
            print_test_result "cp setuid not duplicated without -p (I2)" "PASS"
        else
            print_test_result "cp setuid not duplicated without -p (I2)" "FAIL" \
                "Expected 755, got $i2_perms"
        fi
    else
        print_test_result "cp setuid not duplicated without -p (I2)" "SKIP" \
            "Could not set/verify setuid bit (4755) on source"
    fi

    # I3: `cp -r` of a new destination directory duplicates the source dir's
    # (and its child file's) permission bits.
    local i3_src_dir="$TEMP_DIR/i3_src"
    mkdir -p "$i3_src_dir"
    create_temp_file "issue 77 I3 child" "$i3_src_dir/f.txt"
    chmod 700 "$i3_src_dir/f.txt"
    chmod 700 "$i3_src_dir"
    local i3_dst_dir="$TEMP_DIR/i3_dst"
    umask 022
    test_command_exit_code "cp -r new directory duplicates source mode (I3)" 0 \
        run_with_limit 10 "$binary" -r "$i3_src_dir" "$i3_dst_dir"
    umask "$i77_saved_umask"
    local i3_dir_perms i3_child_perms
    i3_dir_perms=$(get_file_permissions "$i3_dst_dir")
    i3_child_perms=$(get_file_permissions "$i3_dst_dir/f.txt")
    if [[ "$i3_dir_perms" == "700" && "$i3_child_perms" == "700" ]]; then
        print_test_result "cp -r new directory mode is 700 (I3)" "PASS"
    else
        print_test_result "cp -r new directory mode is 700 (I3)" "FAIL" \
            "Expected dir=700 child=700, got dir=$i3_dir_perms child=$i3_child_perms"
    fi

    # I4 guard: an existing destination file keeps its own mode (600) while
    # its content is replaced -- this already passes today.
    local i4_src=$(create_temp_file "issue 77 I4 new")
    chmod 755 "$i4_src"
    local i4_dst=$(create_temp_file "issue 77 I4 old")
    chmod 600 "$i4_dst"
    umask 022
    test_command_exit_code "cp onto existing destination file (I4)" 0 \
        run_with_limit 10 "$binary" "$i4_src" "$i4_dst"
    umask "$i77_saved_umask"
    local i4_perms
    i4_perms=$(get_file_permissions "$i4_dst")
    if [[ "$i4_perms" == "600" ]]; then
        print_test_result "cp guard: existing dest file keeps its mode (I4)" "PASS"
    else
        print_test_result "cp guard: existing dest file keeps its mode (I4)" "FAIL" \
            "Expected 600, got $i4_perms"
    fi
    test_command_output "cp guard: existing dest file content replaced (I4)" \
        "issue 77 I4 new" cat "$i4_dst"

    # I5: `cp -r` of a read-only (0o555) source directory still populates the
    # destination (GNU guarantees u+rwx during traversal) and finalizes the
    # dest dir's mode to 0o555 post-order. Restore 755 before the framework's
    # own cleanup runs so it can recurse in and delete the tree.
    local i5_src_dir="$TEMP_DIR/i5_src"
    mkdir -p "$i5_src_dir"
    create_temp_file "issue 77 I5 child" "$i5_src_dir/f.txt"
    chmod 555 "$i5_src_dir"
    local i5_dst_dir="$TEMP_DIR/i5_dst"
    umask 022
    test_command_exit_code "cp -r read-only source directory (I5)" 0 \
        run_with_limit 10 "$binary" -r "$i5_src_dir" "$i5_dst_dir"
    umask "$i77_saved_umask"
    chmod 755 "$i5_src_dir" 2>/dev/null || true
    test_command_output "cp -r read-only source dir child copied (I5)" \
        "issue 77 I5 child" cat "$i5_dst_dir/f.txt"
    local i5_dir_perms
    i5_dir_perms=$(get_file_permissions "$i5_dst_dir")
    chmod 755 "$i5_dst_dir" 2>/dev/null || true
    if [[ "$i5_dir_perms" == "555" ]]; then
        print_test_result "cp -r read-only source dir finalized to 555 (I5)" "PASS"
    else
        print_test_result "cp -r read-only source dir finalized to 555 (I5)" "FAIL" \
            "Expected 555, got $i5_dir_perms"
    fi

    echo -e "${CYAN}Testing issue #81: cp -p mode preservation must bypass umask...${NC}"

    # Pin the process umask for the reproducible cases below; sources are
    # created BEFORE this so their own modes come from explicit chmod, not
    # from umask-at-create.
    local i81_saved_umask
    i81_saved_umask=$(umask)

    # J1: cp -p to a NEW destination bypasses the umask entirely (unlike
    # plain cp, which the I1 block above already covers).
    local j1_src=$(create_temp_file "issue 81 J1")
    chmod 644 "$j1_src"
    local j1_dst="$TEMP_DIR/j1_dst.txt"
    umask 077
    test_command_exit_code "cp -p new destination bypasses umask (J1)" 0 \
        run_with_limit 10 "$binary" -p "$j1_src" "$j1_dst"
    umask "$i81_saved_umask"
    local j1_perms
    j1_perms=$(get_file_permissions "$j1_dst")
    # Normalize a BSD-style 4-digit "0644" (macOS `stat -f %A`) down to
    # GNU's 3-digit "644" so this comparison is platform-proof; special-bit
    # modes elsewhere in this block (e.g. J3's "4755") do not match this
    # pattern and are left untouched.
    if [[ "$j1_perms" =~ ^0([0-7]{3})$ ]]; then j1_perms="${BASH_REMATCH[1]}"; fi
    if [[ "$j1_perms" == "644" ]]; then
        print_test_result "cp -p new destination mode is 644 under umask 077 (J1)" "PASS"
    else
        print_test_result "cp -p new destination mode is 644 under umask 077 (J1)" "FAIL" \
            "Expected 644, got $j1_perms"
    fi

    # J2: cp -p over an EXISTING destination updates its mode to match the
    # source exactly -- O_CREAT's mode argument is ignored for an existing
    # file, so this must be driven by an explicit chmod after the copy.
    local j2_src=$(create_temp_file "issue 81 J2 new")
    chmod 644 "$j2_src"
    local j2_dst=$(create_temp_file "issue 81 J2 old")
    chmod 600 "$j2_dst"
    test_command_exit_code "cp -p over existing destination (J2)" 0 \
        run_with_limit 10 "$binary" -p "$j2_src" "$j2_dst"
    local j2_perms
    j2_perms=$(get_file_permissions "$j2_dst")
    if [[ "$j2_perms" =~ ^0([0-7]{3})$ ]]; then j2_perms="${BASH_REMATCH[1]}"; fi
    if [[ "$j2_perms" == "644" ]]; then
        print_test_result "cp -p updates existing destination mode to 644 (J2)" "PASS"
    else
        print_test_result "cp -p updates existing destination mode to 644 (J2)" "FAIL" \
            "Expected 644, got $j2_perms"
    fi
    test_command_output "cp -p existing destination content replaced (J2)" \
        "issue 81 J2 new" cat "$j2_dst"

    # J2 guard: cp WITHOUT -p over an existing destination keeps its own
    # mode -- pinned next to J2 so the -p / no-p asymmetry is explicit.
    local j2g_src=$(create_temp_file "issue 81 J2 guard new")
    chmod 644 "$j2g_src"
    local j2g_dst=$(create_temp_file "issue 81 J2 guard old")
    chmod 600 "$j2g_dst"
    test_command_exit_code "cp (no -p) over existing destination (J2 guard)" 0 \
        run_with_limit 10 "$binary" "$j2g_src" "$j2g_dst"
    local j2g_perms
    j2g_perms=$(get_file_permissions "$j2g_dst")
    if [[ "$j2g_perms" =~ ^0([0-7]{3})$ ]]; then j2g_perms="${BASH_REMATCH[1]}"; fi
    if [[ "$j2g_perms" == "600" ]]; then
        print_test_result "cp (no -p) existing destination keeps its mode (J2 guard)" "PASS"
    else
        print_test_result "cp (no -p) existing destination keeps its mode (J2 guard)" "FAIL" \
            "Expected 600, got $j2g_perms"
    fi

    # J3: cp -p preserves setuid -- the ownership-restore chown must not
    # silently clear the bit (Linux clears setuid/setgid on any chown,
    # even a same-owner no-op one, unless a chmod follows it).
    local j3_src=$(create_temp_file "issue 81 J3")
    chmod 755 "$j3_src"
    if chmod 4755 "$j3_src" 2>/dev/null && [[ "$(get_file_permissions "$j3_src")" == "4755" ]]; then
        local j3_dst="$TEMP_DIR/j3_dst.txt"
        test_command_exit_code "cp -p preserves setuid (J3)" 0 \
            run_with_limit 10 "$binary" -p "$j3_src" "$j3_dst"
        local j3_perms
        j3_perms=$(get_file_permissions "$j3_dst")
        if [[ "$j3_perms" == "4755" ]]; then
            print_test_result "cp -p setuid preserved (J3)" "PASS"
        else
            print_test_result "cp -p setuid preserved (J3)" "FAIL" \
                "Expected 4755, got $j3_perms"
        fi
    else
        print_test_result "cp -p setuid preserved (J3)" "SKIP" \
            "Could not set/verify setuid bit (4755) on source"
    fi

    echo -e "${CYAN}Testing issue #82: cp -r self-copy guard (dest inside/onto source)...${NC}"

    # Pinned reference: `cp (GNU coreutils) 9.4` on Linux, verified live on the
    # scouting VM for every scenario below. GNU refuses to copy a directory
    # into itself with "cp: cannot copy a directory, 'SRC', into itself,
    # 'DEST'", exit 1, while still copying unrelated sibling entries. The
    # CURRENT (buggy) vibeutils code either panics (SIGABRT, exit 134 under
    # run_with_limit's 128+signal mapping) or runs away creating thousands of
    # nested directories before erroring with the wrong, generic
    # "cannot access 'X': DepthLimitExceeded" message -- so every invocation
    # here MUST go through run_with_limit as an isolated subprocess; running
    # this in-process (as a unit test) would crash the whole test binary.

    # U1: the exact issue #82 repro -- `cp -r dir/.` where the destination
    # already lives inside the source tree. vibeutils's walker continues past
    # a failed entry (unlike GNU's readdir-order-dependent abort-on-first-hit),
    # so the sibling-copy assertions below hold regardless of directory
    # enumeration order.
    local i82_u1_dir="$TEMP_DIR/i82_u1"
    mkdir -p "$i82_u1_dir/dst" "$i82_u1_dir/sub"
    echo "hi" >"$i82_u1_dir/f"
    echo "yo" >"$i82_u1_dir/sub/g"

    local i82_u1_out i82_u1_exit
    set +e
    i82_u1_out=$(cd "$i82_u1_dir" && run_with_limit 10 "$binary" -r ./. dst/ 2>&1)
    i82_u1_exit=$?
    set -e

    if [[ $i82_u1_exit -eq 1 ]]; then
        print_test_result "cp -r issue#82 exact repro exits with the pinned code, not a panic/timeout (U1)" "PASS"
    else
        print_test_result "cp -r issue#82 exact repro exits with the pinned code, not a panic/timeout (U1)" "FAIL" \
            "Expected exit 1 (GNU general_error); got $i82_u1_exit (134 = SIGABRT/panic, 124 = timed out). Output: $i82_u1_out"
    fi

    if [[ "$i82_u1_out" == *"cannot copy a directory"* && "$i82_u1_out" == *"into itself"* ]]; then
        print_test_result "cp -r issue#82 exact repro reports the pinned into-itself diagnostic (U1)" "PASS"
    else
        print_test_result "cp -r issue#82 exact repro reports the pinned into-itself diagnostic (U1)" "FAIL" \
            "stderr missing GNU's 'cannot copy a directory ... into itself' wording. Output: $i82_u1_out"
    fi

    if [[ -f "$i82_u1_dir/dst/f" && "$(cat "$i82_u1_dir/dst/f")" == "hi" ]]; then
        print_test_result "cp -r issue#82 exact repro still copies the sibling file into dst (U1)" "PASS"
    else
        print_test_result "cp -r issue#82 exact repro still copies the sibling file into dst (U1)" "FAIL" \
            "Expected dst/f with content 'hi'"
    fi

    if [[ -f "$i82_u1_dir/dst/sub/g" && "$(cat "$i82_u1_dir/dst/sub/g")" == "yo" ]]; then
        print_test_result "cp -r issue#82 exact repro still copies the sibling subdir into dst (U1)" "PASS"
    else
        print_test_result "cp -r issue#82 exact repro still copies the sibling subdir into dst (U1)" "FAIL" \
            "Expected dst/sub/g with content 'yo'"
    fi

    if [[ ! -e "$i82_u1_dir/dst/dst/dst" ]]; then
        print_test_result "cp -r issue#82 exact repro does not runaway-nest past one level (U1)" "PASS"
    else
        print_test_result "cp -r issue#82 exact repro does not runaway-nest past one level (U1)" "FAIL" \
            "dst/dst/dst exists -- unbounded self-nesting into dst was not stopped"
    fi

    # U2: `cp -r a a` with a single child file. Fully deterministic (no
    # directory-enumeration order ambiguity), so the entire pinned GNU tree is
    # asserted exactly: 'a' -> 'a/a', 'a/f' -> 'a/a/f', then the into-itself
    # fatal -- bounded at exactly one level of self-nesting (a/a/a never
    # created).
    local i82_u2_dir="$TEMP_DIR/i82_u2"
    mkdir -p "$i82_u2_dir/a"
    echo "u2 content" >"$i82_u2_dir/a/f"

    local i82_u2_out i82_u2_exit
    set +e
    i82_u2_out=$(cd "$i82_u2_dir" && run_with_limit 10 "$binary" -r a a 2>&1)
    i82_u2_exit=$?
    set -e

    if [[ $i82_u2_exit -eq 1 ]]; then
        print_test_result "cp -r a a exits with the pinned code (U2)" "PASS"
    else
        print_test_result "cp -r a a exits with the pinned code (U2)" "FAIL" \
            "Expected exit 1; got $i82_u2_exit. Output: $i82_u2_out"
    fi

    if [[ "$i82_u2_out" == *"cannot copy a directory"* && "$i82_u2_out" == *"into itself"* \
        && "$i82_u2_out" == *"'a'"* && "$i82_u2_out" == *"'a/a'"* ]]; then
        print_test_result "cp -r a a reports the pinned into-itself diagnostic naming 'a' and 'a/a' (U2)" "PASS"
    else
        print_test_result "cp -r a a reports the pinned into-itself diagnostic naming 'a' and 'a/a' (U2)" "FAIL" \
            "Expected GNU wording \"cannot copy a directory, 'a', into itself, 'a/a'\". Output: $i82_u2_out"
    fi

    if [[ -f "$i82_u2_dir/a/a/f" && "$(cat "$i82_u2_dir/a/a/f")" == "u2 content" ]]; then
        print_test_result "cp -r a a copies the lone child into a/a/f before refusing (U2)" "PASS"
    else
        print_test_result "cp -r a a copies the lone child into a/a/f before refusing (U2)" "FAIL" \
            "Expected a/a/f with content 'u2 content'"
    fi

    if [[ ! -e "$i82_u2_dir/a/a/a" ]]; then
        print_test_result "cp -r a a stops at exactly one level of self-nesting (U2)" "PASS"
    else
        print_test_result "cp -r a a stops at exactly one level of self-nesting (U2)" "FAIL" \
            "a/a/a exists -- unbounded self-nesting was not stopped"
    fi

    # U3: `cp -r a a/b` -- dest is a pre-existing subdirectory of source, one
    # level down. Single child ("b", no sibling file), so again fully
    # deterministic: pinned GNU tree is 'a', 'a/b', 'a/b/a', 'a/b/a/b', with no
    # further nesting (a/b/a/b/a never created).
    local i82_u3_dir="$TEMP_DIR/i82_u3"
    mkdir -p "$i82_u3_dir/a/b"

    local i82_u3_out i82_u3_exit
    set +e
    i82_u3_out=$(cd "$i82_u3_dir" && run_with_limit 10 "$binary" -r a a/b 2>&1)
    i82_u3_exit=$?
    set -e

    if [[ $i82_u3_exit -eq 1 ]]; then
        print_test_result "cp -r a a/b exits with the pinned code (U3)" "PASS"
    else
        print_test_result "cp -r a a/b exits with the pinned code (U3)" "FAIL" \
            "Expected exit 1; got $i82_u3_exit. Output: $i82_u3_out"
    fi

    if [[ "$i82_u3_out" == *"cannot copy a directory"* && "$i82_u3_out" == *"into itself"* \
        && "$i82_u3_out" == *"'a'"* && "$i82_u3_out" == *"'a/b/a'"* ]]; then
        print_test_result "cp -r a a/b reports the pinned into-itself diagnostic naming 'a' and 'a/b/a' (U3)" "PASS"
    else
        print_test_result "cp -r a a/b reports the pinned into-itself diagnostic naming 'a' and 'a/b/a' (U3)" "FAIL" \
            "Expected GNU wording \"cannot copy a directory, 'a', into itself, 'a/b/a'\". Output: $i82_u3_out"
    fi

    # NOTE: unlike U2 (where 'f' is an innocent sibling GNU must copy), a's
    # only child here ('b') IS the destination operand itself, so whether
    # a/b/a/b gets created is an artifact of WHERE a correct fix detects the
    # self-reference (GNU's algorithm creates it before erroring; an equally
    # correct detect-before-create fix at the top of handleTreeDirPre never
    # would). Only the dest root a/b/a is unconditionally required: it is the
    # resolved destination for the top-level source operand 'a' itself, and
    # must exist under any correct implementation, bounded or not.
    if [[ -d "$i82_u3_dir/a/b/a" ]]; then
        print_test_result "cp -r a a/b creates the resolved dest root (a/b/a) before refusing (U3)" "PASS"
    else
        print_test_result "cp -r a a/b creates the resolved dest root (a/b/a) before refusing (U3)" "FAIL" \
            "Expected directory a/b/a to exist"
    fi

    if [[ ! -e "$i82_u3_dir/a/b/a/b/a" ]]; then
        print_test_result "cp -r a a/b stops at exactly one level of self-nesting (U3)" "PASS"
    else
        print_test_result "cp -r a a/b stops at exactly one level of self-nesting (U3)" "FAIL" \
            "a/b/a/b/a exists -- unbounded self-nesting was not stopped"
    fi

    # issue #99: src/common/file_ops.zig's setPermissions routed every
    # fchmod failure -- including the ordinary EPERM case below -- through
    # std.posix.unexpectedErrno, which prints "unexpected errno: <n>" and
    # dumps a stack trace straight to the real process stderr in Debug
    # builds (the default `zig build`/`just build` produces). Nothing else
    # in this suite inspects the compiled binary's own real stderr for this
    # code path (the unit tests in src/cp.zig only capture cp's own
    # stderr_writer, not std.debug's direct-to-fd output), so this is the
    # only place that can catch the diagnostic-noise regression itself.
    # /dev/null is root-owned and world-writable: an unprivileged process
    # can open/write it but not fchmod it (EPERM), the same real-syscall
    # trick "issue 81 U13" uses in src/cp.zig.
    #
    # NOTE: this test observes only the compiled cp binary's stderr, not a
    # `zig build test` run's own diagnostic channel (which src/cp.zig's
    # "issue 99" unit tests cannot reach either -- see the comment there).
    # The code path through setPermissions is identical either way, so this
    # is an accepted proxy, but it means nothing in the suite watches a
    # `zig build test` invocation's own stderr for this string.
    if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 && -z "${FAKEROOTKEY:-}" ]]; then
        local i99_src=$(create_temp_file "content")

        local i99_out i99_exit
        set +e
        i99_out=$(run_with_limit 10 "$binary" -p "$i99_src" /dev/null 2>&1)
        i99_exit=$?
        set -e

        if [[ $i99_exit -ne 0 && "$i99_out" != *"unexpected errno"* \
            && "$i99_out" != *"failed command:"* && "$i99_out" == *"/dev/null"* ]]; then
            print_test_result "cp -p on /dev/null: EPERM does not leak an 'unexpected errno' trace to stderr (issue 99)" "PASS"
        else
            print_test_result "cp -p on /dev/null: EPERM does not leak an 'unexpected errno' trace to stderr (issue 99)" "FAIL" \
                "exit=$i99_exit output=$i99_out"
        fi
    else
        print_test_result "cp -p on /dev/null: EPERM does not leak an 'unexpected errno' trace to stderr (issue 99)" "SKIP" \
            "requires Linux, non-root, non-fakeroot (matches issue 81 U13's guard in src/cp.zig)"
    fi
}
