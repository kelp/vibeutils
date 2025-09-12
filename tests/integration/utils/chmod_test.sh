#!/usr/bin/env bash
# Comprehensive integration tests for chmod utility
# Tests all flags, edge cases, error handling, and permission operations

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
CHMOD_TIMEOUT=10
RECURSIVE_TIMEOUT=20

# Permission verification helper functions
get_file_permissions() {
    local file="$1"
    if is_macos; then
        local perms
        perms=$(stat -f "%Mp%Lp" "$file" 2>/dev/null)
        # Remove leading zeros and handle empty result
        perms=$(echo "$perms" | sed 's/^0*//')
        if [[ -z "$perms" ]]; then
            echo "000"
        elif [[ ${#perms} -eq 1 ]]; then
            echo "00$perms"
        elif [[ ${#perms} -eq 2 ]]; then
            echo "0$perms"
        else
            echo "$perms"
        fi
    else
        stat -c "%a" "$file" 2>/dev/null
    fi
}

verify_permissions() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(get_file_permissions "$file")
    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        return 1
    fi
}

create_test_file_with_perms() {
    local file="$1"
    local perms="$2"
    local content="${3:-Test content}"
    printf "%s\n" "$content" > "$file"
    chmod "$perms" "$file"
}

create_test_dir_with_perms() {
    local dir="$1"
    local perms="$2"
    mkdir -p "$dir"
    chmod "$perms" "$dir"
}

cleanup_with_permissions() {
    local items=("$@")
    for item in "${items[@]}"; do
        if [[ -f "$item" ]] || [[ -d "$item" ]]; then
            # Restore full permissions before deletion to avoid issues
            chmod -R 755 "$item" 2>/dev/null || true
            rm -rf "$item" 2>/dev/null || true
        fi
    done
}

# Test helper functions
setup_chmod_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# =============================================================================
# Basic Functionality Tests (12 tests)
# =============================================================================

test_chmod_octal_mode_basic() {
    setup_chmod_test
    
    local test_file="octal_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Change to 755
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$test_file"
    
    assert_success "chmod should succeed with octal mode"
    assert_equals "true" "$(verify_permissions "$test_file" "755" && echo true || echo false)" "file should have 755 permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_mode_basic() {
    setup_chmod_test
    
    local test_file="symbolic_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Add execute for owner
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u+x" "$test_file"
    
    assert_success "chmod should succeed with symbolic mode"
    assert_equals "true" "$(verify_permissions "$test_file" "744" && echo true || echo false)" "file should have execute permission added"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_multiple_files() {
    setup_chmod_test
    
    local file1="multi1.txt"
    local file2="multi2.txt"
    create_test_file_with_perms "$file1" "644"
    create_test_file_with_perms "$file2" "644"
    
    # Change both files
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$file1" "$file2"
    
    assert_success "chmod should succeed with multiple files"
    assert_equals "true" "$(verify_permissions "$file1" "755" && echo true || echo false)" "first file should have new permissions"
    assert_equals "true" "$(verify_permissions "$file2" "755" && echo true || echo false)" "second file should have new permissions"
    
    cleanup_with_permissions "$file1" "$file2"
}

test_chmod_directory_basic() {
    setup_chmod_test
    
    local test_dir="test_directory"
    create_test_dir_with_perms "$test_dir" "755"
    
    # Change directory permissions
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "644" "$test_dir"
    
    assert_success "chmod should succeed with directory"
    assert_equals "true" "$(verify_permissions "$test_dir" "644" && echo true || echo false)" "directory should have new permissions"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_all_rwx_permissions() {
    setup_chmod_test
    
    local test_file="rwx_test.txt"
    create_test_file_with_perms "$test_file" "000"
    
    # Set all permissions
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "777" "$test_file"
    
    assert_success "chmod should succeed setting all permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "777" && echo true || echo false)" "file should have all permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_remove_all_permissions() {
    setup_chmod_test
    
    local test_file="remove_test.txt"
    create_test_file_with_perms "$test_file" "777"
    
    # Remove all permissions
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "000" "$test_file"
    
    assert_success "chmod should succeed removing all permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "000" && echo true || echo false)" "file should have no permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_owner_group_other() {
    setup_chmod_test
    
    local test_file="ugo_test.txt"
    create_test_file_with_perms "$test_file" "000"
    
    # Set different permissions for user, group, other
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "741" "$test_file"
    
    assert_success "chmod should succeed with different ugo permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "741" && echo true || echo false)" "file should have 741 permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_user_permissions() {
    setup_chmod_test
    
    local test_file="user_perms.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Add execute for user only
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u+x" "$test_file"
    
    assert_success "chmod should succeed with user-specific permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "744" && echo true || echo false)" "user should have execute permission"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_group_permissions() {
    setup_chmod_test
    
    local test_file="group_perms.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Add execute for group
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "g+x" "$test_file"
    
    assert_success "chmod should succeed with group permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "654" && echo true || echo false)" "group should have execute permission"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_other_permissions() {
    setup_chmod_test
    
    local test_file="other_perms.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Remove read for others
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "o-r" "$test_file"
    
    assert_success "chmod should succeed with other permissions"
    assert_equals "true" "$(verify_permissions "$test_file" "640" && echo true || echo false)" "others should lose read permission"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_all_users() {
    setup_chmod_test
    
    local test_file="all_users.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Add execute for all users
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "a+x" "$test_file"
    
    assert_success "chmod should succeed with all users"
    assert_equals "true" "$(verify_permissions "$test_file" "755" && echo true || echo false)" "all users should have execute permission"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_mixed_symbolic_operations() {
    setup_chmod_test
    
    local test_file="mixed_ops.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Multiple symbolic operations: u+x,g-w,o+w
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u+x,g-w,o+w" "$test_file"
    
    assert_success "chmod should succeed with mixed symbolic operations"
    assert_equals "true" "$(verify_permissions "$test_file" "746" && echo true || echo false)" "file should have mixed permissions applied"
    
    cleanup_with_permissions "$test_file"
}

# =============================================================================
# All Flags Tests (15 tests)
# =============================================================================

test_chmod_changes_flag_short() {
    setup_chmod_test
    
    local test_file="changes_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test -c flag (only show changes)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -c "755" "$test_file"
    
    assert_success "chmod -c should succeed"
    assert_output_contains "$test_file" "output should show changed file"
    assert_output_contains "755" "output should show new permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_changes_flag_long() {
    setup_chmod_test
    
    local test_file="changes_long.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test --changes flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --changes "755" "$test_file"
    
    assert_success "chmod --changes should succeed"
    assert_output_contains "$test_file" "output should show changed file"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_verbose_flag_short() {
    setup_chmod_test
    
    local test_file="verbose_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test -v flag (verbose output)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v "755" "$test_file"
    
    assert_success "chmod -v should succeed"
    assert_output_contains "$test_file" "verbose output should show file"
    assert_output_contains "755" "verbose output should show permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_verbose_flag_long() {
    setup_chmod_test
    
    local test_file="verbose_long.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test --verbose flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --verbose "755" "$test_file"
    
    assert_success "chmod --verbose should succeed"
    assert_output_contains "$test_file" "verbose output should show file"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_silent_flag_short() {
    setup_chmod_test
    
    local nonexistent="does_not_exist.txt"
    
    # Test -f flag (silent mode)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure -f "755" "$nonexistent"
    
    # Should still fail but produce no output
    assert_failure "chmod -f should still fail with non-existent file"
    assert_output_empty "silent mode should produce no output"
}

test_chmod_silent_flag_long() {
    setup_chmod_test
    
    local nonexistent="silent_long.txt"
    
    # Test --silent flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure --silent "755" "$nonexistent"
    
    assert_failure "chmod --silent should still fail with non-existent file"
    assert_output_empty "silent mode should produce no output"
}

test_chmod_recursive_flag_short() {
    setup_chmod_test
    
    local test_dir="recursive_test"
    local sub_file="$test_dir/sub_file.txt"
    local sub_dir="$test_dir/sub_dir"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_file_with_perms "$sub_file" "644"
    create_test_dir_with_perms "$sub_dir" "755"
    
    # Test -R flag (recursive)
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -R "700" "$test_dir"
    
    assert_success "chmod -R should succeed"
    assert_equals "true" "$(verify_permissions "$test_dir" "700" && echo true || echo false)" "directory should have new permissions"
    assert_equals "true" "$(verify_permissions "$sub_file" "700" && echo true || echo false)" "subdirectory file should have new permissions"
    assert_equals "true" "$(verify_permissions "$sub_dir" "700" && echo true || echo false)" "subdirectory should have new permissions"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_recursive_flag_long() {
    setup_chmod_test
    
    local test_dir="recursive_long"
    local sub_file="$test_dir/file.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_file_with_perms "$sub_file" "644"
    
    # Test --recursive flag
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" --recursive "755" "$test_dir"
    
    assert_success "chmod --recursive should succeed"
    assert_equals "true" "$(verify_permissions "$sub_file" "755" && echo true || echo false)" "recursive should change file permissions"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_reference_flag() {
    setup_chmod_test
    
    local ref_file="reference.txt"
    local target_file="target.txt"
    
    create_test_file_with_perms "$ref_file" "751"
    create_test_file_with_perms "$target_file" "644"
    
    # Test --reference flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --reference="$ref_file" "$target_file"
    
    assert_success "chmod --reference should succeed"
    assert_equals "true" "$(verify_permissions "$target_file" "751" && echo true || echo false)" "target should match reference permissions"
    
    cleanup_with_permissions "$ref_file" "$target_file"
}

test_chmod_combined_flags_cv() {
    setup_chmod_test
    
    local test_file="combined_cv.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test -cv combination
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -cv "755" "$test_file"
    
    assert_success "chmod -cv should succeed"
    assert_output_contains "$test_file" "output should show file with combined flags"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_combined_flags_vR() {
    setup_chmod_test
    
    local test_dir="combined_vR"
    local sub_file="$test_dir/file.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_file_with_perms "$sub_file" "644"
    
    # Test -vR combination
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -vR "700" "$test_dir"
    
    assert_success "chmod -vR should succeed"
    assert_output_contains "$test_dir" "verbose recursive should show directory"
    assert_output_contains "$sub_file" "verbose recursive should show file"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_combined_flags_fR() {
    setup_chmod_test
    
    local test_dir="combined_fR"
    local nonexistent="$test_dir/does_not_exist.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    
    # Test -fR combination with non-existent file
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" --expect-failure -fR "755" "$test_dir" "$nonexistent"
    
    assert_failure "chmod -fR should fail with non-existent file but suppress error messages"
    assert_output_empty "silent mode should produce no output"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_long_and_short_mixed() {
    setup_chmod_test
    
    local test_file="mixed_flags.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test mixing long and short flags
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --verbose -c "755" "$test_file"
    
    assert_success "chmod with mixed flag formats should succeed"
    assert_output_contains "$test_file" "mixed flags should work"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_all_flags_combination() {
    setup_chmod_test
    
    local test_dir="all_flags"
    local ref_file="all_ref.txt"
    local target_file="$test_dir/target.txt"
    
    create_test_file_with_perms "$ref_file" "755"
    create_test_dir_with_perms "$test_dir" "755"
    create_test_file_with_perms "$target_file" "644"
    
    # Test combination of multiple flags
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -cvR --reference="$ref_file" "$test_dir"
    
    assert_success "chmod with all flags should succeed"
    assert_output_contains "$test_dir" "all flags should work together"
    
    cleanup_with_permissions "$test_dir" "$ref_file"
}

test_chmod_flag_precedence_order() {
    setup_chmod_test
    
    local test_file="precedence.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test flag precedence: verbose and changes together should show verbose behavior
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -vc "755" "$test_file"
    
    assert_success "chmod with precedence flags should succeed"
    assert_output_contains "$test_file" "precedence should work with combined flags"
    
    cleanup_with_permissions "$test_file"
}

# =============================================================================
# Edge Cases Tests (18 tests)
# =============================================================================

test_chmod_special_permissions_setuid() {
    setup_chmod_test
    
    local test_file="setuid_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Set setuid bit (4755)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "4755" "$test_file"
    
    assert_success "chmod should succeed with setuid"
    assert_equals "true" "$(verify_permissions "$test_file" "4755" && echo true || echo false)" "file should have setuid bit"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_special_permissions_setgid() {
    setup_chmod_test
    
    local test_file="setgid_test.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Set setgid bit (2755)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "2755" "$test_file"
    
    assert_success "chmod should succeed with setgid"
    assert_equals "true" "$(verify_permissions "$test_file" "2755" && echo true || echo false)" "file should have setgid bit"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_special_permissions_sticky() {
    setup_chmod_test
    
    local test_dir="sticky_test"
    create_test_dir_with_perms "$test_dir" "755"
    
    # Set sticky bit (1755)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "1755" "$test_dir"
    
    assert_success "chmod should succeed with sticky bit"
    assert_equals "true" "$(verify_permissions "$test_dir" "1755" && echo true || echo false)" "directory should have sticky bit"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_symbolic_special_setuid() {
    setup_chmod_test
    
    local test_file="sym_setuid.txt"
    create_test_file_with_perms "$test_file" "755"
    
    # Set setuid symbolically
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u+s" "$test_file"
    
    assert_success "chmod should succeed with symbolic setuid"
    assert_equals "true" "$(verify_permissions "$test_file" "4755" && echo true || echo false)" "file should have setuid via symbolic"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_special_setgid() {
    setup_chmod_test
    
    local test_file="sym_setgid.txt"
    create_test_file_with_perms "$test_file" "755"
    
    # Set setgid symbolically
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "g+s" "$test_file"
    
    assert_success "chmod should succeed with symbolic setgid"
    assert_equals "true" "$(verify_permissions "$test_file" "2755" && echo true || echo false)" "file should have setgid via symbolic"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_special_sticky() {
    setup_chmod_test
    
    local test_dir="sym_sticky"
    create_test_dir_with_perms "$test_dir" "755"
    
    # Set sticky bit symbolically
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "o+t" "$test_dir"
    
    assert_success "chmod should succeed with symbolic sticky"
    assert_equals "true" "$(verify_permissions "$test_dir" "1755" && echo true || echo false)" "directory should have sticky via symbolic"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_empty_file() {
    setup_chmod_test
    
    local empty_file="empty.txt"
    touch "$empty_file"
    
    # Change permissions on empty file
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$empty_file"
    
    assert_success "chmod should succeed on empty file"
    assert_equals "true" "$(verify_permissions "$empty_file" "755" && echo true || echo false)" "empty file should have new permissions"
    
    cleanup_with_permissions "$empty_file"
}

test_chmod_large_file() {
    setup_chmod_test
    
    local large_file="large.txt"
    # Create a reasonably sized file (not too large for test performance)
    dd if=/dev/zero of="$large_file" bs=1024 count=100 2>/dev/null || {
        # Fallback if dd not available
        for i in {1..100}; do
            printf "Line %d with some content to make it reasonably long\n" "$i"
        done > "$large_file"
    }
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "644" "$large_file"
    
    assert_success "chmod should succeed on large file"
    assert_equals "true" "$(verify_permissions "$large_file" "644" && echo true || echo false)" "large file should have correct permissions"
    
    cleanup_with_permissions "$large_file"
}

test_chmod_special_filenames() {
    setup_chmod_test
    
    local special_files=(
        "file with spaces.txt"
        "file-with-dashes.txt"
        "file.with.dots.txt"
        "file_with_underscores.txt"
    )
    
    for file in "${special_files[@]}"; do
        create_test_file_with_perms "$file" "644"
        
        exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$file"
        
        assert_success "chmod should succeed with special filename: $file"
        assert_equals "true" "$(verify_permissions "$file" "755" && echo true || echo false)" "special filename should have correct permissions"
    done
    
    cleanup_with_permissions "${special_files[@]}"
}

test_chmod_deeply_nested_paths() {
    setup_chmod_test
    
    local nested_dir="deep/very/deeply/nested/directory"
    local nested_file="$nested_dir/file.txt"
    
    mkdir -p "$nested_dir"
    create_test_file_with_perms "$nested_file" "644"
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$nested_file"
    
    assert_success "chmod should succeed with deeply nested paths"
    assert_equals "true" "$(verify_permissions "$nested_file" "755" && echo true || echo false)" "deeply nested file should have correct permissions"
    
    cleanup_with_permissions "deep"
}

test_chmod_already_correct_permissions() {
    setup_chmod_test
    
    local test_file="already_correct.txt"
    create_test_file_with_perms "$test_file" "755"
    
    # Set same permissions again
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "$test_file"
    
    assert_success "chmod should succeed even when permissions already correct"
    assert_equals "true" "$(verify_permissions "$test_file" "755" && echo true || echo false)" "permissions should remain correct"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_changes_flag_no_changes() {
    setup_chmod_test
    
    local test_file="no_changes.txt"
    create_test_file_with_perms "$test_file" "755"
    
    # Use -c flag when no changes needed
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -c "755" "$test_file"
    
    assert_success "chmod -c should succeed when no changes needed"
    assert_output_empty "should produce no output when no changes made with -c flag"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_symbolic_equals_assignment() {
    setup_chmod_test
    
    local test_file="equals_test.txt"
    create_test_file_with_perms "$test_file" "777"
    
    # Use equals to set exact permissions
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u=rw,g=r,o=" "$test_file"
    
    assert_success "chmod should succeed with equals assignment"
    assert_equals "true" "$(verify_permissions "$test_file" "640" && echo true || echo false)" "equals assignment should set exact permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_multiple_symbolic_operations() {
    setup_chmod_test
    
    local test_file="multi_symbolic.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Multiple operations: u+x,g+w,o-r
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u+x,g+w,o-r" "$test_file"
    
    assert_success "chmod should succeed with multiple symbolic operations"
    assert_equals "true" "$(verify_permissions "$test_file" "760" && echo true || echo false)" "multiple symbolic operations should work"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_complex_symbolic_with_classes() {
    setup_chmod_test
    
    local test_file="complex_symbolic.txt"
    create_test_file_with_perms "$test_file" "000"
    
    # Complex symbolic: ug=rw,o=r,a+x
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "ug=rw,o=r,a+x" "$test_file"
    
    assert_success "chmod should succeed with complex symbolic"
    assert_equals "true" "$(verify_permissions "$test_file" "775" && echo true || echo false)" "complex symbolic should work correctly"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_recursive_mixed_content() {
    setup_chmod_test
    
    local test_dir="mixed_recursive"
    local sub_dir1="$test_dir/subdir1"
    local sub_dir2="$test_dir/subdir2"
    local file1="$test_dir/file1.txt"
    local file2="$sub_dir1/file2.txt"
    local file3="$sub_dir2/file3.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_dir_with_perms "$sub_dir1" "755"
    create_test_dir_with_perms "$sub_dir2" "755"
    create_test_file_with_perms "$file1" "644"
    create_test_file_with_perms "$file2" "644"
    create_test_file_with_perms "$file3" "644"
    
    # Recursive change on mixed content
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -R "700" "$test_dir"
    
    assert_success "chmod -R should succeed with mixed content"
    assert_equals "true" "$(verify_permissions "$test_dir" "700" && echo true || echo false)" "top directory should have new permissions"
    assert_equals "true" "$(verify_permissions "$sub_dir1" "700" && echo true || echo false)" "subdirectory 1 should have new permissions"
    assert_equals "true" "$(verify_permissions "$file2" "700" && echo true || echo false)" "nested file should have new permissions"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_zero_length_filename_edge() {
    setup_chmod_test
    
    # Test with current directory reference
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" "."
    
    assert_success "chmod should succeed with current directory"
    
    # Note: We don't verify permissions of . as it might affect test environment
}

test_chmod_parent_directory_reference() {
    setup_chmod_test
    
    local sub_dir="subdir_test"
    create_test_dir_with_perms "$sub_dir" "755"
    cd "$sub_dir"
    
    # Change parent directory permissions
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "755" ".."
    
    assert_success "chmod should succeed with parent directory reference"
    
    cd ..
    cleanup_with_permissions "$sub_dir"
}

# =============================================================================
# Error Conditions Tests (10 tests)
# =============================================================================

test_chmod_nonexistent_file() {
    setup_chmod_test
    
    local nonexistent="definitely_does_not_exist.txt"
    
    # Test with non-existent file (without -f flag)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "755" "$nonexistent"
    
    assert_failure "chmod should fail with non-existent file"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "$nonexistent" "error should mention the file"
}

test_chmod_invalid_mode_format() {
    setup_chmod_test
    
    local test_file="invalid_mode.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test with invalid mode format
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "999" "$test_file"
    
    assert_failure "chmod should fail with invalid octal mode"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "invalid mode" "error should mention invalid mode"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_invalid_symbolic_mode() {
    setup_chmod_test
    
    local test_file="invalid_symbolic.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test with invalid symbolic mode
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "u+q" "$test_file"
    
    assert_failure "chmod should fail with invalid symbolic mode"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "invalid mode" "error should mention invalid mode"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_no_arguments() {
    setup_chmod_test
    
    # Test with no arguments
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure
    
    assert_failure "chmod should fail with no arguments"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "missing operand" "error should mention missing operand"
}

test_chmod_missing_file_arguments() {
    setup_chmod_test
    
    # Test with mode but no files
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "755"
    
    assert_failure "chmod should fail with mode but no files"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "missing operand" "error should mention missing file operand"
}

test_chmod_invalid_reference_file() {
    setup_chmod_test
    
    local target_file="target.txt"
    local nonexistent_ref="nonexistent_ref.txt"
    create_test_file_with_perms "$target_file" "644"
    
    # Test with non-existent reference file
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure --reference="$nonexistent_ref" "$target_file"
    
    assert_failure "chmod should fail with non-existent reference file"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "$nonexistent_ref" "error should mention reference file"
    
    cleanup_with_permissions "$target_file"
}

test_chmod_invalid_flag() {
    setup_chmod_test
    
    local test_file="invalid_flag.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test with invalid flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure --nonexistent-flag "$test_file"
    
    assert_failure "chmod should fail with invalid flag"
    assert_output_contains "invalid argument" "error should mention invalid argument"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_permission_denied_change() {
    setup_chmod_test
    
    # Skip if not privileged (can't properly test permission scenarios)
    if ! is_privileged; then
        skip_test "permission denied test" "requires privileges for proper permission testing"
        return 0
    fi
    
    local restricted_dir="restricted_dir"
    local restricted_file="$restricted_dir/restricted.txt"
    
    create_test_dir_with_perms "$restricted_dir" "755"
    create_test_file_with_perms "$restricted_file" "644"
    
    # Remove write permission from parent directory to make file unchangeable
    chmod 555 "$restricted_dir" 2>/dev/null || true
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "777" "$restricted_file"
    
    assert_failure "chmod should fail when permission denied"
    assert_output_contains "chmod:" "error should include program name"
    
    # Cleanup - restore permissions
    chmod 755 "$restricted_dir" 2>/dev/null || true
    cleanup_with_permissions "$restricted_dir"
}

test_chmod_too_many_args_reference() {
    setup_chmod_test
    
    local ref_file="ref.txt"
    local target1="target1.txt"
    local target2="target2.txt"
    
    create_test_file_with_perms "$ref_file" "755"
    create_test_file_with_perms "$target1" "644"
    create_test_file_with_perms "$target2" "644"
    
    # Reference can work with multiple targets - this should succeed
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --reference="$ref_file" "$target1" "$target2"
    
    assert_success "chmod --reference should work with multiple targets"
    
    cleanup_with_permissions "$ref_file" "$target1" "$target2"
}

test_chmod_conflicting_flags() {
    setup_chmod_test
    
    local test_file="conflict.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test potentially conflicting flags (but they should work together)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -vf "755" "$test_file"
    
    assert_success "chmod should handle potentially conflicting flags gracefully"
    
    cleanup_with_permissions "$test_file"
}

# =============================================================================
# Help and Version Tests (3 tests)
# =============================================================================

test_chmod_help() {
    setup_chmod_test
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --help
    
    assert_success "chmod --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "chmod" "help should mention chmod"
    assert_output_contains -- "-R" "help should document -R flag"
    assert_output_contains -- "-v" "help should document -v flag"
    assert_output_contains "recursive" "help should mention recursive functionality"
    assert_output_contains "permissions" "help should mention permissions"
}

test_chmod_version() {
    setup_chmod_test
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --version
    
    assert_success "chmod --version should succeed"
    assert_output_contains "chmod" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

test_chmod_short_help() {
    setup_chmod_test
    
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -h
    
    assert_success "chmod -h should succeed"
    assert_output_contains "Usage:" "short help should contain usage information"
}

# =============================================================================
# Advanced Feature Tests (12 tests)
# =============================================================================

test_chmod_reference_with_verbose() {
    setup_chmod_test
    
    local ref_file="ref_verbose.txt"
    local target_file="target_verbose.txt"
    
    create_test_file_with_perms "$ref_file" "751"
    create_test_file_with_perms "$target_file" "644"
    
    # Test reference with verbose output
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v --reference="$ref_file" "$target_file"
    
    assert_success "chmod --reference -v should succeed"
    assert_output_contains "$target_file" "verbose output should show target file"
    assert_output_contains "751" "verbose output should show reference permissions"
    assert_equals "true" "$(verify_permissions "$target_file" "751" && echo true || echo false)" "target should match reference"
    
    cleanup_with_permissions "$ref_file" "$target_file"
}

test_chmod_reference_with_changes() {
    setup_chmod_test
    
    local ref_file="ref_changes.txt"
    local target_file="target_changes.txt"
    local unchanged_file="unchanged.txt"
    
    create_test_file_with_perms "$ref_file" "755"
    create_test_file_with_perms "$target_file" "644"
    create_test_file_with_perms "$unchanged_file" "755"
    
    # Test reference with changes flag
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -c --reference="$ref_file" "$target_file" "$unchanged_file"
    
    assert_success "chmod --reference -c should succeed"
    assert_output_contains "$target_file" "changes output should show changed file"
    assert_output_not_contains "$unchanged_file" "changes output should not show unchanged file"
    
    cleanup_with_permissions "$ref_file" "$target_file" "$unchanged_file"
}

test_chmod_recursive_with_reference() {
    setup_chmod_test
    
    local ref_file="recursive_ref.txt"
    local test_dir="recursive_ref_test"
    local sub_file="$test_dir/sub.txt"
    
    create_test_file_with_perms "$ref_file" "750"
    create_test_dir_with_perms "$test_dir" "755"
    create_test_file_with_perms "$sub_file" "644"
    
    # Test recursive with reference
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -R --reference="$ref_file" "$test_dir"
    
    assert_success "chmod -R --reference should succeed"
    assert_equals "true" "$(verify_permissions "$test_dir" "750" && echo true || echo false)" "directory should match reference"
    assert_equals "true" "$(verify_permissions "$sub_file" "750" && echo true || echo false)" "subdirectory file should match reference"
    
    cleanup_with_permissions "$ref_file" "$test_dir"
}

test_chmod_recursive_symbolic_operations() {
    setup_chmod_test
    
    local test_dir="recursive_symbolic"
    local sub_dir="$test_dir/subdir"
    local file1="$test_dir/file1.txt"
    local file2="$sub_dir/file2.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_dir_with_perms "$sub_dir" "755"
    create_test_file_with_perms "$file1" "644"
    create_test_file_with_perms "$file2" "644"
    
    # Recursive symbolic operation
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -R "g+w,o-r" "$test_dir"
    
    assert_success "chmod -R with symbolic should succeed"
    # Initial: 644 (rw-r--r--), g+w,o-r -> 660 (rw-rw----)
    assert_equals "true" "$(verify_permissions "$file1" "660" && echo true || echo false)" "file1 should have symbolic changes applied"
    assert_equals "true" "$(verify_permissions "$file2" "660" && echo true || echo false)" "file2 should have symbolic changes applied"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_preserve_special_bits_symbolic() {
    setup_chmod_test
    
    local test_file="preserve_special.txt"
    create_test_file_with_perms "$test_file" "4755"  # setuid bit set
    
    # Add group write without affecting setuid
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "g+w" "$test_file"
    
    assert_success "chmod symbolic should preserve special bits"
    assert_equals "true" "$(verify_permissions "$test_file" "4775" && echo true || echo false)" "setuid bit should be preserved"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_remove_special_bits_symbolic() {
    setup_chmod_test
    
    local test_file="remove_special.txt"
    create_test_file_with_perms "$test_file" "4755"  # setuid bit set
    
    # Remove setuid bit symbolically
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "u-s" "$test_file"
    
    assert_success "chmod should remove special bits symbolically"
    assert_equals "true" "$(verify_permissions "$test_file" "755" && echo true || echo false)" "setuid bit should be removed"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_multiple_references() {
    setup_chmod_test
    
    local ref_file="multi_ref.txt"
    local target1="multi_target1.txt"
    local target2="multi_target2.txt"
    local target3="multi_target3.txt"
    
    create_test_file_with_perms "$ref_file" "642"
    create_test_file_with_perms "$target1" "644"
    create_test_file_with_perms "$target2" "755"
    create_test_file_with_perms "$target3" "777"
    
    # Apply reference to multiple targets
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --reference="$ref_file" "$target1" "$target2" "$target3"
    
    assert_success "chmod --reference should work with multiple targets"
    assert_equals "true" "$(verify_permissions "$target1" "642" && echo true || echo false)" "target1 should match reference"
    assert_equals "true" "$(verify_permissions "$target2" "642" && echo true || echo false)" "target2 should match reference"
    assert_equals "true" "$(verify_permissions "$target3" "642" && echo true || echo false)" "target3 should match reference"
    
    cleanup_with_permissions "$ref_file" "$target1" "$target2" "$target3"
}

test_chmod_complex_recursive_structure() {
    setup_chmod_test
    
    local base_dir="complex_recursive"
    local level1="$base_dir/level1"
    local level2="$level1/level2"
    local level3="$level2/level3"
    local files=(
        "$base_dir/file0.txt"
        "$level1/file1.txt"
        "$level2/file2.txt"
        "$level3/file3.txt"
    )
    
    create_test_dir_with_perms "$base_dir" "755"
    create_test_dir_with_perms "$level1" "755"
    create_test_dir_with_perms "$level2" "755"
    create_test_dir_with_perms "$level3" "755"
    
    for file in "${files[@]}"; do
        create_test_file_with_perms "$file" "644"
    done
    
    # Recursive change on complex structure
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -R "755" "$base_dir"
    
    assert_success "chmod -R should work on complex structure"
    for file in "${files[@]}"; do
        assert_equals "true" "$(verify_permissions "$file" "755" && echo true || echo false)" "$file should have new permissions"
    done
    
    cleanup_with_permissions "$base_dir"
}

test_chmod_mixed_symbolic_and_octal_error() {
    setup_chmod_test
    
    local test_file="mixed_error.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test with mixed mode format (should fail)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "755,u+x" "$test_file"
    
    assert_failure "chmod should fail with mixed symbolic and octal"
    assert_output_contains "chmod:" "error should include program name"
    assert_output_contains "invalid mode" "error should mention invalid mode"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_verbose_no_changes() {
    setup_chmod_test
    
    local test_file="verbose_no_change.txt"
    create_test_file_with_perms "$test_file" "755"
    
    # Test verbose when no changes made
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v "755" "$test_file"
    
    assert_success "chmod -v should succeed even with no changes"
    assert_output_contains "$test_file" "verbose should show file even when no changes"
    assert_output_contains "755" "verbose should show current permissions"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_changes_vs_verbose_difference() {
    setup_chmod_test
    
    local changed_file="will_change.txt"
    local unchanged_file="no_change.txt"
    
    create_test_file_with_perms "$changed_file" "644"
    create_test_file_with_perms "$unchanged_file" "755"
    
    # Test changes flag behavior
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -c "755" "$changed_file" "$unchanged_file"
    
    assert_success "chmod -c should succeed"
    assert_output_contains "$changed_file" "changes should show changed file"
    assert_output_not_contains "$unchanged_file" "changes should not show unchanged file"
    
    cleanup_with_permissions "$changed_file" "$unchanged_file"
}

test_chmod_all_special_bits_combined() {
    setup_chmod_test
    
    local test_file="all_special.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Set all special bits: setuid + setgid + sticky (7755)
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" "7755" "$test_file"
    
    assert_success "chmod should succeed with all special bits"
    assert_equals "true" "$(verify_permissions "$test_file" "7755" && echo true || echo false)" "file should have all special bits"
    
    cleanup_with_permissions "$test_file"
}

# =============================================================================
# Output Format Tests (8 tests)  
# =============================================================================

test_chmod_verbose_output_format() {
    setup_chmod_test
    
    local test_file="verbose_format.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test verbose output format
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v "755" "$test_file"
    
    assert_success "chmod -v should succeed"
    assert_output_contains "mode of" "verbose should contain 'mode of'"
    assert_output_contains "$test_file" "verbose should show filename"
    assert_output_contains "755" "verbose should show new mode"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_changes_output_format() {
    setup_chmod_test
    
    local test_file="changes_format.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test changes output format
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -c "755" "$test_file"
    
    assert_success "chmod -c should succeed"
    assert_output_contains "mode of" "changes should contain 'mode of'"
    assert_output_contains "$test_file" "changes should show filename"
    assert_output_contains "changed" "changes should indicate change occurred"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_error_message_format() {
    setup_chmod_test
    
    local nonexistent="error_format_test.txt"
    
    # Test error message format
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "755" "$nonexistent"
    
    assert_failure "chmod should fail with non-existent file"
    assert_output_contains "chmod:" "error should start with program name"
    assert_output_contains "$nonexistent" "error should mention the filename"
    assert_output_contains "No such file" "error should be descriptive"
}

test_chmod_multiple_files_verbose() {
    setup_chmod_test
    
    local file1="multi_verbose1.txt"
    local file2="multi_verbose2.txt"
    local file3="multi_verbose3.txt"
    
    create_test_file_with_perms "$file1" "644"
    create_test_file_with_perms "$file2" "755"
    create_test_file_with_perms "$file3" "644"
    
    # Test verbose with multiple files
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v "755" "$file1" "$file2" "$file3"
    
    assert_success "chmod -v should succeed with multiple files"
    assert_output_contains "$file1" "verbose should show file1"
    assert_output_contains "$file2" "verbose should show file2"
    assert_output_contains "$file3" "verbose should show file3"
    
    cleanup_with_permissions "$file1" "$file2" "$file3"
}

test_chmod_recursive_verbose_output() {
    setup_chmod_test
    
    local test_dir="recursive_verbose_out"
    local sub_dir="$test_dir/subdir"
    local file1="$test_dir/file1.txt"
    local file2="$sub_dir/file2.txt"
    
    create_test_dir_with_perms "$test_dir" "755"
    create_test_dir_with_perms "$sub_dir" "755"
    create_test_file_with_perms "$file1" "644"
    create_test_file_with_perms "$file2" "644"
    
    # Test recursive verbose output
    exec_utility chmod --timeout="$RECURSIVE_TIMEOUT" -vR "755" "$test_dir"
    
    assert_success "chmod -vR should succeed"
    assert_output_contains "$test_dir" "recursive verbose should show directory"
    assert_output_contains "$sub_dir" "recursive verbose should show subdirectory"
    assert_output_contains "$file1" "recursive verbose should show file1"
    assert_output_contains "$file2" "recursive verbose should show file2"
    
    cleanup_with_permissions "$test_dir"
}

test_chmod_silent_mode_output() {
    setup_chmod_test
    
    local test_file="silent_output.txt"
    create_test_file_with_perms "$test_file" "644"
    
    # Test that silent mode produces no output
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -f "755" "$test_file"
    
    assert_success "chmod -f should succeed"
    assert_output_empty "silent mode should produce no output"
    
    cleanup_with_permissions "$test_file"
}

test_chmod_mixed_success_failure_output() {
    setup_chmod_test
    
    local good_file="good.txt"
    local bad_file="does_not_exist.txt"
    
    create_test_file_with_perms "$good_file" "644"
    
    # Test mixed success and failure
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" --expect-failure "755" "$good_file" "$bad_file"
    
    assert_failure "chmod should fail when some files don't exist"
    assert_output_contains "$bad_file" "output should mention failed file"
    assert_output_contains "No such file" "output should have descriptive error"
    
    cleanup_with_permissions "$good_file"
}

test_chmod_reference_file_output_format() {
    setup_chmod_test
    
    local ref_file="ref_output.txt"
    local target_file="target_output.txt"
    
    create_test_file_with_perms "$ref_file" "751"
    create_test_file_with_perms "$target_file" "644"
    
    # Test reference with verbose to see output format
    exec_utility chmod --timeout="$CHMOD_TIMEOUT" -v --reference="$ref_file" "$target_file"
    
    assert_success "chmod --reference -v should succeed"
    assert_output_contains "$target_file" "reference verbose should show target"
    assert_output_contains "751" "reference verbose should show permissions"
    
    cleanup_with_permissions "$ref_file" "$target_file"
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework
    
    if ! has_utility "chmod"; then
        print_error "chmod utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "chmod Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests (12 tests)
    test_specs+=("$(make_test_spec "Octal Mode Basic" "test_chmod_octal_mode_basic" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Mode Basic" "test_chmod_symbolic_mode_basic" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Files" "test_chmod_multiple_files" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Directory Basic" "test_chmod_directory_basic" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "All RWX Permissions" "test_chmod_all_rwx_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Remove All Permissions" "test_chmod_remove_all_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Owner Group Other" "test_chmod_owner_group_other" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic User Permissions" "test_chmod_symbolic_user_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Group Permissions" "test_chmod_symbolic_group_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Other Permissions" "test_chmod_symbolic_other_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic All Users" "test_chmod_symbolic_all_users" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Symbolic Operations" "test_chmod_mixed_symbolic_operations" "$CHMOD_TIMEOUT")")
    
    # All Flags Tests (15 tests)
    test_specs+=("$(make_test_spec "Changes Flag (-c)" "test_chmod_changes_flag_short" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Changes Flag (--changes)" "test_chmod_changes_flag_long" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Verbose Flag (-v)" "test_chmod_verbose_flag_short" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Verbose Flag (--verbose)" "test_chmod_verbose_flag_long" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Silent Flag (-f)" "test_chmod_silent_flag_short" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Silent Flag (--silent)" "test_chmod_silent_flag_long" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive Flag (-R)" "test_chmod_recursive_flag_short" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive Flag (--recursive)" "test_chmod_recursive_flag_long" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Reference Flag" "test_chmod_reference_flag" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Flags (-cv)" "test_chmod_combined_flags_cv" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Flags (-vR)" "test_chmod_combined_flags_vR" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Flags (-fR)" "test_chmod_combined_flags_fR" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Long and Short Mixed" "test_chmod_long_and_short_mixed" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "All Flags Combination" "test_chmod_all_flags_combination" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Precedence Order" "test_chmod_flag_precedence_order" "$CHMOD_TIMEOUT")")
    
    # Edge Cases Tests (18 tests)
    test_specs+=("$(make_test_spec "Special Permissions Setuid" "test_chmod_special_permissions_setuid" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Permissions Setgid" "test_chmod_special_permissions_setgid" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Permissions Sticky" "test_chmod_special_permissions_sticky" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Special Setuid" "test_chmod_symbolic_special_setuid" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Special Setgid" "test_chmod_symbolic_special_setgid" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Special Sticky" "test_chmod_symbolic_special_sticky" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty File" "test_chmod_empty_file" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Large File" "test_chmod_large_file" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Filenames" "test_chmod_special_filenames" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Deeply Nested Paths" "test_chmod_deeply_nested_paths" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Already Correct Permissions" "test_chmod_already_correct_permissions" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Changes Flag No Changes" "test_chmod_changes_flag_no_changes" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symbolic Equals Assignment" "test_chmod_symbolic_equals_assignment" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Symbolic Operations" "test_chmod_multiple_symbolic_operations" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Complex Symbolic Classes" "test_chmod_complex_symbolic_with_classes" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive Mixed Content" "test_chmod_recursive_mixed_content" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Zero Length Filename Edge" "test_chmod_zero_length_filename_edge" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Parent Directory Reference" "test_chmod_parent_directory_reference" "$CHMOD_TIMEOUT")")
    
    # Error Conditions Tests (10 tests)
    test_specs+=("$(make_test_spec "Non-existent File" "test_chmod_nonexistent_file" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Mode Format" "test_chmod_invalid_mode_format" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Symbolic Mode" "test_chmod_invalid_symbolic_mode" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Arguments" "test_chmod_no_arguments" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Missing File Arguments" "test_chmod_missing_file_arguments" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Reference File" "test_chmod_invalid_reference_file" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Flag" "test_chmod_invalid_flag" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Permission Denied Change" "test_chmod_permission_denied_change" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Targets with Reference" "test_chmod_too_many_args_reference" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Conflicting Flags" "test_chmod_conflicting_flags" "$CHMOD_TIMEOUT")")
    
    # Help and Version Tests (3 tests)
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_chmod_help" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_chmod_version" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Short Help (-h)" "test_chmod_short_help" "$CHMOD_TIMEOUT")")
    
    # Advanced Feature Tests (12 tests)
    test_specs+=("$(make_test_spec "Reference with Verbose" "test_chmod_reference_with_verbose" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Reference with Changes" "test_chmod_reference_with_changes" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive with Reference" "test_chmod_recursive_with_reference" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive Symbolic Operations" "test_chmod_recursive_symbolic_operations" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Preserve Special Bits Symbolic" "test_chmod_preserve_special_bits_symbolic" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Remove Special Bits Symbolic" "test_chmod_remove_special_bits_symbolic" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple References" "test_chmod_multiple_references" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Complex Recursive Structure" "test_chmod_complex_recursive_structure" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Symbolic Octal Error" "test_chmod_mixed_symbolic_and_octal_error" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Verbose No Changes" "test_chmod_verbose_no_changes" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Changes vs Verbose Difference" "test_chmod_changes_vs_verbose_difference" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "All Special Bits Combined" "test_chmod_all_special_bits_combined" "$CHMOD_TIMEOUT")")
    
    # Output Format Tests (8 tests)
    test_specs+=("$(make_test_spec "Verbose Output Format" "test_chmod_verbose_output_format" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Changes Output Format" "test_chmod_changes_output_format" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Error Message Format" "test_chmod_error_message_format" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Files Verbose" "test_chmod_multiple_files_verbose" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Recursive Verbose Output" "test_chmod_recursive_verbose_output" "$RECURSIVE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Silent Mode Output" "test_chmod_silent_mode_output" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Success Failure Output" "test_chmod_mixed_success_failure_output" "$CHMOD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Reference File Output Format" "test_chmod_reference_file_output_format" "$CHMOD_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$CHMOD_TIMEOUT"
    
    # Set the test file for the runner
    set_test_file "${BASH_SOURCE[0]}"
    
    # Run all tests
    run_test_suite "${test_specs[@]}"
    local suite_result=$?
    
    end_suite
    
    # Print final summary and exit with appropriate code
    print_final_summary
    local final_result=$?
    
    return $(( suite_result != 0 ? suite_result : final_result ))
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi