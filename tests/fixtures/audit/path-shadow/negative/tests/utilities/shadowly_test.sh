#!/usr/bin/env bash
# Fixture test file whose peer-utility lookups are already qualified.

test_shadowly() {
    local util="shadowly"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    host chmod 644 "$TEMP_DIR/f"
}
