#!/usr/bin/env bash
# Contract tests for scripts/run-integration.sh (issue #125).
#
# WHAT IS BEING GUARDED
# ---------------------
# The integration suite's working directory is shared mutable state.
# tests/utilities/mkdir_test.sh is the only suite that builds fixtures with
# RELATIVE paths -- 39 distinct names (combo, dir1, parent, tree, deep, ...)
# and 46 bare `rm -rf <name>` cleanups -- so whatever directory the runner
# happens to be sitting in becomes a scratch area for the whole mkdir run.
# Two runs that share that directory, or one run that inherits a leftover
# from an interrupted predecessor, corrupt each other: `mkdir -pv
# combo/test/path` prints three "created directory" lines from a clean start
# and only two when `combo` already exists, which is the missing-verbose-line
# failure reported in #125. The failing run then deletes the contaminant
# itself (mkdir_test.sh:137), so the next run is green and the evidence is
# gone -- the self-healing signature the issue describes.
#
# The contract asserted here is therefore about the RUNNER, not about mkdir:
#
#   scripts/run-integration.sh gives every run a private working directory,
#   so no directory the caller can observe is ever read or written by the
#   suite, and no pre-existing state in such a directory can change the
#   suite's outcome.
#
# WHY tests/tools/ AND NOT tests/utilities/
# -----------------------------------------
# tests/lib/test_runner.sh:133-136 globs tests/utilities/*_test.sh and runs a
# file only when zig-out/bin/<name> is executable. There is no binary called
# "run-integration", so a file dropped in tests/utilities/ would be skipped
# silently, forever, while still looking like a suite in the tree. Same
# reasoning as tests/tools/audit-check_test.sh (issue #133); this file follows
# that precedent deliberately. It is invoked directly, with bash.
#
# WHICH DIRECTORY IS WATCHED
# --------------------------
# scripts/run-integration.sh has two shapes, and they put the suite in
# different places today:
#
#   non-root (macOS dev box, GitHub runners, OrbStack VM)
#       :22-24 exec bash "$SUITE" with no cd at all -> the suite runs in the
#       CALLER'S cwd, which under `just it` is the repo root.
#   root + setpriv (agent containers, Docker)
#       :68 cd "$test_home" -> the suite runs in the test user's HOME, a
#       fixed path per VIBEUTILS_TEST_USER.
#
# Both are long-lived directories shared by every run that reaches them, and
# both are the same defect. So each case here watches every directory the
# runner could adopt: the launcher cwd always, plus the dedicated test user's
# home whenever this host will actually demote. The contract is that NEITHER
# is touched. Asserting only on the launcher cwd would be vacuously green on
# the root path, where the runner already cds away -- a toothless gate on the
# very platform these tests run on in CI containers.
#
# TEST USERS AND FIXTURE DIRECTORIES
# ----------------------------------
# Every case gets its own VIBEUTILS_TEST_USER (vibedev125t1..t9) so cases
# cannot contaminate each other, and so a concurrent lane using vibedev,
# vibedev124, vibedev128 or vibedev129 cannot contaminate these.
#
# Fixture directories are created under /tmp explicitly, NOT under $TMPDIR
# and never under an agent scratchpad. This is load-bearing, not tidiness:
# the demoted user needs +x on every component of the launcher cwd. When it
# does not have it, pwd_test.sh:516 `cd "$original_dir"` fails, its
# `unset PWD` on :517 is never undone, the failure is swallowed because
# run_utility_tests is called inside `if` (test_runner.sh:139,158, which
# suppresses set -e), the shell is left inside $TEMP_DIR which
# cleanup_test_session then deletes, and the whole run dies later at
# touch_test.sh:658 with "PWD: unbound variable". /tmp is mode 1777; a
# scratchpad path typically is not.
#
# THE did-not-run SENTINEL
# ------------------------
# The script under test is taken from $RUN_INTEGRATION, defaulting to
# scripts/run-integration.sh. The override exists so this suite can be
# pointed at a deliberate stub and shown to fail on real assertions rather
# than on a missing file. Three things close the vacuous-pass hole:
#
#   1. A missing $RUN_INTEGRATION sets the run status to the string
#      "did-not-run", which equals no expected status.
#   2. Every cleanliness assertion is paired with positive evidence that a
#      real suite executed -- a "Tests run:"/"Passed:"/"Failed:" tally with a
#      three-digit count and zero failures, or (for the interrupted runs) a
#      124 from the time limit plus mkdir suite output in the log. A stub
#      that prints nothing and exits 0 satisfies none of them.
#   3. main() refuses to report a summary if fewer than
#      $MIN_ASSERTIONS assertions ran, so a suite that silently does nothing
#      cannot masquerade as a passing gate either.
#
# GATES vs INFORMATION
# --------------------
# R1, R2, R3 and the two regression guards are gates. R4 (two concurrent
# suites from one shared directory) is reported but deliberately excluded
# from the tally: it is red today and green after the fix, but a race that
# happens not to collide is not a proof, so it must never be the thing that
# turns this suite green.
#
# COST: roughly four minutes. The full-suite regression guard alone is ~3
# minutes and is the only case that exercises every utility from the new
# working directory -- it is what catches a run directory the demoted user
# cannot traverse.

# Reporting helpers, colours, PROJECT_ROOT, and run_with_limit.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; nearly every command below is expected to fail at some
# point (that is the point), so -e has to go. -u and pipefail stay.
set +e

RUN_INTEGRATION="${RUN_INTEGRATION:-$PROJECT_ROOT/scripts/run-integration.sh}"
MKDIR_TEST="$PROJECT_ROOT/tests/utilities/mkdir_test.sh"

# Deliberately /tmp and not $TMPDIR -- see "TEST USERS AND FIXTURE
# DIRECTORIES" above. mktemp -d makes this 0700 root-owned, which the demoted
# user cannot traverse, so widen it immediately.
RI_TMP="$(mktemp -d /tmp/vibeutils_run_integration.XXXXXX)"
chmod 0755 "$RI_TMP"

ri_cleanup() {
    rm -rf "$RI_TMP"
}
trap ri_cleanup EXIT

# print_test_result and print_test_summary need these. init_test_session is
# deliberately not called: it would create and later delete $TEMP_DIR, and
# this suite owns its own scratch space.
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# The number of gating assertions main() must observe: two from each of the
# five gating cases. Below this the suite refuses to report at all rather
# than returning a green tally nobody earned.
MIN_ASSERTIONS=10

# Whether this host will demote at all, decided once from the same conditions
# scripts/run-integration.sh:22-29 uses.
DEMOTE=no

# Per-case state, reset by begin_case.
CASE_USER=""
CASE_DIR=""
CASE_HOME=""
CASE_DEMOTES=no

# Set by every run_suite* helper.
RUN_STATUS=0
RUN_LOG=""
RUN_PID=0
RUN_SEQ=0

# Directories that must never gain an entry, and their baseline snapshots.
WATCH_DIRS=()
WATCH_BASE=()

# Poll and sample budgets. Every loop below is bounded by one of these.
POLL_INTERVAL_S=0.05
POLL_ITERATIONS_MAX=4000
KILL_POINTS_S=(0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0)

# ===========================================================================
# Preflight
#
# These are NOT tests. They are preconditions: if the host cannot demote the
# way CI does, or if mkdir_test.sh has stopped using relative fixtures, every
# result below is meaningless. Keeping them out of the tally also means a
# stubbed-out runner yields a pass count of exactly zero.
# ===========================================================================

preflight_fail() {
    echo -e "${RED}preflight failed:${NC} $*" >&2
    exit 2
}

# The premise of this entire suite is that the mkdir suite writes fixtures
# into whatever directory it is started from. If someone "fixes" #125 by
# rewriting mkdir_test.sh to absolute paths, R1-R3 would go green without the
# runner having changed at all -- and the next suite to use a relative path
# would inherit the same defect. That fix is out of bounds (the plan forbids
# touching mkdir_test.sh), so the premise is checked rather than assumed.
require_relative_fixtures() {
    local relative_cleanups combo_cleanups
    [[ -f "$MKDIR_TEST" ]] || preflight_fail "no mkdir suite at $MKDIR_TEST"

    relative_cleanups=$(grep -c 'rm -rf [a-zA-Z"'"'"']' "$MKDIR_TEST")
    combo_cleanups=$(grep -c 'rm -rf combo$' "$MKDIR_TEST")

    [[ "$relative_cleanups" -ge 40 ]] ||
        preflight_fail "mkdir_test.sh has only $relative_cleanups relative" \
            "cleanups (expected >= 40); the shared-cwd premise no longer holds"
    [[ "$combo_cleanups" -ge 1 ]] ||
        preflight_fail "mkdir_test.sh no longer does a bare 'rm -rf combo'"
}

detect_demotion() {
    if [[ "$(id -u)" -ne 0 ]] || [[ -n "${VIBEUTILS_NO_DEMOTE:-}" ]]; then
        DEMOTE=no
        return 0
    fi
    if command -v setpriv >/dev/null 2>&1; then
        DEMOTE=yes
    else
        DEMOTE=no
    fi
    return 0
}

run_preflight() {
    command -v python3 >/dev/null 2>&1 ||
        preflight_fail "python3 is required by run_with_limit"
    [[ -d "$PROJECT_ROOT/zig-out/bin" ]] ||
        preflight_fail "zig-out/bin is missing -- run 'just build' first"
    [[ -x "$PROJECT_ROOT/zig-out/bin/mkdir" ]] ||
        preflight_fail "zig-out/bin/mkdir is missing -- run 'just build' first"

    require_relative_fixtures
    detect_demotion

    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        echo -e "${YELLOW}note:${NC} $RUN_INTEGRATION does not exist;" \
            "every contract test below must fail." >&2
    fi
}

# ===========================================================================
# Fixture users and directories
# ===========================================================================

case_user() {
    printf 'vibedev125t%s' "$1"
}

ensure_user() {
    local user="$1"
    id -u "$user" >/dev/null 2>&1 && return 0
    command -v useradd >/dev/null 2>&1 || return 1
    useradd -m -s /bin/bash "$user" >/dev/null 2>&1 || return 1
    id -u "$user" >/dev/null 2>&1
}

user_home() {
    local user="$1" home=""
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$user" | cut -d: -f6)"
    fi
    [[ -n "$home" ]] || home="/home/$user"
    printf '%s' "$home"
}

# Fixture homes accumulate debris from a previous RED run of this suite, and
# a stale entry would land in the baseline and hide a real leak. Scrub them
# between cases -- but only ever a home whose path names one of this file's
# own throwaway users, never anything else on the machine.
scrub_fixture_home() {
    local home="$1"
    case "$home" in
        */vibedev125t[1-9]) ;;
        *) return 0 ;;
    esac
    [[ -d "$home" ]] || return 0
    find "$home" -mindepth 1 -maxdepth 1 ! -name '.*' \
        -exec rm -rf {} + 2>/dev/null || true
    return 0
}

scrub_case_dirs() {
    [[ -d "$CASE_DIR" ]] &&
        find "$CASE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    [[ "$CASE_DEMOTES" == yes ]] && scrub_fixture_home "$CASE_HOME"
    return 0
}

# ===========================================================================
# Watching
# ===========================================================================

watch_reset() {
    WATCH_DIRS=()
    WATCH_BASE=()
}

watch_add() {
    local dir="$1"
    local base="$RI_TMP/watch-${#WATCH_DIRS[@]}.base"
    ls -A "$dir" 2>/dev/null | LC_ALL=C sort >"$base"
    WATCH_DIRS+=("$dir")
    WATCH_BASE+=("$base")
}

# Re-baseline in place, so a case that has already reported one sample starts
# the next one from a clean slate instead of re-reporting old debris.
watch_rebase() {
    local i
    for ((i = 0; i < ${#WATCH_DIRS[@]}; i++)); do
        ls -A "${WATCH_DIRS[$i]}" 2>/dev/null | LC_ALL=C sort >"${WATCH_BASE[$i]}"
    done
}

# Prints one absolute path per entry that exists now and did not at baseline.
watch_new_entries() {
    local i cur="$RI_TMP/watch.cur"
    for ((i = 0; i < ${#WATCH_DIRS[@]}; i++)); do
        ls -A "${WATCH_DIRS[$i]}" 2>/dev/null | LC_ALL=C sort >"$cur"
        comm -13 "${WATCH_BASE[$i]}" "$cur" | sed "s|^|${WATCH_DIRS[$i]}/|"
    done
    rm -f "$cur"
}

begin_case() {
    local slot="$1"
    CASE_USER="$(case_user "$slot")"
    CASE_DIR="$RI_TMP/case-$slot"
    CASE_HOME=""
    CASE_DEMOTES=no

    mkdir -p "$CASE_DIR"
    # World-writable on purpose: before the fix the demoted user runs the
    # whole mkdir suite in here, and a launcher cwd it cannot write to would
    # fail for a reason that has nothing to do with #125.
    chmod 0777 "$CASE_DIR"

    if [[ "$DEMOTE" == yes ]] && ensure_user "$CASE_USER"; then
        CASE_DEMOTES=yes
        CASE_HOME="$(user_home "$CASE_USER")"
        chown "$CASE_USER" "$CASE_DIR" 2>/dev/null || true
    elif [[ "$DEMOTE" == yes ]]; then
        # useradd is not concurrency-safe and a parallel lane can lose the
        # race for /etc/passwd. The runner reacts the same way (:31-36: warn
        # and run as root, with no cd), so the launcher cwd really is the only
        # directory to watch here -- but say so, because it means this case is
        # covering less than it looks like it is.
        echo -e "${YELLOW}note:${NC} could not provision $CASE_USER;" \
            "this case watches the launcher cwd only." >&2
    fi

    scrub_case_dirs
    watch_reset
    watch_add "$CASE_DIR"
    if [[ "$CASE_DEMOTES" == yes ]] && [[ -d "$CASE_HOME" ]]; then
        watch_add "$CASE_HOME"
    fi
    return 0
}

# ===========================================================================
# Invoking the runner
# ===========================================================================

new_run_log() {
    RUN_SEQ=$((RUN_SEQ + 1))
    RUN_LOG="$RI_TMP/run-$RUN_SEQ.log"
    : >"$RUN_LOG"
}

# A runner that could not be executed at all must not be able to satisfy any
# expectation. An absent script would otherwise make bash exit 127, and 127
# is a number like any other -- the ambiguity between "ran and failed" and
# "never ran" is exactly what this sentinel removes.
run_suite() {
    local dir="$1" user="$2"
    shift 2
    new_run_log
    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        RUN_STATUS="did-not-run"
        return 0
    fi
    (
        cd "$dir" || exit 125
        export VIBEUTILS_TEST_USER="$user"
        exec bash "$RUN_INTEGRATION" "$@"
    ) >"$RUN_LOG" 2>&1
    RUN_STATUS=$?
    return 0
}

# Same, under a hard wall-clock limit. run_with_limit (common.sh:334) rather
# than timeout(1): macOS GitHub runners have no GNU timeout. It returns 124
# when the limit fired, which is how the caller knows the suite was still
# running when it was killed.
run_suite_limited() {
    local limit="$1" dir="$2" user="$3"
    shift 3
    new_run_log
    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        RUN_STATUS="did-not-run"
        return 0
    fi
    (
        cd "$dir" || exit 125
        export VIBEUTILS_TEST_USER="$user"
        run_with_limit "$limit" bash "$RUN_INTEGRATION" "$@"
    ) >"$RUN_LOG" 2>&1
    RUN_STATUS=$?
    return 0
}

run_suite_bg() {
    local dir="$1" user="$2"
    shift 2
    new_run_log
    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        RUN_STATUS="did-not-run"
        RUN_PID=0
        return 0
    fi
    (
        cd "$dir" || exit 125
        export VIBEUTILS_TEST_USER="$user"
        exec bash "$RUN_INTEGRATION" "$@"
    ) >"$RUN_LOG" 2>&1 &
    RUN_PID=$!
    return 0
}

# ===========================================================================
# Evidence extraction and assertions
# ===========================================================================

# The suite's own tally lines, e.g. "Tests run: 109" / "Passed: 109" /
# "Failed: 0". Colour is empty here because the log is not a tty.
summary_field() {
    local log="$1" label="$2"
    grep -a -m1 "^$label: " "$log" 2>/dev/null | awk '{print $NF}'
}

# Evidence that a suite really executed. "Nothing appeared in the watched
# directories" is satisfied by silence, so every cleanliness assertion below
# is paired with one of these: a run that reached a tally, or -- for the runs
# this suite kills on purpose -- one that at least reached the mkdir suite.
suite_ran_to_summary() {
    grep -a -qE '^Tests run: [0-9]+' "$1" 2>/dev/null
}

suite_started() {
    grep -a -q 'Testing mkdir utility' "$1" 2>/dev/null
}

# A green mkdir run, proven green rather than merely silent: exit 0, a tally
# with at least 109 assertions (the count the suite has today), every one of
# them passing, and the mkdir suite named in the log. A stub that exits 0
# without printing fails on all four.
assert_mkdir_run_green() {
    local label="$1" log="${2:-$RUN_LOG}"
    local run passed failed ok=yes why=""

    run=$(summary_field "$log" "Tests run")
    passed=$(summary_field "$log" "Passed")
    failed=$(summary_field "$log" "Failed")

    [[ "$RUN_STATUS" == "0" ]] || { ok=no; why="status=$RUN_STATUS"; }
    grep -a -q 'Testing mkdir utility' "$log" 2>/dev/null ||
        { ok=no; why="$why no-mkdir-suite-output"; }
    [[ "$run" =~ ^[0-9]+$ ]] && [[ "$run" -ge 109 ]] ||
        { ok=no; why="$why tests-run='$run'"; }
    [[ "$passed" == "$run" ]] || { ok=no; why="$why passed='$passed'"; }
    [[ "$failed" == "0" ]] || { ok=no; why="$why failed='$failed'"; }

    if [[ "$ok" == yes ]]; then
        print_test_result "$label: mkdir suite passes $run/$run" "PASS"
    else
        print_test_result "$label: mkdir suite passes 109/109" "FAIL" \
            "$why -- $(grep -a -m3 '^✗' "$log" 2>/dev/null |
                tr '\n' '|' | cut -c1-300)"
    fi
}

assert_no_new_entries() {
    local label="$1"
    local leaked count why=""
    leaked=$(watch_new_entries)
    count=$(printf '%s' "$leaked" | grep -c .)

    [[ "$count" == "0" ]] ||
        why="$count new entries: $(printf '%s' "$leaked" | tr '\n' ' ' |
            cut -c1-300)"
    suite_ran_to_summary "$RUN_LOG" || why="$why; no suite tally in the log"

    if [[ -z "$why" ]]; then
        print_test_result "$label: watched directories gained nothing" "PASS"
    else
        print_test_result "$label: watched directories gained nothing" "FAIL" \
            "$why"
    fi
}

# The isolation proof for R1. Today the contaminated run deletes the plant
# itself, so a surviving plant means the suite never entered that directory.
# It has to be paired with proof the suite ran: a runner that does nothing
# also leaves the plant alone.
assert_paths_exist() {
    local label="$1"
    shift
    local missing="" path why=""
    for path in "$@"; do
        [[ -e "$path" ]] || missing="$missing $path"
    done
    [[ -z "$missing" ]] || why="deleted by the suite:$missing"
    [[ $# -gt 0 ]] || why="$why; nothing was planted"
    suite_ran_to_summary "$RUN_LOG" || why="$why; no suite tally in the log"

    if [[ -z "$why" ]]; then
        print_test_result "$label: planted directories survive the run" "PASS"
    else
        print_test_result "$label: planted directories survive the run" "FAIL" \
            "$why"
    fi
}

# ===========================================================================
# R1 -- a contaminated working directory must not change the outcome.
#
# This is the mandated deterministic red. `combo` is planted in every
# directory the runner could adopt. Today exactly one of them is the suite's
# cwd, `mkdir -pv combo/test/path` creates two levels instead of three, and
# the run exits 1 with "✗ mkdir -pv combination" at 108/109. The second
# assertion is the isolation proof rather than a luck check: today the
# failing run deletes the plant itself (mkdir_test.sh:137), so a surviving
# plant means the suite genuinely never entered that directory.
# ===========================================================================

test_r1_contaminated_working_directory() {
    echo -e "${CYAN}R1: a pre-existing 'combo' must not poison the run...${NC}"
    begin_case 2

    local -a plants=("$CASE_DIR/combo")
    if [[ "$CASE_DEMOTES" == yes ]] && [[ -d "$CASE_HOME" ]]; then
        plants+=("$CASE_HOME/combo")
    fi

    local plant
    for plant in "${plants[@]}"; do
        mkdir -p "$plant"
        [[ "$CASE_DEMOTES" == yes ]] &&
            chown "$CASE_USER" "$plant" 2>/dev/null
    done
    # The plants are pre-existing state, not leakage.
    watch_rebase

    run_suite "$CASE_DIR" "$CASE_USER" mkdir
    assert_mkdir_run_green "R1"
    assert_paths_exist "R1" "${plants[@]}"
}

# ===========================================================================
# R2 -- an interrupted run must leave nothing behind.
#
# Ctrl-C during a run is the dev-box source of the leftover: teardown is a
# per-assertion `rm -rf`, so a kill mid-suite strands whatever fixture was
# live. Nine kill points are sampled because a single one can land in the gap
# between an rm and the next mkdir; the contract is that EVERY interruption
# leaves the watched directories clean, which after the fix is deterministic
# (the suite is not in them at all) and today is not.
# ===========================================================================

test_r2_interrupted_run_leaves_nothing() {
    echo -e "${CYAN}R2: an interrupted run must not strand fixtures...${NC}"
    begin_case 3

    local limit dirty="" killed=0 observed=0 saw_suite=0
    for limit in "${KILL_POINTS_S[@]}"; do
        run_suite_limited "$limit" "$CASE_DIR" "$CASE_USER" mkdir
        observed=$((observed + 1))
        [[ "$RUN_STATUS" == "124" ]] && killed=$((killed + 1))
        suite_started "$RUN_LOG" && saw_suite=$((saw_suite + 1))

        local leaked
        leaked=$(watch_new_entries)
        if [[ -n "$leaked" ]]; then
            dirty="$dirty ${limit}s:[$(printf '%s' "$leaked" |
                sed 's|.*/||' | tr '\n' ',')]"
        fi
        # Judge each interruption on its own, not on its predecessors' mess.
        scrub_case_dirs
        watch_rebase
    done

    # "Clean" is only meaningful when the runs being interrupted were doing
    # something, hence the saw_suite conjunct here as well as below.
    local detail
    detail="stranded fixtures at$(printf '%s' "$dirty" | cut -c1-260)"
    detail="$detail; mkdir output seen in $saw_suite of $observed sampled runs"

    if [[ -z "$dirty" ]] && [[ "$saw_suite" -ge 1 ]]; then
        print_test_result \
            "R2: $observed interrupted runs leave the watched dirs clean" "PASS"
    else
        print_test_result \
            "R2: $observed interrupted runs leave the watched dirs clean" \
            "FAIL" "$detail"
    fi

    # Sentinel: a runner that exits instantly, or one that hangs without ever
    # starting the suite, must not be able to satisfy the assertion above by
    # doing nothing at all.
    if [[ "$killed" == "$observed" ]] && [[ "$saw_suite" -ge 1 ]]; then
        print_test_result "R2: every sampled run was still executing the suite" \
            "PASS"
    else
        print_test_result "R2: every sampled run was still executing the suite" \
            "FAIL" \
            "killed=$killed/$observed with mkdir output in $saw_suite logs"
    fi
}

# ===========================================================================
# R3 -- the launcher's directories are never written to, at any instant.
#
# R1 and R2 look at the state after the fact, and mkdir_test.sh's own
# cleanups hide most of what it did. Polling through a complete run is what
# shows the traffic: today 83 distinct fixture names appear and disappear in
# the suite's working directory over ~3 seconds. After the fix the union is
# empty.
# ===========================================================================

test_r3_working_directory_never_written() {
    echo -e "${CYAN}R3: nothing may ever appear in the watched dirs...${NC}"
    begin_case 4

    run_suite_bg "$CASE_DIR" "$CASE_USER" mkdir
    local seen="$RI_TMP/r3-seen"
    : >"$seen"

    if [[ "$RUN_PID" != "0" ]]; then
        local i
        for ((i = 0; i < POLL_ITERATIONS_MAX; i++)); do
            watch_new_entries >>"$seen"
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep "$POLL_INTERVAL_S"
        done
        wait "$RUN_PID"
        RUN_STATUS=$?
        watch_new_entries >>"$seen"
    fi

    local union count
    union=$(LC_ALL=C sort -u "$seen")
    count=$(printf '%s' "$union" | grep -c .)

    local why=""
    [[ "$count" == "0" ]] ||
        why="$count distinct entries seen, e.g. $(printf '%s' "$union" |
            sed 's|.*/||' | head -8 | tr '\n' ' ')"
    suite_ran_to_summary "$RUN_LOG" || why="$why; no suite tally in the log"

    if [[ -z "$why" ]]; then
        print_test_result "R3: no entry ever appears in the watched dirs" "PASS"
    else
        print_test_result "R3: no entry ever appears in the watched dirs" \
            "FAIL" "$why"
    fi

    # Same sentinel discipline as everywhere else: "nothing appeared" only
    # means something when a real suite ran to completion.
    assert_mkdir_run_green "R3"
}

# ===========================================================================
# Regression guards
# ===========================================================================

test_regression_clean_mkdir_run() {
    echo -e "${CYAN}Regression: a clean mkdir run stays 109/109...${NC}"
    begin_case 1
    run_suite "$CASE_DIR" "$CASE_USER" mkdir
    assert_mkdir_run_green "clean run"
    assert_no_new_entries "clean run"
}

# The whole suite, from a working directory that is not the repo root. This
# is the case that catches a run directory the demoted user cannot traverse:
# such a directory does not fail here, it kills the run several utilities
# later at touch_test.sh:658 with "PWD: unbound variable". Nothing cheaper
# reproduces that chain.
test_regression_full_suite_completes() {
    echo -e "${CYAN}Regression: the full suite still completes (~3 min)...${NC}"
    begin_case 5
    run_suite "$CASE_DIR" "$CASE_USER"

    local tested ok=yes why=""
    tested=$(summary_field "$RUN_LOG" "Utilities tested")

    [[ "$RUN_STATUS" == "0" ]] || { ok=no; why="status=$RUN_STATUS"; }
    [[ "$tested" =~ ^[0-9]+$ ]] && [[ "$tested" -ge 40 ]] ||
        { ok=no; why="$why utilities-tested='$tested'"; }
    grep -a -q 'All utilities passed!' "$RUN_LOG" 2>/dev/null ||
        { ok=no; why="$why no all-passed line"; }
    grep -a -q 'PWD: unbound variable' "$RUN_LOG" 2>/dev/null &&
        { ok=no; why="$why run died on an untraversable working directory"; }

    if [[ "$ok" == yes ]]; then
        print_test_result "full suite: $tested utilities pass from a private cwd" \
            "PASS"
    else
        print_test_result "full suite: every utility passes from a private cwd" \
            "FAIL" "$why -- $(grep -a -m3 '^✗' "$RUN_LOG" 2>/dev/null |
                tr '\n' '|' | cut -c1-300)"
    fi

    assert_no_new_entries "full suite"
}

# ===========================================================================
# R4 -- concurrency. INFORMATIONAL ONLY, never part of the tally.
#
# Two suites started at the same instant from one shared directory and one
# test user. Today this is red 6/6 and 8/8 (assertions ranging from "Got: ''"
# on mkdir -pvm, because the sibling had already built the tree, to 29
# failures in a round). After the fix it must be green -- but a race that
# happens not to collide proves nothing, so this result is printed and
# excluded from TESTS_RUN. R1-R3 are the gates.
# ===========================================================================

INFO_RUN=0
INFO_FAILED=0

report_info() {
    local name="$1" result="$2" details="${3:-}"
    INFO_RUN=$((INFO_RUN + 1))
    if [[ "$result" == "PASS" ]]; then
        echo -e "${CYAN}i${NC} $name (informational: pass)"
    else
        INFO_FAILED=$((INFO_FAILED + 1))
        echo -e "${CYAN}i${NC} $name (informational: FAIL)"
        [[ -n "$details" ]] && echo "    $details"
    fi
    return 0
}

test_r4_concurrent_runs_informational() {
    echo -e "${CYAN}R4: two concurrent suites, one shared directory...${NC}"
    begin_case 6

    local log_a log_b pid_a pid_b rc_a rc_b
    log_a="$RI_TMP/r4-a.log"
    log_b="$RI_TMP/r4-b.log"

    if [[ ! -f "$RUN_INTEGRATION" ]]; then
        report_info "R4: both concurrent runs exit 0" "FAIL" "did-not-run"
        return 0
    fi

    (
        cd "$CASE_DIR" || exit 125
        export VIBEUTILS_TEST_USER="$CASE_USER"
        exec bash "$RUN_INTEGRATION" mkdir
    ) >"$log_a" 2>&1 &
    pid_a=$!
    (
        cd "$CASE_DIR" || exit 125
        export VIBEUTILS_TEST_USER="$CASE_USER"
        exec bash "$RUN_INTEGRATION" mkdir
    ) >"$log_b" 2>&1 &
    pid_b=$!

    wait "$pid_a"
    rc_a=$?
    wait "$pid_b"
    rc_b=$?

    local fails_a fails_b
    fails_a=$(summary_field "$log_a" "Failed")
    fails_b=$(summary_field "$log_b" "Failed")

    if [[ "$rc_a" == "0" ]] && [[ "$rc_b" == "0" ]] &&
        suite_ran_to_summary "$log_a" && suite_ran_to_summary "$log_b"; then
        report_info "R4: both concurrent runs exit 0" "PASS"
    else
        report_info "R4: both concurrent runs exit 0" "FAIL" \
            "rc=$rc_a/$rc_b failed-assertions=$fails_a/$fails_b -- $(
                grep -a -h -m2 '^✗' "$log_a" "$log_b" 2>/dev/null |
                tr '\n' '|' | cut -c1-300)"
    fi
}

# ===========================================================================
# Entry point
# ===========================================================================

main() {
    detect_platform
    run_preflight

    echo -e "${BLUE}Testing run-integration.sh${NC}"
    echo "=========================="
    echo "script under test: $RUN_INTEGRATION"
    echo "platform: $PLATFORM   demotes: $DEMOTE"
    echo "fixture root: $RI_TMP"
    echo ""

    test_regression_clean_mkdir_run
    test_r1_contaminated_working_directory
    test_r2_interrupted_run_leaves_nothing
    test_r3_working_directory_never_written
    test_r4_concurrent_runs_informational
    test_regression_full_suite_completes

    echo ""
    echo "informational (not gating): $INFO_RUN checked, $INFO_FAILED failing"

    # The last hole in the sentinel: a suite that runs no assertions at all
    # would otherwise print "All tests passed!" and exit 0.
    if [[ "$TESTS_RUN" -lt "$MIN_ASSERTIONS" ]]; then
        echo -e "${RED}did-not-run:${NC} only $TESTS_RUN assertions ran," \
            "expected at least $MIN_ASSERTIONS" >&2
        exit 2
    fi

    print_test_summary "run-integration.sh"
}

main "$@"
