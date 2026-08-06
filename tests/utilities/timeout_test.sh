#!/usr/bin/env bash
# Integration tests for timeout utility
# Tests timeout behavior, signal handling, exit codes, and options

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_timeout() {
    local util="timeout"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing command completes before timeout...${NC}"

    # Command that finishes quickly
    test_command_exit_code "timeout command succeeds" 0 "$binary" 10 true

    # Command that fails before timeout
    test_command_exit_code "timeout command fails" 1 "$binary" 10 false

    echo -e "${CYAN}Testing timeout behavior...${NC}"

    # Command that times out (sleep 60 with 0.5s timeout)
    test_command_exit_code "timeout kills slow command" 124 "$binary" 0.5 sleep 60

    echo -e "${CYAN}Testing zero timeout...${NC}"

    # Zero timeout disables the timeout
    test_command_exit_code "timeout 0 disables timeout" 0 "$binary" 0 true

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Missing operand
    test_command_fails "timeout missing operand" "$binary"

    # Missing command
    "$binary" 5 >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "timeout missing command" "PASS"
    else
        print_test_result "timeout missing command" "FAIL" \
            "Expected exit 125, got $exit_code"
    fi

    # Invalid duration
    "$binary" abc true >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "timeout invalid duration" "PASS"
    else
        print_test_result "timeout invalid duration" "FAIL" \
            "Expected exit 125, got $exit_code"
    fi

    # Command not found must exit exactly 127 (standard convention)
    "$binary" 1 /nonexistent_command_xyz >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 127 ]]; then
        print_test_result "timeout command not found exits 127" "PASS"
    else
        print_test_result "timeout command not found exits 127" "FAIL" \
            "Expected exit 127, got $exit_code"
    fi

    echo -e "${CYAN}Testing signal options...${NC}"

    # Custom signal name
    test_command_exit_code "timeout with -s KILL" 137 "$binary" -s KILL 0.5 sleep 60

    # Preserve status
    "$binary" --preserve-status 0.5 sleep 60 >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 143 ]]; then
        print_test_result "timeout --preserve-status" "PASS"
    else
        print_test_result "timeout --preserve-status" "FAIL" \
            "Expected exit 143 (128+TERM), got $exit_code"
    fi

    # Regression: setpgid race — very short timeouts with -s KILL must
    # still produce exit 137 (128+9), not 0.  Run several iterations to
    # increase the chance of hitting the race window where setpgid hasn't
    # taken effect before the signal is sent to the process group.
    # Each invocation is guarded by the system timeout (5s) to prevent
    # hangs when the race causes our binary to block in waitpid forever.
    echo -e "${CYAN}Testing setpgid race with -s KILL (multiple iterations)...${NC}"
    local kill_failures=0
    local kill_detail=""
    for i in $(seq 1 20); do
        run_with_limit 5 "$binary" -s KILL 0.01 sleep 60 >/dev/null 2>&1
        exit_code=$?
        if [[ $exit_code -ne 137 ]]; then
            kill_failures=$((kill_failures + 1))
            kill_detail="${kill_detail}  iter $i: got $exit_code\n"
        fi
    done
    if [[ $kill_failures -eq 0 ]]; then
        print_test_result "timeout -s KILL race (20 iterations)" "PASS"
    else
        print_test_result "timeout -s KILL race (20 iterations)" "FAIL" \
            "$kill_failures/20 runs did not exit 137:\n$kill_detail"
    fi

    # Regression: setpgid race — very short timeouts with --preserve-status
    # must still produce exit 143 (128+15), not 0.
    echo -e "${CYAN}Testing setpgid race with --preserve-status (multiple iterations)...${NC}"
    local ps_failures=0
    local ps_detail=""
    for i in $(seq 1 20); do
        run_with_limit 5 "$binary" --preserve-status 0.01 sleep 60 >/dev/null 2>&1
        exit_code=$?
        if [[ $exit_code -ne 143 ]]; then
            ps_failures=$((ps_failures + 1))
            ps_detail="${ps_detail}  iter $i: got $exit_code\n"
        fi
    done
    if [[ $ps_failures -eq 0 ]]; then
        print_test_result "timeout --preserve-status race (20 iterations)" "PASS"
    else
        print_test_result "timeout --preserve-status race (20 iterations)" "FAIL" \
            "$ps_failures/20 runs did not exit 143:\n$ps_detail"
    fi

    echo -e "${CYAN}Testing duration suffixes...${NC}"

    # Test with seconds suffix
    test_command_exit_code "timeout with seconds suffix" 0 "$binary" 10s true

    # Test with fractional duration
    test_command_exit_code "timeout with fractional duration" 0 "$binary" 0.5 true

    echo -e "${CYAN}Testing platform-correct signal names...${NC}"

    # Regression test: signal names resolve to platform-correct numbers
    # USR1 should be a valid signal name that timeout accepts
    local sig_cmd sig_out sig_stderr sig_exit
    run_command sig_cmd sig_out sig_stderr sig_exit "$binary" -s USR1 0.5 sleep 60
    # Exit code should indicate signal termination, not an invalid-signal error (125)
    if [[ $sig_exit -ne 125 ]]; then
        print_test_result "timeout -s USR1 is accepted" "PASS"
    else
        print_test_result "timeout -s USR1 is accepted" "FAIL" \
            "Expected signal delivery (not 125), got exit $sig_exit. Stderr: $sig_stderr"
    fi

    # Regression test: USR2 is also accepted as a valid signal name
    run_command sig_cmd sig_out sig_stderr sig_exit "$binary" -s USR2 0.5 sleep 60
    if [[ $sig_exit -ne 125 ]]; then
        print_test_result "timeout -s USR2 is accepted" "PASS"
    else
        print_test_result "timeout -s USR2 is accepted" "FAIL" \
            "Expected signal delivery (not 125), got exit $sig_exit. Stderr: $sig_stderr"
    fi

    # Verify --help documents the --signal flag
    local help_out
    help_out=$("$binary" --help 2>&1) || true
    if [[ "$help_out" == *"--signal"* ]]; then
        print_test_result "timeout --help documents --signal flag" "PASS"
    else
        print_test_result "timeout --help documents --signal flag" "FAIL" \
            "Expected --help to mention --signal"
    fi

    # Missing operands and invalid flags both exit 125
    echo -e "${CYAN}Testing exit codes for missing operands and bad flags...${NC}"

    test_command_exit_code "timeout no args exits 125" 125 "$binary"

    "$binary" --bad-flag 2>/dev/null
    exit_code=$?
    if [[ $exit_code -eq 125 ]]; then
        print_test_result "timeout --bad-flag exits 125" "PASS"
    else
        print_test_result "timeout --bad-flag exits 125" "FAIL" \
            "Expected exit 125, got $exit_code"
    fi

    echo -e "${CYAN}Testing audit findings (wave 5)...${NC}"

    # Audit: --kill-after should send KILL if command survives initial signal
    # Use a trap-ignoring script that ignores TERM but can be killed by KILL
    local ka_exit
    "$binary" -k 0.5 -s TERM 0.5 bash -c 'trap "" TERM; sleep 60' >/dev/null 2>&1
    ka_exit=$?
    if [[ $ka_exit -eq 137 ]]; then
        print_test_result "timeout --kill-after sends KILL after grace" "PASS"
    else
        print_test_result "timeout --kill-after sends KILL after grace" "FAIL" \
            "Expected exit 137 (128+KILL), got $ka_exit"
    fi

    # Audit: --verbose should print diagnostic to stderr when signal is sent
    local verbose_stderr
    verbose_stderr=$("$binary" --verbose 0.5 sleep 60 2>&1 >/dev/null)
    local verbose_exit=$?
    if [[ "$verbose_stderr" == *"sending signal"* ]]; then
        print_test_result "timeout --verbose prints signal diagnostic" "PASS"
    else
        print_test_result "timeout --verbose prints signal diagnostic" "FAIL" \
            "Expected 'sending signal' in stderr, got: '$verbose_stderr'"
    fi

    # Audit: --foreground should not create a new process group
    # Basic test: command should still complete normally
    test_command_exit_code "timeout --foreground basic" 0 "$binary" --foreground 10 true

    # --foreground with timeout should still produce exit 124
    test_command_exit_code "timeout --foreground with timeout" 124 "$binary" --foreground 0.5 sleep 60
}
