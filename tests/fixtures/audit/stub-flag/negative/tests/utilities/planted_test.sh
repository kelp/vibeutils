#!/usr/bin/env bash
# Fixture test file for the planted utility. Deliberately free of the
# toothless-assert patterns: the existence guard returns, the pattern is
# anchored and carries a literal, and no oracle names a built binary.

test_planted() {
    local util="planted"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" =~ ^planted$ ]]; then
        print_test_result "planted prints its name" "PASS"
    else
        print_test_result "planted prints its name" "FAIL" "Output: $output"
    fi
}
