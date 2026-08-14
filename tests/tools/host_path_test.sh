#!/usr/bin/env bash
# Contract tests for host/host_resolve and PATH wrappers (issue #167).
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs each
# file only when zig-out/bin/<name> exists. host-path isolation is test
# infrastructure, not a built utility, so a file dropped in
# tests/utilities/ would be skipped silently. Invoke this with
# `just test-host-path` and from CI. Needs no Zig build.
#
# WHAT IS BEING PINNED
# --------------------
# tests/integration.sh prepends zig-out/bin to PATH so `$binary` and a
# forgotten unqualified name of the unit under test resolve to the build.
# Fixture setup must NOT follow that PATH: a fake chmod sitting first on
# PATH (the #167 shape) must not run when a test says `chmod`. Explicit
# `$BIN_DIR/chmod` still must, because that is how we invoke the subject.
#
# Every case asserts behaviour (a marker file the fake chmod writes), not
# that a function happens to be defined.

# Reporting helpers, colours, and PROJECT_ROOT.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; several cases expect a command to fail (host_resolve
# of a BIN_DIR-only name, GNU chmod rejecting +a). -u and pipefail stay.
set +e

HOST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_host_path.XXXXXX")"
FAKE_BIN="$HOST_TMP/fakebin"
MARKER="$HOST_TMP/fake-chmod-ran"
TARGET="$HOST_TMP/target"

host_cleanup() {
    rm -rf "$HOST_TMP"
}
trap host_cleanup EXIT

# print_test_summary needs these; init_test_session is not called, because
# it requires zig-out/bin and this suite needs no build at all.
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Make the fake executable with the real host chmod, never PATH. Using
# PATH here would recurse into the thing under test.
sys_chmod() {
    if [[ -x /bin/chmod ]]; then
        /bin/chmod "$@"
    else
        /usr/bin/chmod "$@"
    fi
}

install_fake_chmod() {
    mkdir -p "$FAKE_BIN"
    cat >"$FAKE_BIN/chmod" <<'EOF'
#!/usr/bin/env bash
printf 'fake-chmod ran\n' >>"${FAKE_CHMOD_MARKER:?}"
exit 0
EOF
    sys_chmod +x "$FAKE_BIN/chmod"
}

# A name that exists only in FAKE_BIN, so host_resolve cannot fall back
# to /bin or /usr/bin.
install_vibe_only_tool() {
    cat >"$FAKE_BIN/onlyinvibe" <<'EOF'
#!/usr/bin/env bash
printf 'onlyinvibe ran\n' >>"${FAKE_CHMOD_MARKER:?}"
exit 0
EOF
    sys_chmod +x "$FAKE_BIN/onlyinvibe"
}

truncate_marker() {
    : >"$MARKER"
}

marker_was_written() {
    grep -q 'fake-chmod ran' "$MARKER" 2>/dev/null
}

setup_path_shadow() {
    install_fake_chmod
    install_vibe_only_tool
    : >"$TARGET"
    truncate_marker
    export FAKE_CHMOD_MARKER="$MARKER"
    # Fake sits in front of everything, including zig-out/bin, matching
    # the prepend tests/integration.sh performs for the real build.
    export PATH="$FAKE_BIN:$PATH"
}

# ===========================================================================
# Bare `chmod` must not follow PATH into a vibeutils (or fake) binary.
# ===========================================================================

test_bare_chmod_does_not_run_path_shadow() {
    echo -e "${CYAN}Bare chmod does not run a PATH-shadowing fake...${NC}"
    truncate_marker
    chmod 644 "$TARGET" >/dev/null 2>&1
    if marker_was_written; then
        print_test_result "bare chmod does not run a PATH-shadowing fake" "FAIL" \
            "fake $FAKE_BIN/chmod ran; fixture setup followed PATH"
    else
        print_test_result "bare chmod does not run a PATH-shadowing fake" "PASS"
    fi
}

test_host_resolve_chmod_is_system() {
    echo -e "${CYAN}host_resolve chmod is the system binary...${NC}"
    local resolved=""
    if declare -F host_resolve >/dev/null 2>&1; then
        resolved=$(host_resolve chmod)
    fi
    if [[ "$resolved" == "/bin/chmod" || "$resolved" == "/usr/bin/chmod" ]]; then
        print_test_result "host_resolve chmod is /bin/chmod or /usr/bin/chmod" "PASS"
    else
        print_test_result "host_resolve chmod is /bin/chmod or /usr/bin/chmod" "FAIL" \
            "got '$resolved'"
    fi
}

test_host_chmod_does_not_run_path_shadow() {
    echo -e "${CYAN}host chmod does not run a PATH-shadowing fake...${NC}"
    truncate_marker
    if declare -F host >/dev/null 2>&1; then
        host chmod 644 "$TARGET" >/dev/null 2>&1
    fi
    if marker_was_written; then
        print_test_result "host chmod does not run a PATH-shadowing fake" "FAIL" \
            "fake $FAKE_BIN/chmod ran"
    elif ! declare -F host >/dev/null 2>&1; then
        print_test_result "host chmod does not run a PATH-shadowing fake" "FAIL" \
            "host is not defined"
    else
        print_test_result "host chmod does not run a PATH-shadowing fake" "PASS"
    fi
}

test_explicit_bindir_chmod_still_runs_the_subject() {
    echo -e "${CYAN}Explicit BIN_DIR/chmod still runs the subject...${NC}"
    truncate_marker
    "$FAKE_BIN/chmod" 644 "$TARGET" >/dev/null 2>&1
    if marker_was_written; then
        print_test_result "explicit BIN_DIR/chmod still runs the fake subject" "PASS"
    else
        print_test_result "explicit BIN_DIR/chmod still runs the fake subject" "FAIL" \
            "fake $FAKE_BIN/chmod did not run; the subject path was swallowed"
    fi
}

test_host_resolve_refuses_bindir() {
    echo -e "${CYAN}host_resolve refuses a name that only exists in BIN_DIR...${NC}"
    local saved_bin="$BIN_DIR"
    local resolved="" status=0
    if ! declare -F host_resolve >/dev/null 2>&1; then
        print_test_result "host_resolve refuses a BIN_DIR-only name" "FAIL" \
            "host_resolve is not defined"
        return
    fi
    BIN_DIR="$FAKE_BIN"
    resolved=$(host_resolve onlyinvibe)
    status=$?
    BIN_DIR="$saved_bin"
    if [[ "$status" -ne 0 && "$resolved" != "$FAKE_BIN/onlyinvibe" ]]; then
        print_test_result "host_resolve refuses a BIN_DIR-only name" "PASS"
    else
        print_test_result "host_resolve refuses a BIN_DIR-only name" "FAIL" \
            "status=$status resolved='$resolved'"
    fi
}

test_host_refuses_bindir() {
    echo -e "${CYAN}host refuses to exec a BIN_DIR-only name...${NC}"
    local saved_bin="$BIN_DIR"
    truncate_marker
    BIN_DIR="$FAKE_BIN"
    if declare -F host >/dev/null 2>&1; then
        host onlyinvibe >/dev/null 2>&1
    fi
    BIN_DIR="$saved_bin"
    if grep -q 'onlyinvibe ran' "$MARKER" 2>/dev/null; then
        print_test_result "host refuses to exec a BIN_DIR-only name" "FAIL" \
            "onlyinvibe from BIN_DIR ran"
    elif ! declare -F host >/dev/null 2>&1; then
        print_test_result "host refuses to exec a BIN_DIR-only name" "FAIL" \
            "host is not defined"
    else
        print_test_result "host refuses to exec a BIN_DIR-only name" "PASS"
    fi
}

# Regression: wrappers are export -f'd into `bash -c` / timeout children,
# but BIN_DIR was a shell-local. An empty BIN_DIR made the refuse pattern
# `"$BIN_DIR"/*` expand to `/*`, so every absolute host path (e.g.
# /bin/sleep) was treated as the build and returned 127. That is why
# timeout --kill-after, tr extra-operand, tee special-characters, cut,
# and find failed in CI: they all spawn bash -c that calls a wrapped name.
test_host_resolve_empty_bin_dir_does_not_refuse_host() {
    echo -e "${CYAN}host_resolve with empty BIN_DIR still returns a host binary...${NC}"
    local resolved="" status=0
    if ! declare -F host_resolve >/dev/null 2>&1; then
        print_test_result "host_resolve empty BIN_DIR does not refuse /bin or /usr/bin" "FAIL" \
            "host_resolve is not defined"
        return
    fi
    (
        unset BIN_DIR
        resolved=$(host_resolve cat)
        status=$?
        if [[ "$status" -eq 0 && ( "$resolved" == "/bin/cat" || "$resolved" == "/usr/bin/cat" ) ]]; then
            exit 0
        fi
        printf 'status=%s resolved=%s\n' "$status" "$resolved" >&2
        exit 1
    )
    if [[ $? -eq 0 ]]; then
        print_test_result "host_resolve empty BIN_DIR does not refuse /bin or /usr/bin" "PASS"
    else
        print_test_result "host_resolve empty BIN_DIR does not refuse /bin or /usr/bin" "FAIL" \
            "empty BIN_DIR treated a host path as BIN_DIR/*"
    fi
}

test_wrapper_works_in_bash_c_without_bin_dir() {
    echo -e "${CYAN}exported cat wrapper works in bash -c when BIN_DIR is unset...${NC}"
    local status=0
    (
        unset BIN_DIR
        bash -c 'cat /dev/null'
    )
    status=$?
    if [[ "$status" -eq 0 ]]; then
        print_test_result "exported wrapper works in bash -c without BIN_DIR" "PASS"
    else
        print_test_result "exported wrapper works in bash -c without BIN_DIR" "FAIL" \
            "bash -c 'cat /dev/null' exited $status (expected 0); empty BIN_DIR likely matched /*"
    fi
}

# Fallback for host-missing names (seq/timeout on macOS) is `"$BIN_DIR/$name"`.
# That only works in `bash -c` if BIN_DIR is in the environment, not just
# the parent shell. Timeout's child is a new bash; unexported BIN_DIR is
# empty there even when the parent set it.
test_bin_dir_is_exported_to_bash_c() {
    echo -e "${CYAN}BIN_DIR is visible to bash -c children...${NC}"
    local child_bin=""
    child_bin=$(bash -c 'printf %s "${BIN_DIR-}"')
    if [[ -n "$child_bin" && "$child_bin" == "$BIN_DIR" ]]; then
        print_test_result "BIN_DIR is exported to bash -c" "PASS"
    else
        print_test_result "BIN_DIR is exported to bash -c" "FAIL" \
            "child saw '$child_bin' parent has '$BIN_DIR'"
    fi
}

# GNU `yes -- -not` prints `-not`; BSD `yes -- -not` prints `--` (the
# first operand is the payload). Wrapping `yes` to the host made
# find_test.sh's `yes -- -not | head` build 50000 `--` tokens on macOS,
# so find exited 1 instead of parsing a deep -not chain. repeat_lines
# must not go through that GNU-only `--` spelling: sabotage `yes` to
# emit `--` and still require `-not`.
test_repeat_lines_dash_prefixed_token_ignores_host_yes() {
    echo -e "${CYAN}repeat_lines emits a dash-prefixed token even if yes prints --...${NC}"
    if ! declare -F repeat_lines >/dev/null 2>&1; then
        print_test_result "repeat_lines emits -not, not --" "FAIL" \
            "repeat_lines is not defined"
        return
    fi
    local lines=()
    (
        yes() { printf '%s\n' --; }
        export -f yes
        mapfile -t lines < <(repeat_lines 3 -not)
        if [[ ${#lines[@]} -eq 3 && ${lines[0]} == "-not" && ${lines[1]} == "-not" && ${lines[2]} == "-not" ]]; then
            exit 0
        fi
        printf 'count=%s first=%s\n' "${#lines[@]}" "${lines[0]-}" >&2
        exit 1
    )
    if [[ $? -eq 0 ]]; then
        print_test_result "repeat_lines emits -not, not --" "PASS"
    else
        print_test_result "repeat_lines emits -not, not --" "FAIL" \
            "repeat_lines followed GNU yes -- and emitted -- (or is missing)"
    fi
}

test_repeat_lines_paren_token_and_count() {
    echo -e "${CYAN}repeat_lines emits N copies of a parenthesis token...${NC}"
    if ! declare -F repeat_lines >/dev/null 2>&1; then
        print_test_result "repeat_lines emits N parenthesis tokens" "FAIL" \
            "repeat_lines is not defined"
        return
    fi
    local lines=()
    mapfile -t lines < <(repeat_lines 4 '(')
    if [[ ${#lines[@]} -eq 4 && ${lines[0]} == "(" && ${lines[3]} == "(" ]]; then
        print_test_result "repeat_lines emits N parenthesis tokens" "PASS"
    else
        print_test_result "repeat_lines emits N parenthesis tokens" "FAIL" \
            "count=${#lines[@]} first='${lines[0]-}'"
    fi
}

main() {
    detect_platform
    setup_path_shadow

    echo -e "${BLUE}Testing host PATH isolation${NC}"
    echo "============================"

    test_bare_chmod_does_not_run_path_shadow
    test_host_resolve_chmod_is_system
    test_host_chmod_does_not_run_path_shadow
    test_explicit_bindir_chmod_still_runs_the_subject
    test_host_resolve_refuses_bindir
    test_host_refuses_bindir
    test_host_resolve_empty_bin_dir_does_not_refuse_host
    test_wrapper_works_in_bash_c_without_bin_dir
    test_bin_dir_is_exported_to_bash_c
    test_repeat_lines_dash_prefixed_token_ignores_host_yes
    test_repeat_lines_paren_token_and_count

    print_test_summary "host-path"
}

main "$@"
