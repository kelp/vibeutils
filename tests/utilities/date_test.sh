#!/usr/bin/env bash
# Integration tests for date utility
# Tests default output, flags, format strings, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_date() {
    local util="date"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should be non-empty
    local output
    output=$("$binary" 2>/dev/null)
    if [[ -n "$output" ]]; then
        print_test_result "date default output is non-empty" "PASS"
    else
        print_test_result "date default output is non-empty" "FAIL" \
            "Expected non-empty output"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage text and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "date --help shows usage" "PASS"
    else
        print_test_result "date --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ date ]]; then
        print_test_result "date --version shows version" "PASS"
    else
        print_test_result "date --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "date invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    echo -e "${CYAN}Testing format strings...${NC}"

    # +%Y outputs 4-digit year
    local year_output
    year_output=$("$binary" "+%Y" 2>/dev/null)
    if [[ "$year_output" =~ ^[0-9]{4}$ ]]; then
        print_test_result "date +%Y outputs 4-digit year" "PASS"
    else
        print_test_result "date +%Y outputs 4-digit year" "FAIL" \
            "Expected 4-digit year, got '$year_output'"
    fi

    echo -e "${CYAN}Testing UTC mode...${NC}"

    # -u (UTC) exits 0
    test_command_exit_code "date -u exits 0" 0 "$binary" -u

    # Regression test: date -v exits non-zero (not yet implemented)
    # Should fail cleanly with no misleading date output on stdout
    echo -e "${CYAN}Testing unimplemented -v flag...${NC}"

    local dv_cmd dv_out dv_err dv_exit
    run_command dv_cmd dv_out dv_err dv_exit "$binary" -v +1d
    if [[ $dv_exit -ne 0 ]]; then
        print_test_result "date -v exits non-zero" "PASS"
    else
        print_test_result "date -v exits non-zero" "FAIL" \
            "Expected non-zero exit for unimplemented -v flag, got 0"
    fi
    if [[ -z "$dv_out" ]]; then
        print_test_result "date -v produces no stdout" "PASS"
    else
        print_test_result "date -v produces no stdout" "FAIL" \
            "Expected empty stdout, got: '$dv_out'"
    fi
}
