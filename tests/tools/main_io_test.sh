#!/usr/bin/env bash
# Compiled-binary I/O init: 8KB writerStreaming buffers and flush-before-exit.
#
# runUtil() tests inject Allocating writers and never construct those buffers
# or flush them. This suite spawns the built echo/pwd/env binaries so a
# missing stdout.flush() or stderr.flush() in main() is visible.
#
# Invoked from tests/integration.sh on the all-utilities path. Lives in
# tests/tools/ because there is no main_io binary; tests/utilities/ would
# skip this file. Must return, never exit, so a failure cannot abort just it.

test_main_io() {
    local out err code payload got stripped tail
    local limit=10

    # PATH stays pinned to the build; spawn only these three binaries.
    if [[ -z "${BIN_DIR:-}" ]]; then
        print_test_result "main I/O BIN_DIR" "FAIL" "BIN_DIR is unset"
        return 0
    fi
    export PATH="${BIN_DIR}:${PATH}"

    if [[ -z "${TEMP_DIR:-}" || ! -d "${TEMP_DIR}" ]]; then
        TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_main_io.XXXXXX") || {
            print_test_result "main I/O temp dir" "FAIL" "mktemp failed"
            return 0
        }
    fi

    out=$(mktemp "$TEMP_DIR/main_io_out.XXXXXX") || {
        print_test_result "main I/O stdout temp" "FAIL" "mktemp failed"
        return 0
    }
    err=$(mktemp "$TEMP_DIR/main_io_err.XXXXXX") || {
        print_test_result "main I/O stderr temp" "FAIL" "mktemp failed"
        return 0
    }

    # --- short stdout: payload < 8192 survives process exit (flush) ---
    if [[ ! -x "$BIN_DIR/echo" ]]; then
        print_test_result "echo hi flushes short stdout" "FAIL" \
            "missing executable $BIN_DIR/echo"
    else
        code=0
        run_with_limit "$limit" "$BIN_DIR/echo" hi \
            < /dev/null > "$out" 2> "$err" || code=$?
        got=$(cat "$out")
        if [[ "$code" -eq 0 && ( "$got" == $'hi\n' || "$got" == "hi" ) ]]; then
            print_test_result "echo hi flushes short stdout" "PASS"
        else
            print_test_result "echo hi flushes short stdout" "FAIL" \
                "expected payload 'hi' (flush); exit=$code stdout_len=${#got}" \
                "$BIN_DIR/echo hi"
        fi
    fi

    # --- long stdout: 9000 bytes including the tail past one 8KB buffer ---
    # Unique tail (B vs A) so a flush of only the first 8192 cannot pass.
    if [[ ! -x "$BIN_DIR/echo" ]]; then
        print_test_result "echo 9000-byte payload includes tail" "FAIL" \
            "missing executable $BIN_DIR/echo"
    else
        payload=$(python3 -c 'import sys; sys.stdout.write("A" * 8192 + "B" * 808)')
        code=0
        run_with_limit "$limit" "$BIN_DIR/echo" "$payload" \
            < /dev/null > "$out" 2> "$err" || code=$?
        got=$(cat "$out")
        stripped="$got"
        if [[ "$stripped" == *$'\n' ]]; then
            stripped="${stripped%$'\n'}"
        fi
        tail="${payload: -808}"
        if [[ "$code" -eq 0 && "$stripped" == "$payload" && "$got" == *"$tail"* ]]; then
            print_test_result "echo 9000-byte payload includes tail" "PASS"
        else
            print_test_result "echo 9000-byte payload includes tail" "FAIL" \
                "expected 9000-byte payload plus unique tail; exit=$code stdout_len=${#got}" \
                "$BIN_DIR/echo <9000-byte arg>"
        fi
    fi

    # --- stderr flush: pwd uses utilityMain; echo treats unknown tokens as operands ---
    if [[ ! -x "$BIN_DIR/pwd" ]]; then
        print_test_result "pwd --not-a-flag flushes stderr" "FAIL" \
            "missing executable $BIN_DIR/pwd"
    else
        code=0
        run_with_limit "$limit" "$BIN_DIR/pwd" --not-a-flag \
            < /dev/null > "$out" 2> "$err" || code=$?
        got=$(cat "$err")
        if [[ "$code" -ne 0 && "$got" == *"unrecognized option"* ]]; then
            print_test_result "pwd --not-a-flag flushes stderr" "PASS"
        else
            print_test_result "pwd --not-a-flag flushes stderr" "FAIL" \
                "expected non-zero exit and stderr 'unrecognized option'; exit=$code" \
                "$BIN_DIR/pwd --not-a-flag"
        fi
    fi

    # --- custom main: env's own 8KB writerStreaming + flush, not utilityMain ---
    if [[ ! -x "$BIN_DIR/env" ]]; then
        print_test_result "env --help writes via custom main" "FAIL" \
            "missing executable $BIN_DIR/env"
    else
        code=0
        run_with_limit "$limit" "$BIN_DIR/env" --help \
            < /dev/null > "$out" 2> "$err" || code=$?
        got=$(cat "$out")
        if [[ -n "$got" ]]; then
            print_test_result "env --help writes via custom main" "PASS"
        else
            print_test_result "env --help writes via custom main" "FAIL" \
                "expected non-empty stdout from env's own main(); exit=$code" \
                "$BIN_DIR/env --help"
        fi
    fi

    return 0
}
