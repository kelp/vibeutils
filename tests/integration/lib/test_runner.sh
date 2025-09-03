#!/usr/bin/env bash
# Test runner and execution management for shell integration testing framework
# Handles parallel execution, timeouts, signal handling, and result collection

# Test runner configuration
RUNNER_PARALLEL_JOBS=1
RUNNER_TIMEOUT=30
RUNNER_STOP_ON_FAILURE=false
RUNNER_DRY_RUN=false
RUNNER_FILTER=""
RUNNER_EXCLUDE=""
RUNNER_MAX_FAILURES=0

# Test execution state
RUNNER_ACTIVE_TESTS=()
RUNNER_COMPLETED_TESTS=()
RUNNER_FAILED_TESTS=()
RUNNER_SKIPPED_TESTS=()

# Process management for parallel execution
RUNNER_PIDS=()
RUNNER_TEST_NAMES=()
RUNNER_TEMP_BASE=""
RUNNER_TEST_FILE=""  # Path to current test file

# Set the current test file path
set_test_file() {
    RUNNER_TEST_FILE="$1"
}

# Initialize test runner
init_test_runner() {
    local jobs=1
    local timeout=30
    local stop_on_failure=false
    local dry_run=false
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --jobs|-j)
                jobs="$2"
                shift 2
                ;;
            --timeout|-t)
                timeout="$2"
                shift 2
                ;;
            --stop-on-failure)
                stop_on_failure=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --filter|-f)
                RUNNER_FILTER="$2"
                shift 2
                ;;
            --exclude|-e)
                RUNNER_EXCLUDE="$2"
                shift 2
                ;;
            --max-failures)
                RUNNER_MAX_FAILURES="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    RUNNER_PARALLEL_JOBS="$jobs"
    RUNNER_TIMEOUT="$timeout"
    RUNNER_STOP_ON_FAILURE="$stop_on_failure"
    RUNNER_DRY_RUN="$dry_run"
    
    # Validate jobs count
    if [[ "$RUNNER_PARALLEL_JOBS" -lt 1 ]]; then
        RUNNER_PARALLEL_JOBS=1
    elif [[ "$RUNNER_PARALLEL_JOBS" -gt 16 ]]; then
        print_warning "Limiting parallel jobs to 16 (requested: $RUNNER_PARALLEL_JOBS)"
        RUNNER_PARALLEL_JOBS=16
    fi
    
    # Create temp directory for runner state
    RUNNER_TEMP_BASE="${TEST_TEMP_DIR}/runner_$$"
    mkdir -p "$RUNNER_TEMP_BASE"
    
    # Set up signal handling for cleanup
    trap cleanup_test_runner EXIT INT TERM
    
    if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
        print_info "Test runner initialized:"
        print_info "  Parallel jobs: $RUNNER_PARALLEL_JOBS"
        print_info "  Timeout: ${RUNNER_TIMEOUT}s"
        print_info "  Stop on failure: $RUNNER_STOP_ON_FAILURE"
        print_info "  Dry run: $RUNNER_DRY_RUN"
        if [[ -n "$RUNNER_FILTER" ]]; then
            print_info "  Filter: $RUNNER_FILTER"
        fi
        if [[ -n "$RUNNER_EXCLUDE" ]]; then
            print_info "  Exclude: $RUNNER_EXCLUDE"
        fi
    fi
}

# Clean up test runner resources
cleanup_test_runner() {
    # Kill any remaining background processes
    if [[ ${#RUNNER_PIDS[@]} -gt 0 ]]; then
        print_warning "Terminating ${#RUNNER_PIDS[@]} running tests..."
        for pid in "${RUNNER_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null
                fi
            fi
        done
    fi
    
    # Clean up temporary files
    if [[ -n "$RUNNER_TEMP_BASE" ]] && [[ -d "$RUNNER_TEMP_BASE" ]]; then
        rm -rf "$RUNNER_TEMP_BASE" 2>/dev/null || true
    fi
}

# Check if test name matches filter criteria
test_matches_filter() {
    local test_name="$1"
    
    # Apply inclusion filter
    if [[ -n "$RUNNER_FILTER" ]]; then
        if [[ ! "$test_name" =~ $RUNNER_FILTER ]]; then
            return 1
        fi
    fi
    
    # Apply exclusion filter
    if [[ -n "$RUNNER_EXCLUDE" ]]; then
        if [[ "$test_name" =~ $RUNNER_EXCLUDE ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Execute a single test in the background (for parallel execution)
execute_test_background() {
    local test_name="$1"
    local test_function="$2"
    local test_timeout="${3:-$RUNNER_TIMEOUT}"
    local test_file="${4:-}"
    
    # Create output file for this test
    local output_file="${RUNNER_TEMP_BASE}/${test_name//\//_}.out"
    local status_file="${RUNNER_TEMP_BASE}/${test_name//\//_}.status"
    
    # Execute test in background
    {
        local start_time end_time duration exit_code=0
        start_time=$(date +%s)
        
        # Create a temporary script for the test execution
        local script_file="${RUNNER_TEMP_BASE}/${test_name//\//_}.sh"
        cat > "$script_file" << 'SCRIPT_EOF'
set -euo pipefail

# Create isolated temp directory for this test
mkdir -p "$TEST_TEMP_DIR"
cd "$TEST_TEMP_DIR"

# Source framework
source "$FRAMEWORK_DIR/lib.sh"

# Initialize framework 
init_framework

# Source the test file if provided
if [[ -n "$TEST_FILE" ]]; then
    source "$TEST_FILE"
fi

# Reset assertion counters
reset_assertions

# Execute the test function
"$TEST_FUNCTION"

# Check assertion results
if [[ $ASSERTION_FAILED -gt 0 ]]; then
    echo "Test failed: $ASSERTION_FAILED assertion(s) failed" >&2
    exit 1
fi

# Cleanup temp directory
cd /
rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
SCRIPT_EOF

        # Make script executable
        chmod +x "$script_file"
        
        # Run the test function with timeout and proper isolation
        if timeout "$test_timeout" env \
            TEST_ROOT_DIR="$TEST_ROOT_DIR" \
            TEST_BIN_DIR="$TEST_BIN_DIR" \
            TEST_FIXTURES_DIR="$TEST_FIXTURES_DIR" \
            TEST_VERBOSE="$TEST_VERBOSE" \
            TEST_PARALLEL="$TEST_PARALLEL" \
            TEST_TIMEOUT="$TEST_TIMEOUT" \
            FRAMEWORK_DIR="$FRAMEWORK_DIR" \
            TEST_TEMP_DIR="$TEST_TEMP_DIR/${test_name//\//_}_$$" \
            CURRENT_TEST_NAME="$test_name" \
            TEST_FILE="$test_file" \
            TEST_FUNCTION="$test_function" \
            bash "$script_file" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi
        
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        # Write status information
        {
            echo "exit_code=$exit_code"
            echo "duration=$duration"
            echo "timeout=$test_timeout"
        } > "$status_file"
        
        # Clean up the script file
        rm -f "$script_file" 2>/dev/null || true
        
        exit $exit_code
        
    } > "$output_file" 2>&1 &
    
    local bg_pid=$!
    
    # Track the background process
    RUNNER_PIDS+=("$bg_pid")
    RUNNER_TEST_NAMES+=("$test_name")
    
    if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
        print_debug "Started test '$test_name' (PID: $bg_pid)"
    fi
    
    echo "$bg_pid"
}

# Wait for a background test to complete and collect results
wait_for_test_completion() {
    local pid="$1"
    local test_name="$2"
    
    local output_file="${RUNNER_TEMP_BASE}/${test_name//\//_}.out"
    local status_file="${RUNNER_TEMP_BASE}/${test_name//\//_}.status"
    
    # Process has already completed (checked by caller with kill -0)
    # Try to get exit code, but don't rely on wait since process may be reaped
    local exit_code=0
    wait "$pid" 2>/dev/null || exit_code=$?
    
    # Read status information
    local duration=0
    local timeout_exceeded=false
    if [[ -f "$status_file" ]]; then
        source "$status_file"
        if [[ $exit_code -eq 124 ]]; then
            timeout_exceeded=true
        fi
    fi
    
    # Read test output
    local output=""
    if [[ -f "$output_file" ]]; then
        output=$(cat "$output_file" 2>/dev/null || echo "")
    fi
    
    # Remove PID from tracking arrays
    local new_pids=()
    local new_names=()
    if [[ ${#RUNNER_PIDS[@]} -gt 0 ]]; then
        for i in "${!RUNNER_PIDS[@]}"; do
            if [[ "${RUNNER_PIDS[i]}" != "$pid" ]]; then
                new_pids+=("${RUNNER_PIDS[i]}")
                new_names+=("${RUNNER_TEST_NAMES[i]}")
            fi
        done
    fi
    if [[ ${#new_pids[@]} -gt 0 ]]; then
        RUNNER_PIDS=("${new_pids[@]}")
        RUNNER_TEST_NAMES=("${new_names[@]}")
    else
        RUNNER_PIDS=()
        RUNNER_TEST_NAMES=()
    fi
    
    # Report results
    RUNNER_COMPLETED_TESTS+=("$test_name")
    
    if [[ $exit_code -eq 0 ]]; then
        print_test_pass "$test_name"
        if [[ "${TEST_VERBOSE:-false}" == "true" ]] && [[ -n "$output" ]]; then
            print_indented 1 "Output:"
            echo "$output" | sed 's/^/    /'
        fi
        ((TEST_PASSED++))
    elif [[ "$timeout_exceeded" == "true" ]]; then
        print_test_timeout "$test_name" "$RUNNER_TIMEOUT"
        if [[ "${TEST_VERBOSE:-false}" == "true" ]] && [[ -n "$output" ]]; then
            print_indented 1 "Partial output:"
            echo "$output" | sed 's/^/    /' | head -20
        fi
        RUNNER_FAILED_TESTS+=("$test_name")
        ((TEST_FAILED++))
    else
        print_test_fail "$test_name"
        if [[ -n "$output" ]]; then
            print_indented 1 "Error output:"
            echo "$output" | sed 's/^/    /'
        fi
        RUNNER_FAILED_TESTS+=("$test_name")
        ((TEST_FAILED++))
    fi
    
    # Clean up temp files
    rm -f "$output_file" "$status_file" 2>/dev/null || true
    
    return $exit_code
}

# Execute tests with parallelism management using sequential batching
# This fixes the race condition where fast tests complete before tracking
execute_test_batch() {
    local -a test_specs=("$@")
    
    if [[ ${#test_specs[@]} -eq 0 ]]; then
        print_warning "No tests to execute"
        return 0
    fi
    
    local total_tests=${#test_specs[@]}
    local completed_tests=0
    local current_batch_start=0
    
    print_info "Executing $total_tests tests (max ${RUNNER_PARALLEL_JOBS} parallel, sequential batching)"
    
    # Process tests in sequential batches to avoid race conditions
    while [[ $current_batch_start -lt ${#test_specs[@]} ]]; do
        local -a batch_tests=()
        local -a batch_pids=()
        local -a batch_names=()
        local batch_size=0
        
        # Build current batch (up to RUNNER_PARALLEL_JOBS tests)
        local batch_index
        for ((batch_index = 0; batch_index < RUNNER_PARALLEL_JOBS && (current_batch_start + batch_index) < ${#test_specs[@]}; batch_index++)); do
            local test_spec="${test_specs[current_batch_start + batch_index]}"
            
            # Parse test specification (format: "name|function|timeout")
            IFS='|' read -ra spec_parts <<< "$test_spec"
            local test_name="${spec_parts[0]:-}"
            local test_function="${spec_parts[1]:-}"
            local test_timeout="${spec_parts[2]:-$RUNNER_TIMEOUT}"
            
            # Check filters
            if ! test_matches_filter "$test_name"; then
                skip_test "$test_name" "filtered out"
                ((completed_tests++))
                continue
            fi
            
            # Check if we should skip due to dry run
            if [[ "$RUNNER_DRY_RUN" == "true" ]]; then
                print_info "[DRY RUN] Would execute: $test_name"
                ((completed_tests++))
                continue
            fi
            
            batch_tests+=("$test_spec")
            batch_names+=("$test_name")
        done
        
        # Launch all tests in current batch
        for test_spec in "${batch_tests[@]}"; do
            IFS='|' read -ra spec_parts <<< "$test_spec"
            local test_name="${spec_parts[0]:-}"
            local test_function="${spec_parts[1]:-}"
            local test_timeout="${spec_parts[2]:-$RUNNER_TIMEOUT}"
            
            ((TEST_TOTAL++))
            local pid
            pid=$(execute_test_background "$test_name" "$test_function" "$test_timeout" "$RUNNER_TEST_FILE")
            batch_pids+=("$pid")
            
            if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
                print_debug "Launched batch test '$test_name' (PID: $pid)"
            fi
        done
        
        # Wait for ALL tests in current batch to complete
        if [[ ${#batch_pids[@]} -gt 0 ]]; then
            if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
                print_debug "Waiting for batch of ${#batch_pids[@]} tests to complete..."
            fi
            
            local remaining_pids=("${batch_pids[@]}")
            local remaining_names=("${batch_names[@]}")
            
            while [[ ${#remaining_pids[@]} -gt 0 ]]; do
                local new_pids=()
                local new_names=()
                
                # Check each PID in the batch
                for i in "${!remaining_pids[@]}"; do
                    local pid="${remaining_pids[i]}"
                    local name="${remaining_names[i]}"
                    
                    if kill -0 "$pid" 2>/dev/null; then
                        # Still running - keep in remaining list
                        new_pids+=("$pid")
                        new_names+=("$name")
                    else
                        # Completed - process results
                        wait_for_test_completion "$pid" "$name"
                        ((completed_tests++))
                        
                        # Check stop conditions after each completion
                        if [[ "$RUNNER_STOP_ON_FAILURE" == "true" ]] && [[ ${#RUNNER_FAILED_TESTS[@]} -gt 0 ]]; then
                            print_warning "Stopping execution due to test failure"
                            cleanup_test_runner
                            return 1
                        fi
                        
                        if [[ $RUNNER_MAX_FAILURES -gt 0 ]] && [[ ${#RUNNER_FAILED_TESTS[@]} -ge $RUNNER_MAX_FAILURES ]]; then
                            print_warning "Stopping execution: reached maximum failures ($RUNNER_MAX_FAILURES)"
                            cleanup_test_runner
                            return 1
                        fi
                    fi
                done
                
                # Update remaining lists
                remaining_pids=()
                remaining_names=()
                if [[ ${#new_pids[@]} -gt 0 ]]; then
                    remaining_pids=("${new_pids[@]}")
                    remaining_names=("${new_names[@]}")
                fi
                
                # Brief sleep to prevent tight polling if tests are still running
                if [[ ${#remaining_pids[@]} -gt 0 ]]; then
                    sleep 0.1
                fi
                
                # Show progress
                if [[ "${TEST_VERBOSE:-false}" == "false" ]]; then
                    print_progress "$completed_tests" "$total_tests" "tests"
                fi
            done
        fi
        
        # Move to next batch
        current_batch_start=$((current_batch_start + RUNNER_PARALLEL_JOBS))
    done
    
    # Complete the progress bar
    if [[ "${TEST_VERBOSE:-false}" == "false" ]]; then
        print_progress "$completed_tests" "$total_tests" "tests"
        printf "\\n"  # Complete the progress bar
    fi
    
    return 0
}

# Execute a single test synchronously (for serial execution or debugging)
execute_test_sync() {
    local test_name="$1"
    local test_function="$2"
    local test_timeout="${3:-$RUNNER_TIMEOUT}"
    
    # Check filters
    if ! test_matches_filter "$test_name"; then
        skip_test "$test_name" "filtered out"
        return 0
    fi
    
    if [[ "$RUNNER_DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would execute: $test_name"
        return 0
    fi
    
    ((TEST_TOTAL++))
    
    # Use the standard run_test function for synchronous execution
    if run_test "$test_name" "$test_function" "$test_timeout"; then
        RUNNER_COMPLETED_TESTS+=("$test_name")
        return 0
    else
        RUNNER_FAILED_TESTS+=("$test_name")
        
        # Check stop conditions
        if [[ "$RUNNER_STOP_ON_FAILURE" == "true" ]]; then
            print_warning "Stopping execution due to test failure"
            return 1
        fi
        
        if [[ $RUNNER_MAX_FAILURES -gt 0 ]] && [[ ${#RUNNER_FAILED_TESTS[@]} -ge $RUNNER_MAX_FAILURES ]]; then
            print_warning "Stopping execution: reached maximum failures ($RUNNER_MAX_FAILURES)"
            return 1
        fi
        
        return 1
    fi
}

# Main test execution coordinator
run_test_suite() {
    local -a test_specs=("$@")
    
    if [[ ${#test_specs[@]} -eq 0 ]]; then
        print_error "No tests provided to run_test_suite"
        return 1
    fi
    
    # Initialize if not already done
    if [[ -z "${RUNNER_TEMP_BASE:-}" ]]; then
        init_test_runner
    fi
    
    local start_time
    start_time=$(date +%s)
    
    # Choose execution method based on parallelism setting
    if [[ $RUNNER_PARALLEL_JOBS -gt 1 ]]; then
        execute_test_batch "${test_specs[@]}"
    else
        # Serial execution
        for test_spec in "${test_specs[@]}"; do
            IFS='|' read -ra spec_parts <<< "$test_spec"
            local test_name="${spec_parts[0]:-}"
            local test_function="${spec_parts[1]:-}"
            local test_timeout="${spec_parts[2]:-$RUNNER_TIMEOUT}"
            
            execute_test_sync "$test_name" "$test_function" "$test_timeout"
            
            # Check stop conditions
            if [[ "$RUNNER_STOP_ON_FAILURE" == "true" ]] && [[ ${#RUNNER_FAILED_TESTS[@]} -gt 0 ]]; then
                break
            fi
            
            if [[ $RUNNER_MAX_FAILURES -gt 0 ]] && [[ ${#RUNNER_FAILED_TESTS[@]} -ge $RUNNER_MAX_FAILURES ]]; then
                break
            fi
        done
    fi
    
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Print execution summary
    print_separator
    print_info "Test execution completed in ${duration}s"
    print_info "Completed: ${#RUNNER_COMPLETED_TESTS[@]}, Failed: ${#RUNNER_FAILED_TESTS[@]}, Skipped: $TEST_SKIPPED"
    
    # Debug: Show what tests actually completed
    if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
        print_info "Completed tests list:"
        for completed_test in "${RUNNER_COMPLETED_TESTS[@]}"; do
            print_indented 1 "- $completed_test"
        done
    fi
    
    if [[ ${#RUNNER_FAILED_TESTS[@]} -gt 0 ]]; then
        print_error "Failed tests:"
        for failed_test in "${RUNNER_FAILED_TESTS[@]}"; do
            print_indented 1 "- $failed_test"
        done
    fi
    
    return $(( ${#RUNNER_FAILED_TESTS[@]} > 0 ? 1 : 0 ))
}

# Utility function to create test specification strings
make_test_spec() {
    local name="$1"
    local function="$2"
    local timeout="${3:-}"
    
    if [[ -n "$timeout" ]]; then
        echo "${name}|${function}|${timeout}"
    else
        echo "${name}|${function}"
    fi
}

# Discovery helper - find test functions in a file or current context
discover_test_functions() {
    local pattern="${1:-test_}"
    
    # Get all function names matching the pattern
    declare -F | awk '{print $3}' | grep "^$pattern" || true
}

# Auto-discover and execute tests from current environment
run_discovered_tests() {
    local pattern="${1:-test_}"
    local timeout="${2:-$RUNNER_TIMEOUT}"
    
    local -a test_specs=()
    local functions
    functions=$(discover_test_functions "$pattern")
    
    if [[ -z "$functions" ]]; then
        print_warning "No test functions found matching pattern: $pattern"
        return 0
    fi
    
    while IFS= read -r func; do
        if [[ -n "$func" ]]; then
            test_specs+=($(make_test_spec "$func" "$func" "$timeout"))
        fi
    done <<< "$functions"
    
    print_info "Discovered ${#test_specs[@]} test functions"
    run_test_suite "${test_specs[@]}"
}

# Export test runner functions
export RUNNER_PARALLEL_JOBS RUNNER_TIMEOUT RUNNER_STOP_ON_FAILURE RUNNER_DRY_RUN
export RUNNER_FILTER RUNNER_EXCLUDE RUNNER_MAX_FAILURES
export RUNNER_ACTIVE_TESTS RUNNER_COMPLETED_TESTS RUNNER_FAILED_TESTS RUNNER_SKIPPED_TESTS
export RUNNER_PIDS RUNNER_TEST_NAMES RUNNER_TEMP_BASE

export -f init_test_runner cleanup_test_runner set_test_file
export -f test_matches_filter execute_test_background wait_for_test_completion
export -f execute_test_batch execute_test_sync run_test_suite
export -f make_test_spec discover_test_functions run_discovered_tests