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

    # Invalid flag exits with code 1
    test_command_exit_code "free invalid flag exits 1" 1 \
        "$binary" --invalid-flag

    echo -e "${CYAN}Testing audit findings (wave 4)...${NC}"

    # AUDIT: -w wide mode buffers column should show nonzero on Linux
    if [[ "$(uname)" == "Linux" ]]; then
        local wide_out
        wide_out=$("$binary" -w -b 2>/dev/null)
        # Extract the Mem: line
        local mem_line
        mem_line=$(echo "$wide_out" | grep "^Mem:")
        # Parse the 5th numeric column (buffers)
        local buffers_val
        buffers_val=$(echo "$mem_line" | awk '{print $6}')
        if [[ -n "$buffers_val" && "$buffers_val" -gt 0 ]] 2>/dev/null; then
            print_test_result "free -w shows nonzero buffers" "PASS"
        else
            print_test_result "free -w shows nonzero buffers" "FAIL" \
                "Buffers column is '$buffers_val', expected > 0. Line: '$mem_line'"
        fi
    fi

    # AUDIT: -c without -s should error (GNU rejects it)
    "$binary" -c 3 2>/dev/null
    exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        print_test_result "free -c without -s exits 1" "PASS"
    else
        print_test_result "free -c without -s exits 1" "FAIL" \
            "Expected exit 1, got: $exit_code"
    fi

    # AUDIT: -s should set seconds interval, not SI mode
    # free -s 1 -c 1 should succeed (continuous mode, 1 iteration).
    # Wrap in run_with_limit because macOS CI has no GNU timeout(1).
    run_with_limit 5 "$binary" -s 1 -c 1 >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "free -s 1 -c 1 sets seconds interval" "PASS"
    else
        print_test_result "free -s 1 -c 1 sets seconds interval" "FAIL" \
            "Expected exit 0, got: $exit_code"
    fi
}
