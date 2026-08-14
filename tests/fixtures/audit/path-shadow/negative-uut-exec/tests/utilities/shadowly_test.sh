#!/usr/bin/env bash
# Unit-under-test -exec operands: these are arguments to $binary, not a
# fixture `find -exec chmod` PATH lookup. Quote stripping removes
# `"$binary"`, so a scanner that then matches unquoted `-exec true`
# falsely flags this shape.

test_shadowly() {
    local util="shadowly"
    local binary="$BIN_DIR/$util"

    test_binary_exists "$util" || return 1

    "$binary" -exec true
    "$binary" -type f -exec echo {} +
    "$binary" -exec ls {} \;
}
