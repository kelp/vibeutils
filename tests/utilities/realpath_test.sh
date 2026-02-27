#!/usr/bin/env bash
# Comprehensive tests for realpath utility
# Tests all flags, path resolution, edge cases, and GNU extensions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_realpath() {
    local util="realpath"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Help and version
    local help_output
    help_output=$("$binary" --help)
    if [[ "$help_output" =~ "Usage: realpath" && "$help_output" =~ "--no-symlinks" ]]; then
        print_test_result "help output contains expected content" "PASS"
    else
        print_test_result "help output contains expected content" "FAIL" "Missing expected help content"
    fi

    local version_output
    version_output=$("$binary" --version)
    if [[ "$version_output" =~ "realpath" ]]; then
        print_test_result "version output contains utility name" "PASS"
    else
        print_test_result "version output contains utility name" "FAIL" "Version output: '$version_output'"
    fi

    echo -e "${CYAN}Testing default mode (canonicalize-existing)...${NC}"

    # Existing paths should resolve
    test_command_exit_code "existing path succeeds" 0 "$binary" /tmp
    test_command_exit_code "root path succeeds" 0 "$binary" /

    # Output should be absolute
    local output
    output=$("$binary" /tmp 2>/dev/null)
    if [[ "$output" == /* ]]; then
        print_test_result "output is absolute path" "PASS"
    else
        print_test_result "output is absolute path" "FAIL" "Expected absolute path, got: $output"
    fi

    # Nonexistent paths should fail
    test_command_exit_code "nonexistent path fails" 1 "$binary" /nonexistent_vibeutils_path 2>/dev/null

    # Error message for nonexistent path
    local err_output
    err_output=$("$binary" /nonexistent_vibeutils_path 2>&1 >/dev/null)
    if [[ "$err_output" =~ realpath ]]; then
        print_test_result "error message includes program name" "PASS"
    else
        print_test_result "error message includes program name" "FAIL" "Error: $err_output"
    fi

    echo -e "${CYAN}Testing -e (canonicalize-existing)...${NC}"

    test_command_exit_code "-e existing path succeeds" 0 "$binary" -e /tmp
    test_command_exit_code "-e nonexistent path fails" 1 "$binary" -e /nonexistent_vibeutils_path 2>/dev/null

    echo -e "${CYAN}Testing -m (canonicalize-missing)...${NC}"

    # -m should succeed even for nonexistent paths
    test_command_exit_code "-m nonexistent path succeeds" 0 "$binary" -m /tmp/nonexistent_vibeutils_path

    local missing_output
    missing_output=$("$binary" -m /tmp/nonexistent_vibeutils_path 2>/dev/null)
    if [[ "$missing_output" == *"nonexistent_vibeutils_path"* ]]; then
        print_test_result "-m preserves nonexistent component" "PASS"
    else
        print_test_result "-m preserves nonexistent component" "FAIL" "Output: $missing_output"
    fi

    # -m should still resolve .. components
    local missing_dotdot
    missing_dotdot=$("$binary" -m /tmp/foo/../bar 2>/dev/null)
    if [[ "$missing_dotdot" != *".."* ]]; then
        print_test_result "-m resolves .. in nonexistent paths" "PASS"
    else
        print_test_result "-m resolves .. in nonexistent paths" "FAIL" "Output: $missing_dotdot"
    fi

    echo -e "${CYAN}Testing -s (no-symlinks)...${NC}"

    # -s should resolve . and .. without following symlinks
    test_command_output "-s resolves .." "/usr/lib" "$binary" -s /usr/bin/../lib
    test_command_output "-s resolves ." "/usr/bin" "$binary" -s /usr/./bin
    test_command_output "-s resolves complex .." "/a/d" "$binary" -s /a/b/c/../../d
    test_command_output "-s resolves root .." "/" "$binary" -s /../../..
    test_command_output "-s removes redundant slashes" "/usr/bin/ls" "$binary" -s /usr///bin///ls

    # --strip alias should work identically
    test_command_output "--strip alias" "/usr/lib" "$binary" --strip /usr/bin/../lib

    # --no-symlinks long form
    test_command_output "--no-symlinks long form" "/usr/lib" "$binary" --no-symlinks /usr/bin/../lib

    echo -e "${CYAN}Testing -z (zero delimiter)...${NC}"

    local zero_out="$TEMP_DIR/realpath_zero_test"
    "$binary" -z -s /usr/bin > "$zero_out" 2>/dev/null
    if printf "/usr/bin\0" | cmp -s - "$zero_out"; then
        print_test_result "-z NUL delimiter" "PASS"
    else
        print_test_result "-z NUL delimiter" "FAIL" "Output doesn't match expected NUL-terminated"
    fi
    rm -f "$zero_out"

    # --zero long form
    test_command_exit_code "--zero flag exists" 0 "$binary" --zero -s /tmp

    echo -e "${CYAN}Testing -q (quiet)...${NC}"

    # -q should suppress error messages
    local quiet_stderr
    quiet_stderr=$("$binary" -q /nonexistent_vibeutils_path 2>&1 >/dev/null)
    if [[ -z "$quiet_stderr" ]]; then
        print_test_result "-q suppresses error messages" "PASS"
    else
        print_test_result "-q suppresses error messages" "FAIL" "Stderr: $quiet_stderr"
    fi

    # But exit code should still be non-zero
    test_command_exit_code "-q still returns error code" 1 "$binary" -q /nonexistent_vibeutils_path 2>/dev/null

    echo -e "${CYAN}Testing --relative-to...${NC}"

    test_command_output "--relative-to basic" "bin/ls" "$binary" -s --relative-to=/usr /usr/bin/ls
    test_command_output "--relative-to same dir" "." "$binary" -s --relative-to=/usr /usr
    test_command_output "--relative-to parent" ".." "$binary" -s --relative-to=/usr/bin /usr

    echo -e "${CYAN}Testing --relative-base...${NC}"

    # Path under base: relative output
    test_command_output "--relative-base under base" "bin/ls" "$binary" -s --relative-base=/usr /usr/bin/ls

    # Path not under base: absolute output
    test_command_output "--relative-base not under base" "/etc/hosts" "$binary" -s --relative-base=/usr /etc/hosts

    echo -e "${CYAN}Testing multiple paths...${NC}"

    test_command_output "multiple paths" $'/usr/bin\n/usr/lib' "$binary" -s /usr/bin /usr/lib

    # Multiple paths with one failing
    local multi_out multi_err
    multi_out=$("$binary" /tmp /nonexistent_vibeutils_path 2>/dev/null)
    multi_err=$("$binary" /tmp /nonexistent_vibeutils_path 2>&1 >/dev/null)
    if [[ "$multi_out" == *"/tmp"* || "$multi_out" == *"/private/tmp"* ]]; then
        print_test_result "multiple paths: valid one succeeds" "PASS"
    else
        print_test_result "multiple paths: valid one succeeds" "FAIL" "Output: $multi_out"
    fi
    test_command_exit_code "multiple paths with failure returns error" 1 "$binary" /tmp /nonexistent_vibeutils_path 2>/dev/null

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments
    test_command_exit_code "no arguments" 2 "$binary" 2>/dev/null

    # Missing operand error message
    local no_args_err
    no_args_err=$("$binary" 2>&1 >/dev/null)
    if [[ "$no_args_err" =~ "missing operand" ]]; then
        print_test_result "missing operand error message" "PASS"
    else
        print_test_result "missing operand error message" "FAIL" "Error: $no_args_err"
    fi

    # Invalid flags
    test_command_exit_code "invalid flag" 2 "$binary" --invalid 2>/dev/null
    test_command_exit_code "invalid short flag" 2 "$binary" -x 2>/dev/null

    echo -e "${CYAN}Testing symlink resolution...${NC}"

    # Create a temporary symlink for testing
    local link_dir="$TEMP_DIR/realpath_symlink_test"
    mkdir -p "$link_dir"
    echo "test" > "$link_dir/real_file"
    ln -sf "$link_dir/real_file" "$link_dir/link_file" 2>/dev/null

    if [[ -L "$link_dir/link_file" ]]; then
        # Default mode should resolve symlink
        local resolved
        resolved=$("$binary" "$link_dir/link_file" 2>/dev/null)
        if [[ "$resolved" == *"real_file"* ]]; then
            print_test_result "default mode resolves symlinks" "PASS"
        else
            print_test_result "default mode resolves symlinks" "FAIL" "Output: $resolved"
        fi

        # -s mode should NOT resolve symlink
        local no_resolve
        no_resolve=$("$binary" -s "$link_dir/link_file" 2>/dev/null)
        if [[ "$no_resolve" == *"link_file"* ]]; then
            print_test_result "-s mode preserves symlinks" "PASS"
        else
            print_test_result "-s mode preserves symlinks" "FAIL" "Output: $no_resolve"
        fi
    else
        print_test_result "symlink tests" "SKIP" "Cannot create symlinks"
    fi

    rm -rf "$link_dir"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # -m -s combined
    test_command_output "-m -s combined" "/nonexistent/resolved" "$binary" -m -s /nonexistent/./foo/../resolved
    test_command_exit_code "-m -s combined succeeds" 0 "$binary" -m -s /nonexistent/path

    # -q -m combined
    test_command_exit_code "-q -m succeeds for nonexistent" 0 "$binary" -q -m /nonexistent/path

    # -z -s combined
    local zs_out="$TEMP_DIR/realpath_zs_test"
    "$binary" -z -s /usr/bin > "$zs_out" 2>/dev/null
    if printf "/usr/bin\0" | cmp -s - "$zs_out"; then
        print_test_result "-z -s combined" "PASS"
    else
        print_test_result "-z -s combined" "FAIL"
    fi
    rm -f "$zs_out"

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Root path
    test_command_output "-s root" "/" "$binary" -s /

    # Path with only dots
    test_command_exit_code "dot path succeeds" 0 "$binary" .

    # Double dash separator
    test_command_exit_code "double dash with path" 0 "$binary" -s -- /usr/bin
}
