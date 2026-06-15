#!/usr/bin/env bash
# Common test infrastructure for vibeutils integration tests
# Provides core testing functions and utilities
#
# Requires: bash 4.0+ (install with: brew install bash)

set -euo pipefail

# Check bash version (skip if already checked by parent script)
if [[ -z "${BASH_VERSION_CHECKED:-}" ]] && [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    echo "Error: This script requires bash 4.0 or later. Current version: $BASH_VERSION"
    echo "Install modern bash with: brew install bash"
    exit 1
fi
export BASH_VERSION_CHECKED=1

# Project paths
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$LIB_DIR")"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
BIN_DIR="$PROJECT_ROOT/zig-out/bin"
# Canonicalize the temp root so physical-path checks (e.g. pwd -P) compare
# equal regardless of the /tmp -> /private/tmp or /var -> /private/var
# symlinks on macOS, without per-prefix special-casing in the tests.
_temp_root="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || _temp_root="${TMPDIR:-/tmp}"
TEMP_DIR="$_temp_root/vibeutils_tests_$$"
unset _temp_root

# Colors for output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# Platform detection (global variable)
PLATFORM=""

# Detect platform and export for use in tests
detect_platform() {
    case "$(uname -s)" in
        Darwin*) PLATFORM="macos" ;;
        Linux*)  PLATFORM="linux" ;;
        *)       PLATFORM="unknown" ;;
    esac
    export PLATFORM
}

# Cross-platform file permissions getter
get_file_permissions() {
    local file="$1"
    local perms=""

    # Ensure platform is detected
    if [[ -z "$PLATFORM" ]]; then
        detect_platform
    fi

    # Debug: Check if file exists
    if [[ ! -e "$file" ]]; then
        echo "000"
        return 0
    fi

    # Try GNU stat first (works on Linux and macOS with GNU coreutils)
    perms=$(stat -c %a "$file" 2>/dev/null)
    # Fall back to BSD stat (macOS default)
    if [[ -z "$perms" ]]; then
        perms=$(stat -f %A "$file" 2>/dev/null)
    fi

    # If stat failed or returned empty, try fallback methods
    if [[ -z "$perms" ]]; then
        # Fallback: Use ls -l and parse permissions manually
        if [[ -e "$file" ]]; then
            local ls_output
            ls_output=$(ls -ld "$file" 2>/dev/null | cut -c2-10)
            if [[ -n "$ls_output" && ${#ls_output} -eq 9 ]]; then
                # Convert rwxrwxrwx format to octal
                local octal=0
                # User permissions
                [[ "${ls_output:0:1}" == "r" ]] && octal=$((octal + 400))
                [[ "${ls_output:1:1}" == "w" ]] && octal=$((octal + 200))
                [[ "${ls_output:2:1}" == "x" ]] && octal=$((octal + 100))
                # Group permissions
                [[ "${ls_output:3:1}" == "r" ]] && octal=$((octal + 40))
                [[ "${ls_output:4:1}" == "w" ]] && octal=$((octal + 20))
                [[ "${ls_output:5:1}" == "x" ]] && octal=$((octal + 10))
                # Other permissions
                [[ "${ls_output:6:1}" == "r" ]] && octal=$((octal + 4))
                [[ "${ls_output:7:1}" == "w" ]] && octal=$((octal + 2))
                [[ "${ls_output:8:1}" == "x" ]] && octal=$((octal + 1))

                printf "%03d" "$octal"
                return 0
            fi
        fi
        echo "000"
    else
        echo "$perms"
    fi
}

# Cross-platform file size getter
get_file_size() {
    local file="$1"

    # Ensure platform is detected
    if [[ -z "$PLATFORM" ]]; then
        detect_platform
    fi

    # Try GNU stat first, fall back to BSD stat
    local size
    size=$(stat -c %s "$file" 2>/dev/null)
    if [[ -z "$size" ]]; then
        size=$(stat -f %z "$file" 2>/dev/null)
    fi
    echo "${size:-0}"
}

# Export the platform functions for use in subshells
export -f get_file_permissions
export -f get_file_size

# Test counters (global state)
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
declare -a FAILED_TESTS=()

# Initialize test session
init_test_session() {
    TESTS_RUN=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    FAILED_TESTS=()

    # Detect platform for cross-platform compatibility
    detect_platform

    # Create temp directory
    mkdir -p "$TEMP_DIR"

    # On macOS new files inherit the directory's group (BSD semantics). If the
    # temp root belongs to a group the user is not a member of (e.g. a
    # wheel-owned /tmp), created files get an un-settable group, which breaks
    # cp -p group preservation and `test -G`. Force the user's primary group
    # so tests behave the same regardless of the ambient temp dir's group.
    chgrp "$(id -g)" "$TEMP_DIR" 2>/dev/null || true

    # Verify binary directory exists
    if [[ ! -d "$BIN_DIR" ]]; then
        echo -e "${RED}Error: Binary directory not found at $BIN_DIR${NC}"
        echo "Run 'make build' first"
        exit 1
    fi
}

# Cleanup test session
cleanup_test_session() {
    # Remove temp directory, but first restore permissions for any directories
    # that may have been made inaccessible by chmod tests
    if [[ -d "$TEMP_DIR" ]]; then
        # Restore execute permissions on any directories that lost them
        find "$TEMP_DIR" -type d -exec chmod u+x {} \; 2>/dev/null || true
        rm -rf "$TEMP_DIR"
    fi
}

# Print test result with consistent formatting
print_test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"
    local failed_command="${4:-}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [[ "$result" == "SKIP" ]]; then
        echo -e "${YELLOW}-${NC} $test_name (skipped)"
        if [[ -n "$details" ]]; then
            echo "    $details"
        fi
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    else
        echo -e "${RED}✗${NC} $test_name"
        if [[ -n "$details" ]]; then
            echo "    $details"
        fi
        if [[ -n "$failed_command" ]]; then
            echo -e "    ${CYAN}Failed command:${NC} $failed_command"
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
    fi
}

# Test if a utility binary exists and is executable
test_binary_exists() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    
    if [[ ! -x "$binary" ]]; then
        print_test_result "$util binary" "FAIL" "Binary not found or not executable at $binary"
        return 1
    fi
    
    print_test_result "$util binary" "PASS"
    return 0
}

# Test basic flags (--help and --version)
test_basic_flags() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    
    # Special handling for true/false - test their actual behavior
    if [[ "$util" == "true" ]]; then
        if "$binary" >/dev/null 2>&1; then
            print_test_result "true exit code" "PASS"
        else
            print_test_result "true exit code" "FAIL" "Should return 0" "$binary"
        fi
        return 0
    fi
    
    if [[ "$util" == "false" ]]; then
        if ! "$binary" >/dev/null 2>&1; then
            print_test_result "false exit code" "PASS"
        else
            print_test_result "false exit code" "FAIL" "Should return 1" "$binary"
        fi
        return 0
    fi
    
    # Test help flag
    # Special case: test utility treats --help as string (exit code 0), [ rejects it (exit code 2)
    if [[ "$util" == "test" ]]; then
        "$binary" --help >/dev/null 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            print_test_result "$util --help" "PASS"
        else
            print_test_result "$util --help" "FAIL" "Expected exit code 0 (POSIX), got $exit_code" "$binary --help"
        fi
    elif [[ "$util" == "[" ]]; then
        "$binary" --help >/dev/null 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            print_test_result "$util --help" "PASS"
        else
            print_test_result "$util --help" "FAIL" "Expected exit code 2, got $exit_code" "$binary --help"
        fi
    else
        if "$binary" --help >/dev/null 2>&1; then
            print_test_result "$util --help" "PASS"
        else
            print_test_result "$util --help" "FAIL" "Help flag failed" "$binary --help"
        fi
    fi
    
    # Test version flag
    # Special case: test utility treats --version as string (exit code 0), [ rejects it (exit code 2)
    if [[ "$util" == "test" ]]; then
        "$binary" --version >/dev/null 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            print_test_result "$util --version" "PASS"
        else
            print_test_result "$util --version" "FAIL" "Expected exit code 0 (POSIX), got $exit_code" "$binary --version"
        fi
    elif [[ "$util" == "[" ]]; then
        "$binary" --version >/dev/null 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            print_test_result "$util --version" "PASS"
        else
            print_test_result "$util --version" "FAIL" "Expected exit code 2, got $exit_code" "$binary --version"
        fi
    else
        if "$binary" --version >/dev/null 2>&1; then
            print_test_result "$util --version" "PASS"
        else
            print_test_result "$util --version" "FAIL" "Version flag failed" "$binary --version"
        fi
    fi
}

# Run a command and capture exit code, stdout, stderr
run_command() {
    local result_var=$1
    local stdout_var=$2
    local stderr_var=$3
    local exit_code_var=$4
    shift 4
    
    local stdout_file="$TEMP_DIR/stdout_$$"
    local stderr_file="$TEMP_DIR/stderr_$$"
    
    set +e
    "$@" >"$stdout_file" 2>"$stderr_file"
    eval "$exit_code_var=$?"
    set -e
    
    # Use printf to safely assign file contents to variables
    printf -v "$stdout_var" '%s' "$(cat "$stdout_file")"
    printf -v "$stderr_var" '%s' "$(cat "$stderr_file")"
    printf -v "$result_var" '%s' "$*"
    
    rm -f "$stdout_file" "$stderr_file"
}

# Run a command with a hard time limit. Returns the command's exit
# code, or 124 if the limit was exceeded. Uses python3 because macOS
# GitHub Actions runners don't have GNU `timeout(1)` installed.
#
# Uses os.fork + os.execvp so the child inherits the parent's stdin
# (and other fds) directly. Passing the script via `python3 -c` rather
# than a heredoc preserves the caller's stdin (heredocs would
# redirect stdin and break pipeline semantics).
#
# Usage: run_with_limit SECONDS CMD [ARGS...]
run_with_limit() {
    python3 -c '
import os, sys, time
limit = float(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    sys.exit(0)
try:
    pid = os.fork()
except OSError:
    sys.exit(127)
if pid == 0:
    try:
        os.execvp(cmd[0], cmd)
    except FileNotFoundError:
        os._exit(127)
    except OSError:
        os._exit(126)
deadline = time.monotonic() + limit
while True:
    try:
        done, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        sys.exit(1)
    if done != 0:
        if os.WIFEXITED(status):
            sys.exit(os.WEXITSTATUS(status))
        if os.WIFSIGNALED(status):
            sys.exit(128 + os.WTERMSIG(status))
        sys.exit(1)
    if time.monotonic() >= deadline:
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        sys.exit(124)
    time.sleep(0.05)
' "$@"
}

# Run a command with stderr attached to a pseudo-terminal and capture
# what the command writes to that PTY. Useful for testing behaviour
# gated on `isatty(stderr)`. Uses Python 3's `pty` module — present on
# every standard CI image (Ubuntu, macOS), with no BSD/Linux divergence.
#
# Writes the PTY output (stderr only) to stdout. ANSI escapes are stripped
# so callers can do simple substring matches.
run_with_stderr_tty() {
    python3 - "$@" <<'PYEOF'
import os, pty, re, select, sys

argv = sys.argv[1:]
if not argv:
    sys.exit(0)

# Fork with stderr attached to a pty; stdout goes to a pipe we discard.
stdout_r, stdout_w = os.pipe()
err_pid, err_fd = pty.fork()
if err_pid == 0:
    # Child: stdout → pipe, stderr → pty (inherited from pty.fork).
    os.dup2(stdout_w, 1)
    os.close(stdout_r)
    os.close(stdout_w)
    try:
        os.execvp(argv[0], argv)
    except OSError as e:
        sys.stderr.write(f"exec failed: {e}\n")
        os._exit(127)
os.close(stdout_w)

buf = bytearray()
while True:
    try:
        r, _, _ = select.select([err_fd, stdout_r], [], [], 5.0)
    except OSError:
        break
    if not r:
        break
    done = True
    for fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            continue
        if chunk:
            done = False
            if fd == err_fd:
                buf.extend(chunk)
    if done:
        break

# Safety net: if we bailed via the select timeout, the child may still
# be alive. SIGTERM it before waiting to avoid a hang.
try:
    pid, _ = os.waitpid(err_pid, os.WNOHANG)
    if pid == 0:
        try: os.kill(err_pid, 15)
        except ProcessLookupError: pass
        os.waitpid(err_pid, 0)
except ChildProcessError:
    pass
try:
    os.close(err_fd)
    os.close(stdout_r)
except OSError:
    pass

text = buf.decode("utf-8", errors="replace")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)  # strip ANSI
sys.stdout.write(text)
PYEOF
}

# Test a command with expected exit code
test_command_exit_code() {
    local test_name="$1"
    local expected_exit="$2"
    shift 2
    
    local command stdout stderr actual_exit
    run_command command stdout stderr actual_exit "$@"
    
    if [[ $actual_exit -eq $expected_exit ]]; then
        print_test_result "$test_name" "PASS"
        return 0
    else
        print_test_result "$test_name" "FAIL" "Expected exit $expected_exit, got $actual_exit" "$command"
        return 1
    fi
}

# Test a command with expected output
test_command_output() {
    local test_name="$1"
    local expected_output="$2"
    shift 2

    local command stdout stderr actual_exit
    run_command command stdout stderr actual_exit "$@"

    if [[ "$stdout" == "$expected_output" ]]; then
        print_test_result "$test_name" "PASS"
        return 0
    else
        print_test_result "$test_name" "FAIL" "Output mismatch. Expected: '$expected_output', Got: '$stdout'" "$command"
        return 1
    fi
}

# Test a command with expected output (preserves exact newlines)
test_command_output_exact() {
    local test_name="$1"
    local expected_output="$2"
    shift 2

    local temp_out="$TEMP_DIR/exact_out_$$"
    set +e
    "$@" >"$temp_out" 2>/dev/null
    local exit_code=$?
    set -e

    if cmp -s <(printf '%s' "$expected_output") "$temp_out"; then
        print_test_result "$test_name" "PASS"
        rm -f "$temp_out"
        return 0
    else
        local actual_output="$(<"$temp_out")"
        print_test_result "$test_name" "FAIL" "Output mismatch. Expected: '$expected_output', Got: '$actual_output'"
        rm -f "$temp_out"
        return 1
    fi
}

# Test a command with expected output pattern (regex)
test_command_output_pattern() {
    local test_name="$1"
    local expected_pattern="$2"
    shift 2
    
    local command stdout stderr actual_exit
    run_command command stdout stderr actual_exit "$@"
    
    if [[ "$stdout" =~ $expected_pattern ]]; then
        print_test_result "$test_name" "PASS"
        return 0
    else
        print_test_result "$test_name" "FAIL" "Output doesn't match pattern '$expected_pattern'. Got: '$stdout'" "$command"
        return 1
    fi
}

# Test a command that should succeed (exit 0)
test_command_succeeds() {
    local test_name="$1"
    shift
    test_command_exit_code "$test_name" 0 "$@"
}

# Test a command that should fail (exit non-zero)
test_command_fails() {
    local test_name="$1"
    shift
    
    local command stdout stderr actual_exit
    run_command command stdout stderr actual_exit "$@"
    
    if [[ $actual_exit -ne 0 ]]; then
        print_test_result "$test_name" "PASS"
        return 0
    else
        print_test_result "$test_name" "FAIL" "Expected command to fail, but it succeeded" "$command"
        return 1
    fi
}

# Create a temporary file with specific content
create_temp_file() {
    local content="$1"
    local filename="${2:-$(mktemp "$TEMP_DIR/testfile_XXXXXX")}"

    echo -n "$content" > "$filename"
    # Only echo the filename if it was auto-generated (no path provided)
    # This allows: local file=$(create_temp_file "content")
    # But prevents noise when: create_temp_file "content" "/specific/path"
    if [[ $# -eq 1 ]]; then
        echo "$filename"
    fi
}

# Create a temporary directory
create_temp_dir() {
    local dirname="${1:-$(mktemp -d "$TEMP_DIR/testdir_XXXXXX")}"
    mkdir -p "$dirname"
    echo "$dirname"
}

# Print test summary
print_test_summary() {
    local utility_name="${1:-Tests}"

    echo -e "\n${BLUE}$utility_name Summary${NC}"
    echo "$(printf '=%.0s' $(seq 1 $((${#utility_name} + 8))))"
    echo "Tests run: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    if [[ $TESTS_SKIPPED -gt 0 ]]; then
        echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    fi
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "\n${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $test"
        done
    fi

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "\n${RED}Some tests failed${NC}"
        return 1
    fi
}

# Trap to cleanup on exit
trap cleanup_test_session EXIT

# Test flags automatically extracted from --help output
test_automatic_flags() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    
    if [[ ! -x "$binary" ]]; then
        echo "Warning: Binary $binary not found" >&2
        return 1
    fi
    
    # Source flag parser
    source "$LIB_DIR/flag_parser.sh"
    
    # Extract flags
    local -a flags
    if extract_flags_from_help "$util" flags; then
        local flag_count=${#flags[@]}
        if [[ $flag_count -gt 0 ]]; then
            echo "  Found $flag_count documented flags to test..."
            
            # Test each flag exists (basic smoke test)
            local tested=0
            local passed=0
            for flag_info in "${flags[@]}"; do
                local flag="${flag_info%%:*}"
                # Skip --help and --version (already tested)
                [[ "$flag" =~ ^(-h|--help|-V|--version)$ ]] && continue
                
                ((tested++))
                # Basic smoke test: flag does not cause immediate error
                if "$binary" "$flag" --help >/dev/null 2>&1 || [[ $? -eq 1 ]]; then
                    ((passed++))
                    print_test_result "  $util $flag exists" "PASS"
                else
                    print_test_result "  $util $flag exists" "FAIL" "Flag not recognized" "$binary $flag"
                fi
            done
            
            echo "  Automatic flag tests: $passed/$tested passed"
        else
            echo "  No additional flags found to test"
        fi
        return 0
    else
        echo "  Could not extract flags from --help output"
        return 1
    fi
}
