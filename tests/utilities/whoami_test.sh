#!/usr/bin/env bash
# Integration tests for whoami utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_whoami() {
    local util="whoami"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing output correctness...${NC}"

    # Output should match system whoami
    local expected
    expected=$(whoami)
    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" == "$expected" ]]; then
        print_test_result "whoami matches system whoami" "PASS"
    else
        print_test_result "whoami matches system whoami" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "whoami --help shows usage" "PASS"
    else
        print_test_result "whoami --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ whoami ]]; then
        print_test_result "whoami --version shows version" "PASS"
    else
        print_test_result "whoami --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "whoami invalid flag exits 2" 2 \
        "$binary" --invalid-flag
}
