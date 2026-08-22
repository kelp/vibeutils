#!/usr/bin/env bash
# Contract tests for concurrent useradd in scripts/run-integration.sh
# (issue #150).
#
# WHAT IS BEING GUARDED
# ---------------------
# Two scripts/run-integration.sh processes that create the SAME
# VIBEUTILS_TEST_USER race on useradd. The loser has been observed to
# leave /home/<user> owned by a uid passwd no longer has, and to die
# with `setpriv: uid N not found`. The post-create chown added for #125
# repairs the home after the fact; it does not serialize useradd, so
# the setpriv death remains.
#
# The contract: two concurrent runner invocations creating the same
# test user cannot leave home-owner-uid != passwd-uid, and cannot die
# with `setpriv: uid … not found`.
#
# WHY tests/tools/ AND NOT tests/utilities/
# -----------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a
# file only when zig-out/bin/<name> is executable. There is no binary
# called "run-integration", so a file dropped in tests/utilities/
# would be skipped silently. Same reasoning as
# tests/tools/run-integration_test.sh (issue #125). Invoked from the
# justfile with bash.
#
# HOW THE RACE IS MADE DETERMINISTIC
# ----------------------------------
# Real useradd can win or lose the race in microseconds. A useradd (and
# id) shim is planted first on PATH so two overlapping creates are
# reproducible:
#
#   * `id <user>` existence checks wait (bounded) for a second checker
#     so both runners observe "no such user" and enter useradd.
#   * overlapping `useradd` invocations (in-flight at the same time)
#     create the user, then usermod the uid without -m so home stays
#     owned by the first uid — the #150 shape.
#   * a non-overlapping `useradd` (serialized by a future lock, or a
#     single caller) is a pass-through to the real binary, so this
#     suite can go green once the runner serializes creation.
#
# The runner is launched with `env -i` so the host-tool function
# wrappers export -f'd by tests/lib/common.sh cannot hide the shims
# (`id` is in that wrap list and would otherwise resolve to /usr/bin/id
# via host_resolve, ignoring PATH).
#
# The suite argument is --help: setpriv still runs, then integration.sh
# exits immediately. No Zig build is required; zig-out/bin need only
# exist as a directory so the runner reaches setpriv.
#
# SKIP-AND-PASS IS FORBIDDEN
# --------------------------
# This bug lives on the root -> setpriv -> useradd demotion path. If
# that path cannot be exercised (not root and sudo -n fails, or no
# setpriv, or no useradd), the suite exits 2 with a preflight error
# rather than reporting a green tally.

# Become root before sourcing common.sh: the demotion path is the one
# that calls useradd. Relative $0 is resolved first so sudo exec keeps
# the same file.
_SELF="${BASH_SOURCE[0]}"
_SELF="$(cd "$(dirname "$_SELF")" && pwd)/$(basename "$_SELF")"
if [[ "$(id -u)" -ne 0 ]]; then
    if sudo -n true >/dev/null 2>&1; then
        _sudo_env=(PATH="/usr/sbin:/usr/bin:/bin:${PATH}")
        [[ -n "${RUN_INTEGRATION:-}" ]] &&
            _sudo_env+=("RUN_INTEGRATION=$RUN_INTEGRATION")
        exec sudo -n env "${_sudo_env[@]}" bash "$_SELF" "$@"
    fi
    echo "preflight failed: #150 needs the root demotion path" \
        "(useradd + setpriv); not root and sudo -n failed" >&2
    exit 2
fi

# Reporting helpers, colours, PROJECT_ROOT, and run_with_limit.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; several commands below are expected to fail.
set +e
set -uo pipefail

RUN_INTEGRATION="${RUN_INTEGRATION:-$PROJECT_ROOT/scripts/run-integration.sh}"

# Deliberately /tmp: the demoted user needs +x on every component of
# the launcher cwd, and /tmp is 1777.
RI_TMP="$(mktemp -d /tmp/vibeutils_run_integration_useradd.XXXXXX)"
chmod 0755 "$RI_TMP"

CASE_USER="vibedev150t"
RACE_DIR="$RI_TMP/race"
SHIM_DIR="$RI_TMP/shim"
LOG_A=""
LOG_B=""
PID_A=0
PID_B=0
RUN_PID=0

# Real binaries, never PATH — the shims would recurse.
REAL_USERADD=""
REAL_USERMOD=""
REAL_ID=""
REAL_USERDEL=""
REAL_GETENT=""

# Poll budget: 40 * 0.05s = 2s. Every wait in the shims is bounded by
# the same figure so a missed rendezvous cannot hang CI.
POLL_INTERVAL_S=0.05
POLL_ITERATIONS_MAX=40
RUNNER_LIMIT_S=20

# The number of gating assertions main() must observe. Below this the
# suite refuses to report at all rather than returning a green tally
# nobody earned.
MIN_ASSERTIONS=2

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

ri_cleanup() {
    local pid home
    for pid in "$PID_A" "$PID_B"; do
        [[ "$pid" != "0" && -n "$pid" ]] || continue
        kill -9 "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
    if [[ -n "$CASE_USER" && -n "$REAL_ID" && -x "$REAL_ID" ]] &&
        "$REAL_ID" "$CASE_USER" >/dev/null 2>&1; then
        home="$("$REAL_GETENT" passwd "$CASE_USER" 2>/dev/null | cut -d: -f6)"
        if [[ -n "$REAL_USERDEL" && -x "$REAL_USERDEL" ]]; then
            "$REAL_USERDEL" -r "$CASE_USER" >/dev/null 2>&1 ||
                "$REAL_USERDEL" "$CASE_USER" >/dev/null 2>&1
        fi
        [[ -n "$home" && "$home" == */"$CASE_USER" && -d "$home" ]] &&
            rm -rf "$home"
    fi
    rm -rf "$RI_TMP"
}
trap ri_cleanup EXIT

preflight_fail() {
    echo -e "${RED}preflight failed:${NC} $*" >&2
    exit 2
}

resolve_real() {
    local name="$1" cand
    for cand in "/usr/sbin/$name" "/usr/bin/$name" "/sbin/$name" "/bin/$name"; do
        if [[ -x "$cand" ]]; then
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

run_preflight() {
    command -v python3 >/dev/null 2>&1 ||
        preflight_fail "python3 is required by run_with_limit"
    [[ "$(id -u)" -eq 0 ]] ||
        preflight_fail "#150 needs root; demotion/useradd path not reached"
    [[ -z "${VIBEUTILS_NO_DEMOTE:-}" ]] ||
        preflight_fail "VIBEUTILS_NO_DEMOTE is set; the useradd path is skipped"

    REAL_USERADD="$(resolve_real useradd)" ||
        preflight_fail "useradd is required to exercise the demotion path (#150)"
    REAL_USERMOD="$(resolve_real usermod)" ||
        preflight_fail "usermod is required by the overlapping-useradd shim (#150)"
    REAL_USERDEL="$(resolve_real userdel)" ||
        preflight_fail "userdel is required to clean up the fixture user (#150)"
    REAL_ID="$(resolve_real id)" ||
        preflight_fail "id is required"
    REAL_GETENT="$(resolve_real getent)" ||
        preflight_fail "getent is required"
    command -v setpriv >/dev/null 2>&1 || [[ -x /usr/bin/setpriv ]] ||
        preflight_fail "setpriv is required to exercise the demotion path (#150)"

    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        echo -e "${YELLOW}note:${NC} $RUN_INTEGRATION does not exist;" \
            "every contract test below must fail." >&2
    fi

    # The runner refuses to reach setpriv without this directory. An
    # empty tree is enough: the suite argument is --help.
    mkdir -p "$PROJECT_ROOT/zig-out/bin" ||
        preflight_fail "could not create $PROJECT_ROOT/zig-out/bin"
}

# Wipe a leftover fixture user from a previous RED run. Only ever a
# name this file owns.
scrub_fixture_user() {
    local home
    case "$CASE_USER" in
        vibedev150t) ;;
        *) return 0 ;;
    esac
    if "$REAL_ID" "$CASE_USER" >/dev/null 2>&1; then
        home="$("$REAL_GETENT" passwd "$CASE_USER" 2>/dev/null | cut -d: -f6)"
        "$REAL_USERDEL" -r "$CASE_USER" >/dev/null 2>&1 ||
            "$REAL_USERDEL" "$CASE_USER" >/dev/null 2>&1
        [[ -n "$home" && "$home" == */"$CASE_USER" && -d "$home" ]] &&
            rm -rf "$home"
    fi
    [[ -d /home/"$CASE_USER" ]] && rm -rf /home/"$CASE_USER"
    return 0
}

install_shims() {
    mkdir -p "$SHIM_DIR" "$RACE_DIR/inflight" "$RACE_DIR/exist"
    chmod 0755 "$SHIM_DIR" "$RACE_DIR" "$RACE_DIR/inflight" "$RACE_DIR/exist"

    cat >"$SHIM_DIR/id" <<'EOF'
#!/usr/bin/env bash
# PATH shim for #150. See tests/tools/run-integration_useradd_test.sh.
REAL_ID="${VIBEUTILS_150_ID:?}"
RACE="${VIBEUTILS_150_RACE:?}"
USER_NAME="${VIBEUTILS_150_USER:?}"
POLL_MAX="${VIBEUTILS_150_POLL_MAX:-40}"

wait_for() {
    local f="$1" i
    for ((i = 0; i < POLL_MAX; i++)); do
        [[ -f "$f" ]] && return 0
        sleep 0.05
    done
    return 1
}

# Existence check: `id "$TEST_USER"`. Hold until a second checker
# arrives so both runners see "no such user" and enter useradd. A
# serialized caller times out and falls through to the real id.
if [[ $# -eq 1 && "$1" == "$USER_NAME" ]]; then
    mkdir "$RACE/exist/$$" 2>/dev/null || true
    waited=0
    for ((waited = 0; waited < POLL_MAX; waited++)); do
        n=0
        for d in "$RACE/exist"/*; do
            [[ -e "$d" ]] && n=$((n + 1))
        done
        [[ "$n" -ge 2 ]] && break
        sleep 0.05
    done
    exec "$REAL_ID" "$@"
fi

# Capture: `id -u "$TEST_USER"`. Print the uid first so the runner
# stores the pre-usermod value, then (only if useradd overlap was
# already detected) wait for the uid reassignment so setpriv still
# sees the stale uid. Non-overlapping creates must not wait, or a
# future lock-serialized runner would hang here and this suite could
# never go green.
if [[ $# -eq 2 && "$1" == "-u" && "$2" == "$USER_NAME" ]]; then
    "$REAL_ID" "$@"
    rc=$?
    if [[ -f "$RACE/overlapping" ]]; then
        : >"$RACE/captured"
        wait_for "$RACE/recreated"
    fi
    exit "$rc"
fi

exec "$REAL_ID" "$@"
EOF
    chmod 0755 "$SHIM_DIR/id"

    cat >"$SHIM_DIR/useradd" <<'EOF'
#!/usr/bin/env bash
# PATH shim for #150. See tests/tools/run-integration_useradd_test.sh.
#
# Overlapping invocations (two in-flight at once) reproduce the race:
# create, then usermod -u without -m so home stays on the first uid.
# A non-overlapping invocation is a pass-through, so a runner that
# serializes user creation goes green rather than being failed by the
# shim itself.
REAL_USERADD="${VIBEUTILS_150_USERADD:?}"
REAL_USERMOD="${VIBEUTILS_150_USERMOD:?}"
REAL_ID="${VIBEUTILS_150_ID:?}"
REAL_GETENT="${VIBEUTILS_150_GETENT:?}"
RACE="${VIBEUTILS_150_RACE:?}"
USER_NAME="${VIBEUTILS_150_USER:?}"
POLL_MAX="${VIBEUTILS_150_POLL_MAX:-40}"

wait_for() {
    local f="$1" i
    for ((i = 0; i < POLL_MAX; i++)); do
        [[ -f "$f" ]] && return 0
        sleep 0.05
    done
    return 1
}

free_uid_after() {
    local uid="$1" i
    for ((i = 0; i < 100; i++)); do
        uid=$((uid + 1))
        if ! "$REAL_GETENT" passwd "$uid" >/dev/null 2>&1; then
            printf '%s' "$uid"
            return 0
        fi
    done
    return 1
}

: >"$RACE/useradd-called.$$"
mkdir "$RACE/inflight/$$" 2>/dev/null || true

# Widen the overlap window so a sibling started in the same instant is
# still in-flight when we count.
sleep 0.2

n=0
for d in "$RACE/inflight"/*; do
    [[ -e "$d" ]] && n=$((n + 1))
done

rc=0
if [[ "$n" -ge 2 ]]; then
    : >"$RACE/overlapping"
    if mkdir "$RACE/first.lock" 2>/dev/null; then
        "$REAL_USERADD" "$@"
        rc=$?
        if [[ "$rc" -eq 0 ]]; then
            "$REAL_ID" -u "$USER_NAME" >"$RACE/first_uid" 2>/dev/null
            : >"$RACE/created"
        fi
    else
        wait_for "$RACE/created" || {
            rm -rf "$RACE/inflight/$$"
            exit 1
        }
        wait_for "$RACE/captured" || {
            rm -rf "$RACE/inflight/$$"
            exit 1
        }
        old_uid="$(cat "$RACE/first_uid" 2>/dev/null)"
        new_uid="$(free_uid_after "${old_uid:-1000}")" || {
            rm -rf "$RACE/inflight/$$"
            exit 1
        }
        # No -m: home ownership stays on old_uid, matching the observed
        # #150 leftover. Old uid disappears from passwd.
        "$REAL_USERMOD" -u "$new_uid" "$USER_NAME"
        rc=$?
        : >"$RACE/recreated"
    fi
else
    "$REAL_USERADD" "$@"
    rc=$?
fi

rm -rf "$RACE/inflight/$$"
exit "$rc"
EOF
    chmod 0755 "$SHIM_DIR/useradd"
}

launch_runner() {
    local log="$1"
    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        echo "did-not-run" >"$log"
        RUN_PID=0
        return 0
    fi
    # --help reaches setpriv, then integration.sh exits. The race is
    # in the runner's user-create / setpriv prologue, not the suite.
    # /usr/bin/env -i (absolute) drops the export -f host wrappers so
    # PATH is what the runner actually searches for `id` and `useradd`.
    # run_with_limit execvp's its command, so a bash function here
    # would be invisible.
    #
    # PID is stored in RUN_PID, not printed: $(launch_runner) would
    # run this in a subshell, the background job would not be a
    # child of the caller, and wait would fail with 127.
    (
        cd "$RI_TMP" || exit 125
        run_with_limit "$RUNNER_LIMIT_S" /usr/bin/env -i \
            PATH="$SHIM_DIR:/usr/sbin:/usr/bin:/bin" \
            HOME=/root \
            USER=root \
            LOGNAME=root \
            TMPDIR=/tmp \
            LANG=C \
            LC_ALL=C \
            VIBEUTILS_TEST_USER="$CASE_USER" \
            VIBEUTILS_150_RACE="$RACE_DIR" \
            VIBEUTILS_150_USER="$CASE_USER" \
            VIBEUTILS_150_USERADD="$REAL_USERADD" \
            VIBEUTILS_150_USERMOD="$REAL_USERMOD" \
            VIBEUTILS_150_USERDEL="$REAL_USERDEL" \
            VIBEUTILS_150_ID="$REAL_ID" \
            VIBEUTILS_150_GETENT="$REAL_GETENT" \
            VIBEUTILS_150_POLL_MAX="$POLL_ITERATIONS_MAX" \
            bash "$RUN_INTEGRATION" --help
    ) >"$log" 2>&1 &
    RUN_PID=$!
}

home_uid_of() {
    local home="$1"
    python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_uid)' \
        "$home" 2>/dev/null
}

# ===========================================================================
# Sentinels and the #150 contract
# ===========================================================================

assert_runners_executed() {
    local why="" a_ran=no b_ran=no
    if [[ -f "$RUN_INTEGRATION" ]]; then
        if grep -a -qE 'integration:|setpriv:|vibeutils' "$LOG_A" 2>/dev/null; then
            a_ran=yes
        fi
        if grep -a -qE 'integration:|setpriv:|vibeutils' "$LOG_B" 2>/dev/null; then
            b_ran=yes
        fi
        grep -a -qx 'did-not-run' "$LOG_A" 2>/dev/null && a_ran=no
        grep -a -qx 'did-not-run' "$LOG_B" 2>/dev/null && b_ran=no
    else
        why="RUN_INTEGRATION missing"
    fi
    [[ "$a_ran" == yes ]] || why="$why; runner A did not execute"
    [[ "$b_ran" == yes ]] || why="$why; runner B did not execute"

    if [[ -z "$why" ]]; then
        print_test_result \
            "both concurrent runners executed run-integration.sh (#150)" "PASS"
    else
        print_test_result \
            "both concurrent runners executed run-integration.sh (#150)" \
            "FAIL" "$why"
    fi
}

assert_no_stale_home_or_setpriv_death() {
    local why="" hits home p_uid h_uid
    hits="$(grep -a -h -E 'setpriv: uid [0-9]+ not found' \
        "$LOG_A" "$LOG_B" 2>/dev/null | tr '\n' '|' | cut -c1-300)"
    [[ -z "$hits" ]] || why="setpriv uid-not-found: $hits"

    if "$REAL_ID" "$CASE_USER" >/dev/null 2>&1; then
        p_uid="$("$REAL_ID" -u "$CASE_USER")"
        home="$("$REAL_GETENT" passwd "$CASE_USER" | cut -d: -f6)"
        if [[ -n "$home" && -d "$home" ]]; then
            h_uid="$(home_uid_of "$home")"
            if [[ -n "$h_uid" && -n "$p_uid" && "$h_uid" != "$p_uid" ]]; then
                why="$why; home owner uid=$h_uid != passwd uid=$p_uid ($home)"
            fi
        fi
    fi

    # Silence is not evidence: two runners that never started also
    # leave no stale home and no setpriv death.
    grep -a -qE 'integration:|setpriv:|vibeutils' "$LOG_A" "$LOG_B" 2>/dev/null ||
        why="$why; neither runner produced output, so the race was not observed"

    if [[ -z "$why" ]]; then
        print_test_result \
            "concurrent useradd of the same VIBEUTILS_TEST_USER cannot leave a stale home uid or 'setpriv: uid … not found' (#150)" \
            "PASS"
    else
        print_test_result \
            "concurrent useradd of the same VIBEUTILS_TEST_USER cannot leave a stale home uid or 'setpriv: uid … not found' (#150)" \
            "FAIL" "$why"
    fi
}

test_concurrent_useradd_same_user() {
    echo -e "${CYAN}#150: two concurrent runners creating the same test user...${NC}"

    scrub_fixture_user
    install_shims

    LOG_A="$RI_TMP/run-a.log"
    LOG_B="$RI_TMP/run-b.log"
    : >"$LOG_A"
    : >"$LOG_B"

    RUN_PID=0
    launch_runner "$LOG_A"
    PID_A="$RUN_PID"
    launch_runner "$LOG_B"
    PID_B="$RUN_PID"

    local rc_a=0 rc_b=0
    if [[ "$PID_A" != "0" && -n "$PID_A" ]]; then
        wait "$PID_A"
        rc_a=$?
        PID_A=0
    else
        rc_a=127
    fi
    if [[ "$PID_B" != "0" && -n "$PID_B" ]]; then
        wait "$PID_B"
        rc_b=$?
        PID_B=0
    else
        rc_b=127
    fi

    echo "runner A exit=$rc_a  runner B exit=$rc_b"
    if [[ -f "$RACE_DIR/overlapping" ]]; then
        echo "useradd overlap provoked: yes"
    else
        echo "useradd overlap provoked: no"
    fi

    assert_runners_executed
    assert_no_stale_home_or_setpriv_death
}

main() {
    detect_platform
    run_preflight

    echo -e "${BLUE}Testing run-integration.sh concurrent useradd (#150)${NC}"
    echo "======================================================="
    echo "script under test: $RUN_INTEGRATION"
    echo "platform: $PLATFORM   fixture user: $CASE_USER"
    echo "fixture root: $RI_TMP"
    echo ""

    test_concurrent_useradd_same_user

    echo ""
    if [[ "$TESTS_RUN" -lt "$MIN_ASSERTIONS" ]]; then
        echo -e "${RED}did-not-run:${NC} only $TESTS_RUN assertions ran," \
            "expected at least $MIN_ASSERTIONS" >&2
        exit 2
    fi

    print_test_summary "run-integration.sh useradd (#150)"
}

main "$@"
