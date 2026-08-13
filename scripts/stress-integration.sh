#!/usr/bin/env bash
# Stress one utility's integration suite, hunting the working-directory
# contamination behind issue #125.
#
# WHAT THIS IS FOR
#
# tests/utilities/mkdir_test.sh builds its fixtures with RELATIVE paths, so
# the directory the runner happens to sit in is scratch space for the whole
# suite. When two runs share that directory, `mkdir -pv combo/test/path`
# prints two "created directory" lines instead of three and the run fails —
# then deletes the contaminant itself, so the next run is green and the
# evidence is gone. That self-healing is why #125 was reported as an
# unreproducible flake.
#
# READ THIS BEFORE TRUSTING A GREEN RUN
#
#   A SERIAL LOOP WILL NOT REPRODUCE #125, NOT EVEN BEFORE THE FIX.
#
# Nothing contaminates the working directory between serial iterations: the
# suite tears its own fixtures down, and the next iteration starts from the
# same clean slate. A serial run is a regression guard against ordinary
# flakiness, nothing more. `--concurrent K` is the mode that probes the real
# mechanism — K suites started at the same instant from ONE shared working
# directory, which is red 6/6 before the fix and green after it.
#
# EVIDENCE
#
# Each iteration gets its own TMPDIR ("$out/iter-NNN"), so the runner's
# private working directory AND the suite's $TEMP_DIR land in one tree.
# On success the tree is deleted; on failure it is kept along with the full
# log, and the failing assertion is printed with its Expected/Got block —
# the evidence the issue says was never captured. Preserving $TEMP_DIR needs
# VIBEUTILS_KEEP_TEMP, which tests/lib/common.sh honours in
# cleanup_test_session.
#
# Because VIBEUTILS_KEEP_TEMP also suppresses the between-utilities cleanup
# in tests/lib/test_runner.sh, this harness deliberately takes exactly one
# utility name rather than running the whole suite.
#
# PORTABILITY
#
# Every time limit goes through run_with_limit (tests/lib/common.sh), never
# timeout(1) — macOS GitHub runners do not ship GNU timeout. mktemp is
# always given an explicit XXXXXX template, and no GNU-only flags are used,
# so this runs on BSD userland as-is. VIBEUTILS_TEST_USER is inherited and
# passed through unchanged.
#
# Usage: scripts/stress-integration.sh [--iterations N] [--concurrent K]
#                                      [--keep] <util>

# common.sh gives us PROJECT_ROOT, the colours, and run_with_limit. It also
# turns on errexit; almost every command below is allowed to fail, since a
# failing run is the result we are looking for, so errexit goes back off.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests/lib" && pwd)/common.sh"
set +e
set -uo pipefail

RUNNER="$PROJECT_ROOT/scripts/run-integration.sh"

# Wall-clock ceiling for a single suite invocation. One mkdir suite is a
# few seconds; this only exists so a wedged run cannot hang CI forever.
LIMIT_S=600

iterations=10
concurrent=0
keep=0
util=""

usage() {
    cat <<'EOF'
Usage: scripts/stress-integration.sh [options] <util>

  --iterations N   How many iterations (or concurrent rounds) to run.
                   Default 10. Stops at the first failure.
  --concurrent K   Run K suites at once from one shared working directory
                   per iteration. This is the mode that reproduces #125;
                   a serial loop does not. Default 0 (serial).
  --keep           Keep every iteration's tree, not just a failing one.
  -h, --help       This text.
EOF
}

die() {
    echo -e "${RED}stress:${NC} $*" >&2
    exit 2
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --iterations) iterations="${2:-}"; shift 2 ;;
            --iterations=*) iterations="${1#*=}"; shift ;;
            --concurrent) concurrent="${2:-}"; shift 2 ;;
            --concurrent=*) concurrent="${1#*=}"; shift ;;
            --keep) keep=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) usage >&2; die "unknown option '$1'" ;;
            *) [ -z "$util" ] || die "only one utility at a time"; util="$1"; shift ;;
        esac
    done
    [ $# -eq 0 ] || util="$1"

    [ -n "$util" ] || { usage >&2; die "no utility named"; }
    case "$iterations" in ''|*[!0-9]*) die "--iterations wants a number" ;; esac
    case "$concurrent" in ''|*[!0-9]*) die "--concurrent wants a number" ;; esac
    [ "$iterations" -ge 1 ] || die "--iterations must be at least 1"
    [ -x "$PROJECT_ROOT/zig-out/bin/$util" ] ||
        die "zig-out/bin/$util is missing — run 'just build' first"
}

# The one directory every run shares. Before the fix this is where the
# fixtures collide; after it, nothing should ever appear here. World
# writable because the runner may demote to an unprivileged test user.
setup_workspace() {
    out="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils-stress-XXXXXX")" ||
        die "could not create a workspace"
    # mktemp -d gives 0700; a demoted test user needs +x on every component
    # of both the workspace and the working directory it is handed.
    chmod 0755 "$out"
    shared_cwd="$out/shared-cwd"
    mkdir -p "$shared_cwd"
    chmod 0777 "$shared_cwd"
}

# useradd is not concurrency-safe (issue #150): two runs racing to create
# the same test user leave one of them with "setpriv: uid N not found".
# That is a different bug from the one this harness hunts, and it would
# swamp the signal, so provision the user once up front.
ensure_test_user() {
    local user="${VIBEUTILS_TEST_USER:-vibedev}"
    [ "$(id -u)" -eq 0 ] || return 0
    [ -n "${VIBEUTILS_NO_DEMOTE:-}" ] && return 0
    command -v setpriv >/dev/null 2>&1 || return 0
    id "$user" >/dev/null 2>&1 && return 0
    command -v useradd >/dev/null 2>&1 || return 0
    useradd -m -s /bin/bash "$user" >/dev/null 2>&1 ||
        echo -e "${YELLOW}stress:${NC} could not provision '$user'" >&2
    return 0
}

iter_label() {
    printf 'iter-%03d' "$1"
}

# One suite invocation, in the background, with its own log. The caller
# waits on the pid it leaves in LAUNCH_PID.
LAUNCH_PID=0
launch_run() {
    local iter_dir="$1" log="$2"
    (
        cd "$shared_cwd" || exit 125
        export TMPDIR="$iter_dir"
        export VIBEUTILS_KEEP_TEMP=1
        run_with_limit "$LIMIT_S" bash "$RUNNER" "$util"
    ) >"$log" 2>&1 &
    LAUNCH_PID=$!
}

# grep -a everywhere: some utility under test emits bytes that make GNU grep
# call the log binary, and a "Binary file matches" line captures nothing at
# all — which would quietly defeat the entire point of this harness.
report_failure() {
    local label="$1"
    shift
    local log
    echo -e "${RED}FAIL${NC} $label"
    for log in "$@"; do
        [ -f "$log" ] || continue
        echo "--- $log"
        if grep -a -q '^✗' "$log"; then
            grep -a -E '^(Tests run|Passed|Failed): ' "$log" | head -3
            grep -a -A4 '^✗' "$log" | head -60
        else
            # No assertion failed, so the run died some other way: the
            # tail is the only thing that says how.
            tail -5 "$log"
        fi
    done
}

run_serial_iteration() {
    local iter_dir="$1" label="$2"
    local log="$iter_dir/run.log" rc=0
    launch_run "$iter_dir" "$log"
    wait "$LAUNCH_PID"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_failure "$label (exit $rc)" "$log"
        return 1
    fi
    echo -e "${GREEN}ok${NC}   $label"
    return 0
}

run_concurrent_iteration() {
    local iter_dir="$1" label="$2"
    local -a pids=() logs=()
    local k rc=0 worst=0

    for ((k = 1; k <= concurrent; k++)); do
        local log="$iter_dir/run-$k.log"
        launch_run "$iter_dir" "$log"
        pids+=("$LAUNCH_PID")
        logs+=("$log")
    done

    for ((k = 0; k < ${#pids[@]}; k++)); do
        wait "${pids[$k]}"
        rc=$?
        [ "$rc" -eq 0 ] || worst="$rc"
    done

    if [ "$worst" -ne 0 ]; then
        report_failure "$label ($concurrent concurrent, exit $worst)" "${logs[@]}"
        return 1
    fi
    echo -e "${GREEN}ok${NC}   $label ($concurrent concurrent)"
    return 0
}

main() {
    parse_args "$@"
    detect_platform
    ensure_test_user
    setup_workspace

    local mode="serial"
    [ "$concurrent" -gt 0 ] && mode="concurrent x$concurrent"

    echo -e "${BLUE}Stressing '$util' integration suite${NC}"
    echo "mode:        $mode"
    echo "iterations:  $iterations"
    echo "workspace:   $out"
    echo "shared cwd:  $shared_cwd"
    echo "test user:   ${VIBEUTILS_TEST_USER:-vibedev (default)}"
    if [ "$concurrent" -eq 0 ]; then
        echo "note: a serial loop does NOT reproduce #125; use --concurrent K."
    fi
    echo ""

    local i label iter_dir failed=0
    for ((i = 1; i <= iterations; i++)); do
        label="$(iter_label "$i")"
        iter_dir="$out/$label"
        mkdir -p "$iter_dir"
        chmod 0777 "$iter_dir"

        if [ "$concurrent" -gt 0 ]; then
            run_concurrent_iteration "$iter_dir" "$label" || failed=1
        else
            run_serial_iteration "$iter_dir" "$label" || failed=1
        fi

        if [ "$failed" -ne 0 ]; then
            echo ""
            echo -e "${RED}stopped at $label${NC}; tree kept at $iter_dir"
            echo "shared working directory now holds:"
            ls -A "$shared_cwd" 2>/dev/null | head -20
            return 1
        fi

        [ "$keep" -eq 1 ] || rm -rf "$iter_dir"
    done

    echo ""
    echo -e "${GREEN}$iterations iterations passed${NC} ($mode)"
    if [ "$keep" -eq 1 ]; then
        echo "trees kept at $out"
    else
        rm -rf "$out"
    fi
    return 0
}

main "$@"
