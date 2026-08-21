#!/usr/bin/env bash
# Runtime fd-mode harness for every vibeutils binary (TODO ### 1).
#
# Callers must source tests/lib/common.sh first (BIN_DIR, run_with_limit,
# print_test_result). Do not export NO_COLOR; prefix each spawn.

FD_MODES_SEED=$'EXISTING\n'
FD_MODES_LIMIT=2

# Explicit fixture table. A name missing from this case is RED for the
# coverage oracle. Default argv is --help (bounded, hits writerStreaming).
fd_modes_load_args() {
    local name="$1"
    FD_MODES_ARGS=()
    case "$name" in
        echo) FD_MODES_ARGS=(fd-mode) ;;
        true | false) FD_MODES_ARGS=() ;;
        test) FD_MODES_ARGS=(-n x) ;;
        '[') FD_MODES_ARGS=(-n x ']') ;;
        sleep) FD_MODES_ARGS=(0) ;;
        *) FD_MODES_ARGS=(--help) ;;
    esac
}

fd_modes_has_fixture() {
    case "$1" in
        echo | cat | ls | cp | mv | rm | mkdir | rmdir | touch | pwd | \
            dirname | chmod | chown | ln | basename | sleep | true | false | \
            test | '[' | yes | head | tail | tac | tee | wc | date | seq | \
            whoami | realpath | id | mktemp | printf | env | timeout | stat | \
            sort | tr | nl | uniq | readlink | cut | free | du | df | dd | \
            find | grep)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Spawn $BIN_DIR/$name (never the bash builtin). Status is captured so
# false exiting 1 does not abort under set -e. Restore errexit like
# test_command_output_exact. 124 means the limit fired.
fd_modes_spawn() {
    local file="$1"
    local redirect="$2"
    shift 2
    local bin="$1"
    shift
    local rc=0
    set +e

    case "$redirect" in
        append)
            NO_COLOR=1 run_with_limit "$FD_MODES_LIMIT" "$bin" "$@" \
                </dev/null >>"$file" 2>/dev/null
            rc=$?
            ;;
        pipe)
            NO_COLOR=1 run_with_limit "$FD_MODES_LIMIT" "$bin" "$@" \
                </dev/null 2>/dev/null | cat >"$file"
            rc=${PIPESTATUS[0]}
            ;;
        truncate)
            NO_COLOR=1 run_with_limit "$FD_MODES_LIMIT" "$bin" "$@" \
                </dev/null >"$file" 2>/dev/null
            rc=$?
            ;;
        dup-outer)
            NO_COLOR=1 run_with_limit "$FD_MODES_LIMIT" "$bin" "$@" \
                </dev/null 2>&1 >>"$file"
            rc=$?
            ;;
        dup-inner)
            NO_COLOR=1 run_with_limit "$FD_MODES_LIMIT" "$bin" "$@" \
                </dev/null >>"$file" 2>&1
            rc=$?
            ;;
        *)
            set -e
            return 2
            ;;
    esac
    set -e
    return "$rc"
}

fd_modes_run() {
    local mode="$1"
    local name="$2"
    local file="$3"
    local bin="$BIN_DIR/$name"
    local rc=0

    fd_modes_load_args "$name"

    case "$mode" in
        append)
            printf '%s' "$FD_MODES_SEED" >"$file"
            fd_modes_spawn "$file" append "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            ;;
        pipe)
            fd_modes_spawn "$file" pipe "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            ;;
        truncate)
            fd_modes_spawn "$file" truncate "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            if [[ "$rc" != 124 ]]; then
                rc=0
                fd_modes_spawn "$file" truncate "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            fi
            ;;
        dup-outer)
            printf '%s' "$FD_MODES_SEED" >"$file"
            fd_modes_spawn "$file" dup-outer "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            ;;
        dup-inner)
            printf '%s' "$FD_MODES_SEED" >"$file"
            fd_modes_spawn "$file" dup-inner "$bin" "${FD_MODES_ARGS[@]}" || rc=$?
            ;;
        *)
            return 2
            ;;
    esac
    return "$rc"
}

# Direct stdout capture for pipe/truncate compares (same argv, > file).
fd_modes_capture_direct() {
    local dest="$1"
    local name="$2"
    local rc=0
    fd_modes_load_args "$name"
    fd_modes_spawn "$dest" truncate "$BIN_DIR/$name" "${FD_MODES_ARGS[@]}" || rc=$?
    return "$rc"
}

# Per-utility hook. Issue #5 assertion: append/dup files start with the seed.
# Pipe stdout equals a direct capture; truncate twice equals one run.
test_fd_modes() {
    local util="$1"
    local mode got rc direct

    echo -e "${CYAN}File descriptor mode tests...${NC}"

    if ! fd_modes_has_fixture "$util"; then
        print_test_result "fd-modes fixture $util" "FAIL" \
            "no fixture row (missing table is RED)"
        return 0
    fi
    print_test_result "fd-modes fixture $util" "PASS"

    for mode in append pipe truncate dup-outer dup-inner; do
        got="${TEMP_DIR}/fd_modes_${util}_${mode}"
        rm -f "$got"
        rc=0
        fd_modes_run "$mode" "$util" "$got" || rc=$?
        if [[ "$rc" == 124 ]]; then
            print_test_result "fd-modes $util $mode" "FAIL" "run_with_limit fired"
            continue
        fi
        case "$mode" in
            append | dup-outer | dup-inner)
                # Do not capture via $(...); trailing newline is the seed's
                # last byte and command substitution would strip it.
                if cmp -s <(printf '%s' "$FD_MODES_SEED") <(head -c 9 "$got"); then
                    print_test_result "fd-modes $util $mode marker" "PASS"
                else
                    print_test_result "fd-modes $util $mode marker" "FAIL" \
                        "file did not start with EXISTING\\n"
                fi
                ;;
            pipe | truncate)
                direct="${got}.direct"
                rc=0
                fd_modes_capture_direct "$direct" "$util" || rc=$?
                if [[ "$rc" == 124 ]]; then
                    print_test_result "fd-modes $util $mode" "FAIL" \
                        "direct capture hit run_with_limit"
                elif cmp -s "$got" "$direct"; then
                    print_test_result "fd-modes $util $mode equals direct" "PASS"
                else
                    print_test_result "fd-modes $util $mode equals direct" "FAIL" \
                        "redirected stdout != one direct capture"
                fi
                ;;
        esac
    done
}
