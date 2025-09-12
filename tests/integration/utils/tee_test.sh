#!/usr/bin/env bash
# Comprehensive integration tests for tee utility
# Tests all flags, edge cases, signals, error handling, and POSIX compliance

set -euo pipefail

# Source the testing framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/lib.sh"

# Test configuration
TEE_TIMEOUT=10

# Test helper functions
setup_tee_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

cleanup_tee_files() {
    local files=("$@")
    for file in "${files[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
}

create_test_input() {
    local content="${1:-test input data}"
    printf "%s" "$content"
}

# Basic functionality tests
test_tee_basic_functionality() {
    setup_tee_test
    
    local input="Hello, tee world!"
    local output_file="test_output.txt"
    
    # Test basic tee functionality: input to stdout and file
    exec_utility tee --timeout=5 --input="$input" "$output_file"
    
    assert_success "tee should succeed with basic usage"
    assert_output_equals "$input" "stdout should contain input"
    assert_file_exists "$output_file" "output file should be created"
    assert_file_contains "$output_file" "$input" "file should contain input"
    
    cleanup_tee_files "$output_file"
}

test_tee_multiple_files() {
    setup_tee_test
    
    local input="Multiple files test"
    local file1="output1.txt"
    local file2="output2.txt"
    local file3="output3.txt"
    
    # Test writing to multiple files
    exec_utility tee --timeout=5 --input="$input" "$file1" "$file2" "$file3"
    
    assert_success "tee should succeed with multiple files"
    assert_output_equals "$input" "stdout should contain input"
    
    for file in "$file1" "$file2" "$file3"; do
        assert_file_exists "$file" "output file $file should exist"
        assert_file_contains "$file" "$input" "$file should contain input"
    done
    
    cleanup_tee_files "$file1" "$file2" "$file3"
}

test_tee_stdin_only() {
    setup_tee_test
    
    local input="Standard output only"
    
    # Test tee without any files (should just copy to stdout)
    exec_utility tee --timeout=5 --input="$input"
    
    assert_success "tee should succeed with no files"
    assert_output_equals "$input" "stdout should contain input"
}

# Append mode tests
test_tee_append_mode() {
    setup_tee_test
    
    local file="append_test.txt"
    local input1="First line"
    local input2="Second line"
    
    # First write
    exec_utility tee --timeout=5 --input="$input1" "$file"
    assert_success "first tee write should succeed"
    assert_file_contains "$file" "$input1" "file should contain first input"
    
    # Second write in append mode
    exec_utility tee --timeout=5 -a --input="$input2" "$file"
    assert_success "tee append should succeed"
    assert_output_equals "$input2" "stdout should contain second input"
    assert_file_contains "$file" "$input1" "file should still contain first input"
    assert_file_contains "$file" "$input2" "file should also contain second input"
    
    # Verify both inputs are in file
    local file_content
    file_content=$(cat "$file")
    assert_equals "${input1}${input2}" "$file_content" "file should contain concatenated content"
    
    cleanup_tee_files "$file"
}

test_tee_append_long_form() {
    setup_tee_test
    
    local file="append_long.txt"
    local input="Test append long form"
    
    # Create initial content
    printf "Initial content" > "$file"
    
    # Use long form --append
    exec_utility tee --timeout=5 --append --input="$input" "$file"
    
    assert_success "tee --append should succeed"
    assert_file_contains "$file" "Initial content" "file should contain initial content"
    assert_file_contains "$file" "$input" "file should contain appended content"
    
    cleanup_tee_files "$file"
}

# Signal handling tests
test_tee_ignore_interrupts() {
    setup_tee_test
    
    # This test is complex to implement safely in a test environment
    # We'll test that the -i flag is accepted and doesn't cause errors
    local input="Interrupt test"
    local file="interrupt_test.txt"
    
    # Test that -i flag is accepted
    exec_utility tee --timeout=5 -i --input="$input" "$file"
    
    assert_success "tee -i should succeed"
    assert_output_equals "$input" "stdout should contain input with -i flag"
    assert_file_exists "$file" "file should be created with -i flag"
    
    cleanup_tee_files "$file"
}

test_tee_ignore_interrupts_long_form() {
    setup_tee_test
    
    local input="Long form interrupt test"
    local file="interrupt_long.txt"
    
    # Test long form --ignore-interrupts
    exec_utility tee --timeout=5 --ignore-interrupts --input="$input" "$file"
    
    assert_success "tee --ignore-interrupts should succeed"
    assert_output_equals "$input" "stdout should contain input"
    assert_file_exists "$file" "file should be created"
    
    cleanup_tee_files "$file"
}

# Error diagnosis tests
test_tee_diagnose_errors() {
    setup_tee_test
    
    local input="Diagnose test"
    local file="diagnose_test.txt"
    
    # Test -p flag (diagnose write errors to non-pipes)
    exec_utility tee --timeout=5 -p --input="$input" "$file"
    
    assert_success "tee -p should succeed with normal file"
    assert_output_equals "$input" "stdout should contain input"
    assert_file_exists "$file" "file should be created with -p flag"
    
    cleanup_tee_files "$file"
}

# Special file handling tests
test_tee_dash_output() {
    setup_tee_test
    
    local input="Dash output test"
    
    # Test using "-" as a filename (should write to stdout twice)
    exec_utility tee --timeout=5 --input="$input" -
    
    assert_success "tee with dash should succeed"
    # Note: output should appear twice (once regular stdout, once from "-" file)
    assert_output_contains "$input" "stdout should contain input"
}

test_tee_special_filenames() {
    setup_tee_test
    
    local input="Special filename test"
    local files=("file with spaces.txt" "file-with-dashes.txt" "file.with.dots.txt")
    
    exec_utility tee --timeout=5 --input="$input" "${files[@]}"
    
    assert_success "tee should handle special filenames"
    
    for file in "${files[@]}"; do
        assert_file_exists "$file" "special filename '$file' should be created"
        assert_file_contains "$file" "$input" "special filename '$file' should contain input"
    done
    
    cleanup_tee_files "${files[@]}"
}

# Binary data tests
test_tee_binary_data() {
    setup_tee_test
    
    local binary_input
    local file="binary_output.txt"
    
    # Create binary input using the binary fixture
    if [[ -f "${TEST_FIXTURES_DIR}/binary.bin" ]]; then
        binary_input=$(cat "${TEST_FIXTURES_DIR}/binary.bin")
    else
        # Fallback: create some binary data
        binary_input=$(printf '\x00\x01\x02\x03\x04\x05\xFF\xFE\xFD')
    fi
    
    # Test binary data handling
    exec_utility tee --timeout=5 --input="$binary_input" "$file"
    
    assert_success "tee should handle binary data"
    assert_file_exists "$file" "binary output file should exist"
    
    # Compare file content with original (using cmp for binary comparison)
    local expected_file="${TEST_TEMP_DIR}/expected_binary.txt"
    printf "%s" "$binary_input" > "$expected_file"
    
    if cmp -s "$file" "$expected_file"; then
        print_debug "✓ Binary data preserved correctly"
    else
        print_error "Binary data not preserved correctly"
        return 1
    fi
    
    cleanup_tee_files "$file" "$expected_file"
}

test_tee_utf8_data() {
    setup_tee_test
    
    local file="utf8_output.txt"
    local utf8_input
    
    # Use UTF-8 fixture if available
    if [[ -f "${TEST_FIXTURES_DIR}/utf8.txt" ]]; then
        utf8_input=$(cat "${TEST_FIXTURES_DIR}/utf8.txt")
    else
        # Fallback UTF-8 content
        utf8_input="UTF-8 test: Café naïve résumé 中文 日本語 🌍🚀"
    fi
    
    exec_utility tee --timeout=5 --input="$utf8_input" "$file"
    
    assert_success "tee should handle UTF-8 data"
    assert_file_exists "$file" "UTF-8 output file should exist"
    assert_file_contains "$file" "UTF-8" "file should contain UTF-8 content"
    
    cleanup_tee_files "$file"
}

# Large data tests
test_tee_large_input() {
    setup_tee_test
    
    local file="large_output.txt"
    local large_input
    
    # Use large fixture or generate large content
    if [[ -f "${TEST_FIXTURES_DIR}/large.txt" ]]; then
        large_input=$(cat "${TEST_FIXTURES_DIR}/large.txt")
    else
        # Generate large content
        large_input=$(printf 'Large data test\n%.0s' {1..1000})
    fi
    
    exec_utility tee --timeout=15 --input="$large_input" "$file"
    
    assert_success "tee should handle large input"
    assert_file_exists "$file" "large output file should exist"
    
    # Check file size is reasonable
    local file_size
    if command -v stat >/dev/null 2>&1; then
        if is_macos; then
            file_size=$(stat -f%z "$file" 2>/dev/null || echo 0)
        else
            file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        fi
        
        assert_greater_than "$file_size" 100 "large file should have reasonable size"
    fi
    
    cleanup_tee_files "$file"
}

# Empty input tests
test_tee_empty_input() {
    setup_tee_test
    
    local file="empty_output.txt"
    
    # Test with empty input
    exec_utility tee --timeout=5 --input="" "$file"
    
    assert_success "tee should handle empty input"
    assert_output_empty "stdout should be empty for empty input"
    assert_file_exists "$file" "output file should still be created"
    
    # Check file is empty
    if [[ ! -s "$file" ]]; then
        print_debug "✓ Empty file created correctly"
    else
        print_error "File should be empty but contains data"
        return 1
    fi
    
    cleanup_tee_files "$file"
}

# Multiline input tests
test_tee_multiline_input() {
    setup_tee_test
    
    local file="multiline_output.txt"
    local multiline_input
    
    if [[ -f "${TEST_FIXTURES_DIR}/multiline.txt" ]]; then
        multiline_input=$(cat "${TEST_FIXTURES_DIR}/multiline.txt")
    else
        multiline_input=$'Line 1\nLine 2\nLine 3\nLine 4'
    fi
    
    exec_utility tee --timeout=5 --input="$multiline_input" "$file"
    
    assert_success "tee should handle multiline input"
    assert_file_exists "$file" "multiline output file should exist"
    assert_file_contains "$file" "Line 1" "file should contain first line"
    assert_file_contains "$file" "Line 2" "file should contain second line"
    
    # Count lines in output
    local line_count
    line_count=$(printf "%s" "$multiline_input" | wc -l)
    local file_line_count
    file_line_count=$(wc -l < "$file")
    
    # Note: wc -l counts newlines, so adjust for content without final newline
    if [[ "$multiline_input" == *$'\n' ]]; then
        assert_equals "$line_count" "$file_line_count" "file should have same line count as input"
    else
        # If input doesn't end with newline, file might have same or one more line
        assert_greater_or_equal "$((line_count + 1))" "$file_line_count" "file line count should be reasonable"
    fi
    
    cleanup_tee_files "$file"
}

# Error condition tests
test_tee_readonly_directory() {
    setup_tee_test
    
    # Skip if not privileged (can't test proper permission denied scenarios)
    if ! is_privileged; then
        skip_test "readonly directory test" "requires privileges to test permission denied"
        return 0
    fi
    
    local readonly_dir="readonly_test"
    local file="$readonly_dir/output.txt"
    
    mkdir -p "$readonly_dir"
    chmod 444 "$readonly_dir" 2>/dev/null || true
    
    local input="Permission test"
    
    # This should fail due to permission denied
    exec_utility tee --timeout=5 --expect-failure --input="$input" "$file"
    
    assert_failure "tee should fail with permission denied"
    
    # Cleanup
    chmod 755 "$readonly_dir" 2>/dev/null || true
    rm -rf "$readonly_dir" 2>/dev/null || true
}

test_tee_nonexistent_directory() {
    setup_tee_test
    
    local file="nonexistent/output.txt"
    local input="Directory test"
    
    # This should fail because parent directory doesn't exist
    exec_utility tee --timeout=5 --expect-failure --input="$input" "$file"
    
    assert_failure "tee should fail when parent directory doesn't exist"
}

# Help and version tests
test_tee_help() {
    setup_tee_test
    
    exec_utility tee --timeout=5 --help
    
    assert_success "tee --help should succeed"
    assert_output_contains "Usage:" "help should contain usage information"
    assert_output_contains "tee" "help should mention tee"
    assert_output_contains -- "-a" "help should document -a flag"
    assert_output_contains "append" "help should mention append functionality"
}

test_tee_version() {
    setup_tee_test
    
    exec_utility tee --timeout=5 --version
    
    assert_success "tee --version should succeed"
    assert_output_contains "tee" "version should contain program name"
    # Version output format may vary, just ensure it doesn't crash
}

test_tee_short_help() {
    setup_tee_test
    
    exec_utility tee --timeout=5 -h
    
    assert_success "tee -h should succeed"
    assert_output_contains "Usage:" "short help should contain usage information"
}

# Flag combination tests
test_tee_combined_flags() {
    setup_tee_test
    
    local file="combined_flags.txt"
    local input="Combined flags test"
    
    # Create initial content for append test
    printf "Initial: " > "$file"
    
    # Test combining -a, -i, and -p flags
    exec_utility tee --timeout=5 -aip --input="$input" "$file"
    
    assert_success "tee should handle combined flags"
    assert_output_equals "$input" "stdout should contain input"
    assert_file_contains "$file" "Initial:" "file should contain initial content"
    assert_file_contains "$file" "$input" "file should contain appended content"
    
    cleanup_tee_files "$file"
}

test_tee_mixed_flag_formats() {
    setup_tee_test
    
    local file="mixed_flags.txt"
    local input="Mixed flags test"
    
    # Test mixing short and long flags
    exec_utility tee --timeout=5 -a --ignore-interrupts -p --input="$input" "$file"
    
    assert_success "tee should handle mixed flag formats"
    assert_output_equals "$input" "stdout should contain input"
    assert_file_exists "$file" "file should be created"
    
    cleanup_tee_files "$file"
}

# Edge case tests
test_tee_very_long_filename() {
    setup_tee_test
    
    # Create a very long filename (but within reasonable filesystem limits)
    local long_name
    long_name="very_long_filename_$(printf 'a%.0s' {1..50}).txt"
    local input="Long filename test"
    
    exec_utility tee --timeout=5 --input="$input" "$long_name"
    
    assert_success "tee should handle long filenames"
    assert_file_exists "$long_name" "file with long name should be created"
    assert_file_contains "$long_name" "$input" "long filename file should contain input"
    
    cleanup_tee_files "$long_name"
}

test_tee_many_files() {
    setup_tee_test
    
    local input="Many files test"
    local files=()
    
    # Create array of many files
    for i in {1..10}; do
        files+=("output_${i}.txt")
    done
    
    exec_utility tee --timeout=5 --input="$input" "${files[@]}"
    
    assert_success "tee should handle many files"
    assert_output_equals "$input" "stdout should contain input"
    
    # Verify all files were created and contain input
    for file in "${files[@]}"; do
        assert_file_exists "$file" "file $file should exist"
        assert_file_contains "$file" "$input" "file $file should contain input"
    done
    
    cleanup_tee_files "${files[@]}"
}

# Invalid option tests
test_tee_invalid_flag() {
    setup_tee_test
    
    local input="Invalid flag test"
    
    exec_utility tee --timeout=5 --expect-failure --input="$input" --invalid-flag
    
    assert_failure "tee should fail with invalid flag"
}

test_tee_unknown_short_flag() {
    setup_tee_test
    
    local input="Unknown flag test"
    
    exec_utility tee --timeout=5 --expect-failure --input="$input" -z
    
    assert_failure "tee should fail with unknown short flag"
}

# Performance and stress tests
test_tee_rapid_small_writes() {
    setup_tee_test
    
    local file="rapid_writes.txt"
    local input=""
    
    # Generate many small writes
    for i in {1..100}; do
        input="${input}Line ${i}\n"
    done
    
    exec_utility tee --timeout=10 --input="$input" "$file"
    
    assert_success "tee should handle rapid small writes"
    assert_file_exists "$file" "rapid writes output file should exist"
    assert_file_contains "$file" "Line 1" "file should contain first line"
    assert_file_contains "$file" "Line 100" "file should contain last line"
    
    cleanup_tee_files "$file"
}

# Main test execution
main() {
    init_framework
    
    if ! has_utility "tee"; then
        print_error "tee utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    start_suite "tee Integration Tests"
    
    # Define all tests with their functions
    local -a test_specs=()
    test_specs+=("$(make_test_spec "Basic Functionality" "test_tee_basic_functionality" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiple Files" "test_tee_multiple_files" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Stdin Only" "test_tee_stdin_only" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Append Mode (-a)" "test_tee_append_mode" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Append Long Form (--append)" "test_tee_append_long_form" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignore Interrupts (-i)" "test_tee_ignore_interrupts" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Ignore Interrupts Long Form" "test_tee_ignore_interrupts_long_form" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Diagnose Errors (-p)" "test_tee_diagnose_errors" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Dash Output (-)" "test_tee_dash_output" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Special Filenames" "test_tee_special_filenames" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Binary Data" "test_tee_binary_data" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "UTF-8 Data" "test_tee_utf8_data" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Large Input" "test_tee_large_input" 20)")
    test_specs+=("$(make_test_spec "Empty Input" "test_tee_empty_input" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Multiline Input" "test_tee_multiline_input" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Readonly Directory" "test_tee_readonly_directory" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Nonexistent Directory" "test_tee_nonexistent_directory" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Help Output (--help)" "test_tee_help" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Version Output (--version)" "test_tee_version" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Short Help (-h)" "test_tee_short_help" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Combined Flags" "test_tee_combined_flags" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Mixed Flag Formats" "test_tee_mixed_flag_formats" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Very Long Filename" "test_tee_very_long_filename" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Many Files" "test_tee_many_files" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Invalid Flag" "test_tee_invalid_flag" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Unknown Short Flag" "test_tee_unknown_short_flag" "$TEE_TIMEOUT")")
    test_specs+=("$(make_test_spec "Rapid Small Writes" "test_tee_rapid_small_writes" 15)")
    
    # Initialize test runner with parallel execution
    init_test_runner --jobs 2 --timeout "$TEE_TIMEOUT"
    
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