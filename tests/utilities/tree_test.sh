#!/usr/bin/env bash
# Integration tests for tree. This file is sourced by test_runner.sh.

tree_check() {
    local name="$1"
    local condition="$2"
    local details="${3:-}"
    if [[ "$condition" == "true" ]]; then
        print_test_result "$name" "PASS"
    else
        print_test_result "$name" "FAIL" "$details"
    fi
}

test_tree() {
    local util="tree"
    local binary="$BIN_DIR/$util"
    test_binary_exists "$util" || return 1
    test_basic_flags "$util"

    local base="$TEMP_DIR/tree_fixture"
    local root="$base/root"
    mkdir -p "$root/beta/skipme" "$root/.hidden"
    touch "$root/alpha" "$root/zed"
    touch "$root/beta/nested.txt" "$root/beta/z.log"
    touch "$root/beta/skipme/buried.txt"
    touch "$root/.dotfile" "$root/.hidden/visible.txt"

    local cmd="" out="" err="" exit_code=""
    run_command cmd out err exit_code "$binary" --color=never "$root"
    local expected
    expected=$(printf '%s\n' \
        "$root" \
        "├── alpha" \
        "├── beta" \
        "│   ├── nested.txt" \
        "│   ├── skipme" \
        "│   │   └── buried.txt" \
        "│   └── z.log" \
        "└── zed" \
        "" \
        "3 directories, 5 files")
    tree_check "tree bare topology and summary" \
        "$([[ $exit_code -eq 0 && "$out" == "$expected" && -z "$err" ]] && echo true || echo false)" \
        "exit=$exit_code out='$out' err='$err'"

    local empty="$base/empty"
    mkdir "$empty"
    run_command cmd out err exit_code "$binary" --color=never "$empty"
    tree_check "tree empty root counts as a directory" \
        "$([[ $exit_code -eq 0 && "$out" == "$empty"$'\n\n''1 directory, 0 files' ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    run_command cmd out err exit_code "$binary" --color=never "$root"
    tree_check "tree hides and prunes dot entries by default" \
        "$([[ "$out" == *"alpha"* && "$out" != *".dotfile"* && "$out" != *".hidden"* && "$out" != *"visible.txt"* ]] && echo true || echo false)" \
        "out='$out'"
    run_command cmd out err exit_code "$binary" --color=never -a "$root"
    tree_check "tree -a includes hidden files and descendants" \
        "$([[ "$out" == *".dotfile"* && "$out" == *".hidden"* && "$out" == *"visible.txt"* ]] && echo true || echo false)" \
        "out='$out'"

    run_command cmd out err exit_code "$binary" --color=never -d "$root"
    tree_check "tree -d prints only directories and directory-only summary" \
        "$([[ $exit_code -eq 0 && "$out" == *"beta"* && "$out" != *"alpha"* && "$out" == *$'\n3 directories' && "$out" != *"files"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    run_command cmd out err exit_code "$binary" --color=never -L 1 "$root"
    tree_check "tree -L 1 prunes grandchildren without failing" \
        "$([[ $exit_code -eq 0 && "$out" == *"beta"* && "$out" != *"nested.txt"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out' err='$err'"
    run_command cmd out err exit_code "$binary" --color=never -L 0 "$root"
    tree_check "tree -L 0 prints only its operand" \
        "$([[ $exit_code -eq 0 && "$out" == "$root"$'\n\n''1 directory, 0 files' ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    local -a level_cases=("-L nope" "-L" "-L -1" "-L 999999999999999999999999999999")
    local level_case
    for level_case in "${level_cases[@]}"; do
        local -a level_args=()
        read -r -a level_args <<<"$level_case"
        run_command cmd out err exit_code "$binary" "${level_args[@]}"
        tree_check "tree invalid level '$level_case' exits one" \
            "$([[ $exit_code -eq 1 && -n "$err" ]] && echo true || echo false)" \
            "exit=$exit_code err='$err'"
    done

    run_command cmd out err exit_code "$binary" --color=never -I '*.log' "$root"
    tree_check "tree -I excludes matching files" \
        "$([[ "$out" != *"z.log"* && "$out" == *"nested.txt"* ]] && echo true || echo false)" \
        "out='$out'"
    run_command cmd out err exit_code "$binary" --color=never -I skipme "$root"
    tree_check "tree -I prunes matching directories" \
        "$([[ "$out" == *"nested.txt"* && "$out" != *"skipme"* && "$out" != *"buried.txt"* ]] && echo true || echo false)" \
        "out='$out'"
    run_command cmd out err exit_code "$binary" --color=never \
        -I skipme -I '*.log' "$root"
    tree_check "tree repeated -I patterns accumulate" \
        "$([[ "$out" != *"skipme"* && "$out" != *"buried.txt"* && "$out" != *"z.log"* && "$out" == *"nested.txt"* ]] && echo true || echo false)" \
        "out='$out'"
    run_command cmd out err exit_code "$binary" --color=never \
        -I 'skipme|*.log' "$root"
    tree_check "tree -I pipe alternatives accumulate" \
        "$([[ "$out" == *"nested.txt"* && "$out" != *"skipme"* && "$out" != *"buried.txt"* && "$out" != *"z.log"* ]] && echo true || echo false)" \
        "out='$out'"

    run_command cmd out err exit_code "$binary" --color=never --ignore=skipme "$root"
    tree_check "tree --ignore aliases -I" \
        "$([[ $exit_code -eq 0 && "$out" == *"nested.txt"* && "$out" != *"skipme"* && "$out" != *"buried.txt"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code "$binary" --color=never --level=1 "$root"
    tree_check "tree --level aliases -L" \
        "$([[ $exit_code -eq 0 && "$out" == *"beta"* && "$out" != *"nested.txt"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code "$binary" --color=never --directories-only "$root"
    tree_check "tree --directories-only aliases -d" \
        "$([[ $exit_code -eq 0 && "$out" == *"beta"* && "$out" != *"alpha"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code "$binary" --color=never --all "$root"
    tree_check "tree --all aliases -a" \
        "$([[ $exit_code -eq 0 && "$out" == *".dotfile"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    run_command cmd out err exit_code "$binary" --color=never '-aI*.log' "$root"
    tree_check "tree clustered -aI consumes ignore pattern" \
        "$([[ $exit_code -eq 0 && "$out" == *".dotfile"* && "$out" != *"z.log"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code "$binary" --color=never -dIskipme "$root"
    tree_check "tree clustered -dI consumes ignore pattern" \
        "$([[ $exit_code -eq 0 && "$out" == *"beta"* && "$out" != *"skipme"* && "$out" != *"alpha"* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    run_command cmd out err exit_code "$binary" --color=never -I zed "$root"
    tree_check "tree ignore filter recomputes last sibling" \
        "$([[ "$out" == *"└── beta"* && "$out" != *"├── beta"* ]] && echo true || echo false)" \
        "out='$out'"
    run_command cmd out err exit_code "$binary" --color=never -d "$root"
    tree_check "tree directory filter recomputes last sibling" \
        "$([[ "$out" == *"└── beta"* && "$out" != *"├── beta"* ]] && echo true || echo false)" \
        "out='$out'"

    local default_dir="$base/default"
    mkdir "$default_dir"
    touch "$default_dir/only"
    run_command cmd out err exit_code \
        bash -c 'cd "$1" && "$2" --color=never' _ "$default_dir" "$binary"
    tree_check "tree without operands defaults to dot" \
        "$([[ $exit_code -eq 0 && "$out" == "."$'\n└── only\n\n''1 directory, 1 file' ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    local single="$base/single.txt"
    touch "$single"
    run_command cmd out err exit_code "$binary" --color=never "$single"
    tree_check "tree file operand is a single-node tree" \
        "$([[ $exit_code -eq 0 && "$out" == "$single"$'\n\n''0 directories, 1 file' ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    local one="$base/one" two="$base/two"
    mkdir "$one" "$two"
    run_command cmd out err exit_code "$binary" --color=never "$one" "$two"
    tree_check "tree multiple roots have one pre-summary blank line" \
        "$([[ $exit_code -eq 0 && "$out" == "$one"$'\n'"$two"$'\n\n''2 directories, 0 files' ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    run_command cmd out err exit_code "$binary" --color=never "$root"
    tree_check "tree --color=never emits no escape" \
        "$([[ $exit_code -eq 0 && "$out" == *"alpha"* && "$out" != *$'\033'* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code \
        env NO_COLOR=1 TERM=xterm-256color "$binary" --color=always "$root"
    tree_check "tree NO_COLOR overrides --color=always" \
        "$([[ $exit_code -eq 0 && "$out" == *"alpha"* && "$out" != *$'\033'* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code \
        env NO_COLOR=1 TERM=xterm-256color "$binary" --icons=always "$root"
    tree_check "tree icons survive NO_COLOR and distinguish kinds" \
        "$([[ $exit_code -eq 0 && "$out" == *$'\xef\x81\xbb'* && "$out" == *$'\xef\x85\x9b'* && "$out" != *$'\033'* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
    run_command cmd out err exit_code \
        env -u NO_COLOR TERM=xterm-256color "$binary" --color=always "$root"
    tree_check "tree --color=always emits escape without NO_COLOR" \
        "$([[ $exit_code -eq 0 && "$out" == *$'\033'* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"

    local bad_flag
    for bad_flag in --unknown-tree-flag --color=bogus --icons=bogus; do
        run_command cmd out err exit_code "$binary" "$bad_flag"
        tree_check "tree $bad_flag exits one" \
            "$([[ $exit_code -eq 1 && -n "$err" ]] && echo true || echo false)" \
            "exit=$exit_code err='$err'"
    done

    local missing="$base/definitely-missing"
    run_command cmd out err exit_code "$binary" "$missing"
    tree_check "tree missing operand reports a clean error" \
        "$([[ $exit_code -ne 0 && -n "$err" && "$err" != *"error."* && "$err" != *"FileNotFound"* ]] && echo true || echo false)" \
        "exit=$exit_code err='$err'"

    local locked="$base/locked"
    mkdir "$locked"
    touch "$locked/secret"
    if [[ "$EUID" -eq 0 ]]; then
        print_test_result "tree unreadable root reports a clean error" "SKIP" \
            "root bypasses discretionary access checks"
    else
        chmod 000 "$locked"
        run_command cmd out err exit_code "$binary" "$locked"
        chmod 700 "$locked"
        tree_check "tree unreadable root reports a clean error" \
            "$([[ $exit_code -ne 0 && -n "$err" && "$err" != *"error.AccessDenied"* ]] && echo true || echo false)" \
            "exit=$exit_code err='$err'"
    fi

    local target="$base/target" link_root="$base/link-root"
    mkdir "$target" "$link_root"
    touch "$target/secret.txt"
    ln -s ../target "$link_root/link"
    run_command cmd out err exit_code "$binary" --color=never "$link_root"
    tree_check "tree lists directory symlink without following it" \
        "$([[ $exit_code -eq 0 && "$out" == *"link"* && "$out" != *"secret.txt"* && "$out" != *" -> "* ]] && echo true || echo false)" \
        "exit=$exit_code out='$out'"
}
