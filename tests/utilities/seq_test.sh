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

    # Invalid flag exits with code 2
    test_command_exit_code "seq invalid flag exits 2" 2 \
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
}
