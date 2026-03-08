#!/usr/bin/env bash
# Regression tests for O_APPEND stdout bug (GitHub issue #5)
#
# All vibeutils commands use a positional writer that writes at offset 0,
# ignoring O_APPEND. This causes `command >> file` to overwrite existing
# content instead of appending to it.
#
# These tests verify that >> (append redirect) works correctly with
# several representative utilities.

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_append_redirect() {
    echo -e "${CYAN}Testing O_APPEND redirect behavior (issue #5)...${NC}"

    # --- echo >> file ---
    local echo_file="$TEMP_DIR/append_echo"
    printf 'existing\n' > "$echo_file"
    "$BIN_DIR/echo" "new" >> "$echo_file"
    local expected_echo=$'existing\nnew\n'
    local actual_echo
    actual_echo=$(<"$echo_file")
    # $(<file) strips the trailing newline, so compare without it
    if [[ "$actual_echo" == "existing"$'\n'"new" ]]; then
        print_test_result "echo >> file appends" "PASS"
    else
        print_test_result "echo >> file appends" "FAIL" \
            "Expected 'existing\\nnew', got '$actual_echo'"
    fi

    # --- head >> file ---
    local head_file="$TEMP_DIR/append_head"
    printf 'existing\n' > "$head_file"
    printf '%s\n' "new" | "$BIN_DIR/head" -n 1 >> "$head_file"
    local actual_head
    actual_head=$(<"$head_file")
    if [[ "$actual_head" == "existing"$'\n'"new" ]]; then
        print_test_result "head >> file appends" "PASS"
    else
        print_test_result "head >> file appends" "FAIL" \
            "Expected 'existing\\nnew', got '$actual_head'"
    fi

    # --- cat >> file ---
    local cat_file="$TEMP_DIR/append_cat"
    printf 'existing\n' > "$cat_file"
    printf '%s\n' "new" | "$BIN_DIR/cat" >> "$cat_file"
    local actual_cat
    actual_cat=$(<"$cat_file")
    if [[ "$actual_cat" == "existing"$'\n'"new" ]]; then
        print_test_result "cat >> file appends" "PASS"
    else
        print_test_result "cat >> file appends" "FAIL" \
            "Expected 'existing\\nnew', got '$actual_cat'"
    fi

    # --- wc >> file ---
    local wc_file="$TEMP_DIR/append_wc"
    printf 'existing\n' > "$wc_file"
    printf '%s\n' "new" | "$BIN_DIR/wc" -l >> "$wc_file"
    local actual_wc
    actual_wc=$(<"$wc_file")
    # wc -l output varies in whitespace, so just verify "existing" is
    # still at the start and is followed by the wc output
    if [[ "$actual_wc" == "existing"* ]] && [[ "$actual_wc" == *"1"* ]]; then
        print_test_result "wc >> file appends" "PASS"
    else
        print_test_result "wc >> file appends" "FAIL" \
            "Expected file to start with 'existing' followed by wc output, got '$actual_wc'"
    fi
}
