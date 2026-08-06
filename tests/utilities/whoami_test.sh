#!/usr/bin/env bash
# Integration tests for whoami utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

# The system oracle. It must be an absolute path: tests/integration.sh puts
# zig-out/bin at the front of PATH, so a bare `whoami` resolves to the binary
# under test and every comparison against it is vacuously true.
#
# `id -un` is used rather than the system whoami because it answers the
# EFFECTIVE-uid question on both macOS and Linux, which is the question whoami
# is defined to answer. /usr/bin/id exists on macOS and on ubuntu CI runners.
WHOAMI_ORACLE="/usr/bin/id"

# Assert the exact stderr of a failing whoami invocation.
# GNU coreutils 9.5 emits the operand line followed by the hint line.
whoami_expect_stderr() {
    local test_name="$1"
    local expected="$2"
    shift 2

    local actual
    actual=$("$@" 2>&1 >/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        print_test_result "$test_name" "PASS"
    else
        print_test_result "$test_name" "FAIL" \
            "Expected stderr '$expected', got '$actual'"
    fi
}

# Prove whoami tracks the EFFECTIVE uid, not the real one, by running it from
# a set-user-ID copy owned by another user. This needs root (only root can
# chown to another user) and a filesystem that honors the setuid bit, so it
# probes for both and skips when either is missing.
whoami_test_setuid() {
    local binary="$1"
    local test_name="whoami reports the effective UID under setuid"

    if [[ "$("$WHOAMI_ORACLE" -u)" != "0" ]]; then
        print_test_result "$test_name" "SKIP" \
            "requires root to create a setuid binary owned by another user"
        return 0
    fi

    local target="nobody"
    if ! "$WHOAMI_ORACLE" -u "$target" >/dev/null 2>&1; then
        print_test_result "$test_name" "SKIP" "no '$target' user on this system"
        return 0
    fi

    # /tmp is mounted nosuid on some hosts, so try several locations and use
    # the first one where a setuid probe actually changes the effective uid.
    local dir probe_dir="" candidate
    for candidate in "${TMPDIR:-/tmp}" /var/tmp /tmp "$HOME"; do
        [[ -d "$candidate" && -w "$candidate" ]] || continue
        dir=$(mktemp -d "$candidate/vibeutils-whoami-suid.XXXXXX" 2>/dev/null) || continue
        cp "$WHOAMI_ORACLE" "$dir/id_probe"
        chown "$target" "$dir/id_probe"
        chmod u+s "$dir/id_probe"
        if [[ "$("$dir/id_probe" -un 2>/dev/null)" == "$target" ]]; then
            probe_dir="$dir"
            break
        fi
        rm -rf "$dir"
    done

    if [[ -z "$probe_dir" ]]; then
        print_test_result "$test_name" "SKIP" \
            "no writable filesystem honors the setuid bit"
        return 0
    fi

    cp "$binary" "$probe_dir/whoami"
    chown "$target" "$probe_dir/whoami"
    chmod u+s "$probe_dir/whoami"

    local output
    output=$("$probe_dir/whoami" 2>/dev/null)
    if [[ "$output" == "$target" ]]; then
        print_test_result "$test_name" "PASS"
    else
        print_test_result "$test_name" "FAIL" \
            "Expected '$target' (effective uid), got '$output' (real uid leaked)"
    fi

    rm -rf "$probe_dir"
}

test_whoami() {
    local util="whoami"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing output correctness...${NC}"

    # Output must match the system oracle, not the binary under test.
    local expected
    expected=$("$WHOAMI_ORACLE" -un)
    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" == "$expected" ]]; then
        print_test_result "whoami matches system id -un" "PASS"
    else
        print_test_result "whoami matches system id -un" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    whoami_test_setuid "$binary"

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help prints the usage banner as its first line and exits 0.
    local help_output help_exit
    help_output=$("$binary" --help 2>/dev/null)
    help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" == "Usage: whoami [OPTION]..."* ]]; then
        print_test_result "whoami --help shows usage" "PASS"
    else
        print_test_result "whoami --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version prints exactly one "whoami (NAME) VERSION" line and exits 0.
    local version_output version_exit
    version_output=$("$binary" --version 2>/dev/null)
    version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ ^whoami\ \([^\)]+\)\ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        print_test_result "whoami --version shows version" "PASS"
    else
        print_test_result "whoami --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing flag precedence...${NC}"

    # GNU processes whichever of --help/--version appears FIRST.
    # Verified against GNU coreutils 9.5 with LC_ALL=C.
    local order_output
    order_output=$("$binary" --version --help 2>/dev/null)
    if [[ "$order_output" == whoami\ \(* && "$order_output" != *"Usage: whoami"* ]]; then
        print_test_result "whoami --version --help prints version" "PASS"
    else
        print_test_result "whoami --version --help prints version" "FAIL" \
            "Expected the version banner only, got '$order_output'"
    fi

    order_output=$("$binary" --help --version 2>/dev/null)
    if [[ "$order_output" == "Usage: whoami [OPTION]..."* ]]; then
        print_test_result "whoami --help --version prints help" "PASS"
    else
        print_test_result "whoami --help --version prints help" "FAIL" \
            "Expected the usage banner only, got '$order_output'"
    fi

    echo -e "${CYAN}Testing operand handling...${NC}"

    # A bare -- is the end-of-options marker, not an operand.
    # Verified: `LC_ALL=C /usr/bin/whoami --` prints the user name, exit 0.
    test_command_output "whoami -- prints the user name" "$expected" \
        "$binary" --

    local hint="Try 'whoami --help' for more information."

    whoami_expect_stderr "whoami extra operand message" \
        "whoami: extra operand 'extra'
$hint" \
        "$binary" extra
    test_command_exit_code "whoami extra operand exits 2" 2 "$binary" extra

    # A lone dash is an operand, not a flag.
    whoami_expect_stderr "whoami dash operand message" \
        "whoami: extra operand '-'
$hint" \
        "$binary" -
    test_command_exit_code "whoami dash operand exits 2" 2 "$binary" -

    whoami_expect_stderr "whoami empty operand message" \
        "whoami: extra operand ''
$hint" \
        "$binary" ""
    test_command_exit_code "whoami empty operand exits 2" 2 "$binary" ""

    whoami_expect_stderr "whoami operand after -- message" \
        "whoami: extra operand 'extra'
$hint" \
        "$binary" -- extra

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "whoami invalid flag exits 2" 2 \
        "$binary" --invalid-flag
}
