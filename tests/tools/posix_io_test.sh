#!/usr/bin/env bash
# Coverage oracle and POSIX I/O contract tests for tests/lib/posix_io.sh
# (TODO.md ### 2 POSIX Behavioral Conformance Suite).
#
# WHAT IS BEING GUARDED
# ---------------------
# Five TODO boxes, four runtime contracts plus a fixture table:
#
#   1. >> must append, not overwrite (echo tooth; true vacuous).
#   2. Stdout to a closed pipe must produce SIGPIPE / EPIPE (yes tooth).
#   3. Stderr must be unbuffered. The teeth are the two inline wait-tests
#      below (cat via utilityMain; env via its custom main). They talk to
#      $BIN_DIR/cat and $BIN_DIR/env directly — they do not call any
#      harness helper. There is no posix_io_unbuffered_stderr.
#   4. Exit codes match the measured table (echo/printf unknown=0, env
#      /timeout unknown=125, grep/ls/sort=2, false help=1, [ --help=2).
#   5. Every build/utils.zig name has an explicit fixture row.
#
# An empty fixture table, or a missing tests/lib/posix_io.sh, must make
# this suite RED (coverage). That is a second RED, never a substitute
# for the wait-tests. Both wait-tests run before `source posix_io.sh`
# so a missing harness cannot skip them under set -e.
#
# WHY tests/tools/ AND NOT tests/utilities/
# -----------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a
# file only when zig-out/bin/<name> is executable. There is no binary
# called "posix_io", so a file dropped in tests/utilities/ would be
# skipped silently. Same reasoning as tests/tools/fd_modes_test.sh.
# Invoke this directly with bash, or via `just test-posix-io`. Do not
# hook it into `just it` from here — that hook is the implementer's.
#
# IMPLEMENTER API (tests/lib/posix_io.sh)
# ---------------------------------------
# This oracle sources that file and calls only the names below. Do not
# rename them. The implementer fills in the bodies and the per-util
# fixture table; it does not edit this file's assertions or the
# wait-test Python.
#
#   posix_io_has_fixture NAME
#       Return 0 iff NAME has an explicit argv fixture row. An empty
#       or missing table must return non-zero for every NAME — that
#       is this oracle's coverage RED. `[` is a real name.
#       posix_io_has_fixture __posix_io_not_a_util__ must be nonzero.
#
#   posix_io_run CONTRACT NAME FILE
#       CONTRACT is `append` or `closed-pipe`.
#         append       Seed FILE with the exact bytes EXISTING\n, then
#                      run the fixture >> FILE. FILE must start with
#                      the seed. echo posix-io is the tooth (seed +
#                      posix-io\n); true is vacuous (seed unchanged).
#         closed-pipe  Exec with stdout already a closed pipe (read
#                      end closed before exec, not `cmd | true`).
#                      FILE may be unused. Wrap with run_with_limit 2;
#                      return 124 when the limit fires.
#       Prefix every spawn with NO_COLOR=1 (do not export it). Invoke
#       through "$BIN_DIR/$NAME", never the unqualified name.
#
#   posix_io_exit NAME KIND
#       KIND is `plain`, `help`, or `unknown`. Print the numeric
#       status on stdout. Do not overload a single argv.
#         plain    true / false with no extra args
#         help     $NAME --help (test treats --help as STRING;
#                  [ --help is missing ])
#         unknown  $NAME --posix-io-no-such-flag
#                  ([ needs a trailing ]; echo/printf treat it as
#                  an operand and exit 0)
#
# test_posix_io NAME is the runner hook (called from run_utility_tests
# after init_test_session). This oracle does not call it.
#
# Locked fixtures this oracle relies on (see the plan):
#   echo  →  echo posix-io     stdin /dev/null
#   true  →  true              stdin /dev/null
#   yes   →  unbounded yes     closed-pipe probe only
#
# Scratch dest names are append / seed / plus / vacuous / clobber /
# hang / pipe / prefix / posix-io-missing — never *dirname* / *pwd*
# / *touch* / *wc* / *rm* / *test*.

# Reporting helpers, colours, PROJECT_ROOT, BIN_DIR, run_with_limit.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; posix_io_has_fixture returning 1 is an assertion
# failure we want to record, not an abort. Wait-tests that FAIL must
# not skip the second wait-test or the coverage source. -u and
# pipefail stay.
set +e

POSIX_IO_LIB="$PROJECT_ROOT/tests/lib/posix_io.sh"
UTILS_ZIG="$PROJECT_ROOT/build/utils.zig"
SEED=$'EXISTING\n'
EXPECTED_NAME_COUNT=48

# Own scratch. Do not reuse TEMP_DIR (its name contains "test", a
# utility). Dest names below also avoid every utilities[].name.
POSIX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_posix_io.XXXXXX")"
posix_io_cleanup() {
    rm -rf "$POSIX_TMP"
}
# Replace common.sh's cleanup_test_session trap: this suite owns its
# scratch and does not call init_test_session (BIN_DIR is ensured
# below, but TEMP_DIR is not shared with just it).
trap posix_io_cleanup EXIT

# print_test_summary needs these.
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Parser + two wait-tests + source + `[` + fixture-per-name (48) +
# negative fixture + clobber + hang + run-defined + echo/true append +
# yes closed-pipe + exit-defined + true/false plain + help×48 +
# unknown×48. Below this the suite refuses a green tally — an empty
# harness cannot get here with this many PASSes, and dropping either
# wait-test drops below the floor.
MIN_ASSERTIONS=158

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

# Wait-tests and oracle-owned controls need the build. just build if
# any required binary is missing; do not invent a second install path.
ensure_build() {
    local n
    local missing=no
    for n in cat env sleep echo yes true; do
        if [[ ! -x "$BIN_DIR/$n" ]]; then
            missing=yes
            break
        fi
    done
    if [[ "$missing" == no ]]; then
        return 0
    fi
    echo "zig-out/bin missing required binaries -- running just build" >&2
    if ! (cd "$PROJECT_ROOT" && just build); then
        preflight_fail "just build failed; need $BIN_DIR/{cat,env,sleep,echo,yes,true}"
    fi
    for n in cat env sleep echo yes true; do
        [[ -x "$BIN_DIR/$n" ]] ||
            preflight_fail "just build did not produce $BIN_DIR/$n"
    done
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

require_fn() {
    local fn="$1"
    if ! declare -f "$fn" >/dev/null; then
        echo -e "${RED}implementer API missing:${NC} $fn" \
            "(define it in $POSIX_IO_LIB)" >&2
        return 1
    fi
    return 0
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

# ===========================================================================
# Contract 3 — inline wait-tests (BEFORE source posix_io.sh)
# ===========================================================================

# Accumulate select+read on the child's stderr for up to 2s. PASS only
# if the buffer contains MARKER and poll() is still None. FAIL if the
# process exits before the marker is visible (flush-on-exit cheat) or
# if the deadline fires with no marker (current main: 8KB-buffered
# stderr, select times out, stderr_bytes=b'', still_running=True).
#
# HOLD_STDIN=1 keeps the stdin write end open so cat MISSING - blocks
# on `-`. After the assertion, close stdin and wait with a 2s bound.
# KILL_GROUP=1 (env) kills the process group after the assertion so
# the sleep 5 child is not orphaned.

wait_test_cat() {
    local missing="$POSIX_TMP/posix-io-missing"
    local out rc
    # The path must not exist — cat reports it, then reads stdin for `-`.
    rm -f "$missing"
    out=$(NO_COLOR=1 python3 - "$BIN_DIR/cat" "$missing" <<'PY'
import os, select, signal, subprocess, sys, time

cat_bin, missing = sys.argv[1], sys.argv[2]
marker = b"posix-io-missing"
child_env = os.environ.copy()
child_env["NO_COLOR"] = "1"

proc = subprocess.Popen(
    [cat_bin, missing, "-"],
    stdin=subprocess.PIPE,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    env=child_env,
)
stderr_fd = proc.stderr.fileno()
os.set_blocking(stderr_fd, False)

buf = bytearray()
start = time.monotonic()
deadline = start + 2.0
select_ready = False
exited_before_marker = False

while time.monotonic() < deadline:
    if marker in buf:
        break
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    ready, _, _ = select.select([stderr_fd], [], [], remaining)
    if ready:
        select_ready = True
        try:
            chunk = os.read(stderr_fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            buf.extend(chunk)
            continue
        if proc.poll() is not None:
            break
    if proc.poll() is not None:
        try:
            chunk = os.read(stderr_fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            buf.extend(chunk)
            continue
        if marker not in buf:
            exited_before_marker = True
        break

elapsed = time.monotonic() - start
still_running = proc.poll() is None
has_marker = marker in buf
print(
    f"select_ready={select_ready} elapsed={elapsed:.3f} "
    f"still_running={still_running} stderr_bytes={bytes(buf)!r}",
    flush=True,
)

# Close stdin so cat can leave `-`; 2s wait bound, then SIGKILL.
if proc.stdin is not None:
    try:
        proc.stdin.close()
    except OSError:
        pass
try:
    proc.wait(timeout=2)
except subprocess.TimeoutExpired:
    try:
        proc.kill()
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass

if proc.stderr is not None:
    proc.stderr.close()

passed = has_marker and still_running and not exited_before_marker
sys.exit(0 if passed else 1)
PY
)
    rc=$?
    printf '%s\n' "$out"
    if [[ "$rc" -eq 0 ]]; then
        print_test_result \
            "cat wait-test: unbuffered stderr while blocked on stdin" "PASS"
    else
        print_test_result \
            "cat wait-test: unbuffered stderr while blocked on stdin" "FAIL" \
            "$out"
    fi
}

wait_test_env() {
    local out rc
    out=$(NO_COLOR=1 python3 - "$BIN_DIR/env" "$BIN_DIR/sleep" <<'PY'
import os, select, signal, subprocess, sys, time

env_bin, sleep_bin = sys.argv[1], sys.argv[2]
marker = b"clearing environment"
child_env = os.environ.copy()
child_env["NO_COLOR"] = "1"

proc = subprocess.Popen(
    [env_bin, "-v", "-i", sleep_bin, "5"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    env=child_env,
    start_new_session=True,
)
stderr_fd = proc.stderr.fileno()
os.set_blocking(stderr_fd, False)

buf = bytearray()
start = time.monotonic()
deadline = start + 2.0
select_ready = False
exited_before_marker = False

while time.monotonic() < deadline:
    if marker in buf:
        break
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    ready, _, _ = select.select([stderr_fd], [], [], remaining)
    if ready:
        select_ready = True
        try:
            chunk = os.read(stderr_fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            buf.extend(chunk)
            continue
        if proc.poll() is not None:
            break
    if proc.poll() is not None:
        try:
            chunk = os.read(stderr_fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            buf.extend(chunk)
            continue
        if marker not in buf:
            exited_before_marker = True
        break

elapsed = time.monotonic() - start
still_running = proc.poll() is None
has_marker = marker in buf
print(
    f"select_ready={select_ready} elapsed={elapsed:.3f} "
    f"still_running={still_running} stderr_bytes={bytes(buf)!r}",
    flush=True,
)

# Kill the process group (env and the sleep 5 child).
try:
    os.killpg(proc.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
try:
    proc.wait(timeout=2)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass

if proc.stderr is not None:
    proc.stderr.close()

passed = has_marker and still_running and not exited_before_marker
sys.exit(0 if passed else 1)
PY
)
    rc=$?
    printf '%s\n' "$out"
    if [[ "$rc" -eq 0 ]]; then
        print_test_result \
            "env wait-test: unbuffered stderr while waiting on sleep" "PASS"
    else
        print_test_result \
            "env wait-test: unbuffered stderr while waiting on sleep" "FAIL" \
            "$out"
    fi
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

    PARSED_NAMES=("${names[@]}")
}

# Fail the suite immediately when the harness is absent. An empty
# file that does not define posix_io_has_fixture is the same RED:
# fixtures are missing, so no name is covered. Distinct from the
# wait-test RED — those already ran.
source_harness_or_fail() {
    if [[ ! -f "$POSIX_IO_LIB" ]]; then
        print_test_result "source tests/lib/posix_io.sh" "FAIL" \
            "harness file is missing: $POSIX_IO_LIB"
        echo -e "${RED}posix_io harness missing:${NC} $POSIX_IO_LIB"
        echo "The implementer must add this file with posix_io_has_fixture," \
            "posix_io_run, and posix_io_exit."
        echo ""
        print_test_summary "posix_io"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$POSIX_IO_LIB"
    if ! require_fn posix_io_has_fixture; then
        print_test_result "source tests/lib/posix_io.sh" "FAIL" \
            "posix_io_has_fixture is not defined (empty or incomplete harness)"
        echo ""
        print_test_summary "posix_io"
        exit 1
    fi
    print_test_result "source tests/lib/posix_io.sh" "PASS"
}

test_every_name_has_fixture() {
    local util
    for util in "${PARSED_NAMES[@]}"; do
        if posix_io_has_fixture "$util"; then
            print_test_result "posix_io_has_fixture $util" "PASS"
        else
            print_test_result "posix_io_has_fixture $util" "FAIL" \
                "no fixture row for '$util' (empty/missing table is RED)"
        fi
    done
}

test_negative_fixture() {
    if posix_io_has_fixture __posix_io_not_a_util__; then
        print_test_result \
            "posix_io_has_fixture __posix_io_not_a_util__ is nonzero" "FAIL" \
            "unknown name must not have a fixture row"
    else
        print_test_result \
            "posix_io_has_fixture __posix_io_not_a_util__ is nonzero" "PASS"
    fi
}

# ===========================================================================
# Oracle-owned negative controls (do not need the harness)
# ===========================================================================

# Seed a file, then `$BIN_DIR/echo posix-io > file` (truncate, not >>).
# The seed-prefix cmp MUST fail — that is portable sabotage of the
# observation, not `.writer()`.
test_clobber_control() {
    local dest="$POSIX_TMP/clobber"
    local want="$POSIX_TMP/seed"
    local prefix="$POSIX_TMP/prefix"
    printf '%s' "$SEED" >"$want"
    printf '%s' "$SEED" >"$dest"
    NO_COLOR=1 "$BIN_DIR/echo" posix-io >"$dest"
    head -c "${#SEED}" "$dest" >"$prefix"
    if ! cmp -s "$want" "$prefix"; then
        print_test_result "oracle detects clobber" "PASS"
    else
        print_test_result "oracle detects clobber" "FAIL" \
            "seed prefix still present after truncate redirect"
    fi
}

# run_with_limit 1 on unbounded yes with stdout held open and never
# read must return 124. Proves a yes that ignored EPIPE would fail
# the suite (the closed-pipe contract would hang until the limit).
test_hang_control() {
    local fifo="$POSIX_TMP/hang"
    local rc
    rm -f "$fifo"
    mkfifo "$fifo"
    # RDWR hold: yes can open the write end without blocking on a
    # reader. We never read, so the pipe buffer fills and yes blocks.
    exec {hold}<>"$fifo"
    NO_COLOR=1 run_with_limit 1 "$BIN_DIR/yes" >"$fifo"
    rc=$?
    exec {hold}>&-
    rm -f "$fifo"
    if [[ "$rc" == 124 ]]; then
        print_test_result \
            "run_with_limit 1 yes (stdout held open, never-read) returns 124" \
            "PASS"
    else
        print_test_result \
            "run_with_limit 1 yes (stdout held open, never-read) returns 124" \
            "FAIL" "expected 124, got $rc"
    fi
}

# ===========================================================================
# Contract 1 — >> append (echo tooth, true vacuous)
# Contract 2 — closed pipe (unbounded yes)
# ===========================================================================

test_append_and_closed_pipe() {
    if ! require_fn posix_io_run; then
        print_test_result "posix_io_run is defined" "FAIL" \
            "implementer must provide posix_io_run CONTRACT NAME FILE"
        print_test_result "echo append: seed + posix-io" "FAIL" \
            "posix_io_run missing"
        print_test_result "true append: seed unchanged" "FAIL" \
            "posix_io_run missing"
        print_test_result "yes closed-pipe terminates (SIGPIPE or 0/1)" "FAIL" \
            "posix_io_run missing"
        return 0
    fi
    print_test_result "posix_io_run is defined" "PASS"

    local echo_dest="$POSIX_TMP/append"
    local true_dest="$POSIX_TMP/vacuous"
    local plus="$POSIX_TMP/plus"
    local seedf="$POSIX_TMP/seed"
    local pipef="$POSIX_TMP/pipe"
    local rc

    printf '%s' "$SEED" >"$seedf"
    {
        printf '%s' "$SEED"
        NO_COLOR=1 "$BIN_DIR/echo" posix-io
    } >"$plus"

    rm -f "$echo_dest"
    posix_io_run append echo "$echo_dest"
    rc=$?
    if [[ "$rc" == 124 ]]; then
        print_test_result "echo append: seed + posix-io" "FAIL" \
            "posix_io_run returned 124"
    else
        assert_files_eq "echo append: seed + posix-io" "$echo_dest" "$plus"
    fi

    rm -f "$true_dest"
    posix_io_run append true "$true_dest"
    rc=$?
    if [[ "$rc" == 124 ]]; then
        print_test_result "true append: seed unchanged" "FAIL" \
            "posix_io_run returned 124"
    else
        assert_files_eq "true append: seed unchanged" "$true_dest" "$seedf"
    fi

    rm -f "$pipef"
    posix_io_run closed-pipe yes "$pipef"
    rc=$?
    # PASS: signaled SIGPIPE (141) or exited 0/1 after BrokenPipe.
    # FAIL: hang (124) or any other signal / status.
    case "$rc" in
        0 | 1 | 141)
            print_test_result \
                "yes closed-pipe terminates (SIGPIPE or 0/1)" "PASS"
            ;;
        124)
            print_test_result \
                "yes closed-pipe terminates (SIGPIPE or 0/1)" "FAIL" \
                "posix_io_run returned 124 (hang)"
            ;;
        *)
            print_test_result \
                "yes closed-pipe terminates (SIGPIPE or 0/1)" "FAIL" \
                "wait status $rc (want 141 or exit 0/1)"
            ;;
    esac
}

# ===========================================================================
# Contract 4 — exit-code table (measured 2026-08-21)
# ===========================================================================

expected_help() {
    case "$1" in
        false) printf '%s' 1 ;;
        '[') printf '%s' 2 ;;
        *) printf '%s' 0 ;;
    esac
}

expected_unknown() {
    case "$1" in
        echo | printf | true | test | '[') printf '%s' 0 ;;
        false) printf '%s' 1 ;;
        grep | ls | sort) printf '%s' 2 ;;
        env | timeout) printf '%s' 125 ;;
        *) printf '%s' 1 ;;
    esac
}

assert_exit_kind() {
    local name="$1" kind="$2" want="$3"
    local got
    got=$(posix_io_exit "$name" "$kind")
    got="${got//$'\n'/}"
    if [[ "$got" == "$want" ]]; then
        print_test_result "posix_io_exit $name $kind" "PASS"
    else
        print_test_result "posix_io_exit $name $kind" "FAIL" \
            "expected $want, got '$got'"
    fi
}

fail_all_exit_rows() {
    local name
    print_test_result "posix_io_exit true plain" "FAIL" "posix_io_exit missing"
    print_test_result "posix_io_exit false plain" "FAIL" "posix_io_exit missing"
    for name in "${PARSED_NAMES[@]}"; do
        print_test_result "posix_io_exit $name help" "FAIL" \
            "posix_io_exit missing"
        print_test_result "posix_io_exit $name unknown" "FAIL" \
            "posix_io_exit missing"
    done
}

test_exit_table() {
    local name
    if ! require_fn posix_io_exit; then
        print_test_result "posix_io_exit is defined" "FAIL" \
            "implementer must provide posix_io_exit NAME KIND"
        fail_all_exit_rows
        return 0
    fi
    print_test_result "posix_io_exit is defined" "PASS"

    assert_exit_kind true plain 0
    assert_exit_kind false plain 1

    for name in "${PARSED_NAMES[@]}"; do
        assert_exit_kind "$name" help "$(expected_help "$name")"
        assert_exit_kind "$name" unknown "$(expected_unknown "$name")"
    done
}

# ===========================================================================
# Entry point
# ===========================================================================

main() {
    require_utils_table
    ensure_build
    pin_path

    echo -e "${BLUE}Testing POSIX I/O coverage oracle${NC}"
    echo "=================================="
    echo "harness: $POSIX_IO_LIB"
    echo "utilities: $UTILS_ZIG"
    echo ""

    test_parsed_names

    # Both wait-tests BEFORE source. A missing harness must not skip
    # them under set -e (we already flipped to set +e).
    wait_test_cat
    wait_test_env

    # Oracle-owned teeth; they do not need the harness. Run them
    # before source so a coverage RED still records them.
    test_clobber_control
    test_hang_control

    source_harness_or_fail
    test_every_name_has_fixture
    test_negative_fixture
    test_append_and_closed_pipe
    test_exit_table

    echo ""
    if [[ "$TESTS_RUN" -lt "$MIN_ASSERTIONS" ]]; then
        echo -e "${RED}did-not-run:${NC} only $TESTS_RUN assertions ran," \
            "expected at least $MIN_ASSERTIONS" >&2
        exit 2
    fi

    print_test_summary "posix_io"
}

main "$@"
