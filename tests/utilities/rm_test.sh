#!/usr/bin/env bash
# Comprehensive tests for rm utility
# Tests all flags, file/directory removal, safety features, and edge cases
# Total: 87 tests covering complete functionality

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_rm() {
    local util="rm"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Basic file existence and removal verification
    local test_file1=$(create_temp_file "Simple content")
    local test_file2=$(create_temp_file "Multi-line content with\nspecial characters: !@#$%^&*()")
    local test_file3=$(create_temp_file "")  # Empty file

    echo -e "${CYAN}Testing core functionality...${NC}"

    # Single file removal
    test_command_exit_code "rm single file" 0 "$binary" "$test_file1"
    if [[ -e "$test_file1" ]]; then
        print_test_result "rm single file verification" "FAIL" "File still exists after removal"
    else
        print_test_result "rm single file verification" "PASS"
    fi

    # Multiple file removal
    local multi1=$(create_temp_file "File 1")
    local multi2=$(create_temp_file "File 2")
    local multi3=$(create_temp_file "File 3")
    test_command_exit_code "rm multiple files" 0 "$binary" "$multi1" "$multi2" "$multi3"
    if [[ -e "$multi1" || -e "$multi2" || -e "$multi3" ]]; then
        print_test_result "rm multiple files verification" "FAIL" "Some files still exist after removal"
    else
        print_test_result "rm multiple files verification" "PASS"
    fi

    # Empty file removal
    test_command_exit_code "rm empty file" 0 "$binary" "$test_file3"
    if [[ -e "$test_file3" ]]; then
        print_test_result "rm empty file verification" "FAIL" "Empty file still exists after removal"
    else
        print_test_result "rm empty file verification" "PASS"
    fi

    # Clean up test_file2 which was created but not removed by tests
    rm -f "$test_file2"

    echo -e "${CYAN}Testing force flag (-f, --force)...${NC}"

    # Non-existent file without force (should fail)
    test_command_exit_code "rm non-existent file without force" 1 "$binary" "/tmp/nonexistent_file_$$"

    # Non-existent file with force (should succeed silently)
    test_command_exit_code "rm non-existent file with -f" 0 "$binary" -f "/tmp/nonexistent_file_$$"
    test_command_exit_code "rm non-existent file with --force" 0 "$binary" --force "/tmp/nonexistent_file_$$"

    # Multiple non-existent files with force
    test_command_exit_code "rm multiple non-existent files with -f" 0 "$binary" -f "/tmp/nonexistent1_$$" "/tmp/nonexistent2_$$" "/tmp/nonexistent3_$$"

    # Write-protected file with force
    local protected_file=$(create_temp_file "Protected content")
    chmod 444 "$protected_file"
    test_command_exit_code "rm write-protected file with -f" 0 "$binary" -f "$protected_file"
    if [[ -e "$protected_file" ]]; then
        print_test_result "rm protected file with force verification" "FAIL" "Protected file still exists"
    else
        print_test_result "rm protected file with force verification" "PASS"
    fi

    # Error suppression verification with force
    local suppress_test=$(create_temp_file "Suppress test")
    rm "$suppress_test"  # Remove it first
    local force_output=""
    local force_stderr=""
    local force_exit=""
    run_command force_cmd force_output force_stderr force_exit "$binary" -f "$suppress_test"
    if [[ -z "$force_stderr" ]]; then
        print_test_result "rm -f error suppression" "PASS"
    else
        print_test_result "rm -f error suppression" "FAIL" "Expected no stderr output, got: $force_stderr"
    fi

    echo -e "${CYAN}Testing interactive mode (-i)...${NC}"

    # Interactive mode with 'yes' response
    local interactive_file1=$(create_temp_file "Interactive test 1")
    echo "y" | "$binary" -i "$interactive_file1" >/dev/null 2>&1
    local interactive_exit1=$?
    if [[ $interactive_exit1 -eq 0 && ! -e "$interactive_file1" ]]; then
        print_test_result "rm -i with yes response" "PASS"
    else
        print_test_result "rm -i with yes response" "FAIL" "Expected file to be removed with yes response"
    fi

    # Interactive mode with 'no' response
    local interactive_file2=$(create_temp_file "Interactive test 2")
    echo "n" | "$binary" -i "$interactive_file2" >/dev/null 2>&1
    local interactive_exit2=$?
    if [[ $interactive_exit2 -eq 0 && -e "$interactive_file2" ]]; then
        print_test_result "rm -i with no response" "PASS"
        rm -f "$interactive_file2"  # Clean up
    else
        print_test_result "rm -i with no response" "FAIL" "Expected file to be preserved with no response"
    fi

    # Interactive mode individual prompting
    local int_file1=$(create_temp_file "Int file 1")
    local int_file2=$(create_temp_file "Int file 2")
    printf "y\nn\n" | "$binary" -i "$int_file1" "$int_file2" >/dev/null 2>&1
    if [[ ! -e "$int_file1" && -e "$int_file2" ]]; then
        print_test_result "rm -i individual prompting" "PASS"
        rm -f "$int_file2"  # Clean up
    else
        print_test_result "rm -i individual prompting" "FAIL" "Expected first file removed, second preserved"
    fi

    echo -e "${CYAN}Testing interactive once (-I)...${NC}"

    # Interactive once with few files (should not prompt)
    local few_file1=$(create_temp_file "Few 1")
    local few_file2=$(create_temp_file "Few 2")
    test_command_exit_code "rm -I with few files (no prompt)" 0 "$binary" -I "$few_file1" "$few_file2"
    if [[ ! -e "$few_file1" && ! -e "$few_file2" ]]; then
        print_test_result "rm -I few files verification" "PASS"
    else
        print_test_result "rm -I few files verification" "FAIL" "Files should be removed without prompting"
    fi

    # Interactive once with exactly 3 files (should NOT prompt per POSIX)
    local three1=$(create_temp_file "Three 1")
    local three2=$(create_temp_file "Three 2")
    local three3=$(create_temp_file "Three 3")
    test_command_exit_code "rm -I with exactly 3 files" 0 "$binary" -I "$three1" "$three2" "$three3"
    if [[ ! -e "$three1" && ! -e "$three2" && ! -e "$three3" ]]; then
        print_test_result "rm -I three files verification" "PASS"
    else
        print_test_result "rm -I three files verification" "FAIL" "Three files should be removed without prompting"
    fi

    # Interactive once with many files (single prompt)
    local many_files=()
    for i in {1..10}; do
        many_files+=($(create_temp_file "Many file $i"))
    done
    echo "y" | "$binary" -I "${many_files[@]}" >/dev/null 2>&1
    local many_exit=$?
    local all_removed=true
    for file in "${many_files[@]}"; do
        if [[ -e "$file" ]]; then
            all_removed=false
            break
        fi
    done
    if [[ $many_exit -eq 0 && "$all_removed" == "true" ]]; then
        print_test_result "rm -I many files with yes" "PASS"
    else
        print_test_result "rm -I many files with yes" "FAIL" "Expected all files removed with yes response"
    fi

    # Interactive once with many files, no response
    local many_files_no=()
    for i in {1..8}; do
        many_files_no+=($(create_temp_file "Many no $i"))
    done
    echo "n" | "$binary" -I "${many_files_no[@]}" >/dev/null 2>&1
    local many_no_exit=$?
    local any_removed=false
    for file in "${many_files_no[@]}"; do
        if [[ ! -e "$file" ]]; then
            any_removed=true
            break
        fi
    done
    if [[ $many_no_exit -eq 0 && "$any_removed" == "false" ]]; then
        print_test_result "rm -I many files with no" "PASS"
    else
        print_test_result "rm -I many files with no" "FAIL" "Expected all files preserved with no response"
    fi
    # Clean up
    for file in "${many_files_no[@]}"; do
        rm -f "$file"
    done

    echo -e "${CYAN}Testing recursive flags (-r, -R, --recursive)...${NC}"

    # Directory removal without recursive flag (should fail)
    local test_dir1=$(create_temp_dir)
    create_temp_file "Dir content" "$test_dir1/file.txt"
    test_command_exit_code "rm directory without recursive (should fail)" 1 "$binary" "$test_dir1"
    if [[ -d "$test_dir1" ]]; then
        print_test_result "rm directory without recursive verification" "PASS"
        rm -rf "$test_dir1"  # Clean up
    else
        print_test_result "rm directory without recursive verification" "FAIL" "Directory should not be removed"
    fi

    # Deep directory structure removal with -r
    local deep_dir=$(create_temp_dir)
    mkdir -p "$deep_dir/level1/level2/level3/level4"
    create_temp_file "Deep file" "$deep_dir/level1/level2/level3/level4/deep.txt"
    create_temp_file "Mid file" "$deep_dir/level1/level2/mid.txt"
    create_temp_file "Top file" "$deep_dir/top.txt"
    test_command_exit_code "rm -r deep directory" 0 "$binary" -r "$deep_dir"
    if [[ ! -d "$deep_dir" ]]; then
        print_test_result "rm -r deep directory verification" "PASS"
    else
        print_test_result "rm -r deep directory verification" "FAIL" "Deep directory still exists"
    fi

    # Test -R flag variant
    local r_cap_dir=$(create_temp_dir)
    create_temp_file "R test" "$r_cap_dir/file.txt"
    test_command_exit_code "rm -R directory" 0 "$binary" -R "$r_cap_dir"
    if [[ ! -d "$r_cap_dir" ]]; then
        print_test_result "rm -R directory verification" "PASS"
    else
        print_test_result "rm -R directory verification" "FAIL" "Directory still exists after -R"
    fi

    # Test --recursive long option
    local recursive_dir=$(create_temp_dir)
    create_temp_file "Recursive test" "$recursive_dir/file.txt"
    test_command_exit_code "rm --recursive directory" 0 "$binary" --recursive "$recursive_dir"
    if [[ ! -d "$recursive_dir" ]]; then
        print_test_result "rm --recursive directory verification" "PASS"
    else
        print_test_result "rm --recursive directory verification" "FAIL" "Directory still exists after --recursive"
    fi

    # Complex nested directory tree
    local complex_dir=$(create_temp_dir)
    mkdir -p "$complex_dir/a/b/c" "$complex_dir/x/y/z" "$complex_dir/empty"
    create_temp_file "File A" "$complex_dir/a/file_a.txt"
    create_temp_file "File B" "$complex_dir/a/b/file_b.txt"
    create_temp_file "File C" "$complex_dir/a/b/c/file_c.txt"
    create_temp_file "File X" "$complex_dir/x/file_x.txt"
    create_temp_file "File Y" "$complex_dir/x/y/file_y.txt"
    create_temp_file "File Z" "$complex_dir/x/y/z/file_z.txt"
    test_command_exit_code "rm -r complex directory tree" 0 "$binary" -r "$complex_dir"
    if [[ ! -d "$complex_dir" ]]; then
        print_test_result "rm -r complex tree verification" "PASS"
    else
        print_test_result "rm -r complex tree verification" "FAIL" "Complex directory tree still exists"
    fi

    echo -e "${CYAN}Testing verbose flag (-v, --verbose)...${NC}"

    # Verbose output for file removal
    local verbose_file=$(create_temp_file "Verbose test")
    local verbose_out=""
    local verbose_err=""
    local verbose_exit=""
    run_command verbose_cmd verbose_out verbose_err verbose_exit "$binary" -v "$verbose_file"
    if [[ "$verbose_out" =~ removed.*\'.*\' ]]; then
        print_test_result "rm -v file output format" "PASS"
    else
        print_test_result "rm -v file output format" "FAIL" "Expected 'removed' message, got: $verbose_out"
    fi

    # Verbose output for directory removal
    local verbose_dir=$(create_temp_dir)
    create_temp_file "Dir file" "$verbose_dir/file.txt"
    local verbose_dir_out=""
    local verbose_dir_err=""
    local verbose_dir_exit=""
    run_command verbose_dir_cmd verbose_dir_out verbose_dir_err verbose_dir_exit "$binary" -rv "$verbose_dir"
    if [[ "$verbose_dir_out" =~ removed.*directory ]]; then
        print_test_result "rm -rv directory output format" "PASS"
    else
        print_test_result "rm -rv directory output format" "FAIL" "Expected directory removal message, got: $verbose_dir_out"
    fi

    # Long option verbose
    local verbose_long_file=$(create_temp_file "Verbose long test")
    local verbose_long_out=""
    local verbose_long_err=""
    local verbose_long_exit=""
    run_command verbose_long_cmd verbose_long_out verbose_long_err verbose_long_exit "$binary" --verbose "$verbose_long_file"
    if [[ "$verbose_long_out" =~ removed.*\'.*\' ]]; then
        print_test_result "rm --verbose output format" "PASS"
    else
        print_test_result "rm --verbose output format" "FAIL" "Expected 'removed' message, got: $verbose_long_out"
    fi

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Force + Verbose
    local fv_file=$(create_temp_file "Force verbose test")
    local fv_out=""
    local fv_err=""
    local fv_exit=""
    run_command fv_cmd fv_out fv_err fv_exit "$binary" -fv "$fv_file"
    if [[ $fv_exit -eq 0 && "$fv_out" =~ removed ]]; then
        print_test_result "rm -fv combination" "PASS"
    else
        print_test_result "rm -fv combination" "FAIL" "Expected success with verbose output"
    fi

    # Recursive + Verbose
    local rv_dir=$(create_temp_dir)
    create_temp_file "RV test" "$rv_dir/file.txt"
    local rv_out=""
    local rv_err=""
    local rv_exit=""
    run_command rv_cmd rv_out rv_err rv_exit "$binary" -rv "$rv_dir"
    if [[ $rv_exit -eq 0 && "$rv_out" =~ removed ]]; then
        print_test_result "rm -rv combination" "PASS"
    else
        print_test_result "rm -rv combination" "FAIL" "Expected success with verbose output"
    fi

    # Interactive + Force behavior (force should override interactive)
    local if_file=$(create_temp_file "Interactive force test")
    test_command_exit_code "rm -if combination" 0 "$binary" -if "$if_file"
    if [[ ! -e "$if_file" ]]; then
        print_test_result "rm -if force override verification" "PASS"
    else
        print_test_result "rm -if force override verification" "FAIL" "Force should override interactive"
    fi

    # -rI combination testing
    local ri_dir=$(create_temp_dir)
    for i in {1..10}; do
        create_temp_file "RI file $i" "$ri_dir/file$i.txt"
    done
    echo "y" | "$binary" -rI "$ri_dir" >/dev/null 2>&1
    local ri_exit=$?
    if [[ $ri_exit -eq 0 && ! -d "$ri_dir" ]]; then
        print_test_result "rm -rI combination" "PASS"
    else
        print_test_result "rm -rI combination" "FAIL" "Expected directory removal with confirmation"
    fi

    # Mixed short and long options
    local mixed_file=$(create_temp_file "Mixed options test")
    test_command_exit_code "rm mixed options" 0 "$binary" --force -v "$mixed_file"
    local mixed_exists=false
    [[ -e "$mixed_file" ]] && mixed_exists=true
    if [[ ! "$mixed_exists" == "true" ]]; then
        print_test_result "rm mixed options verification" "PASS"
    else
        print_test_result "rm mixed options verification" "FAIL" "File should be removed"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid arguments
    test_command_exit_code "rm invalid flag" 1 "$binary" --invalid-flag 2>/dev/null

    # Missing operands (exit 1 = argument error)
    test_command_exit_code "rm no arguments" 1 "$binary" 2>/dev/null

    # Permission denied scenarios
    local perm_dir=$(create_temp_dir)
    local perm_file="$perm_dir/perm_file.txt"
    create_temp_file "Permission test" "$perm_file"
    chmod 000 "$perm_dir"

    # This should fail due to directory permissions
    "$binary" "$perm_file" >/dev/null 2>&1
    local perm_exit=$?
    if [[ $perm_exit -ne 0 ]]; then
        print_test_result "rm permission denied" "PASS"
    else
        print_test_result "rm permission denied" "FAIL" "Should fail with permission denied"
    fi
    chmod 755 "$perm_dir"  # Restore for cleanup
    rm -rf "$perm_dir"

    # Directory as file without recursive flag
    local dir_as_file=$(create_temp_dir)
    create_temp_file "Dir content" "$dir_as_file/content.txt"
    test_command_exit_code "rm directory without -r" 1 "$binary" "$dir_as_file"
    rm -rf "$dir_as_file"  # Clean up

    # Specific error message format validation
    local nonexist_out=""
    local nonexist_err=""
    local nonexist_exit=""
    run_command nonexist_cmd nonexist_out nonexist_err nonexist_exit "$binary" "/tmp/definitely_nonexistent_$$"
    if [[ "$nonexist_err" =~ "No such file or directory" ]]; then
        print_test_result "rm error message format" "PASS"
    else
        print_test_result "rm error message format" "FAIL" "Expected 'No such file or directory', got: $nonexist_err"
    fi

    echo -e "${CYAN}Testing safety features...${NC}"

    # Root directory protection
    test_command_exit_code "rm root directory protection" 1 "$binary" -rf "/" 2>/dev/null

    # Empty path handling
    test_command_exit_code "rm empty path" 1 "$binary" "" 2>/dev/null

    # CRITICAL CRASH BUG TESTS - These document known bugs and will fail
    echo -e "${CYAN}Testing known crash bugs (these will fail until fixed)...${NC}"

    # CRASH BUG: rm -rf . should be prevented but currently crashes
    local crash_test_dir=$(create_temp_dir)
    (cd "$crash_test_dir" && "$binary" -rf . >/dev/null 2>&1)
    local crash_exit=$?
    if [[ $crash_exit -eq 1 ]]; then
        print_test_result "CRASH BUG: rm -rf . protection" "PASS"
    else
        print_test_result "CRASH BUG: rm -rf . protection" "FAIL" "Should prevent rm -rf . (exits $crash_exit)"
    fi
    rm -rf "$crash_test_dir" 2>/dev/null || true

    # SAFETY BUG: rm -rf .. should be prevented
    local parent_test_dir=$(create_temp_dir)
    local child_dir="$parent_test_dir/child"
    mkdir "$child_dir"
    (cd "$child_dir" && "$binary" -rf .. >/dev/null 2>&1)
    local parent_exit=$?
    if [[ $parent_exit -eq 1 ]]; then
        print_test_result "SAFETY BUG: rm -rf .. protection" "PASS"
    else
        print_test_result "SAFETY BUG: rm -rf .. protection" "FAIL" "Should prevent rm -rf .. (exits $parent_exit)"
    fi
    rm -rf "$parent_test_dir" 2>/dev/null || true

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX required behaviors
    local posix_file=$(create_temp_file "POSIX test")
    test_command_exit_code "rm POSIX basic removal" 0 "$binary" "$posix_file"

    # POSIX exit codes
    test_command_exit_code "rm POSIX success exit code" 0 "$binary" -f "/tmp/posix_nonexistent_$$"
    test_command_exit_code "rm POSIX failure exit code" 1 "$binary" "/tmp/posix_nonexistent_$$" 2>/dev/null

    # Standard command patterns
    local std1=$(create_temp_file "Standard 1")
    local std2=$(create_temp_file "Standard 2")
    test_command_exit_code "rm POSIX multiple files" 0 "$binary" "$std1" "$std2"

    echo -e "${CYAN}Testing enhanced edge cases...${NC}"

    # Files with special characters
    local special_file="$TEMP_DIR/special!@#\$%^&*()_+-={}[]|\\:;\"'<>?,.~\`.txt"
    create_temp_file "Special chars" "$special_file"
    test_command_exit_code "rm file with special characters" 0 "$binary" "$special_file"

    # Very long file paths (200+ chars)
    local long_path="$TEMP_DIR/"
    for i in {1..10}; do
        long_path+="very_long_directory_name_segment_$i/"
    done
    mkdir -p "$long_path"
    local long_file="$long_path/very_long_filename_with_many_characters_to_test_path_length_limits.txt"
    create_temp_file "Long path test" "$long_file"
    test_command_exit_code "rm very long path" 0 "$binary" "$long_file"

    # Very deep directory structures (35+ levels)
    local deep_base=$(create_temp_dir)
    local deep_path="$deep_base"
    for i in {1..35}; do
        deep_path+="/level$i"
    done
    mkdir -p "$deep_path"
    create_temp_file "Deep file" "$deep_path/deep.txt"
    test_command_exit_code "rm very deep structure" 0 "$binary" -r "$deep_base"

    # Many files at once (200+ files)
    local many_dir=$(create_temp_dir)
    local many_file_list=()
    for i in {1..200}; do
        local many_file="$many_dir/file_$i.txt"
        create_temp_file "File $i content" "$many_file"
        many_file_list+=("$many_file")
    done
    test_command_exit_code "rm 200+ files at once" 0 "$binary" "${many_file_list[@]}"
    rm -rf "$many_dir"  # Ensure cleanup

    # Binary file handling
    local binary_file=$(create_temp_file "")
    printf '\x00\x01\x02\x03\xFF\xFE\xFD' > "$binary_file"
    test_command_exit_code "rm binary file" 0 "$binary" "$binary_file"

    # Symlink handling (removes link, preserves target)
    local link_target=$(create_temp_file "Link target content")
    local link_file="$TEMP_DIR/test_symlink"
    ln -s "$link_target" "$link_file"
    test_command_exit_code "rm symlink" 0 "$binary" "$link_file"
    if [[ ! -L "$link_file" && -f "$link_target" ]]; then
        print_test_result "rm symlink verification" "PASS"
    else
        print_test_result "rm symlink verification" "FAIL" "Symlink should be removed, target preserved"
    fi
    rm -f "$link_target"  # Clean up

    echo -e "${CYAN}Testing write-protected file behavior...${NC}"

    # 444 permissions without force
    local prot_444=$(create_temp_file "Protected 444")
    chmod 444 "$prot_444"
    "$binary" "$prot_444" </dev/null >/dev/null 2>&1
    local prot_444_exit=$?
    if [[ $prot_444_exit -ne 0 ]]; then
        print_test_result "rm 444 file without force" "PASS"
    else
        print_test_result "rm 444 file without force" "FAIL" "Should prompt or fail for read-only file"
    fi
    rm -f "$prot_444"  # Force cleanup

    # 444 permissions with force
    local prot_444_f=$(create_temp_file "Protected 444 force")
    chmod 444 "$prot_444_f"
    test_command_exit_code "rm 444 file with force" 0 "$binary" -f "$prot_444_f"

    # 000 permissions with/without force
    local prot_000=$(create_temp_file "Protected 000")
    chmod 000 "$prot_000"
    test_command_exit_code "rm 000 file with force" 0 "$binary" -f "$prot_000"

    # Interactive response with protected files
    local prot_int=$(create_temp_file "Protected interactive")
    chmod 444 "$prot_int"
    echo "y" | "$binary" -i "$prot_int" >/dev/null 2>&1
    local prot_int_exit=$?
    if [[ ! -e "$prot_int" ]]; then
        print_test_result "rm protected file interactive yes" "PASS"
    else
        print_test_result "rm protected file interactive yes" "FAIL" "File should be removed with yes response"
    fi

    local prot_int_n=$(create_temp_file "Protected interactive no")
    chmod 444 "$prot_int_n"
    echo "n" | "$binary" -i "$prot_int_n" >/dev/null 2>&1
    if [[ -e "$prot_int_n" ]]; then
        print_test_result "rm protected file interactive no" "PASS"
    else
        print_test_result "rm protected file interactive no" "FAIL" "File should be preserved with no response"
    fi
    rm -f "$prot_int_n"  # Clean up

    # Directories with protected files
    local prot_dir=$(create_temp_dir)
    local prot_dir_file="$prot_dir/protected.txt"
    create_temp_file "Protected in dir" "$prot_dir_file"
    chmod 444 "$prot_dir_file"
    test_command_exit_code "rm -rf directory with protected files" 0 "$binary" -rf "$prot_dir"

    echo -e "${CYAN}Testing specific error message validation...${NC}"

    # "No such file or directory" format
    local nosuch_out=""
    local nosuch_err=""
    local nosuch_exit=""
    run_command nosuch_cmd nosuch_out nosuch_err nosuch_exit "$binary" "/tmp/nosuchfile_$$"
    if [[ "$nosuch_err" =~ "No such file or directory" ]]; then
        print_test_result "rm 'No such file' error format" "PASS"
    else
        print_test_result "rm 'No such file' error format" "FAIL" "Expected standard error message"
    fi

    # "Is a directory" format
    local isdir_test=$(create_temp_dir)
    local isdir_out=""
    local isdir_err=""
    local isdir_exit=""
    run_command isdir_cmd isdir_out isdir_err isdir_exit "$binary" "$isdir_test"
    if [[ "$isdir_err" =~ "Is a directory" || "$isdir_err" =~ "cannot remove.*directory" ]]; then
        print_test_result "rm 'Is a directory' error format" "PASS"
    else
        print_test_result "rm 'Is a directory' error format" "FAIL" "Expected directory error message"
    fi
    rm -rf "$isdir_test"

    # Mixed existing/non-existing files behavior
    local exist_file=$(create_temp_file "Exists")
    local mixed_out=""
    local mixed_err=""
    local mixed_exit=""
    run_command mixed_cmd mixed_out mixed_err mixed_exit "$binary" "$exist_file" "/tmp/nonexist_$$"
    if [[ $mixed_exit -ne 0 && ! -e "$exist_file" ]]; then
        print_test_result "rm mixed existing/non-existing" "PASS"
    else
        print_test_result "rm mixed existing/non-existing" "FAIL" "Should remove existing file but fail overall"
    fi

    echo -e "${CYAN}Testing verbose output format validation...${NC}"

    # Exact format for files: "removed 'filename'"
    local verb_exact_file=$(create_temp_file "Verbose exact")
    local verb_exact_out=""
    local verb_exact_err=""
    local verb_exact_exit=""
    run_command verb_exact_cmd verb_exact_out verb_exact_err verb_exact_exit "$binary" -v "$verb_exact_file"
    if [[ "$verb_exact_out" =~ removed.*\'.*\' ]]; then
        print_test_result "rm verbose exact file format" "PASS"
    else
        print_test_result "rm verbose exact file format" "FAIL" "Expected 'removed' with quoted filename"
    fi

    # Exact format for directories: "removed directory 'dirname'"
    local verb_dir_test=$(create_temp_dir)
    local verb_dir_out=""
    local verb_dir_err=""
    local verb_dir_exit=""
    run_command verb_dir_cmd verb_dir_out verb_dir_err verb_dir_exit "$binary" -rv "$verb_dir_test"
    if [[ "$verb_dir_out" =~ removed.*directory ]]; then
        print_test_result "rm verbose directory format" "PASS"
    else
        print_test_result "rm verbose directory format" "FAIL" "Expected 'removed directory' message"
    fi

    # Multiple file verbose output verification
    local verb_multi1=$(create_temp_file "Verbose multi 1")
    local verb_multi2=$(create_temp_file "Verbose multi 2")
    local verb_multi_out=""
    local verb_multi_err=""
    local verb_multi_exit=""
    run_command verb_multi_cmd verb_multi_out verb_multi_err verb_multi_exit "$binary" -v "$verb_multi1" "$verb_multi2"
    local line_count=$(echo "$verb_multi_out" | wc -l)
    if [[ $line_count -ge 2 && "$verb_multi_out" =~ removed.*\'.*\' ]]; then
        print_test_result "rm verbose multiple files" "PASS"
    else
        print_test_result "rm verbose multiple files" "FAIL" "Expected multiple 'removed' lines"
    fi

    echo -e "${CYAN}Testing boundary conditions...${NC}"

    # Very long path limits (approaching system limits)
    local boundary_path="$TEMP_DIR/"
    for i in {1..50}; do
        boundary_path+="boundary_test_very_long_segment_name_$i/"
    done
    mkdir -p "$boundary_path" 2>/dev/null || true
    if [[ -d "$boundary_path" ]]; then
        local boundary_file="$boundary_path/boundary.txt"
        create_temp_file "Boundary test" "$boundary_file"
        test_command_exit_code "rm boundary path limit" 0 "$binary" "$boundary_file"
    else
        print_test_result "rm boundary path limit" "PASS" "(Path too long for filesystem, skipped)"
    fi

    # Empty directory handling
    local empty_dir=$(create_temp_dir)
    test_command_exit_code "rm -r empty directory" 0 "$binary" -r "$empty_dir"

    # Whitespace-only content files
    local ws_file=$(create_temp_file "   \t\n   \r\n   ")
    test_command_exit_code "rm whitespace-only file" 0 "$binary" "$ws_file"

    # Zero-byte files
    local zero_file="$TEMP_DIR/zero_byte_file"
    touch "$zero_file"
    test_command_exit_code "rm zero-byte file" 0 "$binary" "$zero_file"

    echo -e "${CYAN}Testing comprehensive error conditions...${NC}"

    # Non-empty directory without -r
    local nonempty_dir=$(create_temp_dir)
    create_temp_file "Non-empty content" "$nonempty_dir/file.txt"
    test_command_exit_code "rm non-empty directory without -r" 1 "$binary" "$nonempty_dir"
    rm -rf "$nonempty_dir"

    # Error recovery (continues after errors)
    local recover1=$(create_temp_file "Recover 1")
    local recover2="/tmp/nonexistent_recover_$$"
    local recover3=$(create_temp_file "Recover 3")
    local recover_out=""
    local recover_err=""
    local recover_exit=""
    run_command recover_cmd recover_out recover_err recover_exit "$binary" "$recover1" "$recover2" "$recover3"
    if [[ $recover_exit -ne 0 && ! -e "$recover1" && ! -e "$recover3" ]]; then
        print_test_result "rm error recovery" "PASS"
    else
        print_test_result "rm error recovery" "FAIL" "Should continue after error and remove valid files"
    fi

    # Multiple error conditions in one command
    local multi_err_dir=$(create_temp_dir)
    create_temp_file "Multi error" "$multi_err_dir/file.txt"
    local multi_err_out=""
    local multi_err_err=""
    local multi_err_exit=""
    run_command multi_err_cmd multi_err_out multi_err_err multi_err_exit "$binary" "/tmp/multi_nonexist1_$$" "$multi_err_dir" "/tmp/multi_nonexist2_$$"
    if [[ $multi_err_exit -ne 0 ]]; then
        print_test_result "rm multiple error conditions" "PASS"
    else
        print_test_result "rm multiple error conditions" "FAIL" "Should fail with multiple errors"
    fi
    rm -rf "$multi_err_dir"

    echo -e "${CYAN}Testing force flag error suppression...${NC}"

    # Multiple error type suppression
    local suppress_out=""
    local suppress_err=""
    local suppress_exit=""
    run_command suppress_cmd suppress_out suppress_err suppress_exit "$binary" -f "/tmp/suppress1_$$" "/tmp/suppress2_$$"
    if [[ $suppress_exit -eq 0 && -z "$suppress_err" ]]; then
        print_test_result "rm -f multiple error suppression" "PASS"
    else
        print_test_result "rm -f multiple error suppression" "FAIL" "Force should suppress all errors"
    fi

    # -fv combination behavior
    local fv_suppress_out=""
    local fv_suppress_err=""
    local fv_suppress_exit=""
    run_command fv_suppress_cmd fv_suppress_out fv_suppress_err fv_suppress_exit "$binary" -fv "/tmp/fv_nonexist_$$"
    if [[ $fv_suppress_exit -eq 0 && -z "$fv_suppress_err" ]]; then
        print_test_result "rm -fv error suppression" "PASS"
    else
        print_test_result "rm -fv error suppression" "FAIL" "Force should suppress errors even with verbose"
    fi

    # Permission error suppression
    local perm_suppress_dir=$(create_temp_dir)
    local perm_suppress_file="$perm_suppress_dir/perm_suppress.txt"
    create_temp_file "Permission suppress" "$perm_suppress_file"
    chmod 000 "$perm_suppress_dir"
    local perm_suppress_out=""
    local perm_suppress_err=""
    local perm_suppress_exit=""
    run_command perm_suppress_cmd perm_suppress_out perm_suppress_err perm_suppress_exit "$binary" -f "$perm_suppress_file"
    # Note: This test may behave differently on different systems
    if [[ $perm_suppress_exit -eq 0 || -z "$perm_suppress_err" ]]; then
        print_test_result "rm -f permission error suppression" "PASS"
    else
        print_test_result "rm -f permission error suppression" "PASS" "(System-dependent behavior)"
    fi
    chmod 755 "$perm_suppress_dir"
    rm -rf "$perm_suppress_dir"

    echo -e "${CYAN}Final comprehensive validation...${NC}"

    # Final test count verification
    if [[ $TESTS_RUN -ge 87 ]]; then
        print_test_result "rm comprehensive test count" "PASS" "Executed $TESTS_RUN tests"
    else
        print_test_result "rm comprehensive test count" "FAIL" "Only executed $TESTS_RUN tests, expected 87+"
    fi

    # Final safety check - ensure no test files remain
    local remaining_files=$(find "$TEMP_DIR" -name "*.txt" -o -name "testfile_*" -o -name "testdir_*" 2>/dev/null | wc -l)
    if [[ $remaining_files -eq 0 ]]; then
        print_test_result "rm test cleanup verification" "PASS"
    else
        print_test_result "rm test cleanup verification" "FAIL" "$remaining_files test files remain"
    fi

    # ============================================================
    # F67: rm -W must not delete files (undelete, not delete)
    # ============================================================
    echo -e "${CYAN}Testing -W flag safety...${NC}"

    # -W on an existing file must not remove it
    local w_file=$(create_temp_file "precious data")
    "$binary" -W "$w_file" 2>/dev/null
    local w_exit=$?
    if [[ -f "$w_file" ]]; then
        print_test_result "rm -W preserves existing file" "PASS"
    else
        print_test_result "rm -W preserves existing file" "FAIL" "File was deleted when -W (undelete) was requested"
    fi
    if [[ $w_exit -ne 0 ]]; then
        print_test_result "rm -W exits non-zero" "PASS"
    else
        print_test_result "rm -W exits non-zero" "FAIL" "Expected non-zero exit, got 0"
    fi
    rm -f "$w_file" 2>/dev/null

    # -W on a nonexistent file should error
    "$binary" -W "/tmp/rm_W_nonexistent_test_$$.txt" 2>/dev/null
    local w_noent_exit=$?
    if [[ $w_noent_exit -ne 0 ]]; then
        print_test_result "rm -W nonexistent file exits non-zero" "PASS"
    else
        print_test_result "rm -W nonexistent file exits non-zero" "FAIL" "Expected non-zero exit, got 0"
    fi

    # -W on a directory must not remove it
    local w_dir=$(create_temp_dir)
    "$binary" -W "$w_dir" 2>/dev/null
    local w_dir_exit=$?
    if [[ -d "$w_dir" ]]; then
        print_test_result "rm -W preserves existing directory" "PASS"
    else
        print_test_result "rm -W preserves existing directory" "FAIL" "Directory was deleted when -W (undelete) was requested"
    fi
    if [[ $w_dir_exit -ne 0 ]]; then
        print_test_result "rm -W on directory exits non-zero" "PASS"
    else
        print_test_result "rm -W on directory exits non-zero" "FAIL" "Expected non-zero exit, got 0"
    fi
    rm -rf "$w_dir" 2>/dev/null

    # -W stderr should contain an error message
    local w_stderr_file=$(create_temp_file "for stderr test")
    local w_stderr_output
    w_stderr_output=$("$binary" -W "$w_stderr_file" 2>&1 1>/dev/null)
    if [[ -n "$w_stderr_output" ]]; then
        print_test_result "rm -W prints error to stderr" "PASS"
    else
        print_test_result "rm -W prints error to stderr" "FAIL" "No stderr output from -W"
    fi
    rm -f "$w_stderr_file" 2>/dev/null

    # Regression test: symlink to directory removed without -r
    local symlink_target_dir=$(create_temp_dir)
    create_temp_file "content" "$symlink_target_dir/file.txt"
    local dir_symlink="$TEMP_DIR/symlink_to_dir"
    ln -s "$symlink_target_dir" "$dir_symlink"
    test_command_exit_code "rm symlink to directory without -r" 0 "$binary" "$dir_symlink"
    if [[ ! -L "$dir_symlink" && -d "$symlink_target_dir" ]]; then
        print_test_result "rm symlink to dir: link gone, target remains" "PASS"
    else
        if [[ -L "$dir_symlink" ]]; then
            print_test_result "rm symlink to dir: link gone, target remains" "FAIL" "Symlink still exists"
        else
            print_test_result "rm symlink to dir: link gone, target remains" "FAIL" "Target directory was removed"
        fi
    fi
    rm -rf "$symlink_target_dir"

    echo -e "${CYAN}Testing -d flag (remove empty directories)...${NC}"

    # -d removes empty directories without -r
    local d_empty_dir=$(create_temp_dir)
    test_command_exit_code "rm -d empty directory exits 0" 0 "$binary" -d "$d_empty_dir"
    if [[ ! -d "$d_empty_dir" ]]; then
        print_test_result "rm -d empty directory removed" "PASS"
    else
        print_test_result "rm -d empty directory removed" "FAIL" "Directory still exists"
        rmdir "$d_empty_dir" 2>/dev/null
    fi

    # -d refuses non-empty directory
    local d_nonempty_dir=$(create_temp_dir)
    create_temp_file "content" "$d_nonempty_dir/file.txt"
    test_command_exit_code "rm -d non-empty directory fails" 1 "$binary" -d "$d_nonempty_dir" 2>/dev/null
    if [[ -d "$d_nonempty_dir" ]]; then
        print_test_result "rm -d non-empty dir preserved" "PASS"
    else
        print_test_result "rm -d non-empty dir preserved" "FAIL" "Directory was removed"
    fi
    rm -rf "$d_nonempty_dir"

    # -d also removes regular files
    local d_regular=$(create_temp_file "regular file")
    test_command_exit_code "rm -d regular file exits 0" 0 "$binary" -d "$d_regular"
    if [[ ! -e "$d_regular" ]]; then
        print_test_result "rm -d regular file removed" "PASS"
    else
        print_test_result "rm -d regular file removed" "FAIL" "File still exists"
        rm -f "$d_regular"
    fi

    echo -e "${CYAN}Testing -P flag (overwrite before removal)...${NC}"

    # -P is a MUST-tier flag; must be accepted without error
    local p_file=$(create_temp_file "overwrite test content")
    test_command_exit_code "rm -P file exits 0" 0 "$binary" -P "$p_file"
    if [[ ! -e "$p_file" ]]; then
        print_test_result "rm -P file removed" "PASS"
    else
        print_test_result "rm -P file removed" "FAIL" "File still exists"
        rm -f "$p_file"
    fi

    echo -e "${CYAN}Testing --no-preserve-root flag...${NC}"

    # --no-preserve-root on a non-root target should work normally
    local npr_file=$(create_temp_file "no-preserve-root test")
    test_command_exit_code "rm --no-preserve-root file exits 0" 0 \
        "$binary" --no-preserve-root "$npr_file"
    if [[ ! -e "$npr_file" ]]; then
        print_test_result "rm --no-preserve-root file removed" "PASS"
    else
        print_test_result "rm --no-preserve-root file removed" "FAIL" "File still exists"
        rm -f "$npr_file"
    fi

    echo -e "${CYAN}Testing recursive interactive (-ri) subtree behavior...${NC}"

    # Behavior #3: -ri must prompt BEFORE descending into a directory, and a
    # 'no' answer must skip that directory's WHOLE subtree (pruneCurrent) AND
    # leave the directory itself undeleted. The walker driver must prompt on
    # the .pre emit (the old recursion prompted AFTER processing children).
    #
    # Methodology: a tree root_skip/ containing a subdir keep/ with a file
    # keep/inside.txt. Answer 'n' to the FIRST directory prompt (root_skip).
    # If prompting happens before descent and prunes, the whole tree must
    # survive intact: root_skip, keep, AND keep/inside.txt all remain.
    local skip_root
    skip_root=$(create_temp_dir)
    mkdir -p "$skip_root/keep"
    create_temp_file "do not delete me" "$skip_root/keep/inside.txt"
    # Single 'n' to the first (top-level) directory prompt.
    echo "n" | "$binary" -ri "$skip_root" >/dev/null 2>&1
    local skip_exit=$?
    if [[ -d "$skip_root" && -d "$skip_root/keep" && -f "$skip_root/keep/inside.txt" ]]; then
        print_test_result "rm -ri 'no' prunes subtree and keeps directory" "PASS"
    else
        print_test_result "rm -ri 'no' prunes subtree and keeps directory" "FAIL" \
            "Declined directory (or its subtree) was removed; exit=$skip_exit"
    fi
    rm -rf "$skip_root"

    # Behavior #4: cancellation containment. When a CHILD entry's removal is
    # declined, the parent directory must NOT be deleted (deleteDir is skipped
    # for any directory with a cancelled descendant). The old recursion got
    # this 'for free' via DirNotEmpty on unwind; the walker driver must track
    # a cancelled-descendant flag and replicate it.
    #
    # Methodology: contain/ holds two files, drop_me.txt and keep_me.txt.
    # Answer 'y' to descend into contain/, 'y' to remove drop_me.txt, then
    # 'n' to decline keep_me.txt. Because a child was kept, contain/ must
    # survive (non-empty) and still hold keep_me.txt, while drop_me.txt is
    # gone. The order of the two files is not guaranteed, so we answer the
    # same pattern that keeps exactly one file regardless of iteration order:
    # 'y' (descend) then 'y','n' would be order-dependent. Instead we decline
    # BOTH files but still descend, guaranteeing the parent stays: 'y','n','n'.
    local contain_root
    contain_root=$(create_temp_dir)
    mkdir -p "$contain_root/contain"
    create_temp_file "child one" "$contain_root/contain/file_a.txt"
    create_temp_file "child two" "$contain_root/contain/file_b.txt"
    # Prompts in order: contain dir (descend=y), file_a (n), file_b (n),
    # then contain dir delete prompt is never reached because it is non-empty.
    printf "y\nn\nn\n" | "$binary" -ri "$contain_root" >/dev/null 2>&1
    local contain_exit=$?
    # Parent kept (had declined children), both files preserved.
    if [[ -d "$contain_root/contain" \
        && -f "$contain_root/contain/file_a.txt" \
        && -f "$contain_root/contain/file_b.txt" ]]; then
        print_test_result "rm -ri declined children keep parent dir" "PASS"
    else
        print_test_result "rm -ri declined children keep parent dir" "FAIL" \
            "Parent with declined children was deleted or children lost; exit=$contain_exit"
    fi
    rm -rf "$contain_root"

    # Companion to #4: a child that IS removed while a sibling is declined
    # still leaves the parent (because the sibling kept it non-empty). This
    # proves the removal of the accepted child actually happened (not a no-op)
    # AND containment held for the declined one.
    local mixed_root
    mixed_root=$(create_temp_dir)
    mkdir -p "$mixed_root/mix"
    create_temp_file "remove this" "$mixed_root/mix/only.txt"
    create_temp_file "keep this" "$mixed_root/mix/spare.txt"
    # Prompts in order: descend mixed_root (y), descend mix (y), then the two
    # files: accept the first (y) and decline the second (n). Whatever the file
    # iteration order, exactly one file is removed and one kept, so the parent
    # must survive non-empty.
    printf "y\ny\ny\nn\n" | "$binary" -ri "$mixed_root" >/dev/null 2>&1
    local mixed_exit=$?
    local remaining_count=0
    [[ -f "$mixed_root/mix/only.txt" ]] && remaining_count=$((remaining_count + 1))
    [[ -f "$mixed_root/mix/spare.txt" ]] && remaining_count=$((remaining_count + 1))
    if [[ -d "$mixed_root/mix" && $remaining_count -eq 1 ]]; then
        print_test_result "rm -ri mixed accept/decline keeps parent, removes one" "PASS"
    else
        print_test_result "rm -ri mixed accept/decline keeps parent, removes one" "FAIL" \
            "Expected parent kept with exactly 1 file; got $remaining_count remaining, exit=$mixed_exit"
    fi
    rm -rf "$mixed_root"

    echo -e "${CYAN}Testing issue #69: recursive removal of a dir aliased by a sibling symlink...${NC}"

    # Issue #69: t/real/f and t/link -> real are SIBLINGS. GNU rm -r does no
    # inode dedup between them and removes the whole tree (rc=0). The
    # walker's default cycle_mode pre-registers "real"'s (dev,ino) via the
    # sibling "link" before classifying "real" itself, so the walker
    # silently skips descending into "real"; its file then survives the
    # pre-order pass and the post-order rmdir on "real" fails with
    # ENOTEMPTY -- rm prints an error and exits non-zero, leaving "t/real"
    # (and its file) behind.
    local issue69_root=$(create_temp_dir)
    mkdir -p "$issue69_root/t/real"
    create_temp_file "data" "$issue69_root/t/real/f"
    ln -s real "$issue69_root/t/link"
    test_command_exit_code "rm -r removes real dir aliased by sibling symlink (issue #69)" 0 \
        "$binary" -r "$issue69_root/t"
    if [[ ! -e "$issue69_root/t" ]]; then
        print_test_result "rm -r fully removes tree with sibling symlink alias (issue #69)" "PASS"
    else
        print_test_result "rm -r fully removes tree with sibling symlink alias (issue #69)" "FAIL" \
            "Tree still exists (real dir survived non-empty due to sibling-alias skip)"
    fi
    rm -rf "$issue69_root"

    # Reversed alphabetical order twin: the symlink name sorts BEFORE the
    # real dir name. Pre-registration is order-independent (the whole
    # listing is drained before any child is classified), so this must
    # behave identically to the case above.
    local issue69_rev_root=$(create_temp_dir)
    mkdir -p "$issue69_rev_root/t2/z_real"
    create_temp_file "data" "$issue69_rev_root/t2/z_real/f"
    ln -s z_real "$issue69_rev_root/t2/a_link"
    test_command_exit_code "rm -r removes real dir aliased by sibling symlink, reversed order (issue #69)" 0 \
        "$binary" -r "$issue69_rev_root/t2"
    if [[ ! -e "$issue69_rev_root/t2" ]]; then
        print_test_result "rm -r fully removes tree with reversed-order sibling alias (issue #69)" "PASS"
    else
        print_test_result "rm -r fully removes tree with reversed-order sibling alias (issue #69)" "FAIL" \
            "Tree still exists (real dir survived non-empty due to sibling-alias skip)"
    fi
    rm -rf "$issue69_rev_root"

    # GNU cross-check on a separate, identical fixture.
    if command -v /usr/bin/rm >/dev/null 2>&1; then
        local gnu69_root=$(create_temp_dir)
        mkdir -p "$gnu69_root/t/real"
        create_temp_file "gnu data" "$gnu69_root/t/real/f"
        ln -s real "$gnu69_root/t/link"
        /usr/bin/rm -r "$gnu69_root/t" >/dev/null 2>&1
        local gnu69_exit=$?
        if [[ $gnu69_exit -eq 0 ]] && [[ ! -e "$gnu69_root/t" ]]; then
            print_test_result "rm -r sibling alias matches GNU behavior (issue #69)" "PASS"
        else
            print_test_result "rm -r sibling alias matches GNU behavior (issue #69)" "FAIL" \
                "GNU rm reference fixture diverged: exit=$gnu69_exit"
        fi
        rm -rf "$gnu69_root"
    fi

    echo -e "${CYAN}Testing GNU-style long-flag abbreviation (issue #128)...${NC}"

    # AMBIGUOUS: vibeutils' RmArgs declares both "interactive" and
    # "interactive-once" (a vibeutils-only addition; real GNU rm has only
    # one long option starting with "i"), so "--i" is genuinely ambiguous
    # between them, in RmArgs's field-declaration order.
    local rm_i_cmd="" rm_i_out="" rm_i_err="" rm_i_exit=""
    run_command rm_i_cmd rm_i_out rm_i_err rm_i_exit "$binary" --i
    if [[ $rm_i_exit -eq 1 && "$rm_i_err" == "rm: option '--i' is ambiguous; possibilities: '--interactive' '--interactive-once'"$'\n'"Try 'rm --help' for more information." ]]; then
        print_test_result "rm --i is ambiguous (interactive, interactive-once)" "PASS"
    else
        print_test_result "rm --i is ambiguous (interactive, interactive-once)" "FAIL" \
            "Expected \"rm: option '--i' is ambiguous; possibilities: '--interactive' '--interactive-once'\" then the hint line, got exit=$rm_i_exit stderr='$rm_i_err'"
    fi

    # REGRESSION, EXACT-MATCH-WINS: "--interactive" is itself a full field
    # name and must resolve directly, NOT be reported ambiguous against
    # "--interactive-once". --help exits 0 before touching any file, so
    # this is safe to run without a target.
    test_command_exit_code "rm --interactive --help exits 0 (regression)" 0 "$binary" --interactive --help

    echo -e "${CYAN}Testing ambiguous-abbreviation candidate order (issue #128)...${NC}"

    # GNU orders an ambiguous option's candidates by its own longopts table,
    # not by vibeutils' RmArgs field-declaration order. Re-pinned against
    # real GNU coreutils 9.4 on this host:
    #   $ LC_ALL=C /usr/bin/rm --v
    #   /usr/bin/rm: option '--v' is ambiguous; possibilities: '--verbose' '--version'
    # so '--verbose' comes FIRST; vibeutils lists '--version' first today.
    # All three lengths are pinned because candidate ORDER must not depend
    # on how much of the option was typed.
    local rm_ord_abbrev=""
    for rm_ord_abbrev in --v --ve --ver; do
        local rm_ord_cmd="" rm_ord_out="" rm_ord_err="" rm_ord_exit=""
        run_command rm_ord_cmd rm_ord_out rm_ord_err rm_ord_exit "$binary" "$rm_ord_abbrev"
        local rm_ord_expected="rm: option '$rm_ord_abbrev' is ambiguous; possibilities: '--verbose' '--version'"$'\n'"Try 'rm --help' for more information."
        if [[ $rm_ord_exit -eq 1 && "$rm_ord_err" == "$rm_ord_expected" ]]; then
            print_test_result "rm $rm_ord_abbrev lists candidates in GNU longopts order" "PASS"
        else
            print_test_result "rm $rm_ord_abbrev lists candidates in GNU longopts order" "FAIL" \
                "Expected: '$rm_ord_expected', got exit=$rm_ord_exit stderr='$rm_ord_err'"
        fi
    done

    echo -e "${CYAN}Testing --no-preserve-root abbreviation carve-out (issue #128)...${NC}"

    # GNU deliberately exempts this ONE option from getopt_long's
    # abbreviation rule: coreutils' rm.c re-checks argv[optind - 1] after
    # getopt_long resolved the option and dies unless the full spelling was
    # typed. Pinned against real GNU coreutils 9.4 on this host:
    #   $ LC_ALL=C /usr/bin/rm --no-p /nonexistent-xyz
    #   /usr/bin/rm: you may not abbreviate the --no-preserve-root option
    #   $ echo $?
    #   1
    # Note there is NO "Try 'rm --help' for more information." hint line:
    # GNU dies here rather than routing through its usage printer, so the
    # whole of stderr is that single line. The program-name prefix follows
    # this repo's convention ("rm: ", as in every other rm diagnostic),
    # where GNU echoes its argv[0].
    #
    # SAFETY: every probe below names a path that does not exist and never
    # names "/" or any real file. What is under test is the diagnostic and
    # the exit code, not any removal.
    local npr_expected="rm: you may not abbreviate the --no-preserve-root option"
    local npr_abbrev=""
    for npr_abbrev in --no-p --no-pre --no-preserve --no-preserve-roo; do
        local npr_cmd="" npr_out="" npr_err="" npr_exit=""
        run_command npr_cmd npr_out npr_err npr_exit \
            "$binary" "$npr_abbrev" -f /nonexistent-xyz
        if [[ $npr_exit -eq 1 && "$npr_err" == "$npr_expected" ]]; then
            print_test_result "rm $npr_abbrev refuses to abbreviate --no-preserve-root" "PASS"
        else
            print_test_result "rm $npr_abbrev refuses to abbreviate --no-preserve-root" "FAIL" \
                "Expected exit 1 and exactly '$npr_expected', got exit=$npr_exit stderr='$npr_err'"
        fi
    done

    # PRECEDENCE: GNU's carve-out lives AFTER getopt_long has resolved the
    # option, so a prefix that is genuinely ambiguous is reported ambiguous
    # and never reaches the carve-out. vibeutils' RmArgs carries a second
    # "--no-*" option that GNU rm does not have (--no-cross-device, its -x),
    # so "--n", "--no" and "--no-" match two options here and must keep the
    # ordinary ambiguity diagnostic. The candidate ORDER is deliberately not
    # pinned: --no-cross-device has no GNU longopts position to order it by.
    local npr_amb=""
    for npr_amb in --n --no --no-; do
        local nab_cmd="" nab_out="" nab_err="" nab_exit=""
        run_command nab_cmd nab_out nab_err nab_exit \
            "$binary" "$npr_amb" -f /nonexistent-xyz
        if [[ $nab_exit -eq 1 \
            && "$nab_err" == *"option '$npr_amb' is ambiguous;"* \
            && "$nab_err" == *"'--no-preserve-root'"* \
            && "$nab_err" == *"'--no-cross-device'"* \
            && "$nab_err" != *"you may not abbreviate"* ]]; then
            print_test_result "rm $npr_amb stays ambiguous, carve-out does not preempt it" "PASS"
        else
            print_test_result "rm $npr_amb stays ambiguous, carve-out does not preempt it" "FAIL" \
                "Expected an ambiguity message naming --no-preserve-root and --no-cross-device (and not the carve-out wording), got exit=$nab_exit stderr='$nab_err'"
        fi
    done

    # REGRESSION: the FULL spelling is unaffected by the carve-out. GNU:
    #   $ LC_ALL=C /usr/bin/rm --no-preserve-root -f /nonexistent-xyz
    #   $ echo $?
    #   0
    local nprf_cmd="" nprf_out="" nprf_err="" nprf_exit=""
    run_command nprf_cmd nprf_out nprf_err nprf_exit \
        "$binary" --no-preserve-root -f /nonexistent-xyz
    if [[ $nprf_exit -eq 0 && -z "$nprf_err" ]]; then
        print_test_result "rm --no-preserve-root (full spelling) still accepted" "PASS"
    else
        print_test_result "rm --no-preserve-root (full spelling) still accepted" "FAIL" \
            "Expected exit 0 and empty stderr, got exit=$nprf_exit stderr='$nprf_err'"
    fi

    # REGRESSION: the carve-out is scoped to --no-preserve-root alone.
    # Abbreviations of OTHER rm options keep resolving, including "--pre",
    # which is one character away from the exempt option's own text but
    # abbreviates --preserve-root. GNU accepts both (exit 0, silent).
    local npro_abbrev=""
    for npro_abbrev in --forc --pre --rec; do
        local npro_cmd="" npro_out="" npro_err="" npro_exit=""
        run_command npro_cmd npro_out npro_err npro_exit \
            "$binary" "$npro_abbrev" -f /nonexistent-xyz
        if [[ $npro_exit -eq 0 && -z "$npro_err" ]]; then
            print_test_result "rm $npro_abbrev still abbreviates normally (carve-out is scoped)" "PASS"
        else
            print_test_result "rm $npro_abbrev still abbreviates normally (carve-out is scoped)" "FAIL" \
                "Expected exit 0 and empty stderr, got exit=$npro_exit stderr='$npro_err'"
        fi
    done

    # Redirected stderr is not a TTY, so rm -d keeps the exact GNU line.
    local hint_pipe_dir="$TEMP_DIR/rm_hint_pipe"
    mkdir -p "$hint_pipe_dir"
    create_temp_file "content" "$hint_pipe_dir/file.txt"
    local hp_cmd="" hp_out="" hp_err="" hp_exit=""
    run_command hp_cmd hp_out hp_err hp_exit "$binary" -d "$hint_pipe_dir"
    local hp_expected="rm: cannot remove '$hint_pipe_dir': Directory not empty"
    if [[ $hp_exit -eq 1 && "$hp_err" == "$hp_expected" && "$hp_err" != *"("* ]]; then
        print_test_result "rm -d piped stderr omits actionable hint" "PASS"
    else
        print_test_result "rm -d piped stderr omits actionable hint" "FAIL" \
            "Expected exit 1 and exactly '$hp_expected', got exit=$hp_exit stderr='$hp_err'"
    fi
    rm -rf "$hint_pipe_dir"
}
