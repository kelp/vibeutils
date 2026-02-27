#!/usr/bin/env bash
# Integration tests for free utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_free() {
    local util="free"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should contain Mem: and Swap: lines
    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" =~ Mem: && "$output" =~ Swap: ]]; then
        print_test_result "free default output contains Mem: and Swap:" "PASS"
    else
        print_test_result "free default output contains Mem: and Swap:" "FAIL" \
            "Output: '$output'"
    fi

    # Header should contain expected columns
    if [[ "$output" =~ total && "$output" =~ used && "$output" =~ free ]]; then
        print_test_result "free header contains total/used/free" "PASS"
    else
        print_test_result "free header contains total/used/free" "FAIL" \
            "Output: '$output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "free --help shows usage" "PASS"
    else
        print_test_result "free --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ free ]]; then
        print_test_result "free --version shows version" "PASS"
    else
        print_test_result "free --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing unit flags...${NC}"

    # -b (bytes) exits 0
    test_command_exit_code "free -b exits 0" 0 "$binary" -b

    # -k (kibi) exits 0
    test_command_exit_code "free -k exits 0" 0 "$binary" -k

    # -m (mebi) exits 0
    test_command_exit_code "free -m exits 0" 0 "$binary" -m

    # -g (gibi) exits 0
    test_command_exit_code "free -g exits 0" 0 "$binary" -g

    # -h (human) exits 0
    test_command_exit_code "free -h exits 0" 0 "$binary" -h

    echo -e "${CYAN}Testing human readable output...${NC}"

    # -h should contain unit suffixes
    local human_output
    human_output=$("$binary" -h 2>/dev/null)
    if [[ "$human_output" =~ [KMGT]i || "$human_output" =~ [0-9]B ]]; then
        print_test_result "free -h shows unit suffixes" "PASS"
    else
        print_test_result "free -h shows unit suffixes" "FAIL" \
            "Output: '$human_output'"
    fi

    echo -e "${CYAN}Testing total flag...${NC}"

    # -t should add a Total: line
    local total_output
    total_output=$("$binary" -t 2>/dev/null)
    if [[ "$total_output" =~ Total: ]]; then
        print_test_result "free -t shows Total line" "PASS"
    else
        print_test_result "free -t shows Total line" "FAIL" \
            "Output: '$total_output'"
    fi

    echo -e "${CYAN}Testing wide flag...${NC}"

    # -w should show buffers and cache separately
    local wide_output
    wide_output=$("$binary" -w 2>/dev/null)
    if [[ "$wide_output" =~ buffers && "$wide_output" =~ cache ]]; then
        print_test_result "free -w shows buffers and cache" "PASS"
    else
        print_test_result "free -w shows buffers and cache" "FAIL" \
            "Output: '$wide_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "free invalid flag exits 2" 2 \
        "$binary" --invalid-flag
}
