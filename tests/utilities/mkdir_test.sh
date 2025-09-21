#!/usr/bin/env bash
# Comprehensive tests for mkdir utility
# Tests all flags, directory creation, parent handling, and mode setting

# This file is sourced by test_runner.sh, so common.sh is already loaded

# Helper function for create-test-verify-cleanup pattern
# Usage: test_mkdir_and_verify "test description" "directory_name" [additional_mkdir_args]
test_mkdir_and_verify() {
    local description="$1"
    local dir_name="$2"
    shift 2
    local mkdir_args=("$@")

    test_command_succeeds "$description" "$binary" "${mkdir_args[@]}" "$dir_name"
    test_command_exit_code "$description directory exists" 0 bash -c "[ -d '$dir_name' ]"
    rm -rf "$dir_name"
}

test_mkdir() {
    local util="mkdir"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Basic functionality tests - single directory creation
    test_mkdir_and_verify "mkdir creates simple directory" "test_simple_dir"

    # Test single directory creation with absolute path
    local abs_test_dir="$TEMP_DIR/abs_test_dir"
    test_command_succeeds "mkdir creates absolute path directory" "$binary" "$abs_test_dir"
    test_command_exit_code "mkdir absolute path exists" 0 bash -c "[ -d '$abs_test_dir' ]"

    echo -e "${CYAN}Testing core functionality...${NC}"

    # Test multiple directory creation
    test_command_succeeds "mkdir creates multiple directories" "$binary" "dir1" "dir2" "dir3"
    test_command_exit_code "mkdir multiple dir1 exists" 0 bash -c "[ -d 'dir1' ]"
    test_command_exit_code "mkdir multiple dir2 exists" 0 bash -c "[ -d 'dir2' ]"
    test_command_exit_code "mkdir multiple dir3 exists" 0 bash -c "[ -d 'dir3' ]"
    rm -rf dir1 dir2 dir3

    # Test directory with spaces in name
    test_mkdir_and_verify "mkdir handles spaces in name" "dir with spaces"

    echo -e "${CYAN}Testing parents flag (-p)...${NC}"

    # Test -p flag (parents)
    test_command_succeeds "mkdir -p creates parent directories" "$binary" -p "parent/child/grandchild"
    test_command_exit_code "mkdir -p parent exists" 0 bash -c "[ -d 'parent' ]"
    test_command_exit_code "mkdir -p child exists" 0 bash -c "[ -d 'parent/child' ]"
    test_command_exit_code "mkdir -p grandchild exists" 0 bash -c "[ -d 'parent/child/grandchild' ]"
    rm -rf parent

    # Test --parents long option
    test_command_succeeds "mkdir --parents creates directory tree" "$binary" --parents "tree/branch/leaf"
    test_command_exit_code "mkdir --parents tree exists" 0 bash -c "[ -d 'tree/branch/leaf' ]"
    rm -rf tree

    # Test -p with existing directory (should succeed)
    mkdir -p "existing_dir"
    test_command_succeeds "mkdir -p existing directory succeeds" "$binary" -p "existing_dir"
    test_command_exit_code "mkdir -p existing still exists" 0 bash -c "[ -d 'existing_dir' ]"
    rm -rf existing_dir

    # Test -p with partial existing path (should succeed - this is intentional behavior)
    # When part of the path already exists, mkdir -p should create only the missing parts
    mkdir -p "partial/existing"
    test_command_succeeds "mkdir -p partial existing path" "$binary" -p "partial/existing/new"
    test_command_exit_code "mkdir -p partial new exists" 0 bash -c "[ -d 'partial/existing/new' ]"
    rm -rf partial

    echo -e "${CYAN}Testing verbose flag (-v)...${NC}"

    # Test -v flag (verbose)
    test_command_output "mkdir -v shows creation message" "mkdir: created directory 'verbose_test'" "$binary" -v "verbose_test"
    test_command_exit_code "mkdir -v directory exists" 0 bash -c "[ -d 'verbose_test' ]"
    rm -rf verbose_test

    # Test --verbose long option
    test_command_output "mkdir --verbose shows creation message" "mkdir: created directory 'verbose_long_test'" "$binary" --verbose "verbose_long_test"
    rm -rf verbose_long_test

    # Test verbose with multiple directories
    local expected_multi_verbose=$'mkdir: created directory \'multi1\'\nmkdir: created directory \'multi2\''
    test_command_output "mkdir -v multiple directories" "$expected_multi_verbose" "$binary" -v "multi1" "multi2"
    rm -rf multi1 multi2

    echo -e "${CYAN}Testing mode flag (-m)...${NC}"

    # Test -m flag (mode) - only on non-Windows systems
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_succeeds "mkdir -m 755 sets mode" "$binary" -m 755 "mode_test_755"
        test_command_exit_code "mkdir -m directory exists" 0 bash -c "[ -d 'mode_test_755' ]"
        # Check if permissions were set (platform-specific)
        local perms=$(get_file_permissions "mode_test_755")
        if [[ "$perms" == "755" ]]; then
            print_test_result "mkdir -m 755 permissions" "PASS"
        else
            print_test_result "mkdir -m 755 permissions" "FAIL" "Expected 755, got $perms"
        fi
        rm -rf mode_test_755

        # Test --mode long option
        test_command_succeeds "mkdir --mode=644 sets mode" "$binary" --mode=644 "mode_test_644"
        rm -rf mode_test_644

        # Test various mode formats
        test_command_succeeds "mkdir -m 777 full permissions" "$binary" -m 777 "mode_777"
        rm -rf mode_777

        test_command_succeeds "mkdir -m 000 no permissions" "$binary" -m 000 "mode_000"
        # Fix permissions so we can remove it
        chmod 755 mode_000
        rm -rf mode_000

        # Test 4-digit mode
        test_command_succeeds "mkdir -m 0755 4-digit mode" "$binary" -m 0755 "mode_4digit"
        rm -rf mode_4digit
    else
        # On Windows, mode flag should show warning but succeed
        test_command_succeeds "mkdir -m on Windows shows warning" "$binary" -m 755 "mode_windows_test"
        rm -rf mode_windows_test
    fi

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Test -p and -v together
    local expected_pv="mkdir: created directory 'combo/test/path'"
    test_command_output "mkdir -pv combination" "$expected_pv" "$binary" -pv "combo/test/path"
    rm -rf combo

    # Test -p and -m together
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_succeeds "mkdir -pm combination" "$binary" -pm 755 "combo_pm/sub"
        test_command_exit_code "mkdir -pm directory exists" 0 bash -c "[ -d 'combo_pm/sub' ]"
        rm -rf combo_pm
    fi

    # Test -v and -m together
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_output "mkdir -vm combination" "mkdir: created directory 'combo_vm'" "$binary" -vm 755 "combo_vm"
        rm -rf combo_vm
    fi

    # Test all flags together
    if [[ "$PLATFORM" != "windows" ]]; then
        local expected_all="mkdir: created directory 'combo/all/flags'"
        test_command_output "mkdir -pvm all flags" "$expected_all" "$binary" -pvm 755 "combo/all/flags"
        rm -rf combo
    else
        local expected_all="mkdir: created directory 'combo/all/flags'"
        test_command_output "mkdir -pv on Windows" "$expected_all" "$binary" -pv "combo/all/flags"
        rm -rf combo
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Test missing operand
    test_command_fails "mkdir no arguments fails" "$binary"

    # Test invalid flags
    test_command_fails "mkdir invalid flag" "$binary" --invalid-flag
    test_command_fails "mkdir unknown short flag" "$binary" -z

    # Test invalid mode values
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_fails "mkdir invalid mode letters" "$binary" -m abc "test_bad_mode"
        test_command_fails "mkdir invalid mode 888" "$binary" -m 888 "test_bad_mode"
        test_command_fails "mkdir invalid mode 9999" "$binary" -m 9999 "test_bad_mode"
        test_command_fails "mkdir empty mode" "$binary" -m "" "test_empty_mode"
    fi

    # Test directory already exists (without -p)
    mkdir "existing_for_test"
    test_command_fails "mkdir existing directory fails" "$binary" "existing_for_test"
    rm -rf existing_for_test

    # Test permission denied (create unwritable parent)
    mkdir "unwritable_parent"
    chmod 555 "unwritable_parent"  # Remove write permission
    test_command_fails "mkdir permission denied" "$binary" "unwritable_parent/new_dir"
    chmod 755 "unwritable_parent"  # Restore for cleanup
    rm -rf unwritable_parent

    # Test creating directory with file of same name exists
    touch "file_conflict"
    test_command_fails "mkdir conflicts with existing file" "$binary" "file_conflict"
    rm -f file_conflict

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Test path with trailing slashes
    test_command_succeeds "mkdir handles trailing slash" "$binary" "trailing_slash/"
    test_command_exit_code "mkdir trailing slash exists" 0 bash -c "[ -d 'trailing_slash' ]"
    rm -rf trailing_slash

    # Test path with multiple slashes
    test_command_succeeds "mkdir -p handles multiple slashes" "$binary" -p "multi//slash///path"
    test_command_exit_code "mkdir multi slash exists" 0 bash -c "[ -d 'multi/slash/path' ]"
    rm -rf multi

    # Test path with dot components
    test_command_succeeds "mkdir -p handles dot components" "$binary" -p "dot/./path/../path/final"
    test_command_exit_code "mkdir dot path exists" 0 bash -c "[ -d 'dot/path/final' ]"
    rm -rf dot

    # Test very long directory name
    local long_name=$(printf 'a%.0s' {1..100})  # 100 character name
    test_command_succeeds "mkdir handles long name" "$binary" "$long_name"
    test_command_exit_code "mkdir long name exists" 0 bash -c "[ -d '$long_name' ]"
    rm -rf "$long_name"

    # Test special characters in directory name (shell-safe)
    test_command_succeeds "mkdir handles special chars" "$binary" "special-_@#"
    test_command_exit_code "mkdir special chars exists" 0 bash -c "[ -d 'special-_@#' ]"
    rm -rf "special-_@#"

    # Test creating nested structure without -p (should fail)
    test_command_fails "mkdir nested without -p fails" "$binary" "no_parent/nested/deep"

    # Test empty string as directory name
    test_command_fails "mkdir empty name fails" "$binary" ""

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX required behaviors
    test_command_succeeds "POSIX: mkdir creates single directory" "$binary" "posix_single"
    rm -rf posix_single

    test_command_succeeds "POSIX: mkdir -p creates parent directories" "$binary" -p "posix/parent/path"
    rm -rf posix

    # POSIX exit codes
    test_command_exit_code "POSIX: mkdir success exit code" 0 "$binary" "posix_success"
    rm -rf posix_success

    test_command_exit_code "POSIX: mkdir failure exit code" 1 "$binary" "/dev/null/impossible" 2>/dev/null || true

    # POSIX mode handling
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_succeeds "POSIX: mkdir -m mode" "$binary" -m 755 "posix_mode"
        rm -rf posix_mode
    fi

    echo -e "${CYAN}Testing boundary conditions...${NC}"

    # Test current directory (should succeed with -p)
    test_command_succeeds "mkdir -p current directory" "$binary" -p "."

    # Test relative path starting with dot
    test_command_succeeds "mkdir dot relative path" "$binary" -p "./relative/path"
    rm -rf relative

    # Test mixed success and failure (multiple directories)
    mkdir "exists_already"
    # This should succeed for new_success but fail for exists_already, overall exit code should be 1
    test_command_exit_code "mkdir mixed success/failure" 1 "$binary" "new_success" "exists_already" 2>/dev/null || true
    rm -rf exists_already new_success

    # Test deep nesting with -p
    test_command_succeeds "mkdir -p deep nesting" "$binary" -p "level1/level2/level3/level4/level5"
    test_command_exit_code "mkdir deep nesting exists" 0 bash -c "[ -d 'level1/level2/level3/level4/level5' ]"
    rm -rf level1

    # Test that -p doesn't change existing directory permissions
    if [[ "$PLATFORM" != "windows" ]]; then
        mkdir -p "perm_test"
        chmod 755 "perm_test"
        test_command_succeeds "mkdir -p preserves existing permissions" "$binary" -p "perm_test"
        local perms_after=$(get_file_permissions "perm_test")
        if [[ "$perms_after" == "755" ]]; then
            print_test_result "mkdir -p preserves permissions" "PASS"
        else
            print_test_result "mkdir -p preserves permissions" "FAIL" "Permissions changed from 755 to $perms_after"
        fi
        rm -rf perm_test
    fi

    echo -e "${CYAN}Testing verbose output variations...${NC}"

    # Test verbose with existing directory and -p
    mkdir "pre_existing"
    # When -p is used and directory exists, some implementations don't print verbose message
    test_command_succeeds "mkdir -pv existing directory" "$binary" -pv "pre_existing"
    rm -rf pre_existing

    # Test verbose with deep path creation
    test_command_output_pattern "mkdir -pv deep path contains creation message" "created directory" "$binary" -pv "deep/verbose/path"
    rm -rf deep

    echo -e "${CYAN}Testing argument parsing edge cases...${NC}"

    # Test flag terminator (ensure clean state first)
    rm -rf ./-looks-like-flag 2>/dev/null || true
    test_command_succeeds "mkdir -- handles flag terminator" "$binary" -- "-looks-like-flag"
    test_command_exit_code "mkdir flag terminator directory exists" 0 bash -c "[ -d '-looks-like-flag' ]"
    rm -rf ./-looks-like-flag

    # Test combined short flags
    test_command_succeeds "mkdir combined short flags" "$binary" -pv "combined/flags/test"
    rm -rf combined

    # Test mode with equals sign
    if [[ "$PLATFORM" != "windows" ]]; then
        test_command_succeeds "mkdir --mode=value syntax" "$binary" --mode=644 "equals_mode"
        rm -rf equals_mode
    fi

    echo -e "${CYAN}Testing filesystem edge cases...${NC}"

    # Test creating directory where file exists in path
    mkdir -p "path_conflict"
    touch "path_conflict/file_in_path"
    test_command_fails "mkdir path blocked by file" "$binary" "path_conflict/file_in_path/blocked"
    rm -rf path_conflict

    # Test symlink handling (if supported)
    if command -v ln >/dev/null 2>&1; then
        mkdir "symlink_target"
        ln -s "symlink_target" "symlink_to_dir"
        test_command_fails "mkdir over symlink to directory" "$binary" "symlink_to_dir"
        rm -rf symlink_target symlink_to_dir
    fi

    # Test case sensitivity (create similar names) - handle case-insensitive filesystems
    if mkdir "CaseTest" 2>/dev/null && mkdir "casetest" 2>/dev/null; then
        # Case-sensitive filesystem
        test_command_succeeds "mkdir case sensitive names" "$binary" "CaseSensitiveTest1" "casesensitivetest2"
        test_command_exit_code "mkdir CaseSensitiveTest1 exists" 0 bash -c "[ -d 'CaseSensitiveTest1' ]"
        test_command_exit_code "mkdir casesensitivetest2 exists" 0 bash -c "[ -d 'casesensitivetest2' ]"
        rm -rf CaseSensitiveTest1 casesensitivetest2
        rm -rf CaseTest casetest 2>/dev/null || true
    else
        # Case-insensitive filesystem (like macOS default) - conflicting names should fail
        test_command_exit_code "mkdir case conflict on case-insensitive fs" 1 "$binary" "CaseConflict" "caseconflict" 2>/dev/null || true
        rm -rf CaseTest casetest CaseConflict caseconflict 2>/dev/null || true
    fi

    # Note: --silent flag is not implemented in this mkdir utility
    # Some implementations include a --silent or -q flag to suppress verbose output,
    # but this is not part of POSIX specification and is not implemented here.
    # The default behavior (no output on success) already provides silent operation.

    echo -e "${CYAN}Testing Unicode and special characters...${NC}"

    # Test Unicode directory names (if locale supports it)
    if locale | grep -q "UTF-8"; then
        test_command_succeeds "mkdir Unicode name" "$binary" "测试目录"
        test_command_exit_code "mkdir Unicode exists" 0 bash -c "[ -d '测试目录' ]"
        rm -rf "测试目录"

        test_command_succeeds "mkdir Unicode with -p" "$binary" -p "测试/路径/目录"
        rm -rf "测试"
    fi

    echo -e "${CYAN}Testing performance and limits...${NC}"

    # Test many directories at once
    local many_dirs=()
    for i in {1..50}; do
        many_dirs+=("many_dir_$i")
    done
    test_command_succeeds "mkdir many directories" "$binary" "${many_dirs[@]}"

    # Verify a few exist
    test_command_exit_code "mkdir many dir_1 exists" 0 bash -c "[ -d 'many_dir_1' ]"
    test_command_exit_code "mkdir many dir_25 exists" 0 bash -c "[ -d 'many_dir_25' ]"
    test_command_exit_code "mkdir many dir_50 exists" 0 bash -c "[ -d 'many_dir_50' ]"

    # Cleanup
    rm -rf many_dir_*

    # Test maximum path depth (reasonable limit)
    local deep_path="deep"
    for i in {1..10}; do
        deep_path="$deep_path/level$i"
    done
    test_command_succeeds "mkdir very deep path" "$binary" -p "$deep_path"
    test_command_exit_code "mkdir deep path exists" 0 bash -c "[ -d '$deep_path' ]"
    rm -rf deep
}