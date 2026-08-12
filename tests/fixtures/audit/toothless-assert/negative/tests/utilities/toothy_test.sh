#!/usr/bin/env bash
# Fixture test file with a planted toothless assertion.

test_toothy() {
    local util="toothy"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" =~ ^toothy$ ]]; then
        print_test_result "toothy prints its name" "PASS"
    else
        print_test_result "toothy prints its name" "FAIL" "Output: $output"
    fi
}
