#!/usr/bin/env bash
# Coverage oracle and four-mode contract tests for tests/lib/fd_modes.sh
# (TODO.md ### 1 File Descriptor Mode Tests).
#
# WHAT IS BEING GUARDED
# ---------------------
# Issue #5 was a positional File.writer() that seeks to offset 0 and
# overwrites a file opened O_APPEND. A source grep and one echo case
# caught the first instance; they do not catch the next utility that
# grows its own main() or a future writer() regression on stderr.
# The runtime matrix in tests/lib/fd_modes.sh is what would have failed
# on every binary, under >> file, | cat, > file, and 2>&1 >> file.
#
# This file is not that matrix. It is the gate that the matrix is
# complete and that its four modes mean what the plan says:
#
#   1. Every build/utils.zig utilities[].name (49 today, including `[`)
#      has an explicit fixture. A missing row is FAIL, not a skip.
#   2. echo (known payload `fd-mode\n`) and true (empty stdout) satisfy
#      the four fd-mode contracts once the harness exists.
#
# An empty fixture table, or a missing tests/lib/fd_modes.sh, must make
# this suite RED. That is the tooth the implementer turns GREEN.
#
# WHY tests/tools/ AND NOT tests/utilities/
# -----------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a
# file only when zig-out/bin/<name> is executable. There is no binary
# called "fd_modes", so a file dropped in tests/utilities/ would be
# skipped silently, forever, while still looking like a suite in the
# tree. Same reasoning as tests/tools/run-integration_test.sh and
# tests/tools/audit-check_test.sh. Invoke this directly with bash, or
# via `just test-fd-modes`. Do not hook it into `just it` from here —
# that hook is the implementer's (source from test_runner.sh).
#
# IMPLEMENTER API (tests/lib/fd_modes.sh)
# ---------------------------------------
# This oracle sources that file and calls only the names below. Do not
# rename them. The implementer fills in the bodies and the per-util
# fixture table; it does not edit this file's assertions.
#
#   fd_modes_has_fixture NAME
#       Return 0 iff NAME has an explicit argv+stdin fixture row.
#       An empty or missing table must return non-zero for every NAME
#       — that is this oracle's coverage RED. `[` is a real name.
#
#   fd_modes_run MODE NAME FILE
#       Run NAME's fixture under MODE, writing the observable result
#       to FILE. Prefix every spawn with NO_COLOR=1 (do not export
#       it). Stdin is /dev/null. Wrap the spawn in run_with_limit;
#       return 124 when the limit fires. Capture status with set +e
#       — false exiting 1 is success for fd assertions.
#
#       MODE is one of:
#
#         append     Seed FILE with the exact bytes EXISTING\n, then
#                    run the fixture >> FILE. FILE must start with
#                    the seed; if the util wrote N stdout bytes the
#                    file is seed + those bytes.
#
#         pipe       Run the fixture | cat under pipefail. Write the
#                    pipe's stdout to FILE. Return PIPESTATUS[0] so a
#                    124 is visible; do not let `| cat` hide it.
#
#         truncate   Run the fixture > FILE twice. After return, FILE
#                    holds one run, not the concatenation of two.
#
#         dup-outer  Seed FILE with EXISTING\n, then run the fixture
#                    as: util args 2>&1 >> FILE
#                    fd 1 appends (marker survives). fd 2 is a dup of
#                    the original stdout, so stderr is not in FILE
#                    unless the util also wrote that text to stdout.
#
#         dup-inner  Seed FILE with EXISTING\n, then run the fixture
#                    as: util args >> FILE 2>&1
#                    Both streams append; the marker still survives.
#
# Invoke the fixture through "$BIN_DIR/$NAME", never the unqualified
# name: echo, true, false, test, and [ are bash builtins, and PATH
# pinning does not hide them. PATH is still zig-out/bin (issue #167).
#
# Locked fixtures this oracle relies on (see the plan):
#   echo  →  echo fd-mode     stdin /dev/null
#   true  →  true             stdin /dev/null
#
# test_fd_modes NAME is the runner hook (called from run_utility_tests
# after init_test_session). This oracle does not call it.

# Reporting helpers, colours, PROJECT_ROOT, BIN_DIR, run_with_limit.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; fd_modes_has_fixture returning 1 is an assertion
# failure we want to record, not an abort. -u and pipefail stay.
set +e

FD_MODES_LIB="$PROJECT_ROOT/tests/lib/fd_modes.sh"
UTILS_ZIG="$PROJECT_ROOT/build/utils.zig"
SEED=$'EXISTING\n'
EXPECTED_NAME_COUNT=49

FD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_fd_modes.XXXXXX")"
fd_cleanup() {
    rm -rf "$FD_TMP"
}
# Replace common.sh's cleanup_test_session trap: this suite owns its
# scratch and does not call init_test_session (BIN_DIR is ensured
# below, but TEMP_DIR is not shared with just it).
trap fd_cleanup EXIT

# print_test_summary needs these.
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Parser + `[` + fixture-per-name (49) + echo/true × five mode
# observations. Below this the suite refuses a green tally.
MIN_ASSERTIONS=58

# ===========================================================================
# Preflight
# ===========================================================================

preflight_fail() {
    echo -e "${RED}preflight failed:${NC} $*" >&2
    exit 2
}

# Every `.name = "..."` in build/utils.zig. The `[` entry is a real
# utility (src/test.zig); dropping it would make the oracle short by
# one and leave the bracket binary unguarded.
parse_utility_names() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ \.name\ =\ \"([^\"]+)\" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done <"$UTILS_ZIG"
}

require_utils_table() {
    [[ -f "$UTILS_ZIG" ]] || preflight_fail "no utilities table at $UTILS_ZIG"
}

# Contract tests need the build. The coverage oracle does not, but
# once the harness exists we always reach this point. just build if
# echo or true is missing; do not invent a second install path.
ensure_build() {
    if [[ -x "$BIN_DIR/echo" && -x "$BIN_DIR/true" ]]; then
        return 0
    fi
    echo "zig-out/bin missing echo/true -- running just build" >&2
    if ! (cd "$PROJECT_ROOT" && just build); then
        preflight_fail "just build failed; need $BIN_DIR/echo and $BIN_DIR/true"
    fi
    [[ -x "$BIN_DIR/echo" && -x "$BIN_DIR/true" ]] ||
        preflight_fail "just build did not produce $BIN_DIR/echo and $BIN_DIR/true"
}

# Pin PATH to the build after common.sh has captured HOST_PATH, so a
# forgotten unqualified name still resolves to zig-out/bin (issue #167)
# while host wrappers keep using /bin and /usr/bin.
pin_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) export PATH="$BIN_DIR:$PATH" ;;
    esac
}

# ===========================================================================
# Assertions
# ===========================================================================

assert_bytes() {
    local label="$1" file="$2" expected="$3"
    if [[ ! -f "$file" ]]; then
        print_test_result "$label" "FAIL" "no file at $file"
        return 0
    fi
    if printf '%s' "$expected" | cmp -s - "$file"; then
        print_test_result "$label" "PASS"
    else
        print_test_result "$label" "FAIL" \
            "expected $(printf '%s' "$expected" | od -An -tx1 | tr -s ' '), got $(od -An -tx1 "$file" | tr -s ' ')"
    fi
}

assert_files_eq() {
    local label="$1" got="$2" want="$3"
    if [[ ! -f "$got" ]]; then
        print_test_result "$label" "FAIL" "no result file at $got"
        return 0
    fi
    if cmp -s "$got" "$want"; then
        print_test_result "$label" "PASS"
    else
        print_test_result "$label" "FAIL" \
            "got $(od -An -tx1 "$got" | tr -s ' '), want $(od -An -tx1 "$want" | tr -s ' ')"
    fi
}

require_fn() {
    local fn="$1"
    if ! declare -f "$fn" >/dev/null; then
        echo -e "${RED}implementer API missing:${NC} $fn" \
            "(define it in $FD_MODES_LIB)" >&2
        return 1
    fi
    return 0
}

# ===========================================================================
# Coverage oracle
# ===========================================================================

test_parsed_names() {
    local -a names=()
    local name saw_bracket=no

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        names+=("$name")
        [[ "$name" == "[" ]] && saw_bracket=yes
    done < <(parse_utility_names)

    if [[ "${#names[@]}" -eq "$EXPECTED_NAME_COUNT" && "$saw_bracket" == yes ]]; then
        print_test_result \
            "parse $EXPECTED_NAME_COUNT .name entries including [" "PASS"
    else
        print_test_result \
            "parse $EXPECTED_NAME_COUNT .name entries including [" "FAIL" \
            "parsed ${#names[@]} names, bracket=$saw_bracket"
    fi

    # Expose the list to the fixture loop without re-parsing.
    PARSED_NAMES=("${names[@]}")
}

# Fail the suite immediately when the harness is absent. An empty
# file that does not define fd_modes_has_fixture is the same RED:
# fixtures are missing, so no name is covered.
source_harness_or_fail() {
    if [[ ! -f "$FD_MODES_LIB" ]]; then
        print_test_result "source tests/lib/fd_modes.sh" "FAIL" \
            "harness file is missing: $FD_MODES_LIB"
        echo -e "${RED}fd_modes harness missing:${NC} $FD_MODES_LIB"
        echo "The implementer must add this file with fd_modes_has_fixture" \
            "and fd_modes_run."
        echo ""
        print_test_summary "fd_modes"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$FD_MODES_LIB"
    if ! require_fn fd_modes_has_fixture; then
        print_test_result "source tests/lib/fd_modes.sh" "FAIL" \
            "fd_modes_has_fixture is not defined (empty or incomplete harness)"
        echo ""
        print_test_summary "fd_modes"
        exit 1
    fi
    print_test_result "source tests/lib/fd_modes.sh" "PASS"
}

test_every_name_has_fixture() {
    local util
    for util in "${PARSED_NAMES[@]}"; do
        if fd_modes_has_fixture "$util"; then
            print_test_result "fd_modes_has_fixture $util" "PASS"
        else
            print_test_result "fd_modes_has_fixture $util" "FAIL" \
                "no fixture row for '$util' (empty/missing table is RED)"
        fi
    done
}

# ===========================================================================
# Four-mode contracts: $BIN_DIR/echo and $BIN_DIR/true
# ===========================================================================

# Direct captures of the locked fixtures. These are the expected
# stdout bytes the four modes must preserve, append, or replace.
# Using $BIN_DIR/echo and $BIN_DIR/true — not the builtins.
capture_direct() {
    local dest="$1"
    shift
    NO_COLOR=1 "$@" </dev/null >"$dest" 2>/dev/null
}

test_four_modes() {
    local echo_bin="$BIN_DIR/echo"
    local true_bin="$BIN_DIR/true"

    if ! require_fn fd_modes_run; then
        print_test_result "fd_modes_run is defined" "FAIL" \
            "implementer must provide fd_modes_run MODE NAME FILE"
        return 0
    fi
    print_test_result "fd_modes_run is defined" "PASS"

    [[ -x "$echo_bin" ]] || {
        print_test_result "\$BIN_DIR/echo is executable" "FAIL" "$echo_bin"
        return 0
    }
    [[ -x "$true_bin" ]] || {
        print_test_result "\$BIN_DIR/true is executable" "FAIL" "$true_bin"
        return 0
    }
    print_test_result "\$BIN_DIR/echo and \$BIN_DIR/true are executable" "PASS"

    local echo_direct="$FD_TMP/echo.direct"
    local true_direct="$FD_TMP/true.direct"
    local echo_plus_seed="$FD_TMP/echo.plus_seed"
    local true_plus_seed="$FD_TMP/true.plus_seed"
    capture_direct "$echo_direct" "$echo_bin" fd-mode
    capture_direct "$true_direct" "$true_bin"
    { printf '%s' "$SEED"; cat "$echo_direct"; } >"$echo_plus_seed"
    { printf '%s' "$SEED"; cat "$true_direct"; } >"$true_plus_seed"

    local mode util got rc
    for util in echo true; do
        for mode in append pipe truncate dup-outer dup-inner; do
            got="$FD_TMP/${util}.${mode}"
            rm -f "$got"
            fd_modes_run "$mode" "$util" "$got"
            rc=$?

            if [[ "$rc" == 124 ]]; then
                print_test_result "$util $mode: run_with_limit did not fire" \
                    "FAIL" "fd_modes_run returned 124"
                continue
            fi

            case "$mode" in
                append | dup-outer | dup-inner)
                    if [[ "$util" == echo ]]; then
                        assert_files_eq "echo $mode: seed + fd-mode" \
                            "$got" "$echo_plus_seed"
                    else
                        assert_files_eq "true $mode: seed unchanged" \
                            "$got" "$true_plus_seed"
                    fi
                    ;;
                pipe | truncate)
                    if [[ "$util" == echo ]]; then
                        assert_files_eq "echo $mode: equals direct capture" \
                            "$got" "$echo_direct"
                    else
                        assert_files_eq "true $mode: empty stdout" \
                            "$got" "$true_direct"
                    fi
                    ;;
            esac
        done
    done
}

# ===========================================================================
# Entry point
# ===========================================================================

main() {
    require_utils_table

    echo -e "${BLUE}Testing fd-mode coverage oracle${NC}"
    echo "==============================="
    echo "harness: $FD_MODES_LIB"
    echo "utilities: $UTILS_ZIG"
    echo ""

    test_parsed_names
    source_harness_or_fail
    test_every_name_has_fixture

    ensure_build
    pin_path
    test_four_modes

    echo ""
    if [[ "$TESTS_RUN" -lt "$MIN_ASSERTIONS" ]]; then
        echo -e "${RED}did-not-run:${NC} only $TESTS_RUN assertions ran," \
            "expected at least $MIN_ASSERTIONS" >&2
        exit 2
    fi

    print_test_summary "fd_modes"
}

main "$@"
