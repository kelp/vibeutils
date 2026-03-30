#!/usr/bin/env bash
# Comprehensive tests for rmdir utility
# Tests empty directory removal, parents flag, verbose, ignore-fail-on-non-empty,
# multiple directories, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_rmdir() {
    local util="rmdir"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Remove a single empty directory
    local empty_dir=$(create_temp_dir)
    test_command_exit_code "rmdir empty directory" 0 "$binary" "$empty_dir"
    if [[ ! -d "$empty_dir" ]]; then
        print_test_result "rmdir empty directory verification" "PASS"
    else
        print_test_result "rmdir empty directory verification" "FAIL" "Directory still exists after removal"
    fi

    echo -e "${CYAN}Testing core functionality...${NC}"

    # Fail on non-empty directory
    local nonempty_dir=$(create_temp_dir)
    create_temp_file "content" "$nonempty_dir/file.txt"
    test_command_exit_code "rmdir non-empty directory fails" 1 "$binary" "$nonempty_dir"
    if [[ -d "$nonempty_dir" ]]; then
        print_test_result "rmdir non-empty directory preserved" "PASS"
    else
        print_test_result "rmdir non-empty directory preserved" "FAIL" "Non-empty directory was removed"
    fi
    rm -rf "$nonempty_dir"

    # Error message for non-empty directory
    local nonempty_err_dir=$(create_temp_dir)
    create_temp_file "content" "$nonempty_err_dir/file.txt"
    local ne_out=""
    local ne_err=""
    local ne_exit=""
    run_command ne_cmd ne_out ne_err ne_exit "$binary" "$nonempty_err_dir"
    if [[ "$ne_err" =~ "not empty" || "$ne_err" =~ "Not empty" || "$ne_err" =~ "Directory not empty" ]]; then
        print_test_result "rmdir non-empty error message" "PASS"
    else
        print_test_result "rmdir non-empty error message" "FAIL" "Expected 'not empty' error, got: $ne_err"
    fi
    rm -rf "$nonempty_err_dir"

    # Missing operand (no arguments)
    test_command_exit_code "rmdir no arguments" 2 "$binary"

    # Error message for missing operand
    local miss_out=""
    local miss_err=""
    local miss_exit=""
    run_command miss_cmd miss_out miss_err miss_exit "$binary"
    if [[ "$miss_err" =~ "missing operand" ]]; then
        print_test_result "rmdir missing operand error message" "PASS"
    else
        print_test_result "rmdir missing operand error message" "FAIL" "Expected 'missing operand', got: $miss_err"
    fi

    echo -e "${CYAN}Testing parents flag (-p, --parents)...${NC}"

    # Remove directory and its empty parents with -p
    # Note: -p with absolute paths returns exit 1 because it eventually
    # tries to remove a non-empty ancestor (like $TEMP_DIR). This
    # matches GNU rmdir behavior. We verify the target chain was removed.
    local parent_base="$TEMP_DIR/rmdir_parent_test"
    mkdir -p "$parent_base/a/b/c"
    "$binary" -p "$parent_base/a/b/c" >/dev/null 2>&1
    if [[ ! -d "$parent_base/a" ]]; then
        print_test_result "rmdir -p removes parent chain" "PASS"
    else
        print_test_result "rmdir -p removes parent chain" "FAIL" "Parent directories still exist"
    fi
    rm -rf "$parent_base"

    # --parents long option
    local parent_long_base="$TEMP_DIR/rmdir_parent_long"
    mkdir -p "$parent_long_base/x/y/z"
    "$binary" --parents "$parent_long_base/x/y/z" >/dev/null 2>&1
    if [[ ! -d "$parent_long_base/x" ]]; then
        print_test_result "rmdir --parents removes parent chain" "PASS"
    else
        print_test_result "rmdir --parents removes parent chain" "FAIL" "Parent directories still exist"
    fi
    rm -rf "$parent_long_base"

    # -p stops when parent is non-empty
    local parent_stop_base="$TEMP_DIR/rmdir_parent_stop"
    mkdir -p "$parent_stop_base/a/b/c"
    create_temp_file "blocker" "$parent_stop_base/a/blocker.txt"
    test_command_exit_code "rmdir -p stops on non-empty parent" 1 "$binary" -p "$parent_stop_base/a/b/c"
    # c and b should be removed, but a should remain (has blocker.txt)
    if [[ ! -d "$parent_stop_base/a/b" && -d "$parent_stop_base/a" ]]; then
        print_test_result "rmdir -p stops at non-empty parent" "PASS"
    else
        print_test_result "rmdir -p stops at non-empty parent" "FAIL" "Expected a/ to remain, a/b/ to be removed"
    fi
    rm -rf "$parent_stop_base"

    echo -e "${CYAN}Testing --ignore-fail-on-non-empty...${NC}"

    # Non-empty directory with --ignore-fail-on-non-empty succeeds
    local ignore_dir=$(create_temp_dir)
    create_temp_file "content" "$ignore_dir/file.txt"
    test_command_exit_code "rmdir --ignore-fail-on-non-empty succeeds" 0 "$binary" --ignore-fail-on-non-empty "$ignore_dir"
    if [[ -d "$ignore_dir" ]]; then
        print_test_result "rmdir --ignore-fail-on-non-empty preserves dir" "PASS"
    else
        print_test_result "rmdir --ignore-fail-on-non-empty preserves dir" "FAIL" "Directory should not be removed"
    fi
    rm -rf "$ignore_dir"

    # --ignore-fail-on-non-empty suppresses error output
    local ignore_err_dir=$(create_temp_dir)
    create_temp_file "content" "$ignore_err_dir/file.txt"
    local ign_out=""
    local ign_err=""
    local ign_exit=""
    run_command ign_cmd ign_out ign_err ign_exit "$binary" --ignore-fail-on-non-empty "$ignore_err_dir"
    if [[ $ign_exit -eq 0 && -z "$ign_err" ]]; then
        print_test_result "rmdir --ignore-fail-on-non-empty no error output" "PASS"
    else
        print_test_result "rmdir --ignore-fail-on-non-empty no error output" "FAIL" "Expected no stderr, got: $ign_err (exit: $ign_exit)"
    fi
    rm -rf "$ignore_err_dir"

    # Empty directory removed even with --ignore-fail-on-non-empty
    local ignore_empty=$(create_temp_dir)
    test_command_exit_code "rmdir --ignore-fail-on-non-empty removes empty" 0 "$binary" --ignore-fail-on-non-empty "$ignore_empty"
    if [[ ! -d "$ignore_empty" ]]; then
        print_test_result "rmdir --ignore-fail-on-non-empty empty dir removed" "PASS"
    else
        print_test_result "rmdir --ignore-fail-on-non-empty empty dir removed" "FAIL" "Empty directory should be removed"
    fi

    # -p combined with --ignore-fail-on-non-empty
    local ign_parent_base="$TEMP_DIR/rmdir_ign_parent"
    mkdir -p "$ign_parent_base/a/b/c"
    create_temp_file "blocker" "$ign_parent_base/a/blocker.txt"
    "$binary" -p --ignore-fail-on-non-empty "$ign_parent_base/a/b/c" >/dev/null 2>&1
    # c and b should be removed, a remains (has blocker.txt)
    if [[ ! -d "$ign_parent_base/a/b" && -d "$ign_parent_base/a" ]]; then
        print_test_result "rmdir -p --ignore-fail-on-non-empty stops gracefully" "PASS"
    else
        print_test_result "rmdir -p --ignore-fail-on-non-empty stops gracefully" "FAIL" "Expected a/ to remain, a/b/ removed"
    fi
    rm -rf "$ign_parent_base"

    echo -e "${CYAN}Testing verbose flag (-v, --verbose)...${NC}"

    # Verbose output for directory removal
    local verbose_dir=$(create_temp_dir)
    local verb_out=""
    local verb_err=""
    local verb_exit=""
    run_command verb_cmd verb_out verb_err verb_exit "$binary" -v "$verbose_dir"
    if [[ $verb_exit -eq 0 && "$verb_out" =~ "removing directory" ]]; then
        print_test_result "rmdir -v verbose output" "PASS"
    else
        print_test_result "rmdir -v verbose output" "FAIL" "Expected 'removing directory' in output, got: $verb_out"
    fi

    # --verbose long option
    local verbose_long_dir=$(create_temp_dir)
    local verb_long_out=""
    local verb_long_err=""
    local verb_long_exit=""
    run_command verb_long_cmd verb_long_out verb_long_err verb_long_exit "$binary" --verbose "$verbose_long_dir"
    if [[ $verb_long_exit -eq 0 && "$verb_long_out" =~ "removing directory" ]]; then
        print_test_result "rmdir --verbose output" "PASS"
    else
        print_test_result "rmdir --verbose output" "FAIL" "Expected 'removing directory' in output, got: $verb_long_out"
    fi

    # Verbose with -p shows each directory removed
    local verb_parent_base="$TEMP_DIR/rmdir_verb_parent"
    mkdir -p "$verb_parent_base/a/b"
    local vp_out=""
    local vp_err=""
    local vp_exit=""
    run_command vp_cmd vp_out vp_err vp_exit "$binary" -pv "$verb_parent_base/a/b"
    # Exit code may be non-zero due to ancestor removal hitting system dirs
    if [[ "$vp_out" =~ "a/b" && "$vp_out" =~ removing.*directory ]]; then
        print_test_result "rmdir -pv shows each removal" "PASS"
    else
        print_test_result "rmdir -pv shows each removal" "FAIL" "Expected 'a/b' and 'removing directory' in output, got: $vp_out"
    fi
    rm -rf "$verb_parent_base"

    echo -e "${CYAN}Testing multiple directories...${NC}"

    # Remove multiple empty directories
    local multi1=$(create_temp_dir)
    local multi2=$(create_temp_dir)
    local multi3=$(create_temp_dir)
    test_command_exit_code "rmdir multiple empty directories" 0 "$binary" "$multi1" "$multi2" "$multi3"
    if [[ ! -d "$multi1" && ! -d "$multi2" && ! -d "$multi3" ]]; then
        print_test_result "rmdir multiple directories verification" "PASS"
    else
        print_test_result "rmdir multiple directories verification" "FAIL" "Some directories still exist"
    fi

    # Mixed: some empty, some non-empty
    local mix_empty=$(create_temp_dir)
    local mix_nonempty=$(create_temp_dir)
    create_temp_file "content" "$mix_nonempty/file.txt"
    local mix_empty2=$(create_temp_dir)
    local mix_out=""
    local mix_err=""
    local mix_exit=""
    run_command mix_cmd mix_out mix_err mix_exit "$binary" "$mix_empty" "$mix_nonempty" "$mix_empty2"
    # Should fail overall but remove the empty ones
    if [[ $mix_exit -ne 0 && ! -d "$mix_empty" && -d "$mix_nonempty" && ! -d "$mix_empty2" ]]; then
        print_test_result "rmdir mixed empty/non-empty" "PASS"
    else
        print_test_result "rmdir mixed empty/non-empty" "FAIL" "Expected empty dirs removed, non-empty preserved (exit: $mix_exit)"
    fi
    rm -rf "$mix_nonempty"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Non-existent directory
    test_command_exit_code "rmdir nonexistent directory" 1 "$binary" "$TEMP_DIR/nonexistent_rmdir_$$"

    # Error message for nonexistent directory
    local nosuch_out=""
    local nosuch_err=""
    local nosuch_exit=""
    run_command nosuch_cmd nosuch_out nosuch_err nosuch_exit "$binary" "$TEMP_DIR/nonexistent_rmdir_$$"
    if [[ "$nosuch_err" =~ "No such file or directory" ]]; then
        print_test_result "rmdir nonexistent error message" "PASS"
    else
        print_test_result "rmdir nonexistent error message" "FAIL" "Expected 'No such file or directory', got: $nosuch_err"
    fi

    # File instead of directory
    local not_a_dir=$(create_temp_file "this is a file")
    test_command_exit_code "rmdir file instead of directory" 1 "$binary" "$not_a_dir"

    # Error message for file-not-directory
    local notdir_out=""
    local notdir_err=""
    local notdir_exit=""
    run_command notdir_cmd notdir_out notdir_err notdir_exit "$binary" "$not_a_dir"
    if [[ "$notdir_err" =~ "Not a directory" ]]; then
        print_test_result "rmdir file-not-directory error message" "PASS"
    else
        print_test_result "rmdir file-not-directory error message" "FAIL" "Expected 'Not a directory', got: $notdir_err"
    fi
    rm -f "$not_a_dir"

    # Invalid flag
    test_command_exit_code "rmdir invalid flag" 2 "$binary" --invalid-flag 2>/dev/null

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Directory with trailing slash
    local trailing_dir=$(create_temp_dir)
    test_command_exit_code "rmdir trailing slash" 0 "$binary" "${trailing_dir}/"
    if [[ ! -d "$trailing_dir" ]]; then
        print_test_result "rmdir trailing slash verification" "PASS"
    else
        print_test_result "rmdir trailing slash verification" "FAIL" "Directory still exists"
    fi

    # Directory with special characters in name
    local special_dir="$TEMP_DIR/rmdir_special-_@#"
    mkdir -p "$special_dir"
    test_command_exit_code "rmdir special characters" 0 "$binary" "$special_dir"
    if [[ ! -d "$special_dir" ]]; then
        print_test_result "rmdir special characters verification" "PASS"
    else
        print_test_result "rmdir special characters verification" "FAIL" "Directory still exists"
    fi

    # Directory with spaces in name
    local space_dir="$TEMP_DIR/rmdir dir with spaces"
    mkdir -p "$space_dir"
    test_command_exit_code "rmdir spaces in name" 0 "$binary" "$space_dir"
    if [[ ! -d "$space_dir" ]]; then
        print_test_result "rmdir spaces in name verification" "PASS"
    else
        print_test_result "rmdir spaces in name verification" "FAIL" "Directory still exists"
    fi

    # Unicode directory name
    if locale | grep -q "UTF-8"; then
        local unicode_dir="$TEMP_DIR/rmdir_test_unicode"
        mkdir -p "$unicode_dir"
        test_command_exit_code "rmdir Unicode name" 0 "$binary" "$unicode_dir"
        if [[ ! -d "$unicode_dir" ]]; then
            print_test_result "rmdir Unicode name verification" "PASS"
        else
            print_test_result "rmdir Unicode name verification" "FAIL" "Directory still exists"
        fi
    fi

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # -pv combined
    local pv_base="$TEMP_DIR/rmdir_pv_combo"
    mkdir -p "$pv_base/x/y"
    local pv_out=""
    local pv_err=""
    local pv_exit=""
    run_command pv_cmd pv_out pv_err pv_exit "$binary" -pv "$pv_base/x/y"
    # Verify directories were removed and verbose output generated
    if [[ "$pv_out" =~ "removing directory" && ! -d "$pv_base/x/y" ]]; then
        print_test_result "rmdir -pv combination" "PASS"
    else
        print_test_result "rmdir -pv combination" "FAIL" "Expected verbose output and dirs removed (out: $pv_out)"
    fi
    rm -rf "$pv_base"

    # -v with --ignore-fail-on-non-empty on non-empty dir
    local vi_dir=$(create_temp_dir)
    create_temp_file "content" "$vi_dir/file.txt"
    local vi_out=""
    local vi_err=""
    local vi_exit=""
    run_command vi_cmd vi_out vi_err vi_exit "$binary" -v --ignore-fail-on-non-empty "$vi_dir"
    if [[ $vi_exit -eq 0 ]]; then
        print_test_result "rmdir -v --ignore-fail-on-non-empty" "PASS"
    else
        print_test_result "rmdir -v --ignore-fail-on-non-empty" "FAIL" "Expected exit 0, got: $vi_exit"
    fi
    rm -rf "$vi_dir"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX: exit 0 on success
    local posix_dir=$(create_temp_dir)
    test_command_exit_code "rmdir POSIX success exit code" 0 "$binary" "$posix_dir"

    # POSIX: exit >0 on failure
    test_command_exit_code "rmdir POSIX failure exit code" 1 "$binary" "$TEMP_DIR/posix_nonexistent_$$"

    # Regression test: rmdir refuses to remove . and ..
    echo -e "${CYAN}Testing rmdir refuses . and .. removal...${NC}"

    local dot_out=""
    local dot_err=""
    local dot_exit=""
    run_command dot_cmd dot_out dot_err dot_exit "$binary" .
    if [[ $dot_exit -ne 0 && "$dot_err" =~ "refusing" ]]; then
        print_test_result "rmdir . refused with message" "PASS"
    else
        print_test_result "rmdir . refused with message" "FAIL" \
            "Expected non-zero exit and 'refusing' in stderr, got exit=$dot_exit stderr='$dot_err'"
    fi

    local dotdot_out=""
    local dotdot_err=""
    local dotdot_exit=""
    run_command dotdot_cmd dotdot_out dotdot_err dotdot_exit "$binary" ..
    if [[ $dotdot_exit -ne 0 && "$dotdot_err" =~ "refusing" ]]; then
        print_test_result "rmdir .. refused with message" "PASS"
    else
        print_test_result "rmdir .. refused with message" "FAIL" \
            "Expected non-zero exit and 'refusing' in stderr, got exit=$dotdot_exit stderr='$dotdot_err'"
    fi

    echo -e "${CYAN}Testing IMPORTANT audit findings...${NC}"

    # AUDIT: -v --ignore-fail-on-non-empty should still print verbose output
    # GNU rmdir -v --ignore-fail-on-non-empty prints the "removing directory"
    # message even when the directory cannot be removed because it is non-empty.
    # Our implementation suppresses verbose output because it returns early
    # before the verbose print when ignore_fail_on_non_empty is true.
    local audit_vi_dir=$(create_temp_dir)
    create_temp_file "content" "$audit_vi_dir/file.txt"
    local audit_vi_out=""
    local audit_vi_err=""
    local audit_vi_exit=""
    run_command audit_vi_cmd audit_vi_out audit_vi_err audit_vi_exit \
        "$binary" -v --ignore-fail-on-non-empty "$audit_vi_dir"
    if [[ $audit_vi_exit -eq 0 && "$audit_vi_out" =~ "removing directory" ]]; then
        print_test_result "rmdir -v --ignore-fail-on-non-empty still prints verbose (audit)" "PASS"
    else
        print_test_result "rmdir -v --ignore-fail-on-non-empty still prints verbose (audit)" "FAIL" \
            "Expected 'removing directory' in stdout, got: '$audit_vi_out' (exit: $audit_vi_exit)"
    fi
    rm -rf "$audit_vi_dir"
}
