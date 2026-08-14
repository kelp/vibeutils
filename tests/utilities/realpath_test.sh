#!/usr/bin/env bash
# Comprehensive tests for realpath utility
# Tests all flags, path resolution, edge cases, and GNU extensions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_realpath() {
    local util="realpath"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Help and version
    local help_output
    help_output=$("$binary" --help)
    if [[ "$help_output" =~ "Usage: realpath" && "$help_output" =~ "--no-symlinks" ]]; then
        print_test_result "help output contains expected content" "PASS"
    else
        print_test_result "help output contains expected content" "FAIL" "Missing expected help content"
    fi

    local version_output
    version_output=$("$binary" --version)
    if [[ "$version_output" =~ "realpath" ]]; then
        print_test_result "version output contains utility name" "PASS"
    else
        print_test_result "version output contains utility name" "FAIL" "Version output: '$version_output'"
    fi

    echo -e "${CYAN}Testing default mode (canonicalize-existing)...${NC}"

    # Existing paths should resolve
    test_command_exit_code "existing path succeeds" 0 "$binary" /tmp
    test_command_exit_code "root path succeeds" 0 "$binary" /

    # Output should be absolute
    local output
    output=$("$binary" /tmp 2>/dev/null)
    if [[ "$output" == /* ]]; then
        print_test_result "output is absolute path" "PASS"
    else
        print_test_result "output is absolute path" "FAIL" "Expected absolute path, got: $output"
    fi

    # Nonexistent paths: default mode uses GNU -E semantics
    # (all-but-last-exist), so /nonexistent resolves through /
    test_command_exit_code "nonexistent last component succeeds (GNU default)" 0 "$binary" /nonexistent_vibeutils_path 2>/dev/null

    # Error message for fully nonexistent intermediate path
    local err_output
    err_output=$("$binary" /nonexistent_dir/nonexistent_file 2>&1 >/dev/null)
    if [[ "$err_output" =~ realpath ]]; then
        print_test_result "error message includes program name" "PASS"
    else
        print_test_result "error message includes program name" "FAIL" "Error: $err_output"
    fi

    echo -e "${CYAN}Testing -e (canonicalize-existing)...${NC}"

    test_command_exit_code "-e existing path succeeds" 0 "$binary" -e /tmp
    test_command_exit_code "-e nonexistent path fails" 1 "$binary" -e /nonexistent_vibeutils_path 2>/dev/null

    echo -e "${CYAN}Testing -m (canonicalize-missing)...${NC}"

    # -m should succeed even for nonexistent paths
    test_command_exit_code "-m nonexistent path succeeds" 0 "$binary" -m /tmp/nonexistent_vibeutils_path

    local missing_output
    missing_output=$("$binary" -m /tmp/nonexistent_vibeutils_path 2>/dev/null)
    if [[ "$missing_output" == *"nonexistent_vibeutils_path"* ]]; then
        print_test_result "-m preserves nonexistent component" "PASS"
    else
        print_test_result "-m preserves nonexistent component" "FAIL" "Output: $missing_output"
    fi

    # -m should still resolve .. components
    local missing_dotdot
    missing_dotdot=$("$binary" -m /tmp/foo/../bar 2>/dev/null)
    if [[ "$missing_dotdot" != *".."* ]]; then
        print_test_result "-m resolves .. in nonexistent paths" "PASS"
    else
        print_test_result "-m resolves .. in nonexistent paths" "FAIL" "Output: $missing_dotdot"
    fi

    echo -e "${CYAN}Testing -s (no-symlinks)...${NC}"

    # -s should resolve . and .. without following symlinks
    test_command_output "-s resolves .." "/usr/lib" "$binary" -s /usr/bin/../lib
    test_command_output "-s resolves ." "/usr/bin" "$binary" -s /usr/./bin
    # Issue #62: popping '..' requires the preceding component to exist and be a
    # directory. /a/b/c does not exist on any host, so GNU 9.5 errors ENOENT
    # rc=1 rather than printing /a/d. (Was previously asserted as "/a/d" rc=0,
    # which encoded the pre-fix textual-pop bug.)
    test_command_exit_code "-s errors on complex .. with nonexistent prefix" 1 "$binary" -s /a/b/c/../../d
    test_command_output "-s resolves root .." "/" "$binary" -s /../../..
    test_command_output "-s removes redundant slashes" "/usr/bin/ls" "$binary" -s /usr///bin///ls

    # --strip alias should work identically
    test_command_output "--strip alias" "/usr/lib" "$binary" --strip /usr/bin/../lib

    # --no-symlinks long form
    test_command_output "--no-symlinks long form" "/usr/lib" "$binary" --no-symlinks /usr/bin/../lib

    echo -e "${CYAN}Testing -z (zero delimiter)...${NC}"

    local zero_out="$TEMP_DIR/realpath_zero_test"
    "$binary" -z -s /usr/bin > "$zero_out" 2>/dev/null
    if printf "/usr/bin\0" | cmp -s - "$zero_out"; then
        print_test_result "-z NUL delimiter" "PASS"
    else
        print_test_result "-z NUL delimiter" "FAIL" "Output doesn't match expected NUL-terminated"
    fi
    rm -f "$zero_out"

    # --zero long form
    test_command_exit_code "--zero flag exists" 0 "$binary" --zero -s /tmp

    echo -e "${CYAN}Testing -q (quiet)...${NC}"

    # -q should suppress error messages (use path with missing intermediate
    # so default -E mode actually fails).
    local quiet_stderr
    quiet_stderr=$("$binary" -q /nonexistent_vibeutils_dir/nested 2>&1 >/dev/null)
    if [[ -z "$quiet_stderr" ]]; then
        print_test_result "-q suppresses error messages" "PASS"
    else
        print_test_result "-q suppresses error messages" "FAIL" "Stderr: $quiet_stderr"
    fi

    # But exit code should still be non-zero
    test_command_exit_code "-q still returns error code" 1 "$binary" -q /nonexistent_vibeutils_dir/nested 2>/dev/null

    echo -e "${CYAN}Testing --relative-to...${NC}"

    test_command_output "--relative-to basic" "bin/ls" "$binary" -s --relative-to=/usr /usr/bin/ls
    test_command_output "--relative-to same dir" "." "$binary" -s --relative-to=/usr /usr
    test_command_output "--relative-to parent" ".." "$binary" -s --relative-to=/usr/bin /usr

    echo -e "${CYAN}Testing --relative-base...${NC}"

    # Path under base: relative output
    test_command_output "--relative-base under base" "bin/ls" "$binary" -s --relative-base=/usr /usr/bin/ls

    # Path not under base: absolute output
    test_command_output "--relative-base not under base" "/etc/hosts" "$binary" -s --relative-base=/usr /etc/hosts

    echo -e "${CYAN}Testing multiple paths...${NC}"

    test_command_output "multiple paths" $'/usr/bin\n/usr/lib' "$binary" -s /usr/bin /usr/lib

    # Multiple paths — both resolve in default mode (GNU -E semantics)
    local multi_out multi_err
    multi_out=$("$binary" /tmp /nonexistent_vibeutils_path 2>/dev/null)
    if [[ "$multi_out" == *"/tmp"* || "$multi_out" == *"/private/tmp"* ]]; then
        print_test_result "multiple paths: valid one succeeds" "PASS"
    else
        print_test_result "multiple paths: valid one succeeds" "FAIL" "Output: $multi_out"
    fi
    # With -e (strict), nonexistent path causes failure
    test_command_exit_code "multiple paths with -e failure returns error" 1 "$binary" -e /tmp /nonexistent_vibeutils_path 2>/dev/null

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments
    test_command_exit_code "no arguments" 1 "$binary" 2>/dev/null

    # Missing operand error message
    local no_args_err
    no_args_err=$("$binary" 2>&1 >/dev/null)
    if [[ "$no_args_err" =~ "missing operand" ]]; then
        print_test_result "missing operand error message" "PASS"
    else
        print_test_result "missing operand error message" "FAIL" "Error: $no_args_err"
    fi

    # Invalid flags
    test_command_exit_code "invalid flag" 1 "$binary" --invalid 2>/dev/null
    test_command_exit_code "invalid short flag" 1 "$binary" -x 2>/dev/null

    echo -e "${CYAN}Testing symlink resolution...${NC}"

    # Create a temporary symlink for testing
    local link_dir="$TEMP_DIR/realpath_symlink_test"
    mkdir -p "$link_dir"
    echo "test" > "$link_dir/real_file"
    if ! ln -sf "$link_dir/real_file" "$link_dir/link_file" 2>/dev/null || \
        [[ ! -L "$link_dir/link_file" ]]; then
        print_test_result "symlink tests" "FAIL" \
            "host ln could not create a symlink in $link_dir"
    else
        # Default mode should resolve symlink
        local resolved
        resolved=$("$binary" "$link_dir/link_file" 2>/dev/null)
        if [[ "$resolved" == *"real_file"* ]]; then
            print_test_result "default mode resolves symlinks" "PASS"
        else
            print_test_result "default mode resolves symlinks" "FAIL" "Output: $resolved"
        fi

        # -s mode should NOT resolve symlink
        local no_resolve
        no_resolve=$("$binary" -s "$link_dir/link_file" 2>/dev/null)
        if [[ "$no_resolve" == *"link_file"* ]]; then
            print_test_result "-s mode preserves symlinks" "PASS"
        else
            print_test_result "-s mode preserves symlinks" "FAIL" "Output: $no_resolve"
        fi
    fi

    rm -rf "$link_dir"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # -m -s combined
    test_command_output "-m -s combined" "/nonexistent/resolved" "$binary" -m -s /nonexistent/./foo/../resolved
    test_command_exit_code "-m -s combined succeeds" 0 "$binary" -m -s /nonexistent/path

    # -q -m combined
    test_command_exit_code "-q -m succeeds for nonexistent" 0 "$binary" -q -m /nonexistent/path

    # -z -s combined
    local zs_out="$TEMP_DIR/realpath_zs_test"
    "$binary" -z -s /usr/bin > "$zs_out" 2>/dev/null
    if printf "/usr/bin\0" | cmp -s - "$zs_out"; then
        print_test_result "-z -s combined" "PASS"
    else
        print_test_result "-z -s combined" "FAIL"
    fi
    rm -f "$zs_out"

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Root path
    test_command_output "-s root" "/" "$binary" -s /

    # Path with only dots
    test_command_exit_code "dot path succeeds" 0 "$binary" .

    # Double dash separator
    test_command_exit_code "double dash with path" 0 "$binary" -s -- /usr/bin

    # Regression test: --relative-base must check path boundary, not just prefix
    echo -e "${CYAN}Testing --relative-base path boundary...${NC}"

    local rb_dir="$TEMP_DIR/realpath_rb_test"
    mkdir -p "$rb_dir/usr" "$rb_dir/usr2/bin"

    # Path under base: should produce relative output
    local rb_under
    rb_under=$("$binary" -s --relative-base="$rb_dir/usr" "$rb_dir/usr/lib" 2>/dev/null)
    if [[ "$rb_under" == "lib" ]]; then
        print_test_result "--relative-base under base is relative" "PASS"
    else
        print_test_result "--relative-base under base is relative" "FAIL" "Expected 'lib', got '$rb_under'"
    fi

    # Path with similar prefix but different directory: should produce absolute output
    local rb_outside
    rb_outside=$("$binary" -s --relative-base="$rb_dir/usr" "$rb_dir/usr2/bin" 2>/dev/null)
    if [[ "$rb_outside" == /* ]]; then
        print_test_result "--relative-base prefix mismatch is absolute" "PASS"
    else
        print_test_result "--relative-base prefix mismatch is absolute" "FAIL" "Expected absolute path, got '$rb_outside'"
    fi

    rm -rf "$rb_dir"

    # Regression test: realpath -m with .. past root should return /
    echo -e "${CYAN}Testing .. past root regression...${NC}"
    test_command_output "realpath -m .. past root returns /" "/" \
        "$binary" -m /tmp/nonexistent/../../../..

    # F46: GNU default is -E (all-but-last), not -e (all must exist)
    echo -e "${CYAN}Testing default mode uses GNU -E semantics...${NC}"

    # Default mode: last component may be missing if parent exists
    local default_out default_rc
    default_out=$("$binary" /tmp/nonexistent_vibeutils_test_xyz 2>/dev/null)
    default_rc=$?
    if [[ "$default_rc" -eq 0 ]]; then
        print_test_result "default: missing last component exits 0" "PASS"
    else
        print_test_result "default: missing last component exits 0" "FAIL" \
            "Expected exit 0, got $default_rc"
    fi

    if [[ "$default_out" == *"nonexistent_vibeutils_test_xyz"* ]]; then
        print_test_result "default: missing last component prints path" "PASS"
    else
        print_test_result "default: missing last component prints path" "FAIL" \
            "Expected path containing nonexistent_vibeutils_test_xyz, got: $default_out"
    fi

    # Default mode: missing intermediate directory still fails
    test_command_exit_code "default: missing intermediate exits 1" 1 \
        "$binary" /nonexistent_vibeutils_dir/somefile 2>/dev/null

    # -e mode: missing last component must fail (stricter than default)
    local e_rc
    "$binary" -e /tmp/nonexistent_vibeutils_test_xyz >/dev/null 2>&1
    e_rc=$?
    if [[ "$e_rc" -ne 0 ]]; then
        print_test_result "-e: missing last component exits nonzero" "PASS"
    else
        print_test_result "-e: missing last component exits nonzero" "FAIL" \
            "Expected nonzero exit, got $e_rc"
    fi

    # Verify default and -e differ: default succeeds, -e fails for same path
    local default_rc2 e_rc2
    "$binary" /tmp/nonexistent_vibeutils_test_xyz >/dev/null 2>/dev/null
    default_rc2=$?
    "$binary" -e /tmp/nonexistent_vibeutils_test_xyz >/dev/null 2>/dev/null
    e_rc2=$?
    if [[ "$default_rc2" -eq 0 && "$e_rc2" -ne 0 ]]; then
        print_test_result "default vs -e: different behavior for missing last" "PASS"
    else
        print_test_result "default vs -e: different behavior for missing last" "FAIL" \
            "default exit=$default_rc2 -e exit=$e_rc2 (expected 0 and nonzero)"
    fi

    # Audit: error messages use @errorName (Zig symbols) not POSIX strings
    echo -e "${CYAN}Testing POSIX error messages...${NC}"

    local err_msg
    err_msg=$("$binary" -e /nonexistent_vibeutils_xyz 2>&1 >/dev/null)
    if [[ "$err_msg" == *"No such file or directory"* ]]; then
        print_test_result "error message uses POSIX 'No such file or directory'" "PASS"
    else
        print_test_result "error message uses POSIX 'No such file or directory'" "FAIL" \
            "Got: $err_msg"
    fi

    # Must NOT contain Zig error name
    if [[ "$err_msg" != *"FileNotFound"* ]]; then
        print_test_result "error message does not contain 'FileNotFound'" "PASS"
    else
        print_test_result "error message does not contain 'FileNotFound'" "FAIL" \
            "Got: $err_msg"
    fi

    # Issue #63: GNU realpath prints the operand bare for ordinary paths and
    # only quotes it (via quotearg shell-escape style) when the operand is
    # empty or needs shell quoting (pinned on coreutils 9.5:
    # `realpath: /nonexistent_vibeutils_xyz: No such file or directory`, no
    # quotes). Lock in the bare form so a future "helpful" fix doesn't wrap it
    # in quotes without re-verifying against GNU.
    if [[ "$err_msg" == "realpath: /nonexistent_vibeutils_xyz: No such file or directory" ]]; then
        print_test_result "error message operand is unquoted (GNU parity)" "PASS"
    else
        print_test_result "error message operand is unquoted (GNU parity)" "FAIL" \
            "Got: $err_msg"
    fi

    # Audit: --relative-to only tested with -s; verify it works in default mode
    echo -e "${CYAN}Testing --relative-to without -s...${NC}"

    local rel_dir="$TEMP_DIR/realpath_rel_test"
    mkdir -p "$rel_dir/subdir"
    echo "test" > "$rel_dir/subdir/file.txt"

    local rel_out
    rel_out=$("$binary" --relative-to="$rel_dir" "$rel_dir/subdir/file.txt" 2>/dev/null)
    if [[ "$rel_out" == "subdir/file.txt" ]]; then
        print_test_result "--relative-to without -s resolves existing paths" "PASS"
    else
        print_test_result "--relative-to without -s resolves existing paths" "FAIL" \
            "Expected 'subdir/file.txt', got '$rel_out'"
    fi
    rm -rf "$rel_dir"

    # Issue #46: a RELATIVE --relative-to base must be resolved against the cwd,
    # not forwarded verbatim to realPathFileAbsolute (which asserts isAbsolute
    # and aborts with SIGABRT / exit 134). GNU prints the target relative to the
    # resolved base. We cd into a tmp dir so "." is deterministic.
    echo -e "${CYAN}Testing relative --relative-to base (issue #46)...${NC}"

    local rel_base_dir="$TEMP_DIR/realpath_rel_base_test"
    mkdir -p "$rel_base_dir/sub"

    local rel_base_out rel_base_rc
    rel_base_out=$(cd "$rel_base_dir" && "$binary" --relative-to=. "$rel_base_dir/sub" 2>/dev/null)
    rel_base_rc=$?
    if [[ "$rel_base_rc" -eq 0 && "$rel_base_out" == "sub" ]]; then
        print_test_result "relative --relative-to=. resolves against cwd" "PASS"
    else
        print_test_result "relative --relative-to=. resolves against cwd" "FAIL" \
            "Expected exit 0 and 'sub', got exit=$rel_base_rc out='$rel_base_out'"
    fi
    rm -rf "$rel_base_dir"

    # Issue #46: an empty --relative-to= value must produce a clean ENOENT error
    # (exit 1), never a SIGABRT (exit 134) from the isAbsolute assert.
    local empty_rt_err empty_rt_rc
    empty_rt_err=$("$binary" --relative-to= /tmp 2>&1 >/dev/null)
    empty_rt_rc=$?
    if [[ "$empty_rt_rc" -eq 1 ]]; then
        print_test_result "empty --relative-to= exits 1 (not 134)" "PASS"
    else
        print_test_result "empty --relative-to= exits 1 (not 134)" "FAIL" \
            "Expected exit 1, got $empty_rt_rc"
    fi
    if [[ "$empty_rt_err" == *"No such file or directory"* ]]; then
        print_test_result "empty --relative-to= reports No such file or directory" "PASS"
    else
        print_test_result "empty --relative-to= reports No such file or directory" "FAIL" \
            "Error: $empty_rt_err"
    fi

    # Issue #62: under -s, popping '..' requires the preceding component to
    # exist and be a directory. Missing -> ENOENT rc=1; a file (or a
    # symlink-to-file, followed) -> ENOTDIR rc=1. Under -m -s the check is
    # skipped. The final component after cleanup need not exist under plain -s.
    echo -e "${CYAN}Testing -s '..' preceding-component check (issue #62)...${NC}"

    local dd_dir="$TEMP_DIR/realpath_dotdot_test"
    mkdir -p "$dd_dir/sub"
    echo "test" > "$dd_dir/file.txt"
    ln -sfn sub "$dd_dir/slink" 2>/dev/null
    ln -sfn file.txt "$dd_dir/flink" 2>/dev/null

    # Missing preceding component -> ENOENT rc=1 (was <cwd>/x rc=0 pre-fix).
    local dd_enoent_out dd_enoent_err dd_enoent_rc
    dd_enoent_out=$(cd "$dd_dir" && "$binary" -s nosuch/../x 2>/dev/null)
    dd_enoent_err=$(cd "$dd_dir" && "$binary" -s nosuch/../x 2>&1 >/dev/null)
    (cd "$dd_dir" && "$binary" -s nosuch/../x >/dev/null 2>&1)
    dd_enoent_rc=$?
    if [[ "$dd_enoent_rc" -eq 1 && -z "$dd_enoent_out" && \
          "$dd_enoent_err" == *"No such file or directory"* ]]; then
        print_test_result "-s '..' past missing component errors ENOENT" "PASS"
    else
        print_test_result "-s '..' past missing component errors ENOENT" "FAIL" \
            "rc=$dd_enoent_rc out='$dd_enoent_out' err='$dd_enoent_err'"
    fi

    # Preceding component is a regular file -> ENOTDIR rc=1.
    local dd_enotdir_out dd_enotdir_err dd_enotdir_rc
    dd_enotdir_out=$(cd "$dd_dir" && "$binary" -s file.txt/../x 2>/dev/null)
    dd_enotdir_err=$(cd "$dd_dir" && "$binary" -s file.txt/../x 2>&1 >/dev/null)
    (cd "$dd_dir" && "$binary" -s file.txt/../x >/dev/null 2>&1)
    dd_enotdir_rc=$?
    if [[ "$dd_enotdir_rc" -eq 1 && -z "$dd_enotdir_out" && \
          "$dd_enotdir_err" == *"Not a directory"* ]]; then
        print_test_result "-s '..' past regular file errors ENOTDIR" "PASS"
    else
        print_test_result "-s '..' past regular file errors ENOTDIR" "FAIL" \
            "rc=$dd_enotdir_rc out='$dd_enotdir_out' err='$dd_enotdir_err'"
    fi

    # Absolute path with a missing prefix before '..' -> ENOENT rc=1.
    local dd_abs_rc
    "$binary" -s "$dd_dir/nosuch/../x" >/dev/null 2>&1
    dd_abs_rc=$?
    if [[ "$dd_abs_rc" -eq 1 ]]; then
        print_test_result "-s absolute '..' past missing prefix errors" "PASS"
    else
        print_test_result "-s absolute '..' past missing prefix errors" "FAIL" \
            "Expected exit 1, got $dd_abs_rc"
    fi

    # -m -s skips the check: nonexistent components permitted, textual result.
    local dd_ms_out dd_ms_rc
    dd_ms_out=$(cd "$dd_dir" && "$binary" -m -s nosuch/../x 2>/dev/null)
    dd_ms_rc=$?
    if [[ "$dd_ms_rc" -eq 0 && "$dd_ms_out" == "$dd_dir/x" ]]; then
        print_test_result "-m -s '..' past missing component succeeds" "PASS"
    else
        print_test_result "-m -s '..' past missing component succeeds" "FAIL" \
            "Expected exit 0 and '$dd_dir/x', got rc=$dd_ms_rc out='$dd_ms_out'"
    fi

    # Preceding component is a real directory; final component may be missing.
    local dd_ok_out dd_ok_rc
    dd_ok_out=$(cd "$dd_dir" && "$binary" -s sub/../nosuch_final 2>/dev/null)
    dd_ok_rc=$?
    if [[ "$dd_ok_rc" -eq 0 && "$dd_ok_out" == "$dd_dir/nosuch_final" ]]; then
        print_test_result "-s '..' past existing dir, missing final, succeeds" "PASS"
    else
        print_test_result "-s '..' past existing dir, missing final, succeeds" "FAIL" \
            "Expected exit 0 and '$dd_dir/nosuch_final', got rc=$dd_ok_rc out='$dd_ok_out'"
    fi

    # symlink-to-directory before '..': stat follows, sees a dir, pops textually.
    if [[ -L "$dd_dir/slink" ]]; then
        local dd_slink_out dd_slink_rc
        dd_slink_out=$(cd "$dd_dir" && "$binary" -s slink/../file.txt 2>/dev/null)
        dd_slink_rc=$?
        if [[ "$dd_slink_rc" -eq 0 && "$dd_slink_out" == "$dd_dir/file.txt" ]]; then
            print_test_result "-s '..' past symlink-to-dir succeeds" "PASS"
        else
            print_test_result "-s '..' past symlink-to-dir succeeds" "FAIL" \
                "Expected exit 0 and '$dd_dir/file.txt', got rc=$dd_slink_rc out='$dd_slink_out'"
        fi
    else
        print_test_result "-s '..' past symlink-to-dir succeeds" "FAIL" \
            "host ln could not create $dd_dir/slink"
    fi

    # symlink-to-file before '..': stat follows, sees a non-dir -> ENOTDIR rc=1.
    if [[ -L "$dd_dir/flink" ]]; then
        local dd_flink_err dd_flink_rc
        dd_flink_err=$(cd "$dd_dir" && "$binary" -s flink/../file.txt 2>&1 >/dev/null)
        (cd "$dd_dir" && "$binary" -s flink/../file.txt >/dev/null 2>&1)
        dd_flink_rc=$?
        if [[ "$dd_flink_rc" -eq 1 && "$dd_flink_err" == *"Not a directory"* ]]; then
            print_test_result "-s '..' past symlink-to-file errors ENOTDIR" "PASS"
        else
            print_test_result "-s '..' past symlink-to-file errors ENOTDIR" "FAIL" \
                "rc=$dd_flink_rc err='$dd_flink_err'"
        fi
    else
        print_test_result "-s '..' past symlink-to-file errors ENOTDIR" "FAIL" \
            "host ln could not create $dd_dir/flink"
    fi

    rm -rf "$dd_dir"
}
