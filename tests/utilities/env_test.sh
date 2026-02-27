#!/usr/bin/env bash
# Integration tests for env utility
# Tests environment printing, modification, command execution, and flags

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_env() {
    local util="env"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing help and version...${NC}"

    # --help shows usage
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ "Usage: env" ]]; then
        print_test_result "env --help shows usage" "PASS"
    else
        print_test_result "env --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    # --version shows version
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ "env" ]]; then
        print_test_result "env --version shows version" "PASS"
    else
        print_test_result "env --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing environment printing...${NC}"

    # Print current environment (should contain PATH)
    local env_output
    env_output=$("$binary" 2>/dev/null)
    if [[ "$env_output" =~ "PATH=" ]]; then
        print_test_result "env prints current environment" "PASS"
    else
        print_test_result "env prints current environment" "FAIL" \
            "Output does not contain PATH="
    fi

    # Print empty environment
    local empty_output
    empty_output=$("$binary" -i 2>/dev/null)
    if [[ -z "$empty_output" ]]; then
        print_test_result "env -i prints empty environment" "PASS"
    else
        print_test_result "env -i prints empty environment" "FAIL" \
            "Expected empty output, got: '$empty_output'"
    fi

    # Print with assignment
    local assign_output
    assign_output=$("$binary" -i FOO=bar 2>/dev/null)
    if [[ "$assign_output" == "FOO=bar" ]]; then
        print_test_result "env -i FOO=bar prints assignment" "PASS"
    else
        print_test_result "env -i FOO=bar prints assignment" "FAIL" \
            "Expected 'FOO=bar', got: '$assign_output'"
    fi

    echo -e "${CYAN}Testing command execution...${NC}"

    # Run a command
    local cmd_output
    cmd_output=$("$binary" echo hello 2>/dev/null)
    if [[ "$cmd_output" == "hello" ]]; then
        print_test_result "env echo hello" "PASS"
    else
        print_test_result "env echo hello" "FAIL" \
            "Expected 'hello', got: '$cmd_output'"
    fi

    # Run with assignment and command
    cmd_output=$("$binary" -i FOO=bar sh -c 'echo $FOO' 2>/dev/null)
    if [[ "$cmd_output" == "bar" ]]; then
        print_test_result "env -i FOO=bar sh -c 'echo \$FOO'" "PASS"
    else
        print_test_result "env -i FOO=bar sh -c 'echo \$FOO'" "FAIL" \
            "Expected 'bar', got: '$cmd_output'"
    fi

    # Command exit code passthrough
    "$binary" sh -c 'exit 42' 2>/dev/null
    local exit_code=$?
    if [[ $exit_code -eq 42 ]]; then
        print_test_result "env passes through exit code" "PASS"
    else
        print_test_result "env passes through exit code" "FAIL" \
            "Expected exit 42, got: $exit_code"
    fi

    echo -e "${CYAN}Testing -u/--unset...${NC}"

    # Unset a variable
    cmd_output=$(FOO=bar "$binary" -u FOO sh -c 'echo "FOO=${FOO:-unset}"' 2>/dev/null)
    if [[ "$cmd_output" == "FOO=unset" ]]; then
        print_test_result "env -u FOO unsets variable" "PASS"
    else
        print_test_result "env -u FOO unsets variable" "FAIL" \
            "Expected 'FOO=unset', got: '$cmd_output'"
    fi

    # --unset=NAME form
    cmd_output=$(FOO=bar "$binary" --unset=FOO sh -c 'echo "FOO=${FOO:-unset}"' 2>/dev/null)
    if [[ "$cmd_output" == "FOO=unset" ]]; then
        print_test_result "env --unset=FOO unsets variable" "PASS"
    else
        print_test_result "env --unset=FOO unsets variable" "FAIL" \
            "Expected 'FOO=unset', got: '$cmd_output'"
    fi

    echo -e "${CYAN}Testing -C/--chdir...${NC}"

    # Change directory
    cmd_output=$("$binary" -C /tmp sh -c 'pwd' 2>/dev/null)
    # /tmp might resolve to /private/tmp on macOS
    if [[ "$cmd_output" == "/tmp" || "$cmd_output" == "/private/tmp" ]]; then
        print_test_result "env -C /tmp changes directory" "PASS"
    else
        print_test_result "env -C /tmp changes directory" "FAIL" \
            "Expected '/tmp' or '/private/tmp', got: '$cmd_output'"
    fi

    # --chdir=DIR form
    cmd_output=$("$binary" --chdir=/tmp sh -c 'pwd' 2>/dev/null)
    if [[ "$cmd_output" == "/tmp" || "$cmd_output" == "/private/tmp" ]]; then
        print_test_result "env --chdir=/tmp changes directory" "PASS"
    else
        print_test_result "env --chdir=/tmp changes directory" "FAIL" \
            "Expected '/tmp' or '/private/tmp', got: '$cmd_output'"
    fi

    # Invalid directory
    "$binary" -C /nonexistent_dir_12345 echo hi 2>/dev/null
    exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "env -C nonexistent exits 125" "PASS"
    else
        print_test_result "env -C nonexistent exits 125" "FAIL" \
            "Expected exit 125, got: $exit_code"
    fi

    echo -e "${CYAN}Testing -0/--null output...${NC}"

    # Null-delimited output
    local temp_out="$TEMP_DIR/env_null_test"
    mkdir -p "$TEMP_DIR"
    "$binary" -i -0 FOO=bar > "$temp_out"
    if printf "FOO=bar\0" | cmp -s - "$temp_out"; then
        print_test_result "env -0 uses null delimiter" "PASS"
    else
        print_test_result "env -0 uses null delimiter" "FAIL" \
            "Output does not match expected null-terminated output"
    fi
    rm -f "$temp_out"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Unknown flag
    test_command_fails "env unknown flag" "$binary" --invalid-flag

    # Missing value for -u
    test_command_fails "env -u without value" "$binary" -u

    # Missing value for -C
    test_command_fails "env -C without value" "$binary" -C

    # Command not found
    "$binary" nonexistent_command_12345 2>/dev/null
    exit_code=$?
    if [[ $exit_code -eq 127 ]]; then
        print_test_result "env command not found exits 127" "PASS"
    else
        print_test_result "env command not found exits 127" "FAIL" \
            "Expected exit 127, got: $exit_code"
    fi

    echo -e "${CYAN}Testing -- separator...${NC}"

    # -- separates options from command
    cmd_output=$("$binary" -- echo hello 2>/dev/null)
    if [[ "$cmd_output" == "hello" ]]; then
        print_test_result "env -- echo hello" "PASS"
    else
        print_test_result "env -- echo hello" "FAIL" \
            "Expected 'hello', got: '$cmd_output'"
    fi

    echo -e "${CYAN}Testing combined flags...${NC}"

    # Combined -i0
    temp_out="$TEMP_DIR/env_combined_test"
    "$binary" -i0 X=1 > "$temp_out"
    if printf "X=1\0" | cmp -s - "$temp_out"; then
        print_test_result "env -i0 combined flags" "PASS"
    else
        print_test_result "env -i0 combined flags" "FAIL" \
            "Output does not match expected null-terminated output"
    fi
    rm -f "$temp_out"

    echo -e "${CYAN}Testing empty value assignment...${NC}"

    # Assignment with empty value
    cmd_output=$("$binary" -i FOO= sh -c 'echo "FOO=$FOO"' 2>/dev/null)
    if [[ "$cmd_output" == "FOO=" ]]; then
        print_test_result "env FOO= sets empty value" "PASS"
    else
        print_test_result "env FOO= sets empty value" "FAIL" \
            "Expected 'FOO=', got: '$cmd_output'"
    fi
}
