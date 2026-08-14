#!/usr/bin/env bash
# Fixture test file with a planted find -exec PATH lookup.

test_shadowly() {
    local util="shadowly"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    find "$TEMP_DIR" -type f -exec chmod 644 {} \;
}
