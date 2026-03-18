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
    test_command_exit_code "ln no arguments" 2 "$binary"

    # Invalid flag
    test_command_exit_code "ln invalid flag" 2 \
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

    # Verify the backup file exists
    if [[ -e "${backup_link}~" ]]; then
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
}
