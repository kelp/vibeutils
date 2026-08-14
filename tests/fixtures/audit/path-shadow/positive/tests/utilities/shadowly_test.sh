#!/usr/bin/env bash
# Fixture test file with a planted PATH-shadowing command lookup.

test_shadowly() {
    local util="shadowly"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    command chmod 644 "$TEMP_DIR/f"
}
