#!/usr/bin/env bash
# Integration tests for seq utility
# Tests argument forms, separators, equal width, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_seq() {
    local util="seq"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic sequences...${NC}"

    # seq 5 outputs 1 through 5
    local expected=$'1\n2\n3\n4\n5'
    test_command_output "seq 5 outputs 1-5" "$expected" "$binary" 5

    # seq 2 5 outputs 2 through 5
    expected=$'2\n3\n4\n5'
    test_command_output "seq 2 5 outputs 2-5" "$expected" "$binary" 2 5

    # seq 1 2 10 outputs odd numbers 1,3,5,7,9
    expected=$'1\n3\n5\n7\n9'
    test_command_output "seq 1 2 10 outputs 1,3,5,7,9" "$expected" \
        "$binary" 1 2 10

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "seq --help shows usage" "PASS"
    else
        print_test_result "seq --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ seq ]]; then
        print_test_result "seq --version shows version" "PASS"
    else
        print_test_result "seq --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 1
    test_command_exit_code "seq invalid flag exits 1" 1 \
        "$binary" --invalid-flag

    echo -e "${CYAN}Testing separator flag...${NC}"

    # -s ", " separator works
    local sep_output
    sep_output=$("$binary" -s ", " 3 2>/dev/null)
    if [[ "$sep_output" == "1, 2, 3" ]]; then
        print_test_result "seq -s separator" "PASS"
    else
        print_test_result "seq -s separator" "FAIL" \
            "Expected '1, 2, 3', got '$sep_output'"
    fi

    echo -e "${CYAN}Testing equal width flag...${NC}"

    # -w equal width works
    local width_output
    width_output=$("$binary" -w 8 10 2>/dev/null)
    local expected_width=$'08\n09\n10'
    if [[ "$width_output" == "$expected_width" ]]; then
        print_test_result "seq -w equal width" "PASS"
    else
        print_test_result "seq -w equal width" "FAIL" \
            "Expected '$expected_width', got '$width_output'"
    fi

    # ========== AUDIT WAVE 4: seq IMPORTANT findings ==========

    echo -e "${CYAN}Testing audit: negative increment without --...${NC}"

    # IMPORTANT: seq 5 -1 1 should count down without needing --
    # GNU handles this; our argparse rejects -1 as unknown flag
    local neg_output
    neg_output=$("$binary" 5 -1 1 2>/dev/null)
    local neg_exit=$?
    if [[ $neg_exit -eq 0 && "$neg_output" == $'5\n4\n3\n2\n1' ]]; then
        print_test_result "seq audit: negative increment without --" "PASS"
    else
        print_test_result "seq audit: negative increment without --" "FAIL" \
            "Expected countdown 5..1 (exit 0), got exit=$neg_exit output='$neg_output'"
    fi

    echo -e "${CYAN}Testing audit: error exit code should be 1...${NC}"

    # GNU seq with invalid input exits 1, and so do we.
    local err_out="" err_err="" err_exit=""
    run_command err_cmd err_out err_err err_exit "$binary" abc
    if [[ $err_exit -eq 1 ]]; then
        print_test_result "seq audit: invalid number exits 1" "PASS"
    else
        print_test_result "seq audit: invalid number exits 1" "FAIL" \
            "Expected exit 1, got $err_exit"
    fi

    run_command err_cmd err_out err_err err_exit "$binary" 1 0 5
    if [[ $err_exit -eq 1 ]]; then
        print_test_result "seq audit: zero increment exits 1" "PASS"
    else
        print_test_result "seq audit: zero increment exits 1" "FAIL" \
            "Expected exit 1, got $err_exit"
    fi

    echo -e "${CYAN}Testing audit: nan input rejected...${NC}"

    # IMPORTANT: nan input silently produces empty output instead of error
    run_command err_cmd err_out err_err err_exit "$binary" nan
    if [[ $err_exit -ne 0 && -n "$err_err" ]]; then
        print_test_result "seq audit: nan input produces error" "PASS"
    else
        print_test_result "seq audit: nan input produces error" "FAIL" \
            "Expected non-zero exit with stderr, got exit=$err_exit stderr='$err_err'"
    fi

    echo -e "${CYAN}Testing audit: -f format prefix/suffix...${NC}"

    # IMPORTANT: -f format string prefix/suffix text dropped
    local fmt_output
    fmt_output=$("$binary" -f 'val=%g!' 3 2>/dev/null)
    local fmt_expected=$'val=1!\nval=2!\nval=3!'
    if [[ "$fmt_output" == "$fmt_expected" ]]; then
        print_test_result "seq audit: -f format preserves prefix/suffix" "PASS"
    else
        print_test_result "seq audit: -f format preserves prefix/suffix" "FAIL" \
            "Expected '$fmt_expected', got '$fmt_output'"
    fi

    # -f with width and precision
    fmt_output=$("$binary" -f '%05.1f' 3 2>/dev/null)
    fmt_expected=$'001.0\n002.0\n003.0'
    if [[ "$fmt_output" == "$fmt_expected" ]]; then
        print_test_result "seq audit: -f format width and precision" "PASS"
    else
        print_test_result "seq audit: -f format width and precision" "FAIL" \
            "Expected '$fmt_expected', got '$fmt_output'"
    fi

    echo -e "${CYAN}Testing audit: countdown and float sequences...${NC}"

    # Test gap: countdown
    test_command_output "seq audit: countdown 10 -2 1" $'10\n8\n6\n4\n2' \
        "$binary" 10 -- -2 1

    # Test gap: float sequence
    test_command_output "seq audit: float 0.1 0.1 0.5" $'0.1\n0.2\n0.3\n0.4\n0.5' \
        "$binary" 0.1 0.1 0.5
}
