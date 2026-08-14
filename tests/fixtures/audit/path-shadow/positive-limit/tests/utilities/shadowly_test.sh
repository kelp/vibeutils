#!/usr/bin/env bash
# Fixture test file with a planted run_with_limit PATH lookup.

test_shadowly() {
    local util="shadowly"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    run_with_limit 5 chmod 644 "$TEMP_DIR/f"
}
