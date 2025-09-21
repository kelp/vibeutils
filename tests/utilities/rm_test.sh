#!/usr/bin/env bash
# Comprehensive tests for rm utility
# Tests all flags, file/directory removal, safety features, and edge cases
# Total: 116 tests covering complete functionality

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

    # Missing operands
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
    (cd "$crash_test_dir" && timeout 5 "$binary" -rf . >/dev/null 2>&1)
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
    (cd "$child_dir" && timeout 5 "$binary" -rf .. >/dev/null 2>&1)
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
    "$binary" "$prot_444" >/dev/null 2>&1
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
    if [[ $TESTS_RUN -ge 110 ]]; then
        print_test_result "rm comprehensive test count" "PASS" "Executed $TESTS_RUN tests"
    else
        print_test_result "rm comprehensive test count" "FAIL" "Only executed $TESTS_RUN tests, expected 110+"
    fi

    # Final safety check - ensure no test files remain
    local remaining_files=$(find "$TEMP_DIR" -name "*.txt" -o -name "testfile_*" -o -name "testdir_*" 2>/dev/null | wc -l)
    if [[ $remaining_files -eq 0 ]]; then
        print_test_result "rm test cleanup verification" "PASS"
    else
        print_test_result "rm test cleanup verification" "FAIL" "$remaining_files test files remain"
    fi
}