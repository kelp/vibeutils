#!/usr/bin/env bash
# Comprehensive tests for ln utility
# Tests hard links, symbolic links, force, verbose, multiple targets,
# error conditions, and no-dereference flag

# This file is sourced by test_runner.sh, so common.sh is already loaded

# Cross-platform inode getter
# Tries GNU stat first, then BSD stat, to handle systems where
# GNU coreutils is installed on macOS (e.g., via nix or brew).
get_inode() {
    local file="$1"
    local inode=""

    # Try GNU stat format first (works on Linux and macOS with
    # GNU coreutils in PATH)
    inode=$(stat -c %i "$file" 2>/dev/null)
    if [[ -n "$inode" && "$inode" =~ ^[0-9]+$ ]]; then
        echo "$inode"
        return 0
    fi

    # Fall back to BSD stat format (macOS default)
    inode=$(/usr/bin/stat -f %i "$file" 2>/dev/null)
    if [[ -n "$inode" && "$inode" =~ ^[0-9]+$ ]]; then
        echo "$inode"
        return 0
    fi

    echo "0"
}

# Get inode WITHOUT following symlinks (lstat semantics)
get_inode_no_follow() {
    local file="$1"
    local inode=""

    # Try GNU stat with --no-dereference first
    inode=$(stat --no-dereference -c %i "$file" 2>/dev/null)
    if [[ -n "$inode" && "$inode" =~ ^[0-9]+$ ]]; then
        echo "$inode"
        return 0
    fi

    # BSD stat -f already uses lstat by default
    inode=$(/usr/bin/stat -f %i "$file" 2>/dev/null)
    if [[ -n "$inode" && "$inode" =~ ^[0-9]+$ ]]; then
        echo "$inode"
        return 0
    fi

    echo "0"
}

test_ln() {
    local util="ln"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing hard link creation...${NC}"

    # Create a target file for hard link tests
    local target1=$(create_temp_file "hard link content")

    # Basic hard link
    local hardlink1="$TEMP_DIR/hardlink1"
    test_command_exit_code "ln hard link" 0 "$binary" "$target1" "$hardlink1"

    # Verify hard link content matches
    if [[ -f "$hardlink1" ]]; then
        local content
        content=$(cat "$hardlink1")
        if [[ "$content" == "hard link content" ]]; then
            print_test_result "ln hard link content" "PASS"
        else
            print_test_result "ln hard link content" "FAIL" \
                "Expected 'hard link content', got '$content'"
        fi
    else
        print_test_result "ln hard link content" "FAIL" \
            "Hard link file not created"
    fi

    # Verify inodes match (hard link shares inode with target)
    local target_inode
    local link_inode
    target_inode=$(get_inode "$target1")
    link_inode=$(get_inode "$hardlink1")
    if [[ -n "$target_inode" && -n "$link_inode" \
          && "$target_inode" == "$link_inode" ]]; then
        print_test_result "ln hard link inode match" "PASS"
    else
        print_test_result "ln hard link inode match" "FAIL" \
            "Target inode: $target_inode, Link inode: $link_inode"
    fi

    echo -e "${CYAN}Testing symbolic link creation (-s)...${NC}"

    # Create symbolic link
    local symtarget=$(create_temp_file "symbolic link content")
    local symlink1="$TEMP_DIR/symlink1"
    test_command_exit_code "ln -s symbolic link" 0 \
        "$binary" -s "$symtarget" "$symlink1"

    # Verify it is a symlink
    if [[ -L "$symlink1" ]]; then
        print_test_result "ln -s creates symlink" "PASS"
    else
        print_test_result "ln -s creates symlink" "FAIL" \
            "File is not a symbolic link"
    fi

    # Verify symlink content is readable through the link
    if [[ -L "$symlink1" ]]; then
        local sym_content
        sym_content=$(cat "$symlink1")
        if [[ "$sym_content" == "symbolic link content" ]]; then
            print_test_result "ln -s symlink content" "PASS"
        else
            print_test_result "ln -s symlink content" "FAIL" \
                "Expected 'symbolic link content', got '$sym_content'"
        fi
    fi

    # Symbolic link with --symbolic long option
    local symlink_long="$TEMP_DIR/symlink_long"
    test_command_exit_code "ln --symbolic" 0 \
        "$binary" --symbolic "$symtarget" "$symlink_long"
    if [[ -L "$symlink_long" ]]; then
        print_test_result "ln --symbolic creates symlink" "PASS"
    else
        print_test_result "ln --symbolic creates symlink" "FAIL" \
            "File is not a symbolic link"
    fi

    # Symbolic link to nonexistent target (allowed for symlinks)
    local dangling="$TEMP_DIR/dangling_link"
    test_command_exit_code "ln -s dangling symlink" 0 \
        "$binary" -s "/nonexistent/target/file" "$dangling"
    if [[ -L "$dangling" ]]; then
        print_test_result "ln -s dangling symlink created" "PASS"
    else
        print_test_result "ln -s dangling symlink created" "FAIL" \
            "Dangling symlink not created"
    fi

    echo -e "${CYAN}Testing force flag (-f)...${NC}"

    # Force overwrite existing file with hard link
    local force_target=$(create_temp_file "force target content")
    local force_existing=$(create_temp_file "old content")
    test_command_exit_code "ln -f force hard link" 0 \
        "$binary" -f "$force_target" "$force_existing"

    # Verify content replaced
    local force_content
    force_content=$(cat "$force_existing")
    if [[ "$force_content" == "force target content" ]]; then
        print_test_result "ln -f overwrites existing" "PASS"
    else
        print_test_result "ln -f overwrites existing" "FAIL" \
            "Expected 'force target content', got '$force_content'"
    fi

    # Force overwrite with symbolic link
    local force_sym_target=$(create_temp_file "force sym target")
    local force_sym_existing=$(create_temp_file "old sym content")
    test_command_exit_code "ln -sf force symbolic link" 0 \
        "$binary" -sf "$force_sym_target" "$force_sym_existing"
    if [[ -L "$force_sym_existing" ]]; then
        print_test_result "ln -sf creates symlink" "PASS"
    else
        print_test_result "ln -sf creates symlink" "FAIL" \
            "File is not a symbolic link after force"
    fi

    # Force with --force long option
    local force_long_target=$(create_temp_file "force long target")
    local force_long_existing=$(create_temp_file "old long content")
    test_command_exit_code "ln --force" 0 \
        "$binary" --force "$force_long_target" "$force_long_existing"
    local force_long_content
    force_long_content=$(cat "$force_long_existing")
    if [[ "$force_long_content" == "force long target" ]]; then
        print_test_result "ln --force overwrites existing" "PASS"
    else
        print_test_result "ln --force overwrites existing" "FAIL" \
            "Expected 'force long target', got '$force_long_content'"
    fi

    # Without force, existing destination should fail
    local no_force_target=$(create_temp_file "no force target")
    local no_force_existing=$(create_temp_file "existing content")
    test_command_exit_code "ln without force to existing" 1 \
        "$binary" "$no_force_target" "$no_force_existing"

    # Verify existing file was not modified
    local no_force_content
    no_force_content=$(cat "$no_force_existing")
    if [[ "$no_force_content" == "existing content" ]]; then
        print_test_result "ln without force preserves existing" "PASS"
    else
        print_test_result "ln without force preserves existing" "FAIL" \
            "Existing file was modified"
    fi

    echo -e "${CYAN}Testing verbose flag (-v)...${NC}"

    # Verbose hard link
    local verb_target=$(create_temp_file "verbose target")
    local verb_link="$TEMP_DIR/verbose_hardlink"
    local verb_out=""
    local verb_err=""
    local verb_exit=""
    run_command verb_cmd verb_out verb_err verb_exit \
        "$binary" -v "$verb_target" "$verb_link"
    if [[ $verb_exit -eq 0 && "$verb_out" =~ "=>" ]]; then
        print_test_result "ln -v hard link output" "PASS"
    else
        print_test_result "ln -v hard link output" "FAIL" \
            "Expected '=>' in output, got: $verb_out"
    fi

    # Verbose symbolic link
    local verb_sym_target=$(create_temp_file "verbose sym target")
    local verb_sym_link="$TEMP_DIR/verbose_symlink"
    local verb_sym_out=""
    local verb_sym_err=""
    local verb_sym_exit=""
    run_command verb_sym_cmd verb_sym_out verb_sym_err verb_sym_exit \
        "$binary" -sv "$verb_sym_target" "$verb_sym_link"
    if [[ $verb_sym_exit -eq 0 && "$verb_sym_out" =~ "->" ]]; then
        print_test_result "ln -sv symbolic link output" "PASS"
    else
        print_test_result "ln -sv symbolic link output" "FAIL" \
            "Expected '->' in output, got: $verb_sym_out"
    fi

    # Verbose with --verbose long option
    local verb_long_target=$(create_temp_file "verbose long target")
    local verb_long_link="$TEMP_DIR/verbose_long_link"
    local verb_long_out=""
    local verb_long_err=""
    local verb_long_exit=""
    run_command verb_long_cmd verb_long_out verb_long_err verb_long_exit \
        "$binary" --verbose "$verb_long_target" "$verb_long_link"
    if [[ $verb_long_exit -eq 0 && "$verb_long_out" =~ "=>" ]]; then
        print_test_result "ln --verbose output" "PASS"
    else
        print_test_result "ln --verbose output" "FAIL" \
            "Expected '=>' in output, got: $verb_long_out"
    fi

    echo -e "${CYAN}Testing multiple targets to directory...${NC}"

    # Create multiple targets and a destination directory
    local multi_target1=$(create_temp_file "multi target 1")
    local multi_target2=$(create_temp_file "multi target 2")
    local multi_target3=$(create_temp_file "multi target 3")
    local multi_dir=$(create_temp_dir)

    test_command_exit_code "ln multiple targets to directory" 0 \
        "$binary" "$multi_target1" "$multi_target2" "$multi_target3" \
        "$multi_dir"

    # Verify all links created in directory
    local base1
    local base2
    local base3
    base1=$(basename "$multi_target1")
    base2=$(basename "$multi_target2")
    base3=$(basename "$multi_target3")

    if [[ -f "$multi_dir/$base1" ]]; then
        print_test_result "ln multi target 1 created" "PASS"
    else
        print_test_result "ln multi target 1 created" "FAIL" \
            "Link not found in directory"
    fi

    if [[ -f "$multi_dir/$base2" ]]; then
        print_test_result "ln multi target 2 created" "PASS"
    else
        print_test_result "ln multi target 2 created" "FAIL" \
            "Link not found in directory"
    fi

    if [[ -f "$multi_dir/$base3" ]]; then
        print_test_result "ln multi target 3 created" "PASS"
    else
        print_test_result "ln multi target 3 created" "FAIL" \
            "Link not found in directory"
    fi

    # Verify content of links in directory
    local multi_content1
    multi_content1=$(cat "$multi_dir/$base1")
    if [[ "$multi_content1" == "multi target 1" ]]; then
        print_test_result "ln multi target 1 content" "PASS"
    else
        print_test_result "ln multi target 1 content" "FAIL" \
            "Expected 'multi target 1', got '$multi_content1'"
    fi

    # Multiple symbolic links to directory
    local sym_multi_dir=$(create_temp_dir)
    test_command_exit_code "ln -s multiple targets to dir" 0 \
        "$binary" -s "$multi_target1" "$multi_target2" "$sym_multi_dir"

    if [[ -L "$sym_multi_dir/$base1" ]]; then
        print_test_result "ln -s multi target 1 is symlink" "PASS"
    else
        print_test_result "ln -s multi target 1 is symlink" "FAIL" \
            "Not a symbolic link"
    fi

    if [[ -L "$sym_multi_dir/$base2" ]]; then
        print_test_result "ln -s multi target 2 is symlink" "PASS"
    else
        print_test_result "ln -s multi target 2 is symlink" "FAIL" \
            "Not a symbolic link"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Hard link to nonexistent target (should fail)
    local bad_link="$TEMP_DIR/bad_hardlink"
    test_command_exit_code "ln nonexistent target" 1 \
        "$binary" "/nonexistent/target/file" "$bad_link"

    # Verify the link was not created
    if [[ ! -e "$bad_link" ]]; then
        print_test_result "ln nonexistent target no link created" "PASS"
    else
        print_test_result "ln nonexistent target no link created" "FAIL" \
            "Link was created for nonexistent target"
    fi

    # No arguments
    test_command_exit_code "ln no arguments" 1 "$binary"

    # Invalid flag
    test_command_exit_code "ln invalid flag" 1 \
        "$binary" --invalid-flag 2>/dev/null

    # Multiple targets to non-directory destination
    local ndir_target1=$(create_temp_file "ndir 1")
    local ndir_target2=$(create_temp_file "ndir 2")
    local ndir_dest=$(create_temp_file "not a directory")
    test_command_exit_code "ln multiple targets to non-dir" 1 \
        "$binary" "$ndir_target1" "$ndir_target2" "$ndir_dest"

    # Error message for nonexistent target
    local err_out=""
    local err_err=""
    local err_exit=""
    run_command err_cmd err_out err_err err_exit \
        "$binary" "/tmp/definitely_nonexistent_$$" "$TEMP_DIR/err_link"
    if [[ "$err_err" =~ "No such file or directory" \
          || "$err_err" =~ "cannot link" \
          || "$err_err" =~ "FileNotFound" ]]; then
        print_test_result "ln error message format" "PASS"
    else
        print_test_result "ln error message format" "FAIL" \
            "Expected error about missing file, got: $err_err"
    fi

    # Error message for existing destination without force
    local exist_target=$(create_temp_file "exist target")
    local exist_dest=$(create_temp_file "exist dest")
    local exist_out=""
    local exist_err=""
    local exist_exit=""
    run_command exist_cmd exist_out exist_err exist_exit \
        "$binary" "$exist_target" "$exist_dest"
    if [[ "$exist_err" =~ "File exists" \
          || "$exist_err" =~ "FileExists" ]]; then
        print_test_result "ln file exists error message" "PASS"
    else
        print_test_result "ln file exists error message" "FAIL" \
            "Expected 'File exists' error, got: $exist_err"
    fi

    echo -e "${CYAN}Testing no-dereference flag (-n)...${NC}"

    # Test -n with symlink to a regular file: replace the symlink
    # rather than following it.
    local noderef_target=$(create_temp_file "noderef content")
    local noderef_orig_target=$(create_temp_file "original target")
    local noderef_link="$TEMP_DIR/noderef_link"
    ln -s "$noderef_orig_target" "$noderef_link"

    # Use -sfn to replace the existing symlink
    test_command_exit_code "ln -sfn replaces symlink" 0 \
        "$binary" -sfn "$noderef_target" "$noderef_link"

    # The link should still be a symlink (not removed and recreated
    # as a regular file)
    if [[ -L "$noderef_link" ]]; then
        print_test_result "ln -sfn result is symlink" "PASS"
    else
        print_test_result "ln -sfn result is symlink" "FAIL" \
            "Result is not a symlink"
    fi

    # Verify -n flag is accepted (does not cause error)
    local noderef_accept_target=$(create_temp_file "accept target")
    local noderef_accept_link="$TEMP_DIR/noderef_accept"
    test_command_exit_code "ln -n flag accepted" 0 \
        "$binary" -sn "$noderef_accept_target" "$noderef_accept_link"
    if [[ -L "$noderef_accept_link" ]]; then
        print_test_result "ln -n creates symlink" "PASS"
    else
        print_test_result "ln -n creates symlink" "FAIL" \
            "Symlink not created"
    fi

    # Test --no-dereference long option is accepted
    local noderef_long_target=$(create_temp_file "long noderef target")
    local noderef_long_link="$TEMP_DIR/noderef_long"
    test_command_exit_code "ln --no-dereference accepted" 0 \
        "$binary" -s --no-dereference \
        "$noderef_long_target" "$noderef_long_link"
    if [[ -L "$noderef_long_link" ]]; then
        print_test_result "ln --no-dereference creates symlink" "PASS"
    else
        print_test_result "ln --no-dereference creates symlink" "FAIL" \
            "Symlink not created"
    fi

    echo -e "${CYAN}Testing POSIX symlink flags (-L, -P)...${NC}"

    # -L flag: when creating a hard link to a symlink, follow the
    # symlink and hard link to the target instead
    local l_target_file=$(create_temp_file "L target content")
    local l_symlink="$TEMP_DIR/l_symlink"
    ln -s "$l_target_file" "$l_symlink"

    local l_hardlink="$TEMP_DIR/l_hardlink"
    test_command_exit_code "ln -L follows symlink" 0 \
        "$binary" -L "$l_symlink" "$l_hardlink"

    # Verify the hard link points to the target file (same inode as target)
    local l_target_inode
    local l_link_inode
    l_target_inode=$(get_inode "$l_target_file")
    l_link_inode=$(get_inode "$l_hardlink")
    if [[ -n "$l_target_inode" && -n "$l_link_inode" \
          && "$l_target_inode" == "$l_link_inode" ]]; then
        print_test_result "ln -L hard link matches target inode" "PASS"
    else
        print_test_result "ln -L hard link matches target inode" "FAIL" \
            "Target inode: $l_target_inode, Link inode: $l_link_inode"
    fi

    # Verify the result is NOT a symlink (it's a hard link)
    if [[ ! -L "$l_hardlink" ]]; then
        print_test_result "ln -L creates hard link not symlink" "PASS"
    else
        print_test_result "ln -L creates hard link not symlink" "FAIL" \
            "Result is a symlink instead of a hard link"
    fi

    # -P flag: hard link to the symlink itself (not its target)
    # Note: hard-linking to symlinks works on macOS but fails on Linux (EPERM)
    local p_target_file=$(create_temp_file "P target content")
    local p_symlink="$TEMP_DIR/p_symlink"
    ln -s "$p_target_file" "$p_symlink"

    local p_hardlink="$TEMP_DIR/p_hardlink"

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS supports hard linking to symlinks
        test_command_exit_code "ln -P links to symlink itself" 0 \
            "$binary" -P "$p_symlink" "$p_hardlink"

        # The hard link should have the same inode as the symlink
        local p_sym_inode
        local p_hard_inode
        p_sym_inode=$(get_inode_no_follow "$p_symlink")
        p_hard_inode=$(get_inode_no_follow "$p_hardlink")

        if [[ -n "$p_sym_inode" && -n "$p_hard_inode" \
              && "$p_sym_inode" == "$p_hard_inode" ]]; then
            print_test_result "ln -P hard link matches symlink inode" "PASS"
        else
            print_test_result "ln -P hard link matches symlink inode" "FAIL" \
                "Symlink inode: $p_sym_inode, Hard link inode: $p_hard_inode"
        fi

        # Verify the hard link to symlink is itself a symlink
        if [[ -L "$p_hardlink" ]]; then
            print_test_result "ln -P result is symlink" "PASS"
        else
            print_test_result "ln -P result is symlink" "FAIL" \
                "Expected symlink, got regular file"
        fi
    else
        # Linux: hard-linking to symlinks requires CAP_DAC_READ_SEARCH
        # or root privileges. Try the command and branch on result.
        "$binary" -P "$p_symlink" "$p_hardlink" >/dev/null 2>&1
        local p_exit=$?
        if [[ $p_exit -eq 0 ]]; then
            # Succeeded (privileged environment) — verify behavior
            local p_sym_inode
            local p_hard_inode
            p_sym_inode=$(get_inode_no_follow "$p_symlink")
            p_hard_inode=$(get_inode_no_follow "$p_hardlink")

            if [[ -n "$p_sym_inode" && -n "$p_hard_inode" \
                  && "$p_sym_inode" == "$p_hard_inode" ]]; then
                print_test_result "ln -P hard link matches symlink inode" "PASS"
            else
                print_test_result "ln -P hard link matches symlink inode" "FAIL" \
                    "Symlink inode: $p_sym_inode, Hard link inode: $p_hard_inode"
            fi

            if [[ -L "$p_hardlink" ]]; then
                print_test_result "ln -P result is symlink" "PASS"
            else
                print_test_result "ln -P result is symlink" "FAIL" \
                    "Expected symlink, got regular file"
            fi
        else
            print_test_result "ln -P on Linux (requires privileges)" "SKIP"
        fi
    fi

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Force + Verbose + Symbolic
    local combo_target=$(create_temp_file "combo content")
    local combo_existing=$(create_temp_file "old combo")
    local combo_out=""
    local combo_err=""
    local combo_exit=""
    run_command combo_cmd combo_out combo_err combo_exit \
        "$binary" -sfv "$combo_target" "$combo_existing"
    if [[ $combo_exit -eq 0 && "$combo_out" =~ "->" \
          && -L "$combo_existing" ]]; then
        print_test_result "ln -sfv combination" "PASS"
    else
        print_test_result "ln -sfv combination" "FAIL" \
            "Exit: $combo_exit, Output: $combo_out"
    fi

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX: exit 0 on success
    local posix_target=$(create_temp_file "posix target")
    local posix_link="$TEMP_DIR/posix_link"
    test_command_exit_code "ln POSIX success exit code" 0 \
        "$binary" "$posix_target" "$posix_link"

    # POSIX: exit >0 on failure
    test_command_exit_code "ln POSIX failure exit code" 1 \
        "$binary" "/nonexistent/posix/target" "$TEMP_DIR/posix_fail"

    # Regression test: ln -sb should create backup~ and new link without -f
    echo -e "${CYAN}Testing -b backup without -f regression...${NC}"

    local backup_target=$(create_temp_file "backup target content")
    local backup_link="$TEMP_DIR/backup_link"
    ln -s "/some/original/target" "$backup_link"

    test_command_exit_code "ln -sb creates backup and new link" 0 \
        "$binary" -sb "$backup_target" "$backup_link"

    # Verify the backup file exists (use -L since backup may be a broken symlink)
    if [[ -e "${backup_link}~" || -L "${backup_link}~" ]]; then
        print_test_result "ln -sb backup file created" "PASS"
    else
        print_test_result "ln -sb backup file created" "FAIL" \
            "Expected ${backup_link}~ to exist"
    fi

    # Verify the new link exists and is a symlink
    if [[ -L "$backup_link" ]]; then
        print_test_result "ln -sb new symlink created" "PASS"
    else
        print_test_result "ln -sb new symlink created" "FAIL" \
            "Expected $backup_link to be a symlink"
    fi

    rm -f "$backup_link" "${backup_link}~"

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: ln error messages should use readable names, not raw errno
    # stderr should say "No such file or directory" not "errno(123)" or similar
    local reg_err_out=""
    local reg_err_err=""
    local reg_err_exit=""
    run_command reg_err_cmd reg_err_out reg_err_err reg_err_exit \
        "$binary" "/nonexistent/dir/target" "$TEMP_DIR/reg_err_link"
    if [[ "$reg_err_err" =~ "No such file" && ! "$reg_err_err" =~ "errno(" ]]; then
        print_test_result "ln readable error message (regression)" "PASS"
    else
        print_test_result "ln readable error message (regression)" "FAIL" \
            "Expected readable error, got: $reg_err_err"
    fi

    # F54: ln -sfn should replace a symlink-to-directory, not follow it
    echo -e "${CYAN}Testing F54: -n/--no-dereference with symlink-to-directory...${NC}"

    # Create a real directory, a symlink to it, and a target file
    local f54_dir="$TEMP_DIR/f54_real_dir"
    mkdir -p "$f54_dir"
    local f54_dir_link="$TEMP_DIR/f54_dir_link"
    ln -s "$f54_dir" "$f54_dir_link"
    local f54_target=$(create_temp_file "f54 target content")

    # ln -sfn target dir_link should REPLACE dir_link with a symlink to target
    # Bug: our code follows dir_link into f54_real_dir and creates target inside
    local f54_out=""
    local f54_err=""
    local f54_exit=""
    run_command f54_cmd f54_out f54_err f54_exit \
        "$binary" -sfn "$f54_target" "$f54_dir_link"

    if [[ $f54_exit -eq 0 ]]; then
        print_test_result "ln -sfn exit code" "PASS"
    else
        print_test_result "ln -sfn exit code" "FAIL" \
            "Expected exit 0, got $f54_exit, stderr: $f54_err"
    fi

    # dir_link should now point to f54_target, NOT to f54_real_dir
    local f54_readlink
    f54_readlink=$(readlink "$f54_dir_link")
    if [[ "$f54_readlink" == "$f54_target" ]]; then
        print_test_result "ln -sfn replaces symlink-to-dir" "PASS"
    else
        print_test_result "ln -sfn replaces symlink-to-dir" "FAIL" \
            "Expected dir_link -> $f54_target, got dir_link -> $f54_readlink"
    fi

    # dir_link should NOT be a directory anymore (it should be a symlink to a file)
    if [[ -L "$f54_dir_link" && ! -d "$f54_dir_link" ]]; then
        print_test_result "ln -sfn dir_link is not a directory" "PASS"
    else
        print_test_result "ln -sfn dir_link is not a directory" "FAIL" \
            "dir_link is still a directory (symlink was followed)"
    fi

    # F54: same test with -h (POSIX alias for --no-dereference)
    local f54h_dir="$TEMP_DIR/f54h_real_dir"
    mkdir -p "$f54h_dir"
    local f54h_dir_link="$TEMP_DIR/f54h_dir_link"
    ln -s "$f54h_dir" "$f54h_dir_link"
    local f54h_target=$(create_temp_file "f54h target content")

    local f54h_out=""
    local f54h_err=""
    local f54h_exit=""
    run_command f54h_cmd f54h_out f54h_err f54h_exit \
        "$binary" -sfh "$f54h_target" "$f54h_dir_link"

    local f54h_readlink
    f54h_readlink=$(readlink "$f54h_dir_link")
    if [[ "$f54h_readlink" == "$f54h_target" ]]; then
        print_test_result "ln -sfh replaces symlink-to-dir" "PASS"
    else
        print_test_result "ln -sfh replaces symlink-to-dir" "FAIL" \
            "Expected dir_link -> $f54h_target, got dir_link -> $f54h_readlink"
    fi

    # F54: --no-dereference long option
    local f54l_dir="$TEMP_DIR/f54l_real_dir"
    mkdir -p "$f54l_dir"
    local f54l_dir_link="$TEMP_DIR/f54l_dir_link"
    ln -s "$f54l_dir" "$f54l_dir_link"
    local f54l_target=$(create_temp_file "f54l target content")

    local f54l_out=""
    local f54l_err=""
    local f54l_exit=""
    run_command f54l_cmd f54l_out f54l_err f54l_exit \
        "$binary" -sf --no-dereference "$f54l_target" "$f54l_dir_link"

    local f54l_readlink
    f54l_readlink=$(readlink "$f54l_dir_link")
    if [[ "$f54l_readlink" == "$f54l_target" ]]; then
        print_test_result "ln --no-dereference replaces symlink-to-dir" "PASS"
    else
        print_test_result "ln --no-dereference replaces symlink-to-dir" "FAIL" \
            "Expected dir_link -> $f54l_target, got dir_link -> $f54l_readlink"
    fi

    # F66: ln --backup=simple should not crash/panic
    echo -e "${CYAN}Testing F66: --backup=CONTROL should not panic...${NC}"

    local f66_source=$(create_temp_file "f66 source content")
    local f66_dest=$(create_temp_file "f66 dest content")

    # --backup=simple should work or give a clean error, NOT a stack trace
    local f66_out=""
    local f66_err=""
    local f66_exit=""
    run_command f66_cmd f66_out f66_err f66_exit \
        "$binary" --backup=simple "$f66_source" "$f66_dest"

    # Check that it did NOT produce a stack trace / error return trace
    # The binary currently prints "error: TooManyValues" with a Zig
    # error return trace, which is unacceptable for a user-facing tool.
    if [[ "$f66_err" =~ "TooManyValues" || "$f66_err" =~ "panic" \
          || "$f66_err" =~ ".zig:" || "$f66_err" =~ "stack trace" \
          || "$f66_err" =~ "reached unreachable" ]]; then
        print_test_result "ln --backup=simple no error trace" "FAIL" \
            "Got Zig error trace instead of clean message: $f66_err"
    else
        print_test_result "ln --backup=simple no error trace" "PASS"
    fi

    # Should exit cleanly: 0 (success) or 1 (usage error). The stderr
    # trace check above is what catches unhandled error propagation.
    if [[ $f66_exit -eq 0 || $f66_exit -eq 1 ]]; then
        print_test_result "ln --backup=simple clean exit" "PASS"
    else
        print_test_result "ln --backup=simple clean exit" "FAIL" \
            "Expected exit 0 or 1, got $f66_exit (stderr: $f66_err)"
    fi

    # F66: same with --backup=numbered
    local f66n_source=$(create_temp_file "f66n source content")
    local f66n_dest=$(create_temp_file "f66n dest content")

    local f66n_out=""
    local f66n_err=""
    local f66n_exit=""
    run_command f66n_cmd f66n_out f66n_err f66n_exit \
        "$binary" --backup=numbered "$f66n_source" "$f66n_dest"

    if [[ "$f66n_err" =~ "TooManyValues" || "$f66n_err" =~ "panic" \
          || "$f66n_err" =~ ".zig:" || "$f66n_err" =~ "stack trace" \
          || "$f66n_err" =~ "reached unreachable" ]]; then
        print_test_result "ln --backup=numbered no error trace" "FAIL" \
            "Got Zig error trace instead of clean message: $f66n_err"
    else
        print_test_result "ln --backup=numbered no error trace" "PASS"
    fi

    if [[ $f66n_exit -eq 0 || $f66n_exit -eq 1 ]]; then
        print_test_result "ln --backup=numbered clean exit" "PASS"
    else
        print_test_result "ln --backup=numbered clean exit" "FAIL" \
            "Expected exit 0 or 1, got $f66n_exit (stderr: $f66n_err)"
    fi

    # ================================================================
    # AUDIT: ln -i interactive 'y' fails to remove existing destination
    # Bug: after user confirms 'y', code does not delete the existing
    # file before creating the new link, causing PathAlreadyExists.
    # ================================================================
    echo -e "${CYAN}Testing ln -i interactive confirmation...${NC}"

    local i_target=$(create_temp_file "interactive target")
    local i_existing=$(create_temp_file "existing content")

    # Pipe 'y' to confirm replacement; should succeed
    local i_out=""
    local i_err=""
    local i_exit=""
    run_command i_cmd i_out i_err i_exit \
        bash -c "echo y | '$binary' -si '$i_target' '$i_existing'"

    if [[ $i_exit -eq 0 ]]; then
        print_test_result "ln -si y confirms replacement" "PASS"
    else
        print_test_result "ln -si y confirms replacement" "FAIL" \
            "Expected exit 0, got $i_exit (stderr: $i_err)"
    fi

    # The existing file should now be a symlink to the target
    if [[ -L "$i_existing" ]]; then
        local i_readlink
        i_readlink=$(readlink "$i_existing")
        if [[ "$i_readlink" == "$i_target" ]]; then
            print_test_result "ln -si y creates correct symlink" "PASS"
        else
            print_test_result "ln -si y creates correct symlink" "FAIL" \
                "Expected -> $i_target, got -> $i_readlink"
        fi
    else
        print_test_result "ln -si y creates correct symlink" "FAIL" \
            "Destination is not a symlink after 'y' confirmation"
    fi

    # Pipe 'n' to decline; existing file should be preserved
    local i_n_target=$(create_temp_file "n target")
    local i_n_existing=$(create_temp_file "n existing content")

    local i_n_out=""
    local i_n_err=""
    local i_n_exit=""
    run_command i_n_cmd i_n_out i_n_err i_n_exit \
        bash -c "echo n | '$binary' -si '$i_n_target' '$i_n_existing'"

    local i_n_content
    i_n_content=$(cat "$i_n_existing")
    if [[ "$i_n_content" == "n existing content" ]]; then
        print_test_result "ln -si n preserves existing file" "PASS"
    else
        print_test_result "ln -si n preserves existing file" "FAIL" \
            "Expected original content, got '$i_n_content'"
    fi

    # ================================================================
    # AUDIT: ln -b ignores SIMPLE_BACKUP_SUFFIX env var
    # GNU ln reads SIMPLE_BACKUP_SUFFIX to override the default '~'.
    # Our implementation hardcodes '~'.
    # ================================================================
    echo -e "${CYAN}Testing ln -b SIMPLE_BACKUP_SUFFIX...${NC}"

    local bsuf_target=$(create_temp_file "bsuf target")
    local bsuf_link="$TEMP_DIR/bsuf_link"
    ln -s "/some/original" "$bsuf_link"

    local bsuf_out=""
    local bsuf_err=""
    local bsuf_exit=""
    run_command bsuf_cmd bsuf_out bsuf_err bsuf_exit \
        env SIMPLE_BACKUP_SUFFIX=".bak" "$binary" -sb "$bsuf_target" "$bsuf_link"

    if [[ $bsuf_exit -eq 0 ]]; then
        print_test_result "ln -sb with SIMPLE_BACKUP_SUFFIX exits 0" "PASS"
    else
        print_test_result "ln -sb with SIMPLE_BACKUP_SUFFIX exits 0" "FAIL" \
            "Exit $bsuf_exit, stderr: $bsuf_err"
    fi

    # Backup should use .bak suffix, not ~
    if [[ -e "${bsuf_link}.bak" || -L "${bsuf_link}.bak" ]]; then
        print_test_result "ln -sb uses SIMPLE_BACKUP_SUFFIX=.bak" "PASS"
    else
        print_test_result "ln -sb uses SIMPLE_BACKUP_SUFFIX=.bak" "FAIL" \
            "Expected ${bsuf_link}.bak, found: $(ls ${bsuf_link}* 2>/dev/null)"
    fi

    rm -f "$bsuf_link" "${bsuf_link}.bak" "${bsuf_link}~"

    # ================================================================
    # AUDIT: ln -v with -r shows original target, not relative path
    # GNU ln -svr shows the computed relative path in verbose output.
    # Our code shows the original target argument instead.
    # ================================================================
    echo -e "${CYAN}Testing ln -vr verbose shows relative path...${NC}"

    local vr_dir="$TEMP_DIR/vr_test"
    mkdir -p "$vr_dir/subdir"
    create_temp_file "vr target" "$vr_dir/target.txt"

    local vr_out=""
    local vr_err=""
    local vr_exit=""
    run_command vr_cmd vr_out vr_err vr_exit \
        "$binary" -svr "$vr_dir/target.txt" "$vr_dir/subdir/link.txt"

    if [[ $vr_exit -eq 0 ]]; then
        print_test_result "ln -svr exit code" "PASS"
    else
        print_test_result "ln -svr exit code" "FAIL" \
            "Expected exit 0, got $vr_exit"
    fi

    # Verbose output should show the relative path '../target.txt',
    # not the original absolute/relative path
    if [[ "$vr_out" == *"../target.txt"* ]]; then
        print_test_result "ln -svr verbose shows relative path" "PASS"
    else
        print_test_result "ln -svr verbose shows relative path" "FAIL" \
            "Expected '../target.txt' in output, got: $vr_out"
    fi

    rm -rf "$vr_dir"

    # ================================================================
    # AUDIT: ln -F without -s incorrectly enables force
    # macOS spec: -F is a no-op unless -s is specified.
    # Our code sets force=true when -F is given without -s.
    # ================================================================
    echo -e "${CYAN}Testing ln -F without -s...${NC}"

    local fdir_source=$(create_temp_file "F source")
    local fdir_existing=$(create_temp_file "F existing content")

    # -F without -s should NOT force-replace an existing hard link dest
    local fdir_out=""
    local fdir_err=""
    local fdir_exit=""
    run_command fdir_cmd fdir_out fdir_err fdir_exit \
        "$binary" -F "$fdir_source" "$fdir_existing"

    if [[ $fdir_exit -ne 0 ]]; then
        print_test_result "ln -F without -s does not force-replace" "PASS"
    else
        print_test_result "ln -F without -s does not force-replace" "FAIL" \
            "Expected failure (file exists), got exit 0"
    fi

    # Verify existing file was not overwritten
    local fdir_content
    fdir_content=$(cat "$fdir_existing")
    if [[ "$fdir_content" == "F existing content" ]]; then
        print_test_result "ln -F without -s preserves existing file" "PASS"
    else
        print_test_result "ln -F without -s preserves existing file" "FAIL" \
            "File was overwritten despite -F being no-op without -s"
    fi

    # -F WITH -s should enable force (this is correct behavior)
    local fdir_sf_source=$(create_temp_file "Fs source")
    local fdir_sf_existing=$(create_temp_file "Fs existing")

    local fdir_sf_out=""
    local fdir_sf_err=""
    local fdir_sf_exit=""
    run_command fdir_sf_cmd fdir_sf_out fdir_sf_err fdir_sf_exit \
        "$binary" -sF "$fdir_sf_source" "$fdir_sf_existing"

    if [[ $fdir_sf_exit -eq 0 && -L "$fdir_sf_existing" ]]; then
        print_test_result "ln -sF force-replaces with symlink" "PASS"
    else
        print_test_result "ln -sF force-replaces with symlink" "FAIL" \
            "Expected exit 0 and symlink, got exit $fdir_sf_exit"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -w (warn dangling)
    # ================================================================
    echo -e "${CYAN}Testing ln -w warns on dangling symlink...${NC}"

    local w_link="$TEMP_DIR/w_dangling_link"

    local w_out=""
    local w_err=""
    local w_exit=""
    run_command w_cmd w_out w_err w_exit \
        "$binary" -sw "/nonexistent/target/path" "$w_link"

    # Should succeed (dangling symlinks are allowed)
    if [[ $w_exit -eq 0 ]]; then
        print_test_result "ln -sw dangling symlink exits 0" "PASS"
    else
        print_test_result "ln -sw dangling symlink exits 0" "FAIL" \
            "Expected exit 0, got $w_exit"
    fi

    # Should emit a warning about the missing target on stderr
    if [[ "$w_err" =~ "warning" || "$w_err" =~ "dangling" \
          || "$w_err" =~ "does not exist" \
          || "$w_err" =~ "No such file" ]]; then
        print_test_result "ln -sw emits dangling warning" "PASS"
    else
        print_test_result "ln -sw emits dangling warning" "FAIL" \
            "Expected warning about missing target, got stderr: '$w_err'"
    fi

    if [[ -L "$w_link" ]]; then
        print_test_result "ln -sw still creates dangling symlink" "PASS"
    else
        print_test_result "ln -sw still creates dangling symlink" "FAIL" \
            "Symlink not created"
    fi

    rm -f "$w_link"

    # ================================================================
    # AUDIT: Test gap coverage for -r (relative symlink)
    # ================================================================
    echo -e "${CYAN}Testing ln -r relative symlink...${NC}"

    local r_dir="$TEMP_DIR/r_test"
    mkdir -p "$r_dir/a/b"
    create_temp_file "relative target" "$r_dir/a/target.txt"

    test_command_exit_code "ln -sr creates relative symlink" 0 \
        "$binary" -sr "$r_dir/a/target.txt" "$r_dir/a/b/link.txt"

    if [[ -L "$r_dir/a/b/link.txt" ]]; then
        local r_readlink
        r_readlink=$(readlink "$r_dir/a/b/link.txt")
        if [[ "$r_readlink" == "../target.txt" ]]; then
            print_test_result "ln -sr stores relative path" "PASS"
        else
            print_test_result "ln -sr stores relative path" "FAIL" \
                "Expected '../target.txt', got '$r_readlink'"
        fi
    else
        print_test_result "ln -sr stores relative path" "FAIL" \
            "Symlink not created"
    fi

    # Verify the relative symlink actually resolves
    if [[ -f "$r_dir/a/b/link.txt" ]]; then
        local r_content
        r_content=$(cat "$r_dir/a/b/link.txt")
        if [[ "$r_content" == "relative target" ]]; then
            print_test_result "ln -sr relative symlink resolves" "PASS"
        else
            print_test_result "ln -sr relative symlink resolves" "FAIL" \
                "Expected 'relative target', got '$r_content'"
        fi
    else
        print_test_result "ln -sr relative symlink resolves" "FAIL" \
            "Symlink does not resolve to target"
    fi

    rm -rf "$r_dir"

    # ================================================================
    # AUDIT: Test gap coverage for -t (target directory)
    # ================================================================
    echo -e "${CYAN}Testing ln -t target directory...${NC}"

    local t_target=$(create_temp_file "t target content")
    local t_dir=$(create_temp_dir)

    test_command_exit_code "ln -st target-dir source" 0 \
        "$binary" -st "$t_dir" "$t_target"

    local t_base
    t_base=$(basename "$t_target")
    if [[ -L "$t_dir/$t_base" ]]; then
        print_test_result "ln -t creates link in target dir" "PASS"
    else
        print_test_result "ln -t creates link in target dir" "FAIL" \
            "Expected symlink $t_dir/$t_base"
    fi

    # -t with multiple sources
    local t_target2=$(create_temp_file "t target 2")
    local t_dir2=$(create_temp_dir)

    test_command_exit_code "ln -st dir src1 src2" 0 \
        "$binary" -st "$t_dir2" "$t_target" "$t_target2"

    local t_base2
    t_base2=$(basename "$t_target2")
    if [[ -L "$t_dir2/$t_base" && -L "$t_dir2/$t_base2" ]]; then
        print_test_result "ln -t multiple sources" "PASS"
    else
        print_test_result "ln -t multiple sources" "FAIL" \
            "Expected both symlinks in $t_dir2"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -T (treat LINK_NAME as normal file)
    # ================================================================
    echo -e "${CYAN}Testing ln -T no-target-directory...${NC}"

    local T_target=$(create_temp_file "T target content")
    local T_dir=$(create_temp_dir)

    # With -T, even if link_name is an existing directory, treat it
    # as a plain name (should fail because you can't replace a dir
    # with a symlink without -f)
    local T_out=""
    local T_err=""
    local T_exit=""
    run_command T_cmd T_out T_err T_exit \
        "$binary" -sT "$T_target" "$T_dir"

    # Should fail: cannot create symlink over existing directory
    if [[ $T_exit -ne 0 ]]; then
        print_test_result "ln -sT refuses to replace directory" "PASS"
    else
        print_test_result "ln -sT refuses to replace directory" "FAIL" \
            "Expected failure, got exit 0"
    fi

    # -T with a non-directory name should work normally
    local T_link="$TEMP_DIR/T_plain_link"
    test_command_exit_code "ln -sT with plain name" 0 \
        "$binary" -sT "$T_target" "$T_link"

    if [[ -L "$T_link" ]]; then
        print_test_result "ln -sT creates symlink" "PASS"
    else
        print_test_result "ln -sT creates symlink" "FAIL" \
            "Symlink not created at $T_link"
    fi
}
