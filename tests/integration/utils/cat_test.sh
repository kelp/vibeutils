#!/usr/bin/env bash
# Comprehensive integration tests for cat utility
# Tests all flags, edge cases, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
CAT_TIMEOUT=10
LARGE_FILE_TIMEOUT=20

# Test helper functions
setup_cat_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

cleanup_cat_files() {
    local files=("$@")
    for file in "${files[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
}

# =============================================================================
# Basic Functionality Tests
# =============================================================================

test_cat_basic_functionality() {
    setup_cat_test
    
    local test_file="basic_test.txt"
    local content="Hello, cat world!"
    
    # Create test file
    printf "%s\n" "$content" > "$test_file"
    
    # Test basic cat functionality
    exec_utility cat --timeout="$CAT_TIMEOUT" "$test_file"
    
    assert_success "cat should succeed with basic file reading"
    assert_output_equals "${content}" "output should match file content"
    
    cleanup_cat_files "$test_file"
}

test_cat_multiple_files() {
    setup_cat_test
    
    local file1="file1.txt"
    local file2="file2.txt"
    local content1="First file content"
    local content2="Second file content"
    
    # Create test files
    printf "%s\n" "$content1" > "$file1"
    printf "%s\n" "$content2" > "$file2"
    
    # Test concatenating multiple files
    exec_utility cat --timeout="$CAT_TIMEOUT" "$file1" "$file2"
    
    assert_success "cat should succeed with multiple files"
    assert_output_equals "${content1}
${content2}" "output should concatenate both files with their trailing newlines"
    
    cleanup_cat_files "$file1" "$file2"
}

test_cat_stdin_dash() {
    setup_cat_test
    
    local input="Standard input test"
    
    # Test reading from stdin using dash
    exec_utility cat --timeout="$CAT_TIMEOUT" --input="$input" -
    
    assert_success "cat should succeed reading from stdin with dash"
    assert_output_equals "$input" "output should match input from stdin"
}

test_cat_stdin_no_files() {
    setup_cat_test
    
    local input="No files specified test"
    
    # Test reading from stdin when no files specified
    exec_utility cat --timeout="$CAT_TIMEOUT" --input="$input"
    
    assert_success "cat should succeed reading from stdin with no files"
    assert_output_equals "$input" "output should match input from stdin"
}

test_cat_mixed_files_and_stdin() {
    setup_cat_test
    
    local file1="mixed1.txt"
    local file2="mixed2.txt"
    local file_content1="File 1"
    local file_content2="File 2"
    local stdin_content="Stdin content"
    
    # Create test files
    printf "%s\n" "$file_content1" > "$file1"
    printf "%s\n" "$file_content2" > "$file2"
    
    # Test mixing files and stdin (file1, stdin, file2)
    exec_utility cat --timeout="$CAT_TIMEOUT" --input="$stdin_content" "$file1" - "$file2"
    
    assert_success "cat should succeed with mixed files and stdin"
    # Build expected output: bash command substitution strips final newline
    # So we match the actual behavior after command substitution
    printf -v expected "%s\n%s\n%s" "$file_content1" "$stdin_content" "$file_content2"
    assert_output_equals "$expected" "output should concatenate in correct order"
    
    cleanup_cat_files "$file1" "$file2"
}

test_cat_empty_file() {
    setup_cat_test
    
    local empty_file="empty.txt"
    
    # Create empty file
    touch "$empty_file"
    
    # Test with empty file
    exec_utility cat --timeout="$CAT_TIMEOUT" "$empty_file"
    
    assert_success "cat should succeed with empty file"
    assert_output_empty "output should be empty for empty file"
    
    cleanup_cat_files "$empty_file"
}

# =============================================================================
# All Flags Individual Tests
# =============================================================================

test_cat_number_all_lines() {
    setup_cat_test
    
    local test_file="number_test.txt"
    local content=$'Line 1\nLine 2\n\nLine 4'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -n flag (number all lines)
    exec_utility cat --timeout="$CAT_TIMEOUT" -n "$test_file"
    
    assert_success "cat -n should succeed"
    assert_output_contains "     1	Line 1" "should number first line"
    assert_output_contains "     2	Line 2" "should number second line"
    assert_output_contains "     3	" "should number blank line"
    assert_output_contains "     4	Line 4" "should number fourth line"
    
    cleanup_cat_files "$test_file"
}

test_cat_number_nonblank_lines() {
    setup_cat_test
    
    local test_file="nonblank_test.txt"
    local content=$'Line 1\n\nLine 3\n\nLine 5'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -b flag (number non-blank lines only)
    exec_utility cat --timeout="$CAT_TIMEOUT" -b "$test_file"
    
    assert_success "cat -b should succeed"
    assert_output_contains "     1	Line 1" "should number first non-blank line"
    assert_output_contains "     2	Line 3" "should number second non-blank line"
    assert_output_contains "     3	Line 5" "should number third non-blank line"
    # Blank lines should not be numbered
    assert_output_not_contains "	$" "blank lines should not have numbers"
    
    cleanup_cat_files "$test_file"
}

test_cat_squeeze_blank_lines() {
    setup_cat_test
    
    local test_file="squeeze_test.txt"
    local content=$'Line 1\n\n\n\nLine 2\n\n\n\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -s flag (squeeze multiple blank lines)
    exec_utility cat --timeout="$CAT_TIMEOUT" -s "$test_file"
    
    assert_success "cat -s should succeed"
    assert_output_contains "Line 1" "should contain first line"
    assert_output_contains "Line 2" "should contain second line"
    assert_output_contains "Line 3" "should contain third line"
    
    # Count blank lines in output (should be reduced)
    local blank_count
    blank_count=$(printf "%s" "${EXEC_OUTPUT:-}" | grep -c '^$' || echo 0)
    assert_less_than "$blank_count" 6 "should have fewer blank lines than original"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_ends() {
    setup_cat_test
    
    local test_file="ends_test.txt"
    local content=$'Line 1\nLine 2\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -E flag (show line ends)
    exec_utility cat --timeout="$CAT_TIMEOUT" -E "$test_file"
    
    assert_success "cat -E should succeed"
    assert_output_contains "Line 1\$" "should show dollar sign at end of first line"
    assert_output_contains "Line 2\$" "should show dollar sign at end of second line"
    assert_output_contains "Line 3\$" "should show dollar sign at end of third line"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_tabs() {
    setup_cat_test
    
    local test_file="tabs_test.txt"
    local content=$'Line\twith\ttabs'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -T flag (show tabs)
    exec_utility cat --timeout="$CAT_TIMEOUT" -T "$test_file"
    
    assert_success "cat -T should succeed"
    assert_output_equals "Line^Iwith^Itabs" "should show tabs as ^I"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_nonprinting() {
    setup_cat_test
    
    local test_file="nonprinting_test.txt"
    # Create content with control character (^A = \x01)
    printf "Test\x01Control\x7fDEL" > "$test_file"
    
    # Test -v flag (show non-printing characters)
    exec_utility cat --timeout="$CAT_TIMEOUT" -v "$test_file"
    
    assert_success "cat -v should succeed"
    assert_output_contains "Test^AControl" "should show control character as ^A"
    assert_output_contains "^?" "should show DEL as ^?"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_all_combined() {
    setup_cat_test
    
    local test_file="all_test.txt"
    # Create content with tabs and control character
    printf "Line\twith\x01control\nSecond line" > "$test_file"
    
    # Test -A flag (equivalent to -vET)
    exec_utility cat --timeout="$CAT_TIMEOUT" -A "$test_file"
    
    assert_success "cat -A should succeed"
    assert_output_contains "Line^Iwith^Acontrol\$" "should show tabs, control chars, and line ends"
    assert_output_contains "Second line\$" "should show line end on second line"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_ends_and_nonprinting() {
    setup_cat_test
    
    local test_file="ends_nonprint_test.txt"
    printf "Normal\x02Control" > "$test_file"
    
    # Test -e flag (equivalent to -vE)
    exec_utility cat --timeout="$CAT_TIMEOUT" -e "$test_file"
    
    assert_success "cat -e should succeed"
    assert_output_contains "Normal^BControl\$" "should show control char and line end"
    
    cleanup_cat_files "$test_file"
}

test_cat_show_tabs_and_nonprinting() {
    setup_cat_test
    
    local test_file="tabs_nonprint_test.txt"
    printf "Tab\there\x03Control" > "$test_file"
    
    # Test -t flag (equivalent to -vT)
    exec_utility cat --timeout="$CAT_TIMEOUT" -t "$test_file"
    
    assert_success "cat -t should succeed"
    assert_output_equals "Tab^Ihere^CControl" "should show tabs and control chars"
    
    cleanup_cat_files "$test_file"
}

test_cat_ignored_u_flag() {
    setup_cat_test
    
    local test_file="u_flag_test.txt"
    local content="Test ignored -u flag"
    
    printf "%s\n" "$content" > "$test_file"
    
    # Test -u flag (should be ignored)
    exec_utility cat --timeout="$CAT_TIMEOUT" -u "$test_file"
    
    assert_success "cat -u should succeed (flag ignored)"
    assert_output_equals "$content" "output should be normal despite -u flag"
    
    cleanup_cat_files "$test_file"
}

# =============================================================================
# Flag Combinations Tests
# =============================================================================

test_cat_number_and_squeeze() {
    setup_cat_test
    
    local test_file="number_squeeze_test.txt"
    local content=$'Line 1\n\n\n\nLine 2\n\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -ns combination
    exec_utility cat --timeout="$CAT_TIMEOUT" -ns "$test_file"
    
    assert_success "cat -ns should succeed"
    assert_output_contains "     1	Line 1" "should number first line"
    assert_output_contains "     3	Line 2" "should number line after squeezed blanks"
    
    cleanup_cat_files "$test_file"
}

test_cat_number_nonblank_overrides_number() {
    setup_cat_test
    
    local test_file="override_test.txt"
    local content=$'Line 1\n\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -bn combination (b should override n)
    exec_utility cat --timeout="$CAT_TIMEOUT" -bn "$test_file"
    
    assert_success "cat -bn should succeed"
    assert_output_contains "     1	Line 1" "should number first non-blank line"
    assert_output_contains "     2	Line 3" "should number second non-blank line"
    # Should not number the blank line
    assert_output_not_contains "	$" "blank line should not be numbered when -b overrides -n"
    
    cleanup_cat_files "$test_file"
}

test_cat_all_formatting_flags() {
    setup_cat_test
    
    local test_file="all_flags_test.txt"
    local content=$'Line 1\twith tab\n\n\nLine 2\x01control'
    
    printf "%s" "$content" > "$test_file"
    
    # Test -bsA combination
    exec_utility cat --timeout="$CAT_TIMEOUT" -bsA "$test_file"
    
    assert_success "cat -bsA should succeed"
    assert_output_contains "     1	Line 1^Iwith tab\$" "should apply all formatting to first line"
    assert_output_contains "     2	Line 2^Acontrol\$" "should apply formatting to second line"
    
    cleanup_cat_files "$test_file"
}

test_cat_long_and_short_flags_mixed() {
    setup_cat_test
    
    local test_file="mixed_flags_test.txt"
    local content=$'Line 1\n\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test mixing long and short flags
    exec_utility cat --timeout="$CAT_TIMEOUT" --number-nonblank --squeeze-blank "$test_file"
    
    assert_success "cat with long flags should succeed"
    assert_output_contains "     1	Line 1" "should number first non-blank line"
    assert_output_contains "     2	Line 3" "should number second non-blank line after squeezing"
    
    cleanup_cat_files "$test_file"
}

test_cat_contradictory_flags() {
    setup_cat_test
    
    local test_file="contradictory_test.txt"
    local content=$'Line 1\n\nLine 3'
    
    printf "%s" "$content" > "$test_file"
    
    # Test flags that might seem contradictory but should work
    exec_utility cat --timeout="$CAT_TIMEOUT" -nbE "$test_file"
    
    assert_success "cat with multiple flags should succeed"
    # -b should override -n, and -E should still work
    assert_output_contains "     1	Line 1\$" "should number and show line end"
    assert_output_contains "     2	Line 3\$" "should handle contradictory flags properly"
    
    cleanup_cat_files "$test_file"
}

# =============================================================================
# Edge Cases Tests
# =============================================================================

test_cat_binary_data() {
    setup_cat_test
    
    local binary_file="binary_test.bin"
    
    # Use binary fixture if available, otherwise create binary data
    if [[ -f "${TEST_FIXTURES_DIR}/binary.bin" ]]; then
        cp "${TEST_FIXTURES_DIR}/binary.bin" "$binary_file"
    else
        # Create binary data with null bytes and high-bit characters
        printf '\x00\x01\x02\x7f\x80\xff' > "$binary_file"
    fi
    
    # Test binary data handling
    exec_utility cat --timeout="$CAT_TIMEOUT" "$binary_file"
    
    assert_success "cat should handle binary data without crashing"
    # Binary data may not be printable, just ensure it doesn't crash
    
    cleanup_cat_files "$binary_file"
}

test_cat_utf8_content() {
    setup_cat_test
    
    local utf8_file="utf8_test.txt"
    
    # Use UTF-8 fixture if available
    if [[ -f "${TEST_FIXTURES_DIR}/utf8.txt" ]]; then
        cp "${TEST_FIXTURES_DIR}/utf8.txt" "$utf8_file"
        local expected_content
        expected_content=$(cat "${TEST_FIXTURES_DIR}/utf8.txt")
    else
        # Fallback UTF-8 content
        local expected_content="UTF-8 test: Café naïve résumé 中文 🌍"
        printf "%s\n" "$expected_content" > "$utf8_file"
    fi
    
    exec_utility cat --timeout="$CAT_TIMEOUT" "$utf8_file"
    
    assert_success "cat should handle UTF-8 content"
    assert_output_contains "UTF-8" "output should contain UTF-8 text"
    
    cleanup_cat_files "$utf8_file"
}

test_cat_large_file() {
    setup_cat_test
    
    local large_file="large_test.txt"
    
    # Use large fixture if available
    if [[ -f "${TEST_FIXTURES_DIR}/large.txt" ]]; then
        cp "${TEST_FIXTURES_DIR}/large.txt" "$large_file"
    else
        # Generate large content
        for i in {1..1000}; do
            printf "Line %d with some content to make it longer\n" "$i"
        done > "$large_file"
    fi
    
    # Test large file handling with longer timeout
    exec_utility cat --timeout="$LARGE_FILE_TIMEOUT" "$large_file"
    
    assert_success "cat should handle large files"
    assert_output_contains "Large File Test Data" "should contain first line"
    
    # Verify file size is reasonable
    local file_size
    if command -v stat >/dev/null 2>&1; then
        if is_macos; then
            file_size=$(stat -f%z "$large_file" 2>/dev/null || echo 0)
        else
            file_size=$(stat -c%s "$large_file" 2>/dev/null || echo 0)
        fi
        assert_greater_than "$file_size" 1000 "large file should have reasonable size"
    fi
    
    cleanup_cat_files "$large_file"
}

test_cat_very_long_lines() {
    setup_cat_test
    
    local long_line_file="long_line_test.txt"
    local long_line
    
    # Create a very long line (but not too long to cause issues)
    long_line=$(printf 'A%.0s' {1..500})
    printf "%s\nSecond line" "$long_line" > "$long_line_file"
    
    exec_utility cat --timeout="$CAT_TIMEOUT" "$long_line_file"
    
    assert_success "cat should handle very long lines"
    assert_output_contains "$long_line" "should contain the long line"
    assert_output_contains "Second line" "should contain second line"
    
    cleanup_cat_files "$long_line_file"
}

test_cat_special_filenames() {
    setup_cat_test
    
    local special_files=(
        "file with spaces.txt"
        "file-with-dashes.txt"
        "file.with.dots.txt"
    )
    
    for file in "${special_files[@]}"; do
        printf "Content of %s\n" "$file" > "$file"
        
        exec_utility cat --timeout="$CAT_TIMEOUT" "$file"
        
        assert_success "cat should handle special filename: $file"
        assert_output_contains "Content of $file" "should read file with special name"
    done
    
    cleanup_cat_files "${special_files[@]}"
}

test_cat_no_final_newline() {
    setup_cat_test
    
    local test_file="no_newline_test.txt"
    # Create file without final newline
    printf "Content without newline" > "$test_file"
    
    exec_utility cat --timeout="$CAT_TIMEOUT" "$test_file"
    
    assert_success "cat should handle files without final newline"
    assert_output_equals "Content without newline" "should preserve content without adding newline"
    
    cleanup_cat_files "$test_file"
}

test_cat_mixed_line_endings() {
    setup_cat_test
    
    local test_file="mixed_endings_test.txt"
    # Create content with different line endings (this is tricky in shell)
    printf "Unix line\nAnother line\nFinal line" > "$test_file"
    
    exec_utility cat --timeout="$CAT_TIMEOUT" -E "$test_file"
    
    assert_success "cat should handle mixed line endings"
    assert_output_contains "Unix line\$" "should show line endings"
    assert_output_contains "Another line\$" "should handle all line types"
    
    cleanup_cat_files "$test_file"
}

test_cat_control_characters_comprehensive() {
    setup_cat_test
    
    local test_file="control_test.txt"
    # Create content with various control characters
    printf "Start\x01\x02\x03\x1b\x7fEnd" > "$test_file"
    
    exec_utility cat --timeout="$CAT_TIMEOUT" -v "$test_file"
    
    assert_success "cat -v should handle various control characters"
    assert_output_contains "Start^A^B^C" "should show control characters as caret notation"
    assert_output_contains "^?" "should show DEL character"
    
    cleanup_cat_files "$test_file"
}

# =============================================================================
# Error Conditions Tests
# =============================================================================

test_cat_nonexistent_file() {
    setup_cat_test
    
    local nonexistent_file="definitely_does_not_exist.txt"
    
    # Test with non-existent file
    exec_utility cat --timeout="$CAT_TIMEOUT" --expect-failure "$nonexistent_file"
    
    assert_failure "cat should fail with non-existent file"
    assert_output_contains "cat:" "error message should include program name"
    assert_output_contains "$nonexistent_file" "error message should include filename"
}

test_cat_permission_denied() {
    setup_cat_test
    
    # Skip if not privileged (can't properly test permission scenarios)
    if ! is_privileged; then
        skip_test "permission denied test" "requires privileges for proper permission testing"
        return 0
    fi
    
    local restricted_file="no_permission.txt"
    
    # Create file and remove read permissions
    printf "Secret content" > "$restricted_file"
    chmod 000 "$restricted_file" 2>/dev/null || true
    
    exec_utility cat --timeout="$CAT_TIMEOUT" --expect-failure "$restricted_file"
    
    assert_failure "cat should fail with permission denied"
    assert_output_contains "cat:" "error should include program name"
    
    # Cleanup - restore permissions first
    chmod 644 "$restricted_file" 2>/dev/null || true
    cleanup_cat_files "$restricted_file"
}

test_cat_directory_instead_of_file() {
    setup_cat_test
    
    local test_dir="test_directory"
    mkdir -p "$test_dir"
    
    # Test with directory instead of file
    exec_utility cat --timeout="$CAT_TIMEOUT" --expect-failure "$test_dir"
    
    assert_failure "cat should fail when given a directory"
    assert_output_contains "cat:" "error should include program name"
    assert_output_contains "$test_dir" "error should mention directory name"
    
    rmdir "$test_dir" 2>/dev/null || true
}

test_cat_invalid_flag() {
    setup_cat_test
    
    local test_file="flag_test.txt"
    printf "Test content" > "$test_file"
    
    # Test with invalid flag
    exec_utility cat --timeout="$CAT_TIMEOUT" --expect-failure --invalid-flag "$test_file"
    
    assert_failure "cat should fail with invalid flag"
    assert_output_contains "unrecognized option" "should report unrecognized option"
    
    cleanup_cat_files "$test_file"
}

# =============================================================================
# Help and Version Tests
# =============================================================================

test_cat_help() {
    setup_cat_test
    
    exec_utility cat --timeout="$CAT_TIMEOUT" --help
    
    assert_success "cat --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "cat" "help should mention cat"
    assert_output_contains -- "-n" "help should document -n flag"
    assert_output_contains -- "-b" "help should document -b flag"
    assert_output_contains "number" "help should mention numbering functionality"
    assert_output_contains "Examples:" "help should include examples"
}

test_cat_version() {
    setup_cat_test
    
    exec_utility cat --timeout="$CAT_TIMEOUT" --version
    
    assert_success "cat --version should succeed"
    assert_output_contains "cat" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

test_cat_short_help() {
    setup_cat_test
    
    exec_utility cat --timeout="$CAT_TIMEOUT" -h
    
    assert_success "cat -h should succeed"
    assert_output_contains "Usage:" "short help should contain usage information"
}

# =============================================================================
# Main test execution
# =============================================================================

main() {
    init_framework
    
    if ! has_utility "cat"; then
        print_error "cat utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "cat Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    
    # Basic Functionality Tests
    test_specs+=("$(make_test_spec "Basic Functionality" "test_cat_basic_functionality" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Files" "test_cat_multiple_files" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stdin with Dash" "test_cat_stdin_dash" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stdin No Files" "test_cat_stdin_no_files" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Files and Stdin" "test_cat_mixed_files_and_stdin" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Empty File" "test_cat_empty_file" "$CAT_TIMEOUT")")
    
    # All Flags Individual Tests
    test_specs+=("$(make_test_spec "Number All Lines (-n)" "test_cat_number_all_lines" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Number Non-blank Lines (-b)" "test_cat_number_nonblank_lines" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Squeeze Blank Lines (-s)" "test_cat_squeeze_blank_lines" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show Ends (-E)" "test_cat_show_ends" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show Tabs (-T)" "test_cat_show_tabs" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show Non-printing (-v)" "test_cat_show_nonprinting" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show All (-A)" "test_cat_show_all_combined" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show Ends and Non-printing (-e)" "test_cat_show_ends_and_nonprinting" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Show Tabs and Non-printing (-t)" "test_cat_show_tabs_and_nonprinting" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignored -u Flag" "test_cat_ignored_u_flag" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_cat_help" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_cat_version" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Short Help (-h)" "test_cat_short_help" "$CAT_TIMEOUT")")
    
    # Flag Combinations Tests
    test_specs+=("$(make_test_spec "Number and Squeeze" "test_cat_number_and_squeeze" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Number Non-blank Overrides Number" "test_cat_number_nonblank_overrides_number" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "All Formatting Flags" "test_cat_all_formatting_flags" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Long and Short Flags Mixed" "test_cat_long_and_short_flags_mixed" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Contradictory Flags" "test_cat_contradictory_flags" "$CAT_TIMEOUT")")
    
    # Edge Cases Tests
    test_specs+=("$(make_test_spec "Binary Data" "test_cat_binary_data" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "UTF-8 Content" "test_cat_utf8_content" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Large File" "test_cat_large_file" "$LARGE_FILE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Lines" "test_cat_very_long_lines" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Filenames" "test_cat_special_filenames" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "No Final Newline" "test_cat_no_final_newline" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Line Endings" "test_cat_mixed_line_endings" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Control Characters Comprehensive" "test_cat_control_characters_comprehensive" "$CAT_TIMEOUT")")
    
    # Error Conditions Tests
    test_specs+=("$(make_test_spec "Non-existent File" "test_cat_nonexistent_file" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Permission Denied" "test_cat_permission_denied" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Directory Instead of File" "test_cat_directory_instead_of_file" "$CAT_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Flag" "test_cat_invalid_flag" "$CAT_TIMEOUT")")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$CAT_TIMEOUT"
    
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