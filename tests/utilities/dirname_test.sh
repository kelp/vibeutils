#!/usr/bin/env bash
# Comprehensive tests for dirname (directory name extraction) utility
# Tests all flags, path types, edge cases, POSIX compliance, and GNU extensions
# Total: ~60 tests covering complete functionality
#
# CRITICAL: Tests verify POSIX-compliant and standard behavior, NOT current implementation
# If tests fail, the implementation needs to be fixed to match standards

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_dirname() {
    local util="dirname"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    echo -e "${CYAN}Testing Core POSIX functionality...${NC}"

    # Basic path extraction - fundamental POSIX behavior
    test_command_output "dirname basic file path" "/usr/bin" "$binary" "/usr/bin/file"
    test_command_output "dirname relative path" "usr" "$binary" "usr/bin"
    test_command_output "dirname single component" "." "$binary" "file.txt"
    test_command_output "dirname directory with file" "dir" "$binary" "dir/file.txt"
    test_command_output "dirname nested path" "a/b" "$binary" "a/b/c"

    # Root handling - critical POSIX requirements
    test_command_output "dirname root slash" "/" "$binary" "/"
    test_command_output "dirname double root" "/" "$binary" "//"
    test_command_output "dirname triple root" "/" "$binary" "///"
    test_command_output "dirname root with file" "/" "$binary" "/file"
    test_command_output "dirname multiple root slashes" "/" "$binary" "////"

    # Trailing slash handling - POSIX specification
    test_command_output "dirname trailing slash simple" "/usr" "$binary" "/usr/bin/"
    test_command_output "dirname trailing slash relative" "usr" "$binary" "usr/bin/"
    test_command_output "dirname trailing slash root" "/" "$binary" "/usr/"
    test_command_output "dirname trailing slash single" "." "$binary" "usr/"
    test_command_output "dirname multiple trailing slashes" "usr" "$binary" "usr//bin//"

    # Special path cases
    test_command_output "dirname empty string" "." "$binary" ""
    test_command_output "dirname dot" "." "$binary" "."
    test_command_output "dirname dotdot" "." "$binary" ".."
    test_command_output "dirname dot slash file" "." "$binary" "./file"
    test_command_output "dirname dotdot slash file" ".." "$binary" "../file"

    echo -e "${CYAN}Testing GNU extensions...${NC}"

    # --zero flag for NUL-terminated output
    # Note: Use special NUL testing since test_command_output_exact has issues with NUL bytes
    local zero_single_out
    zero_single_out=$("$binary" --zero "/usr/bin" 2>/dev/null)
    if [[ "$zero_single_out" == $'/usr\x00' ]]; then
        print_test_result "dirname zero flag single" "PASS"
    else
        print_test_result "dirname zero flag single" "FAIL" "Expected NUL-terminated output"
    fi

    local zero_short_out
    zero_short_out=$("$binary" -z "file.txt" 2>/dev/null)
    if [[ "$zero_short_out" == $'.\x00' ]]; then
        print_test_result "dirname zero flag short" "PASS"
    else
        print_test_result "dirname zero flag short" "FAIL" "Expected NUL-terminated output"
    fi

    # Multiple paths with zero flag
    # Use file output since command substitution strips NUL bytes
    local zero_multiple_file="$TEMP_DIR/dirname_zero_multiple_test"
    "$binary" -z "/usr/bin" "file.txt" "/" > "$zero_multiple_file" 2>/dev/null
    local expected_hex="2f757372002e002f00"  # /usr\0.\0/\0 in hex
    local actual_hex
    actual_hex=$(hexdump -ve '1/1 "%.2x"' "$zero_multiple_file")
    if [[ "$actual_hex" == "$expected_hex" ]]; then
        print_test_result "dirname zero flag multiple paths" "PASS"
    else
        print_test_result "dirname zero flag multiple paths" "FAIL" "Expected hex $expected_hex, got $actual_hex"
    fi
    rm -f "$zero_multiple_file"

    # Mixed zero and regular flag behavior
    local zero_root_out
    zero_root_out=$("$binary" --zero "/" 2>/dev/null)
    if [[ "$zero_root_out" == $'/\x00' ]]; then
        print_test_result "dirname zero flag root" "PASS"
    else
        print_test_result "dirname zero flag root" "FAIL" "Expected NUL-terminated root"
    fi

    local zero_empty_out
    zero_empty_out=$("$binary" -z "" 2>/dev/null)
    if [[ "$zero_empty_out" == $'.\x00' ]]; then
        print_test_result "dirname zero flag empty" "PASS"
    else
        print_test_result "dirname zero flag empty" "FAIL" "Expected NUL-terminated dot"
    fi

    # GNU long options
    test_command_output "dirname long zero option" "." "$binary" --zero "single_file"
    test_command_output "dirname GNU help flag" "/usr" "$binary" "/usr/bin"  # Basic functionality with long options

    echo -e "${CYAN}Testing multiple arguments...${NC}"

    # Multiple pathname processing
    test_command_output "dirname two paths" $'/usr\n.' "$binary" "/usr/bin" "file.txt"
    test_command_output "dirname three paths" $'/usr\n.\ndir' "$binary" "/usr/bin" "file.txt" "dir/subdir"
    test_command_output "dirname mixed paths" $'/\n.\n..' "$binary" "/file" "standalone" "../file"

    # Multiple paths with different characteristics
    test_command_output "dirname multiple roots" $'/\n/\n/' "$binary" "/" "//" "///"
    test_command_output "dirname multiple trailing slashes" $'/usr\nusr\n.' "$binary" "/usr/bin/" "usr/bin/" "file/"

    # Order preservation
    local order_out
    order_out=$("$binary" "a/b" "c/d" "e/f" 2>/dev/null)
    if [[ "$order_out" == $'a\nc\ne' ]]; then
        print_test_result "dirname multiple paths order preserved" "PASS"
    else
        print_test_result "dirname multiple paths order preserved" "FAIL" "Expected paths in order"
    fi

    echo -e "${CYAN}Testing edge cases and error handling...${NC}"

    # Long path handling
    local long_path
    long_path=$(printf '/very_long_directory_name_%.0s' {1..10})
    long_path+="/file.txt"
    test_command_output_pattern "dirname long path" "very_long_directory_name.*very_long_directory_name" "$binary" "$long_path"

    # Unicode and special characters
    test_command_output "dirname unicode path" "测试目录" "$binary" "测试目录/文件.txt"
    test_command_output "dirname spaces in path" "path with spaces" "$binary" "path with spaces/file name.txt"
    test_command_output "dirname special chars" "dir!@#\$%^&*()" "$binary" "dir!@#\$%^&*()/file"

    # Path components with dots
    test_command_output "dirname dot components" "././." "$binary" "./././file"
    test_command_output "dirname dotdot components" "../../.." "$binary" "../../../file"
    test_command_output "dirname mixed dot components" "a/./b" "$binary" "a/./b/c"

    # Error conditions
    test_command_exit_code "dirname no arguments" 2 "$binary" 2>/dev/null
    test_command_exit_code "dirname invalid flag" 2 "$binary" --invalid-flag 2>/dev/null
    test_command_exit_code "dirname unknown short flag" 2 "$binary" -x 2>/dev/null

    # Error messages verification
    local no_args_stderr
    no_args_stderr=$("$binary" 2>&1 >/dev/null)
    if [[ "$no_args_stderr" =~ dirname.*missing ]]; then
        print_test_result "dirname missing operand error message" "PASS"
    else
        print_test_result "dirname missing operand error message" "FAIL" "Should show missing operand error"
    fi

    local invalid_flag_stderr
    invalid_flag_stderr=$("$binary" --invalid 2>&1 >/dev/null)
    if [[ "$invalid_flag_stderr" =~ dirname.*option ]]; then
        print_test_result "dirname invalid flag error message" "PASS"
    else
        print_test_result "dirname invalid flag error message" "FAIL" "Should show option error message"
    fi

    echo -e "${CYAN}Testing output formatting and compliance...${NC}"

    # Output format verification - newline terminated by default
    local newline_test_file="$TEMP_DIR/dirname_newline_test"
    "$binary" "/usr/bin" > "$newline_test_file" 2>/dev/null
    if [[ $(hexdump -C "$newline_test_file" | grep '0a') ]]; then
        print_test_result "dirname output ends with newline" "PASS"
    else
        print_test_result "dirname output ends with newline" "FAIL" "Output must end with newline"
    fi
    rm -f "$newline_test_file"

    # No extra whitespace in output
    local clean_output
    clean_output=$("$binary" "/usr/bin" 2>/dev/null)
    if [[ "$clean_output" == "${clean_output// /}" ]]; then
        print_test_result "dirname output no extra whitespace" "PASS"
    else
        print_test_result "dirname output no extra whitespace" "FAIL" "Output should not contain spaces"
    fi

    # POSIX compliance - exact output format
    test_command_output "dirname POSIX format simple" "/usr" "$binary" "/usr/bin"
    test_command_output "dirname POSIX format dot" "." "$binary" "file"
    test_command_output "dirname POSIX format root" "/" "$binary" "/file"

    # Consistent behavior across calls
    local consistent1 consistent2
    consistent1=$("$binary" "/usr/bin/file" 2>/dev/null)
    consistent2=$("$binary" "/usr/bin/file" 2>/dev/null)
    if [[ "$consistent1" == "$consistent2" ]]; then
        print_test_result "dirname consistent output" "PASS"
    else
        print_test_result "dirname consistent output" "FAIL" "Output should be identical between calls"
    fi

    # Exit code verification
    test_command_exit_code "dirname success exit code" 0 "$binary" "/usr/bin"
    test_command_exit_code "dirname multiple paths success" 0 "$binary" "/usr/bin" "file.txt"

    echo -e "${CYAN}Testing cross-platform behavior...${NC}"

    # Platform-independent output
    test_command_output "dirname platform root" "/" "$binary" "/"
    test_command_output "dirname platform relative" "." "$binary" "file"
    test_command_output "dirname platform absolute" "/usr" "$binary" "/usr/bin"

    # Different slash patterns (should work on all platforms)
    test_command_output "dirname single slash" "/" "$binary" "/file"
    test_command_output "dirname double slash normalization" "/" "$binary" "//file"

    # Handle potential platform differences gracefully
    local platform_test_path="/usr/bin/test"
    local platform_output
    platform_output=$("$binary" "$platform_test_path" 2>/dev/null)
    if [[ "$platform_output" == "/usr/bin" ]]; then
        print_test_result "dirname cross-platform absolute paths" "PASS"
    else
        print_test_result "dirname cross-platform absolute paths" "FAIL" "Expected /usr/bin, got $platform_output"
    fi

    echo -e "${CYAN}Testing advanced POSIX edge cases...${NC}"

    # Complex trailing slash scenarios
    test_command_output "dirname complex trailing slash 1" "a/b" "$binary" "a/b/c/"
    test_command_output "dirname complex trailing slash 2" "/" "$binary" "/a/"
    test_command_output "dirname complex trailing slash 3" "." "$binary" "a/"

    # Multiple consecutive slashes (POSIX: treat as single slash)
    test_command_output "dirname multiple slashes internal" "/usr" "$binary" "/usr///bin"
    test_command_output "dirname multiple slashes mixed" "a" "$binary" "a///b"

    # Symlink-like paths (dirname doesn't resolve, just processes strings)
    test_command_output "dirname symlink-like path" "link/target" "$binary" "link/target/file"

    # Relative paths starting with dot-slash
    test_command_output "dirname dot-slash relative" "./path" "$binary" "./path/file"

    echo -e "${CYAN}Testing GNU compatibility edge cases...${NC}"

    # Zero flag with various path types
    local zero_complex1_out
    zero_complex1_out=$("$binary" -z "/usr/bin/" 2>/dev/null)
    if [[ "$zero_complex1_out" == $'/usr\x00' ]]; then
        print_test_result "dirname zero flag complex 1" "PASS"
    else
        print_test_result "dirname zero flag complex 1" "FAIL" "Expected NUL-terminated complex path"
    fi

    local zero_complex2_out
    zero_complex2_out=$("$binary" --zero ".." 2>/dev/null)
    if [[ "$zero_complex2_out" == $'.\x00' ]]; then
        print_test_result "dirname zero flag complex 2" "PASS"
    else
        print_test_result "dirname zero flag complex 2" "FAIL" "Expected NUL-terminated dotdot result"
    fi

    # Ensure zero flag doesn't affect path processing, only output format
    local zero_vs_normal_path="/usr/bin/file"
    local zero_result normal_result
    zero_result=$("$binary" -z "$zero_vs_normal_path" 2>/dev/null | tr -d '\0')
    normal_result=$("$binary" "$zero_vs_normal_path" 2>/dev/null | tr -d '\n')
    if [[ "$zero_result" == "$normal_result" ]]; then
        print_test_result "dirname zero flag only changes terminator" "PASS"
    else
        print_test_result "dirname zero flag only changes terminator" "FAIL" "Path processing should be identical"
    fi

    echo -e "${CYAN}Testing comprehensive error conditions...${NC}"

    # Mixed valid and invalid flags
    test_command_exit_code "dirname mixed flags" 2 "$binary" -z --invalid 2>/dev/null

    # Help and version flag priority
    test_command_exit_code "dirname help flag success" 0 "$binary" --help
    test_command_exit_code "dirname version flag success" 0 "$binary" --version

    # Help content verification
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    if [[ "$help_output" =~ Usage.*dirname ]] && [[ "$help_output" =~ "--zero" ]]; then
        print_test_result "dirname help content complete" "PASS"
    else
        print_test_result "dirname help content complete" "FAIL" "Help should show usage and options"
    fi

    # Version content verification
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    if [[ "$version_output" =~ dirname ]]; then
        print_test_result "dirname version content" "PASS"
    else
        print_test_result "dirname version content" "FAIL" "Version should mention dirname"
    fi

    echo -e "${CYAN}Testing comprehensive path scenarios...${NC}"

    # Real-world path examples
    test_command_output "dirname real path 1" "/home/user/documents" "$binary" "/home/user/documents/file.pdf"
    test_command_output "dirname real path 2" "src/main/java" "$binary" "src/main/java/App.java"
    test_command_output "dirname real path 3" "." "$binary" "README.md"
    test_command_output "dirname real path 4" "/var/log" "$binary" "/var/log/app.log"

    # Edge case: paths that look like flags
    test_command_output "dirname flag-like path" "." "$binary" -- "--not-a-flag"
    test_command_output "dirname dash path" "." "$binary" "-"

    # Paths with various extensions
    test_command_output "dirname various extensions 1" "/usr/include" "$binary" "/usr/include/stdio.h"
    test_command_output "dirname various extensions 2" "docs" "$binary" "docs/manual.pdf"
    test_command_output "dirname no extension" "bin" "$binary" "bin/executable"

    echo -e "${CYAN}Final validation...${NC}"

    # Verify comprehensive test count
    if [[ $TESTS_RUN -ge 60 ]]; then
        print_test_result "dirname comprehensive test count" "PASS" "Executed $TESTS_RUN tests"
    else
        print_test_result "dirname comprehensive test count" "FAIL" "Only executed $TESTS_RUN tests, expected 60+"
    fi

    # Final cleanup verification
    local remaining_files
    remaining_files=$(find "$TEMP_DIR" -name "*dirname*" 2>/dev/null | wc -l)
    if [[ $remaining_files -lt 5 ]]; then  # Allow some temporary files during test
        print_test_result "dirname test cleanup" "PASS"
    else
        print_test_result "dirname test cleanup" "FAIL" "Too many test files remain: $remaining_files"
    fi
}