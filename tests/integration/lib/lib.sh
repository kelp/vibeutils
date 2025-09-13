#!/usr/bin/env bash
# Shell-based Integration Testing Framework for vibeutils
# Comprehensive testing framework with platform compatibility, parallel execution,
# and robust error handling.

set -euo pipefail

# Framework version
INTEGRATION_TEST_VERSION="1.0.0"

# Source required framework modules
FRAMEWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${FRAMEWORK_DIR}/colors.sh"
source "${FRAMEWORK_DIR}/platform.sh"
source "${FRAMEWORK_DIR}/assertions.sh"
source "${FRAMEWORK_DIR}/test_runner.sh"

# Global configuration (only set if not already set)
TEST_ROOT_DIR="${TEST_ROOT_DIR:-}"
TEST_BIN_DIR="${TEST_BIN_DIR:-}"
TEST_FIXTURES_DIR="${TEST_FIXTURES_DIR:-}"
TEST_TEMP_DIR="${TEST_TEMP_DIR:-}"
TEST_VERBOSE="${TEST_VERBOSE:-}"
TEST_PARALLEL="${TEST_PARALLEL:-}"
TEST_TIMEOUT="${TEST_TIMEOUT:-}"
TEST_CURRENT_SUITE="${TEST_CURRENT_SUITE:-}"
TEST_SUITE_START_TIME="${TEST_SUITE_START_TIME:-}"

# Test counters (global)
TEST_TOTAL=0
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0

# Current test context
CURRENT_TEST_NAME=""
CURRENT_TEST_SUITE=""

# Initialize the testing framework
# Usage: init_framework [options]
init_framework() {
    local verbose=false
    local parallel=false
    local timeout=30
    local temp_cleanup=true
    
    # Parse initialization options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose|-v)
                verbose=true
                shift
                ;;
            --parallel|-j)
                parallel=true
                shift
                ;;
            --timeout|-t)
                timeout="$2"
                shift 2
                ;;
            --no-cleanup)
                temp_cleanup=false
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Determine project root (only if not already set)
    if [[ -z "${TEST_ROOT_DIR:-}" ]]; then
        TEST_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
        TEST_BIN_DIR="${TEST_ROOT_DIR}/zig-out/bin"
        TEST_FIXTURES_DIR="${TEST_ROOT_DIR}/tests/fixtures"
        TEST_TEMP_DIR="${TEST_ROOT_DIR}/tests/integration/.tmp"
    fi
    
    # Set global configuration
    TEST_VERBOSE="$verbose"
    TEST_PARALLEL="$parallel"
    TEST_TIMEOUT="$timeout"
    
    # Export all test variables for subshells
    export TEST_ROOT_DIR TEST_BIN_DIR TEST_FIXTURES_DIR TEST_TEMP_DIR
    export TEST_VERBOSE TEST_PARALLEL TEST_TIMEOUT
    
    # Initialize platform detection
    init_platform
    
    # Initialize colors
    init_colors
    
    # Create temporary directory
    mkdir -p "$TEST_TEMP_DIR"
    
    # Set up cleanup on exit if enabled
    if [[ "$temp_cleanup" == "true" ]]; then
        trap cleanup_framework EXIT
    fi
    
    # Verify required directories exist
    if [[ ! -d "$TEST_BIN_DIR" ]]; then
        print_error "Binary directory not found: $TEST_BIN_DIR"
        print_error "Run 'make build' first"
        return 1
    fi
    
    if [[ ! -d "$TEST_FIXTURES_DIR" ]]; then
        print_warning "Fixtures directory not found: $TEST_FIXTURES_DIR"
        print_info "Some tests may be skipped"
    fi
    
    print_info "Integration testing framework initialized"
    if [[ "$TEST_VERBOSE" == "true" ]]; then
        print_info "  Root dir: $TEST_ROOT_DIR"
        print_info "  Binary dir: $TEST_BIN_DIR"
        print_info "  Fixtures dir: $TEST_FIXTURES_DIR"
        print_info "  Temp dir: $TEST_TEMP_DIR"
        print_info "  Platform: $(get_platform)"
        print_info "  Parallel: $TEST_PARALLEL"
        print_info "  Timeout: ${TEST_TIMEOUT}s"
    fi
}

# Clean up framework resources
cleanup_framework() {
    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        if [[ "$TEST_VERBOSE" == "true" ]]; then
            print_info "Cleaning up temporary directory: $TEST_TEMP_DIR"
        fi
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
}

# Start a test suite
# Usage: start_suite "suite_name"
start_suite() {
    local suite_name="$1"
    
    TEST_CURRENT_SUITE="$suite_name"
    CURRENT_TEST_SUITE="$suite_name"
    TEST_SUITE_START_TIME=$(date +%s)
    
    print_suite_header "$suite_name"
}

# End a test suite and print summary
# Usage: end_suite
end_suite() {
    if [[ -n "${TEST_CURRENT_SUITE:-}" ]]; then
        local suite_end_time=$(date +%s)
        local duration=$((suite_end_time - TEST_SUITE_START_TIME))
        
        print_suite_footer "$TEST_CURRENT_SUITE" "$duration"
        TEST_CURRENT_SUITE=""
        CURRENT_TEST_SUITE=""
    fi
}

# Run a single test with proper error handling and timeout
# Usage: run_test "test_name" "test_function" [timeout]
run_test() {
    local test_name="$1"
    local test_function="$2"
    local timeout="${3:-$TEST_TIMEOUT}"
    
    CURRENT_TEST_NAME="$test_name"
    ((TEST_TOTAL++))
    
    if [[ "$TEST_VERBOSE" == "true" ]]; then
        print_info "Running test: $test_name"
    fi
    
    # Create isolated temp directory for this test atomically
    local test_temp_dir
    test_temp_dir=$(mktemp -d "${TEST_TEMP_DIR}/$(basename "$test_name" | tr ' ' '_').XXXXXX")
    
    # Run test in subshell with timeout using proper quoting
    local test_result
    if timeout "$timeout" bash -c '
        set -euo pipefail
        cd "$1"
        export TEST_TEMP_DIR="$1"
        export CURRENT_TEST_NAME="$2"
        
        # Source framework again in subshell
        source "$3"
        
        # Validate test function name (security)
        if [[ "$4" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            # Run the actual test function
            "$4"
        else
            echo "Invalid test function name: $4" >&2
            exit 1
        fi
    ' -- "$test_temp_dir" "$test_name" "${FRAMEWORK_DIR}/lib.sh" "$test_function" 2>&1; then
        test_result="PASS"
        ((TEST_PASSED++))
        print_test_pass "$test_name"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            test_result="TIMEOUT"
            print_test_timeout "$test_name" "$timeout"
        else
            test_result="FAIL"
            ((TEST_FAILED++))
            print_test_fail "$test_name"
        fi
    fi
    
    # Cleanup test temp directory
    rm -rf "$test_temp_dir" 2>/dev/null || true
    
    return $(( test_result == "PASS" ? 0 : 1 ))
}

# Skip a test with reason
# Usage: skip_test "test_name" "reason"
skip_test() {
    local test_name="$1"
    local reason="$2"
    
    CURRENT_TEST_NAME="$test_name"
    ((TEST_TOTAL++))
    ((TEST_SKIPPED++))
    
    print_test_skip "$test_name" "$reason"
}

# Print final test results summary
print_final_summary() {
    local total_duration=0
    if [[ -n "${TEST_SUITE_START_TIME:-}" ]]; then
        local end_time=$(date +%s)
        total_duration=$((end_time - TEST_SUITE_START_TIME))
    fi
    
    print_separator
    print_info "Integration Test Results"
    print_separator
    
    printf "Total Tests: %s%d%s\\n" "$BOLD" "$TEST_TOTAL" "$NC"
    printf "Passed:      %s%d%s\\n" "$GREEN$BOLD" "$TEST_PASSED" "$NC"
    printf "Failed:      %s%d%s\\n" "$RED$BOLD" "$TEST_FAILED" "$NC"
    printf "Skipped:     %s%d%s\\n" "$YELLOW$BOLD" "$TEST_SKIPPED" "$NC"
    
    if [[ $total_duration -gt 0 ]]; then
        printf "Duration:    %s%ds%s\\n" "$CYAN" "$total_duration" "$NC"
    fi
    
    print_separator
    
    if [[ $TEST_FAILED -eq 0 ]]; then
        if [[ $TEST_PASSED -eq 0 ]]; then
            print_warning "No tests were executed!"
            return 2
        else
            print_success "All tests passed!"
            return 0
        fi
    else
        print_error "$TEST_FAILED test(s) failed!"
        return 1
    fi
}

# Check if a utility binary exists and is executable
# Usage: has_utility "utility_name"
has_utility() {
    local utility="$1"
    local binary_path="${TEST_BIN_DIR}/${utility}"
    
    [[ -f "$binary_path" ]] && [[ -x "$binary_path" ]]
}

# Get path to utility binary
# Usage: get_utility_path "utility_name"
get_utility_path() {
    local utility="$1"
    echo "${TEST_BIN_DIR}/${utility}"
}

# Create a temporary file with optional content
# Usage: create_temp_file [content] [suffix]
create_temp_file() {
    local content="${1:-}"
    local suffix="${2:-tmp}"
    local temp_file
    temp_file=$(mktemp "${TEST_TEMP_DIR}/test.XXXXXX")
    # Add suffix by renaming if needed
    if [[ "$suffix" != "tmp" ]]; then
        local new_temp_file="${temp_file}.${suffix}"
        mv "$temp_file" "$new_temp_file"
        temp_file="$new_temp_file"
    fi
    
    if [[ -n "$content" ]]; then
        printf "%s" "$content" > "$temp_file"
    else
        touch "$temp_file"
    fi
    
    echo "$temp_file"
}

# Create a temporary directory
# Usage: create_temp_dir [name]
create_temp_dir() {
    local name="${1:-test_dir_${RANDOM}_$$}"
    local temp_dir
    if [[ -n "${name:-}" ]]; then
        # Use provided name as template
        temp_dir=$(mktemp -d "${TEST_TEMP_DIR}/${name}.XXXXXX")
    else
        temp_dir=$(mktemp -d "${TEST_TEMP_DIR}/test_dir.XXXXXX")
    fi
    echo "$temp_dir"
}

# Execute a utility with timeout and capture output/exit code
# Usage: exec_utility "utility" [args...] [options]
# Options: --timeout=N, --input=string, --expect-failure
exec_utility() {
    local utility="$1"
    shift
    
    local timeout="$TEST_TIMEOUT"
    local input=""
    local expect_failure=false
    local args=()
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --timeout=*)
                timeout="${1#*=}"
                shift
                ;;
            --input=*)
                input="${1#*=}"
                shift
                ;;
            --expect-failure)
                expect_failure=true
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    local binary_path="$(get_utility_path "$utility")"
    
    if ! has_utility "$utility"; then
        print_error "Utility not found: $utility"
        return 127
    fi
    
    # Execute with timeout and input handling
    local exit_code=0
    local output
    
    if [[ -n "$input" ]]; then
        output=$(printf "%s" "$input" | timeout "$timeout" "$binary_path" ${args[@]+"${args[@]}"} 2>&1) || exit_code=$?
    else
        output=$(timeout "$timeout" "$binary_path" ${args[@]+"${args[@]}"} 2>&1) || exit_code=$?
    fi
    
    # Store results in global variables for test functions to access
    EXEC_OUTPUT="$output"
    EXEC_EXIT_CODE="$exit_code"
    
    if [[ "$expect_failure" == "true" ]]; then
        [[ $exit_code -ne 0 ]]
    else
        [[ $exit_code -eq 0 ]]
    fi
}

# Utility function to check if running on specific platform
# Usage: is_platform "linux|macos|windows"
is_platform() {
    local platform="$1"
    [[ "$(get_platform)" == "$platform" ]]
}

# Utility function to check if running as root/privileged
is_privileged() {
    [[ $EUID -eq 0 ]] || [[ -n "${FAKEROOT:-}" ]]
}

# Load test fixture file
# Usage: load_fixture "fixture_name"
load_fixture() {
    local fixture_name="$1"
    local fixture_path="${TEST_FIXTURES_DIR}/${fixture_name}"
    
    if [[ ! -f "$fixture_path" ]]; then
        print_error "Fixture not found: $fixture_name"
        return 1
    fi
    
    cat "$fixture_path"
}

# Copy fixture to temp directory
# Usage: copy_fixture "fixture_name" [target_name]
copy_fixture() {
    local fixture_name="$1"
    local target_name="${2:-$fixture_name}"
    local fixture_path="${TEST_FIXTURES_DIR}/${fixture_name}"
    local target_path="${TEST_TEMP_DIR}/${target_name}"
    
    if [[ ! -f "$fixture_path" ]]; then
        print_error "Fixture not found: $fixture_name"
        return 1
    fi
    
    cp "$fixture_path" "$target_path"
    echo "$target_path"
}

# Framework validation - ensure everything is properly set up
validate_framework() {
    local errors=0
    
    # Check required variables
    local required_vars=(
        "TEST_ROOT_DIR"
        "TEST_BIN_DIR" 
        "TEST_FIXTURES_DIR"
        "TEST_TEMP_DIR"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            print_error "Required variable not set: $var"
            ((errors++))
        fi
    done
    
    # Check required directories
    if [[ ! -d "$TEST_BIN_DIR" ]]; then
        print_error "Binary directory missing: $TEST_BIN_DIR"
        ((errors++))
    fi
    
    # Check framework modules
    local modules=(
        "colors.sh"
        "platform.sh"
        "assertions.sh"
        "test_runner.sh"
    )
    
    for module in "${modules[@]}"; do
        if [[ ! -f "${FRAMEWORK_DIR}/${module}" ]]; then
            print_error "Framework module missing: $module"
            ((errors++))
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        print_error "Framework validation failed with $errors errors"
        return 1
    fi
    
    print_success "Framework validation passed"
    return 0
}

# Help function
print_framework_help() {
    cat << 'EOF'
Shell-based Integration Testing Framework for vibeutils

USAGE:
    source tests/integration/lib/lib.sh
    init_framework [options]
    
INITIALIZATION OPTIONS:
    --verbose, -v          Enable verbose output
    --parallel, -j         Enable parallel test execution
    --timeout=N, -t N      Set test timeout in seconds (default: 30)
    --no-cleanup          Don't clean up temporary files on exit

FRAMEWORK FUNCTIONS:
    init_framework         Initialize the testing framework
    start_suite "name"     Start a test suite
    end_suite             End current test suite
    run_test "name" func   Run a single test function
    skip_test "name" "why" Skip a test with reason
    print_final_summary    Print final results and exit with status

UTILITY FUNCTIONS:
    has_utility "name"     Check if utility binary exists
    get_utility_path "name" Get full path to utility binary
    exec_utility "name" args Execute utility with timeout/input handling
    create_temp_file [content] [suffix] Create temporary file
    create_temp_dir [name] Create temporary directory
    load_fixture "name"    Load test fixture content
    copy_fixture "name"    Copy fixture to temp directory

COMMON TEST HELPERS:
    setup_test             Standard test setup (cd to temp dir)
    cleanup_test_files files... Remove test files safely
    create_test_file_with_lines file count [prefix] Create file with N lines
    create_test_file_with_binary file content Create binary content file
    create_test_file_with_perms file perms [content] Create file with permissions
    create_test_input [content] Create test input string
    run_utility_test util timeout args... Execute utility test safely
    run_utility_test_expecting_failure util timeout args... Execute expecting failure
    validate_utility_available util Check utility exists and error if not

ASSERTION FUNCTIONS:
    assert_equals expected actual [message]
    assert_not_equals unexpected actual [message]
    assert_contains haystack needle [message]
    assert_not_contains haystack needle [message]
    assert_matches text pattern [message]
    assert_file_exists path [message]
    assert_file_not_exists path [message]
    assert_directory_exists path [message]
    assert_exit_code expected [message]
    assert_success [message]
    assert_failure [message]

PLATFORM FUNCTIONS:
    is_platform "linux|macos|windows"
    is_privileged
    get_platform

VARIABLES:
    EXEC_OUTPUT           Last command output
    EXEC_EXIT_CODE        Last command exit code
    CURRENT_TEST_NAME     Current test being executed
    CURRENT_TEST_SUITE    Current test suite
    TEST_TEMP_DIR         Temporary directory for current test
    
EOF
}

# =============================================================================
# Common Test Helper Functions (reduce duplication across utility tests)
# =============================================================================

# Generic test setup - changes to temp directory
# Usage: setup_test
setup_test() {
    # Ensure we have a clean test environment
    cd "$TEST_TEMP_DIR"
}

# Generic cleanup for test files
# Usage: cleanup_test_files file1 file2 ...
cleanup_test_files() {
    local files=("$@")
    for file in "${files[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
}

# Create test file with specified number of lines
# Usage: create_test_file_with_lines filename line_count [prefix]
create_test_file_with_lines() {
    local file="$1"
    local line_count="$2"
    local prefix="${3:-line}"
    
    for ((i = 1; i <= line_count; i++)); do
        printf "%s %d\n" "$prefix" "$i"
    done > "$file"
}

# Create test file with binary content
# Usage: create_test_file_with_binary filename content
create_test_file_with_binary() {
    local filename="$1"
    local content="$2"
    printf '%s' "$content" > "$filename"
}

# Create test file with specific permissions
# Usage: create_test_file_with_perms filename permissions [content]
create_test_file_with_perms() {
    local filename="$1"
    local permissions="$2"
    local content="${3:-test file content}"
    
    printf "%s\n" "$content" > "$filename"
    chmod "$permissions" "$filename"
}

# Create test input data helper
# Usage: create_test_input [content]
create_test_input() {
    local content="${1:-test input data}"
    printf "%s" "$content"
}

# Common test execution pattern with utility validation
# Usage: run_utility_test utility_name timeout_seconds [...args]
run_utility_test() {
    local utility="$1"
    local timeout="$2"
    shift 2
    
    if ! has_utility "$utility"; then
        print_error "$utility utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    exec_utility "$utility" --timeout="$timeout" "$@"
}

# Common test execution pattern expecting failure
# Usage: run_utility_test_expecting_failure utility_name timeout_seconds [...args]
run_utility_test_expecting_failure() {
    local utility="$1"
    local timeout="$2"
    shift 2
    
    if ! has_utility "$utility"; then
        print_error "$utility utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    exec_utility "$utility" --timeout="$timeout" --expect-failure "$@"
}

# Standard utility test validation
# Usage: validate_utility_available utility_name
validate_utility_available() {
    local utility="$1"
    
    if ! has_utility "$utility"; then
        print_error "$utility utility not found in ${TEST_BIN_DIR}"
        print_error "Run 'make build' to build the utilities first"
        return 1
    fi
    
    return 0
}

# =============================================================================

# Export all public functions
export -f init_framework cleanup_framework validate_framework
export -f start_suite end_suite run_test skip_test print_final_summary
export -f has_utility get_utility_path exec_utility
export -f create_temp_file create_temp_dir load_fixture copy_fixture
export -f is_platform is_privileged print_framework_help
export -f setup_test cleanup_test_files create_test_file_with_lines create_test_file_with_binary
export -f create_test_file_with_perms create_test_input run_utility_test run_utility_test_expecting_failure
export -f validate_utility_available