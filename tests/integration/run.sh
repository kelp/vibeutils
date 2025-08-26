#!/usr/bin/env bash
# Master integration test runner for vibeutils
# Discovers and executes all integration tests with parallel support

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_UTILS_DIR="${SCRIPT_DIR}/utils"

# Source the testing framework
source "${SCRIPT_DIR}/lib/lib.sh"

# Default configuration
DEFAULT_PARALLEL_JOBS=2
DEFAULT_TIMEOUT=30
DEFAULT_VERBOSE=false
DEFAULT_FILTER=""
DEFAULT_EXCLUDE=""
DEFAULT_STOP_ON_FAILURE=false
DEFAULT_DRY_RUN=false

# Print usage information
print_usage() {
    cat << 'EOF'
Master Integration Test Runner for vibeutils

USAGE:
    ./run.sh [OPTIONS] [UTILITY...]

DESCRIPTION:
    Discovers and executes integration tests for vibeutils. If no utilities
    are specified, runs tests for all available utilities.

OPTIONS:
    -j, --jobs N              Number of parallel test jobs (default: 2)
    -t, --timeout N           Test timeout in seconds (default: 30)
    -v, --verbose             Enable verbose output
    -f, --filter PATTERN      Only run tests matching regex pattern
    -e, --exclude PATTERN     Exclude tests matching regex pattern
    -s, --stop-on-failure     Stop execution on first test failure
    -n, --dry-run            Show what would be executed without running
    --list                   List available test utilities and exit
    --validate               Validate framework setup and exit
    --no-color               Disable colored output
    --no-cleanup             Don't clean up temporary files on exit
    -h, --help               Show this help message

EXAMPLES:
    ./run.sh                          # Run all tests
    ./run.sh tee                      # Run only tee tests
    ./run.sh tee cp mv                # Run tests for specific utilities
    ./run.sh -j 4 -v                  # Run all tests with 4 parallel jobs, verbose
    ./run.sh --filter "basic"         # Run only tests matching "basic"
    ./run.sh --exclude "slow"         # Run all except tests matching "slow"
    ./run.sh --dry-run --verbose      # Show what would be executed
    ./run.sh --list                   # List available test utilities

EXIT CODES:
    0    All tests passed
    1    One or more tests failed
    2    No tests found or executed
    3    Framework validation failed
    4    Invalid arguments or setup error

ENVIRONMENT VARIABLES:
    NO_COLOR=1                Disable colored output
    INTEGRATION_VERBOSE=1     Enable verbose output
    INTEGRATION_JOBS=N        Set number of parallel jobs
    INTEGRATION_TIMEOUT=N     Set test timeout

FILES:
    tests/integration/utils/  Directory containing test scripts
    tests/fixtures/           Test data files
    tests/integration/.tmp/   Temporary files (auto-cleaned)

EOF
}

# Discover available test utilities
discover_test_utilities() {
    local -a utilities=()
    
    if [[ ! -d "$TEST_UTILS_DIR" ]]; then
        print_error "Test utils directory not found: $TEST_UTILS_DIR"
        return 1
    fi
    
    # Find all *_test.sh files in utils directory
    while IFS= read -r -d '' test_file; do
        local basename
        basename=$(basename "$test_file" _test.sh)
        utilities+=("$basename")
    done < <(find "$TEST_UTILS_DIR" -name "*_test.sh" -type f -print0 2>/dev/null)
    
    if [[ ${#utilities[@]} -eq 0 ]]; then
        print_warning "No test utilities found in $TEST_UTILS_DIR"
        return 1
    fi
    
    printf '%s\n' "${utilities[@]}"
}

# List available test utilities
list_test_utilities() {
    print_header "Available Integration Test Utilities"
    
    local -a utilities
    local utilities_output
    if utilities_output=$(discover_test_utilities 2>/dev/null); then
        while IFS= read -r util; do
            [[ -n "$util" ]] && utilities+=("$util")
        done <<< "$utilities_output"
    fi
    
    if [[ ${#utilities[@]} -eq 0 ]]; then
        print_warning "No test utilities found"
        return 1
    fi
    
    printf "Found %d test utilities:\\n\\n" "${#utilities[@]}"
    
    for util in "${utilities[@]}"; do
        local test_file="${TEST_UTILS_DIR}/${util}_test.sh"
        local description=""
        
        # Try to extract description from the test file
        if [[ -f "$test_file" ]]; then
            description=$(grep -m 1 "^# .*integration tests\|^# .*Integration [Tt]ests" "$test_file" 2>/dev/null | sed 's/^# *//' || echo "Integration tests for $util")
        else
            description="Integration tests for $util"
        fi
        
        printf "  %-12s  %s\\n" "$util" "$description"
    done
    
    printf "\\n"
    printf "Usage: %s [OPTIONS] [UTILITY...]\\n" "$(basename "${BASH_SOURCE[0]}")"
    printf "Example: %s tee cp mv --verbose\\n" "$(basename "${BASH_SOURCE[0]}")"
}

# Validate framework setup
validate_framework_setup() {
    print_header "Framework Validation"
    
    local errors=0
    
    # Initialize framework first
    if ! init_framework --no-cleanup; then
        print_error "Framework initialization failed"
        ((errors++))
    fi
    
    # Run standard framework validation
    if ! validate_framework; then
        print_error "Framework validation failed"
        ((errors++))
    fi
    
    # Check for test utilities
    local -a utilities
    local utilities_output
    if utilities_output=$(discover_test_utilities 2>/dev/null); then
        # Convert output to array (compatible with older bash)
        while IFS= read -r util; do
            [[ -n "$util" ]] && utilities+=("$util")
        done <<< "$utilities_output"
        
        if [[ ${#utilities[@]} -gt 0 ]]; then
            print_success "Discovered ${#utilities[@]} test utilities"
        else
            print_error "No test utilities discovered"
            ((errors++))
        fi
    else
        print_error "Failed to discover test utilities"
        ((errors++))
    fi
    
    # Check test fixtures
    if [[ -d "$TEST_FIXTURES_DIR" ]]; then
        local fixture_count
        fixture_count=$(find "$TEST_FIXTURES_DIR" -type f | wc -l)
        print_success "Found $fixture_count test fixtures"
    else
        print_warning "Test fixtures directory not found: $TEST_FIXTURES_DIR"
    fi
    
    # Check binary directory
    if [[ -d "$TEST_BIN_DIR" ]]; then
        local binary_count
        if is_macos; then
            binary_count=$(find "$TEST_BIN_DIR" -type f -perm +111 2>/dev/null | wc -l | sed 's/[[:space:]]//g')
        else
            binary_count=$(find "$TEST_BIN_DIR" -type f -executable 2>/dev/null | wc -l | sed 's/[[:space:]]//g')
        fi
        if [[ $binary_count -gt 0 ]]; then
            print_success "Found $binary_count utility binaries"
        else
            print_warning "No utility binaries found in $TEST_BIN_DIR"
            print_info "Run 'make build' to build utilities"
        fi
    else
        print_error "Binary directory not found: $TEST_BIN_DIR"
        ((errors++))
    fi
    
    # Test platform detection
    print_info "Platform: $(get_platform) $(get_platform_version) ($(get_platform_arch))"
    
    if is_linux && [[ "$(get_linux_distro)" != "unknown" ]]; then
        print_info "Distribution: $(get_linux_distro)"
    fi
    
    # Test tool availability
    local -a tools=("timeout" "stat" "date")
    for tool in "${tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            print_debug "✓ $tool available"
        else
            print_debug "⚠ $tool not available"
        fi
    done
    
    # Summary
    print_separator
    if [[ $errors -eq 0 ]]; then
        print_success "Framework validation passed"
        return 0
    else
        print_error "Framework validation failed with $errors errors"
        return 1
    fi
}

# Execute test for a specific utility
execute_utility_test() {
    local utility="$1"
    local test_file="${TEST_UTILS_DIR}/${utility}_test.sh"
    
    if [[ ! -f "$test_file" ]]; then
        print_error "Test file not found: $test_file"
        return 1
    fi
    
    if [[ ! -x "$test_file" ]]; then
        print_warning "Making test file executable: $test_file"
        chmod +x "$test_file" 2>/dev/null || true
    fi
    
    print_info "Executing tests for utility: $utility"
    
    # Execute the test file
    if bash "$test_file"; then
        print_success "Tests for $utility completed successfully"
        return 0
    else
        local exit_code=$?
        print_error "Tests for $utility failed (exit code: $exit_code)"
        return $exit_code
    fi
}

# Main execution function
main() {
    local parallel_jobs="$DEFAULT_PARALLEL_JOBS"
    local timeout="$DEFAULT_TIMEOUT"
    local verbose="$DEFAULT_VERBOSE"
    local filter="$DEFAULT_FILTER"
    local exclude="$DEFAULT_EXCLUDE"
    local stop_on_failure="$DEFAULT_STOP_ON_FAILURE"
    local dry_run="$DEFAULT_DRY_RUN"
    local list_only=false
    local validate_only=false
    local no_cleanup=false
    local -a target_utilities=()
    
    # Check environment variables
    if [[ -n "${INTEGRATION_VERBOSE:-}" ]]; then
        verbose=true
    fi
    
    if [[ -n "${INTEGRATION_JOBS:-}" ]]; then
        parallel_jobs="${INTEGRATION_JOBS}"
    fi
    
    if [[ -n "${INTEGRATION_TIMEOUT:-}" ]]; then
        timeout="${INTEGRATION_TIMEOUT}"
    fi
    
    if [[ -n "${NO_COLOR:-}" ]]; then
        force_disable_colors
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -j|--jobs)
                parallel_jobs="$2"
                shift 2
                ;;
            -t|--timeout)
                timeout="$2"
                shift 2
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -f|--filter)
                filter="$2"
                shift 2
                ;;
            -e|--exclude)
                exclude="$2"
                shift 2
                ;;
            -s|--stop-on-failure)
                stop_on_failure=true
                shift
                ;;
            -n|--dry-run)
                dry_run=true
                shift
                ;;
            --list)
                list_only=true
                shift
                ;;
            --validate)
                validate_only=true
                shift
                ;;
            --no-color)
                force_disable_colors
                shift
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            -h|--help)
                print_usage
                return 0
                ;;
            -*)
                print_error "Unknown option: $1"
                print_usage >&2
                return 4
                ;;
            *)
                target_utilities+=("$1")
                shift
                ;;
        esac
    done
    
    # Validate numeric arguments
    if ! [[ "$parallel_jobs" =~ ^[0-9]+$ ]] || [[ $parallel_jobs -lt 1 ]]; then
        print_error "Invalid parallel jobs count: $parallel_jobs"
        return 4
    fi
    
    if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ $timeout -lt 1 ]]; then
        print_error "Invalid timeout value: $timeout"
        return 4
    fi
    
    # Handle special modes
    if [[ "$list_only" == "true" ]]; then
        list_test_utilities
        return $?
    fi
    
    if [[ "$validate_only" == "true" ]]; then
        validate_framework_setup
        return $?
    fi
    
    # Initialize the framework
    local init_args=(
        "--timeout=$timeout"
    )
    
    if [[ "$verbose" == "true" ]]; then
        init_args+=("--verbose")
    fi
    
    if [[ $parallel_jobs -gt 1 ]]; then
        init_args+=("--parallel")
    fi
    
    if [[ "$no_cleanup" == "true" ]]; then
        init_args+=("--no-cleanup")
    fi
    
    if ! init_framework "${init_args[@]}"; then
        print_error "Framework initialization failed"
        return 3
    fi
    
    # Discover available utilities if none specified
    if [[ ${#target_utilities[@]} -eq 0 ]]; then
        local utilities_output
        if utilities_output=$(discover_test_utilities 2>/dev/null); then
            while IFS= read -r util; do
                [[ -n "$util" ]] && target_utilities+=("$util")
            done <<< "$utilities_output"
        else
            print_error "Failed to discover test utilities"
            return 2
        fi
    fi
    
    if [[ ${#target_utilities[@]} -eq 0 ]]; then
        print_error "No test utilities found or specified"
        return 2
    fi
    
    # Initialize test runner
    local runner_args=(
        "--jobs=$parallel_jobs"
        "--timeout=$timeout"
    )
    
    if [[ -n "$filter" ]]; then
        runner_args+=("--filter=$filter")
    fi
    
    if [[ -n "$exclude" ]]; then
        runner_args+=("--exclude=$exclude")
    fi
    
    if [[ "$stop_on_failure" == "true" ]]; then
        runner_args+=("--stop-on-failure")
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        runner_args+=("--dry-run")
    fi
    
    init_test_runner "${runner_args[@]}"
    
    # Print execution banner
    start_suite "vibeutils Integration Tests"
    
    if [[ "$verbose" == "true" ]]; then
        print_info "Configuration:"
        print_info "  Target utilities: ${target_utilities[*]}"
        print_info "  Parallel jobs: $parallel_jobs"
        print_info "  Timeout: ${timeout}s"
        print_info "  Platform: $(get_platform) $(get_platform_version)"
        if [[ -n "$filter" ]]; then
            print_info "  Filter: $filter"
        fi
        if [[ -n "$exclude" ]]; then
            print_info "  Exclude: $exclude"
        fi
        if [[ "$dry_run" == "true" ]]; then
            print_info "  Mode: DRY RUN"
        fi
    fi
    
    # Execute tests for each utility
    local overall_success=true
    local executed_count=0
    local failed_utilities=()
    
    for utility in "${target_utilities[@]}"; do
        local test_file="${TEST_UTILS_DIR}/${utility}_test.sh"
        
        if [[ ! -f "$test_file" ]]; then
            print_warning "Test file not found for utility: $utility"
            skip_test "Integration tests for $utility" "test file not found"
            continue
        fi
        
        ((executed_count++))
        
        if [[ "$dry_run" == "true" ]]; then
            print_info "[DRY RUN] Would execute: $test_file"
            continue
        fi
        
        print_info "Running integration tests for: $utility"
        
        # Execute the test script
        if execute_utility_test "$utility"; then
            print_success "✓ $utility tests passed"
        else
            print_error "✗ $utility tests failed"
            failed_utilities+=("$utility")
            overall_success=false
            
            if [[ "$stop_on_failure" == "true" ]]; then
                print_warning "Stopping due to test failure"
                break
            fi
        fi
    done
    
    end_suite
    
    # Print final summary
    print_separator
    print_header "Integration Test Summary"
    
    if [[ $executed_count -eq 0 ]]; then
        print_warning "No tests were executed"
        return 2
    fi
    
    printf "Utilities tested: %d\\n" "$executed_count"
    printf "Utilities passed: %d\\n" $((executed_count - ${#failed_utilities[@]}))
    printf "Utilities failed: %d\\n" "${#failed_utilities[@]}"
    
    if [[ ${#failed_utilities[@]} -gt 0 ]]; then
        printf "\\nFailed utilities:\\n"
        for util in "${failed_utilities[@]}"; do
            printf "  - %s\\n" "$util"
        done
    fi
    
    print_separator
    
    if [[ "$overall_success" == "true" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            print_info "Dry run completed successfully"
            return 0
        else
            print_success "All integration tests passed!"
            return 0
        fi
    else
        print_error "Integration tests failed!"
        return 1
    fi
}

# Set script permissions and execute main if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Make sure framework files are executable
    chmod +x "${SCRIPT_DIR}/lib"/*.sh 2>/dev/null || true
    
    # Execute main function
    main "$@"
fi