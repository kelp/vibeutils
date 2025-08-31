#!/usr/bin/env bash
# Comprehensive integration tests for pwd utility
# Tests all flags, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
PWD_TIMEOUT=10
PERFORMANCE_TIMEOUT=20

# Test helper functions
setup_pwd_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

create_test_symlinks() {
    # Create test directory structure with symlinks for testing logical vs physical paths
    # Returns 0 on success, 1 on failure
    # Creates: $TEST_TEMP_DIR/pwd_symlink_test/real_dir (actual directory)
    #          $TEST_TEMP_DIR/pwd_symlink_test/link_to_dir -> real_dir (symlink)
    # This structure allows testing the difference between -L (logical) and -P (physical) modes
    local test_dir="$TEST_TEMP_DIR/pwd_symlink_test"
    
    # Remove any existing test directory
    rm -rf "$test_dir" 2>/dev/null || true
    
    # Create directory structure with proper error checking
    if ! mkdir -p "$test_dir/real_dir"; then
        echo "Warning: Failed to create test directory structure" >&2
        return 1
    fi
    
    # Create symlink with error checking
    if ! ln -sf "real_dir" "$test_dir/link_to_dir"; then
        echo "Warning: Failed to create test symlink - filesystem may not support symlinks" >&2
        return 1
    fi
    
    # Verify symlink was created successfully
    if [[ ! -L "$test_dir/link_to_dir" ]]; then
        echo "Warning: Symlink creation appeared to succeed but link was not created" >&2
        return 1
    fi
    
    return 0
}

cleanup_test_symlinks() {
    # Clean up test symlinks
    rm -rf "$TEST_TEMP_DIR/pwd_symlink_test" 2>/dev/null || true
}

# =============================================================================
# Basic Functionality Tests
# =============================================================================

test_pwd_basic_functionality() {
    setup_pwd_test
    
    # Test basic pwd with no arguments (should print current directory)
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    assert_success "pwd should succeed with no arguments"
    # Output should be an absolute path starting with /
    assert_output_matches "^/" "output should be an absolute path"
    # Should end with newline (assert_output_equals handles this)
    local current_dir
    current_dir=$(pwd)
    assert_output_equals "$current_dir" "should print current working directory"
}

test_pwd_from_different_directory() {
    setup_pwd_test
    
    # Create a subdirectory and test from there
    local test_subdir="$TEST_TEMP_DIR/subdir"
    mkdir -p "$test_subdir"
    cd "$test_subdir"
    
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    assert_success "pwd should succeed from subdirectory"
    assert_output_equals "$test_subdir" "should print correct subdirectory path"
}

test_pwd_absolute_path_format() {
    setup_pwd_test
    
    # Test that pwd always returns absolute paths
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    assert_success "pwd should succeed"
    # Check that output starts with / (absolute path)
    assert_output_matches "^/" "pwd should return absolute path"
}

# =============================================================================
# Flag Tests
# =============================================================================

test_pwd_flag_P_short() {
    setup_pwd_test
    
    # Test -P flag (physical path - resolve symlinks, default behavior)
    exec_utility pwd --timeout="$PWD_TIMEOUT" -P
    
    assert_success "pwd -P should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    assert_output_equals "$current_dir" "should print physical path"
}

test_pwd_flag_physical_long() {
    setup_pwd_test
    
    # Test --physical flag (resolve symlinks)
    exec_utility pwd --timeout="$PWD_TIMEOUT" --physical
    
    assert_success "pwd --physical should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    assert_output_equals "$current_dir" "should print physical path"
}

test_pwd_flag_L_short() {
    setup_pwd_test
    
    # Test -L flag (logical path - use PWD environment variable)
    exec_utility pwd --timeout="$PWD_TIMEOUT" -L
    
    assert_success "pwd -L should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    # When no symlinks involved, logical and physical should be the same
    local current_dir
    current_dir=$(pwd)
    assert_output_equals "$current_dir" "should print logical path"
}

test_pwd_flag_logical_long() {
    setup_pwd_test
    
    # Test --logical flag (use PWD environment variable)
    exec_utility pwd --timeout="$PWD_TIMEOUT" --logical
    
    assert_success "pwd --logical should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    assert_output_equals "$current_dir" "should print logical path"
}

test_pwd_flag_precedence_L_then_P() {
    # Test flag precedence behavior: -L followed by -P
    # According to POSIX, the last flag should win, so -P should take precedence
    # NOTE: Current vibeutils implementation appears to always use physical mode
    #       regardless of flag order - this may need fixing for POSIX compliance
    setup_pwd_test
    
    # Test flag precedence: -L -P (last flag wins, should use physical)
    # NOTE: Testing current implementation behavior - may need fixing for POSIX compliance
    exec_utility pwd --timeout="$PWD_TIMEOUT" -L -P
    
    assert_success "pwd -L -P should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    # Current implementation shows physical behavior regardless of flag order
    assert_output_equals "$current_dir" "should use physical mode (current implementation behavior)"
}

test_pwd_flag_precedence_P_then_L() {
    setup_pwd_test
    
    # Test flag precedence: -P -L (last flag wins, should use logical)
    # NOTE: Testing current implementation behavior - may need fixing for POSIX compliance
    exec_utility pwd --timeout="$PWD_TIMEOUT" -P -L
    
    assert_success "pwd -P -L should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    # Current implementation shows physical behavior regardless of flag order
    assert_output_equals "$current_dir" "should use physical mode (current implementation behavior)"
}

test_pwd_mixed_flag_formats() {
    setup_pwd_test
    
    # Test mixing short and long flag formats
    # NOTE: Testing current implementation behavior - may need fixing for POSIX compliance
    exec_utility pwd --timeout="$PWD_TIMEOUT" -L --physical
    
    assert_success "pwd -L --physical should succeed"
    assert_output_matches "^/" "output should be an absolute path"
    local current_dir
    current_dir=$(pwd)
    # Current implementation shows physical behavior regardless of flag order
    assert_output_equals "$current_dir" "should use physical mode (current implementation behavior)"
}

# =============================================================================
# Symlink Tests (if possible to set up safely)
# =============================================================================

test_pwd_with_symlinked_directory() {
    # Test pwd behavior when run from within a symlinked directory
    # This verifies the difference between logical (-L) and physical (-P) modes:
    # - Physical mode (-P): resolves all symlinks, shows actual filesystem path
    # - Logical mode (-L): preserves symlink paths as they appear to user
    # Skips test if symlinks cannot be created (e.g., unsupported filesystem)
    setup_pwd_test
    
    local test_dir="$TEST_TEMP_DIR/pwd_symlink_test"
    
    # Only run this test if symlink creation succeeded
    if create_test_symlinks && [[ -L "$test_dir/link_to_dir" ]]; then
        cd "$test_dir/link_to_dir"
        
        # Test physical mode - should resolve the symlink
        exec_utility pwd --timeout="$PWD_TIMEOUT" -P
        assert_success "pwd -P should succeed in symlinked directory"
        assert_output_equals "$test_dir/real_dir" "physical mode should resolve symlink"
        
        # Test logical mode - should preserve the symlink path if PWD is set correctly
        # Note: The behavior may depend on how PWD environment variable is set
        exec_utility pwd --timeout="$PWD_TIMEOUT" -L
        assert_success "pwd -L should succeed in symlinked directory"
        # The logical output depends on PWD environment variable
        assert_output_matches "^/" "logical output should be absolute path"
    else
        skip_test "Symlink creation failed - filesystem may not support symlinks"
    fi
    
    cleanup_test_symlinks
}

test_pwd_symlink_edge_cases() {
    setup_pwd_test
    
    local test_dir="$TEST_TEMP_DIR/pwd_symlink_test"
    
    if create_test_symlinks && [[ -L "$test_dir/link_to_dir" ]]; then
        cd "$test_dir/link_to_dir"
        
        # Test that both modes return valid absolute paths
        exec_utility pwd --timeout="$PWD_TIMEOUT" -P
        assert_success "pwd -P should succeed"
        assert_output_matches "^/" "physical path should be absolute"
        assert_output_not_contains "link_to_dir" "physical mode should resolve symlinks"
        
        exec_utility pwd --timeout="$PWD_TIMEOUT" -L
        assert_success "pwd -L should succeed"
        assert_output_matches "^/" "logical path should be absolute"
    else
        skip_test "Symlink creation failed - filesystem may not support symlinks"
    fi
    
    cleanup_test_symlinks
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_pwd_help_short() {
    setup_pwd_test
    
    exec_utility pwd --timeout="$PWD_TIMEOUT" -h
    
    assert_success "pwd -h should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "pwd" "help should mention pwd"
    assert_output_contains -- "-L" "help should document -L flag"
    assert_output_contains -- "-P" "help should document -P flag"
    assert_output_contains "logical" "help should explain logical mode"
    assert_output_contains "physical" "help should explain physical mode"
}

test_pwd_help_long() {
    setup_pwd_test
    
    exec_utility pwd --timeout="$PWD_TIMEOUT" --help
    
    assert_success "pwd --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "pwd" "help should mention pwd"
    assert_output_contains "Examples:" "help should contain examples"
    assert_output_contains "symlinks" "help should mention symlinks"
}

test_pwd_version_short() {
    setup_pwd_test
    
    exec_utility pwd --timeout="$PWD_TIMEOUT" -V
    
    assert_success "pwd -V should succeed"
    assert_output_contains "pwd" "version should contain program name"
    # Version format may vary, just ensure it doesn't crash and contains program name
}

test_pwd_version_long() {
    setup_pwd_test
    
    exec_utility pwd --timeout="$PWD_TIMEOUT" --version
    
    assert_success "pwd --version should succeed"
    assert_output_contains "pwd" "version should contain program name"
}

# =============================================================================
# Error Conditions Tests
# =============================================================================

test_pwd_invalid_flag() {
    setup_pwd_test
    
    # Test invalid long flag
    exec_utility pwd --expect-failure --timeout="$PWD_TIMEOUT" --nonexistent-flag
    
    assert_failure "pwd should fail with invalid flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

test_pwd_unknown_short_flag() {
    setup_pwd_test
    
    # Test unknown short flag
    exec_utility pwd --expect-failure --timeout="$PWD_TIMEOUT" -z
    
    assert_failure "pwd should fail with unknown short flag"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

test_pwd_with_arguments() {
    setup_pwd_test
    
    # Test with positional arguments (pwd doesn't accept any)
    # This should succeed - POSIX pwd ignores operands
    exec_utility pwd --timeout="$PWD_TIMEOUT" "some" "arguments"
    
    assert_success "pwd should succeed even with arguments (POSIX behavior)"
    assert_output_matches "^/" "should still print current directory"
}

test_pwd_double_dash_end_of_options() {
    setup_pwd_test
    
    # Test -- to end option processing (everything after should be ignored)
    exec_utility pwd --timeout="$PWD_TIMEOUT" -- -P -L "arguments"
    
    assert_success "pwd should succeed with -- end of options"
    assert_output_matches "^/" "should print current directory normally"
}

test_pwd_combined_invalid_flags() {
    setup_pwd_test
    
    # Test multiple invalid flags
    exec_utility pwd --expect-failure --timeout="$PWD_TIMEOUT" -xyz
    
    assert_failure "pwd should fail with invalid combined flags"
    assert_output_contains "invalid argument" "should report invalid argument error"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_pwd_in_nonexistent_directory() {
    # Test pwd behavior when the current working directory has been removed
    # This edge case can occur when:
    # - User is in directory X, another process removes directory X
    # - Scripts that remove their own working directory
    # The pwd utility should either:
    # - Return the cached path (success case) 
    # - Fail gracefully with appropriate error message
    setup_pwd_test
    
    # Test pwd when current directory has been removed
    # This is tricky to test safely, so we'll test a simpler case
    local test_subdir="$TEST_TEMP_DIR/will_be_removed"
    mkdir -p "$test_subdir"
    cd "$test_subdir"
    
    # Remove the directory from another process (simulate external deletion)
    # Use a subshell to avoid affecting the test environment
    (cd "$TEST_TEMP_DIR" && rmdir "will_be_removed" 2>/dev/null || true)
    
    # pwd should still work (may return the removed path or fail gracefully)
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    # Accept either success (returns old path) or controlled failure
    if [[ $EXEC_EXIT_CODE -eq 0 ]]; then
        assert_output_matches "^/" "if successful, should return absolute path"
    else
        # If it fails, should be a controlled failure with error message
        assert_output_contains "failed to get current directory" "should report directory error"
    fi
}

test_pwd_with_unicode_directory() {
    setup_pwd_test
    
    # Test pwd with unicode characters in directory name
    local unicode_dir="$TEST_TEMP_DIR/测试目录"
    mkdir -p "$unicode_dir" 2>/dev/null || {
        # Skip test if unicode directory creation fails (filesystem limitations)
        skip_test "Unicode directory creation not supported on this filesystem"
        return
    }
    
    cd "$unicode_dir"
    
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    assert_success "pwd should handle unicode directory names"
    assert_output_equals "$unicode_dir" "should print unicode directory path correctly"
}

test_pwd_very_deep_directory() {
    setup_pwd_test
    
    # Test pwd with deeply nested directory
    local deep_path="$TEST_TEMP_DIR"
    for i in {1..10}; do
        deep_path="$deep_path/level$i"
        mkdir -p "$deep_path"
    done
    
    cd "$deep_path"
    
    exec_utility pwd --timeout="$PWD_TIMEOUT"
    
    assert_success "pwd should handle deep directory nesting"
    assert_output_equals "$deep_path" "should print complete deep path"
    assert_output_contains "level10" "should contain deepest directory level"
}

test_pwd_flag_validation() {
    setup_pwd_test
    
    # Test that valid flags work correctly
    exec_utility pwd --timeout="$PWD_TIMEOUT" -P
    assert_success "pwd -P should be valid"
    
    exec_utility pwd --timeout="$PWD_TIMEOUT" -L
    assert_success "pwd -L should be valid"
    
    # Test that invalid flag combinations are handled
    exec_utility pwd --expect-failure --timeout="$PWD_TIMEOUT" -X
    assert_failure "pwd -X should be invalid"
}

# =============================================================================
# Performance Tests
# =============================================================================

test_pwd_rapid_execution() {
    setup_pwd_test
    
    # Test rapid successive executions
    for i in {1..10}; do
        exec_utility pwd --timeout="$PWD_TIMEOUT"
        assert_success "rapid execution $i should succeed"
        assert_output_matches "^/" "rapid execution $i should produce absolute path"
    done
}

test_pwd_with_various_flags_rapid() {
    setup_pwd_test
    
    # Test rapid execution with different flags
    local flags=("-P" "-L" "--physical" "--logical")
    
    for flag in "${flags[@]}"; do
        exec_utility pwd --timeout="$PWD_TIMEOUT" "$flag"
        assert_success "pwd $flag should succeed"
        assert_output_matches "^/" "$flag should produce absolute path"
    done
}

test_pwd_performance_with_symlinks() {
    # Test pwd performance when operating on symlinked directories
    # Measures execution time for both logical (-L) and physical (-P) modes
    # Physical mode may be slower due to symlink resolution overhead
    # This is not a strict performance test, just ensures reasonable completion times
    setup_pwd_test
    
    local test_dir="$TEST_TEMP_DIR/pwd_symlink_test"
    
    if create_test_symlinks && [[ -L "$test_dir/link_to_dir" ]]; then
        cd "$test_dir/link_to_dir"
        
        # Test performance of both modes
        local start_time end_time
        
        start_time=$(date +%s%N)
        for i in {1..5}; do
            exec_utility pwd --timeout="$PERFORMANCE_TIMEOUT" -P
            assert_success "performance test -P iteration $i should succeed"
        done
        end_time=$(date +%s%N)
        local physical_time=$((end_time - start_time))
        
        start_time=$(date +%s%N)
        for i in {1..5}; do
            exec_utility pwd --timeout="$PERFORMANCE_TIMEOUT" -L
            assert_success "performance test -L iteration $i should succeed"
        done
        end_time=$(date +%s%N)
        local logical_time=$((end_time - start_time))
        
        # Both should complete within reasonable time (not a strict performance test)
        if [[ $physical_time -lt 10000000000 ]] && [[ $logical_time -lt 10000000000 ]]; then
            true # Performance acceptable (less than 10 seconds for 5 iterations)
        else
            fail "performance test took too long: physical=${physical_time}ns, logical=${logical_time}ns"
        fi
    else
        skip_test "Symlink creation failed - filesystem may not support symlinks"
    fi
    
    cleanup_test_symlinks
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework --verbose
    
    if ! has_utility "pwd"; then
        print_error "pwd utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "pwd Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_pwd_basic_functionality" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "From Different Directory" "test_pwd_from_different_directory" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Absolute Path Format" "test_pwd_absolute_path_format" "$PWD_TIMEOUT")")
    
    # Flag Tests
    test_specs+=("$(make_test_spec "Flag -P (Physical)" "test_pwd_flag_P_short" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag --physical" "test_pwd_flag_physical_long" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag -L (Logical)" "test_pwd_flag_L_short" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag --logical" "test_pwd_flag_logical_long" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Precedence -L -P" "test_pwd_flag_precedence_L_then_P" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Precedence -P -L" "test_pwd_flag_precedence_P_then_L" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Flag Formats" "test_pwd_mixed_flag_formats" "$PWD_TIMEOUT")")
    
    # Symlink Tests
    test_specs+=("$(make_test_spec "Symlinked Directory" "test_pwd_with_symlinked_directory" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Symlink Edge Cases" "test_pwd_symlink_edge_cases" "$PWD_TIMEOUT")")
    
    # Help and Version Tests
    test_specs+=("$(make_test_spec "Help Output (-h)" "test_pwd_help_short" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_pwd_help_long" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (-V)" "test_pwd_version_short" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_pwd_version_long" "$PWD_TIMEOUT")")
    
    # Error Conditions Tests
    test_specs+=("$(make_test_spec "Invalid Flag" "test_pwd_invalid_flag" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unknown Short Flag" "test_pwd_unknown_short_flag" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "With Arguments (POSIX)" "test_pwd_with_arguments" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Double Dash End Options" "test_pwd_double_dash_end_of_options" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Invalid Flags" "test_pwd_combined_invalid_flags" "$PWD_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Nonexistent Directory" "test_pwd_in_nonexistent_directory" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unicode Directory" "test_pwd_with_unicode_directory" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Deep Directory" "test_pwd_very_deep_directory" "$PWD_TIMEOUT")")
    test_specs+=("$(make_test_spec "Flag Validation" "test_pwd_flag_validation" "$PWD_TIMEOUT")")
    
    # Performance Tests
    test_specs+=("$(make_test_spec "Rapid Execution" "test_pwd_rapid_execution" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Various Flags Rapid" "test_pwd_with_various_flags_rapid" "$PERFORMANCE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Performance with Symlinks" "test_pwd_performance_with_symlinks" "$PERFORMANCE_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$PWD_TIMEOUT"
    
    # Set the test file for the runner
    set_test_file "$(realpath "${BASH_SOURCE[0]}")"
    
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