#!/usr/bin/env bash
# POSIX I/O contract fixtures shared by the oracle and integration runner.

posix_io_has_fixture() {
    case "${1:-}" in
        echo | cat | ls | cp | mv | rm | mkdir | rmdir | touch | pwd | dirname)
            return 0
            ;;
        chmod | chown | ln | basename | sleep | true | false | test | '[' | yes)
            return 0
            ;;
        head | tail | tac | tee | wc | date | seq | whoami | realpath | id)
            return 0
            ;;
        mktemp | printf | env | timeout | stat | sort | tr | nl | uniq | readlink)
            return 0
            ;;
        cut | free | du | df | dd | find | grep | tree)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

posix_io_load_args() {
    local name="${1:-}"
    local contract="${2:-append}"
    POSIX_IO_ARGS=(--help)

    case "$name" in
        echo) POSIX_IO_ARGS=(posix-io) ;;
        true | false) POSIX_IO_ARGS=() ;;
        test) POSIX_IO_ARGS=(-n x) ;;
        '[') POSIX_IO_ARGS=(-n x ']') ;;
        sleep) POSIX_IO_ARGS=(0) ;;
        yes)
            if [[ "$contract" == closed-pipe ]]; then
                POSIX_IO_ARGS=()
            fi
            ;;
        printf) POSIX_IO_ARGS=(posix-io) ;;
    esac
}

posix_io_run() {
    local contract="${1:-}"
    local name="${2:-}"
    local file="${3:-}"
    local rc

    posix_io_load_args "$name" "$contract"
    case "$contract" in
        append)
            printf 'EXISTING\n' >"$file"
            set +e
            NO_COLOR=1 run_with_limit 2 \
                "$BIN_DIR/$name" "${POSIX_IO_ARGS[@]}" </dev/null >>"$file" 2>/dev/null
            rc=$?
            set -e
            return "$rc"
            ;;
        closed-pipe)
            set +e
            NO_COLOR=1 run_with_limit 2 python3 - \
                "$BIN_DIR/$name" "${POSIX_IO_ARGS[@]}" 2>/dev/null <<'PY'
import os
import sys

argv = sys.argv[1:]
read_end, write_end = os.pipe()
os.close(read_end)
os.dup2(write_end, 1)
os.close(write_end)
devnull = os.open(os.devnull, os.O_RDONLY)
os.dup2(devnull, 0)
os.close(devnull)
os.execv(argv[0], argv)
PY
            rc=$?
            set -e
            return "$rc"
            ;;
        *)
            return 2
            ;;
    esac
}

posix_io_exit() {
    local name="${1:-}"
    local kind="${2:-}"
    local rc
    local -a args=()

    case "$kind" in
        plain) ;;
        help) args=(--help) ;;
        unknown)
            args=(--posix-io-no-such-flag)
            if [[ "$name" == '[' ]]; then
                args+=(']')
            fi
            ;;
        *)
            printf '%s\n' 2
            return 0
            ;;
    esac

    set +e
    NO_COLOR=1 "$BIN_DIR/$name" "${args[@]}" </dev/null >/dev/null 2>&1
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

_posix_io_expected_fixture() {
    case "$1" in
        false) printf '%s\n' 1 ;;
        *) printf '%s\n' 0 ;;
    esac
}

_posix_io_expected_help() {
    case "$1" in
        false) printf '%s\n' 1 ;;
        '[') printf '%s\n' 2 ;;
        *) printf '%s\n' 0 ;;
    esac
}

_posix_io_expected_unknown() {
    case "$1" in
        echo | printf | true | test | '[') printf '%s\n' 0 ;;
        false) printf '%s\n' 1 ;;
        grep | ls | sort) printf '%s\n' 2 ;;
        env | timeout) printf '%s\n' 125 ;;
        *) printf '%s\n' 1 ;;
    esac
}

_posix_io_check_exit() {
    local name="$1"
    local kind="$2"
    local output="$3"
    local got want

    posix_io_exit "$name" "$kind" >"$output"
    got="$(<"$output")"
    if [[ "$kind" == help ]]; then
        want="$(_posix_io_expected_help "$name")"
    else
        want="$(_posix_io_expected_unknown "$name")"
    fi

    if [[ "$got" == "$want" ]]; then
        print_test_result "POSIX I/O: $name $kind exit status" "PASS"
        return 0
    fi
    print_test_result "POSIX I/O: $name $kind exit status" "FAIL" \
        "status $got, expected $want"
    return 1
}

test_posix_io() {
    local name="$1"
    local scratch="$TEMP_DIR/posix_io_scratch"
    local append="$scratch/append"
    local seed="$scratch/seed"
    local help_out="$scratch/help.out"
    local append_rc closed_rc want

    mkdir -p "$scratch"
    printf 'EXISTING\n' >"$seed"

    if posix_io_run append "$name" "$append"; then append_rc=0; else append_rc=$?; fi
    want="$(_posix_io_expected_fixture "$name")"
    if [[ "$append_rc" != "$want" ]]; then
        print_test_result "POSIX I/O: $name appends with >>" "FAIL" \
            "fixture status $append_rc, expected $want"
    elif python3 - "$append" <<'PY'
import pathlib
import sys

sys.exit(0 if pathlib.Path(sys.argv[1]).read_bytes().startswith(b"EXISTING\n") else 1)
PY
    then
        print_test_result "POSIX I/O: $name appends with >>" "PASS"
    else
        print_test_result "POSIX I/O: $name appends with >>" "FAIL" "seed was overwritten"
    fi

    if posix_io_run closed-pipe "$name" "$help_out"; then closed_rc=0; else closed_rc=$?; fi
    case "$closed_rc" in
        0 | 1 | 141) print_test_result "POSIX I/O: $name observes a closed pipe" "PASS" ;;
        *)
            print_test_result "POSIX I/O: $name observes a closed pipe" "FAIL" \
                "status $closed_rc, expected 0, 1, or 141"
            ;;
    esac

    _posix_io_check_exit "$name" help "$help_out" || true
    _posix_io_check_exit "$name" unknown "$help_out" || true

    rm -rf "$scratch"
    return 0
}
