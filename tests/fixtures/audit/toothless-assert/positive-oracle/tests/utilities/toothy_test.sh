#!/usr/bin/env bash
# Fixture test file whose oracle is the utility under test.

test_toothy() {
    local util="toothy"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    local expected
    expected=$(toothy)
    if [[ "$("$binary")" == "$expected" ]]; then
        print_test_result "toothy matches the reference" "PASS"
    else
        print_test_result "toothy matches the reference" "FAIL"
    fi
}
