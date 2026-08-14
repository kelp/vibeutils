#!/usr/bin/env bash
# Clean peer-utility suite. Findings must come from shadowly_test.sh.

test_chmod() {
    local util="chmod"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1
    "$binary" --help >/dev/null 2>&1
}
