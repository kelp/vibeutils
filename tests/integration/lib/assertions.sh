#!/usr/bin/env bash
# Assertion functions for shell integration testing framework
# Provides comprehensive assertion functions with clear error messages

# Assertion counters (local to current test)
ASSERTION_COUNT=0
ASSERTION_PASSED=0
ASSERTION_FAILED=0

# Reset assertion counters (called by test runner)
reset_assertions() {
    ASSERTION_COUNT=0
    ASSERTION_PASSED=0
    ASSERTION_FAILED=0
}

# Internal assertion helper
_assert() {
    local condition="$1"
    local message="$2"
    local expected="$3"
    local actual="$4"
    local comparison_type="${5:-equals}"
    
    ((ASSERTION_COUNT++))
    
    if [[ "$condition" == "true" ]]; then
        ((ASSERTION_PASSED++))
        if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
            print_debug "✓ $message"
        fi
        return 0
    else
        ((ASSERTION_FAILED++))
        print_error "Assertion failed: $message"
        
        case "$comparison_type" in
            equals|not_equals)
                print_error "  Expected: '$expected'"
                print_error "  Actual:   '$actual'"
                ;;
            contains|not_contains)
                print_error "  Text:     '$actual'"
                print_error "  Pattern:  '$expected'"
                ;;
            matches)
                print_error "  Text:     '$actual'"
                print_error "  Regex:    '$expected'"
                ;;
            file_exists|file_not_exists|dir_exists|dir_not_exists)
                print_error "  Path:     '$expected'"
                ;;
            exit_code)
                print_error "  Expected exit code: $expected"
                print_error "  Actual exit code:   $actual"
                ;;
            *)
                if [[ -n "$expected" ]]; then
                    print_error "  Expected: '$expected'"
                fi
                if [[ -n "$actual" ]]; then
                    print_error "  Actual:   '$actual'"
                fi
                ;;
        esac
        
        # Print stack trace if verbose
        if [[ "${TEST_VERBOSE:-false}" == "true" ]]; then
            print_debug "Call stack:"
            local frame=1
            while caller $frame 2>/dev/null; do
                ((frame++))
            done | while read -r line func file; do
                print_debug "  $func() in $file:$line"
            done
        fi
        
        return 1
    fi
}

# String comparison assertions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    local condition
    if [[ "$expected" == "$actual" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$expected" "$actual" "equals"
}

assert_not_equals() {
    local unexpected="$1"
    local actual="$2" 
    local message="${3:-Values should not be equal}"
    
    local condition
    if [[ "$unexpected" != "$actual" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$unexpected" "$actual" "not_equals"
}

# String pattern assertions
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain pattern}"
    
    local condition
    if [[ "$haystack" == *"$needle"* ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$needle" "$haystack" "contains"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain pattern}"
    
    local condition
    if [[ "$haystack" != *"$needle"* ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$needle" "$haystack" "not_contains"
}

# Regular expression assertions
assert_matches() {
    local text="$1"
    local pattern="$2"
    local message="${3:-Text should match pattern}"
    
    local condition
    if [[ "$text" =~ $pattern ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$pattern" "$text" "matches"
}

assert_not_matches() {
    local text="$1"
    local pattern="$2"
    local message="${3:-Text should not match pattern}"
    
    local condition
    if [[ ! "$text" =~ $pattern ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$pattern" "$text" "matches"
}

# Numeric comparison assertions
assert_greater_than() {
    local actual="$1"
    local expected="$2"
    local message="${3:-Value should be greater than expected}"
    
    local condition
    if [[ "$actual" -gt "$expected" ]] 2>/dev/null; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" ">$expected" "$actual" "numeric"
}

assert_less_than() {
    local actual="$1"
    local expected="$2"
    local message="${3:-Value should be less than expected}"
    
    local condition
    if [[ "$actual" -lt "$expected" ]] 2>/dev/null; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "<$expected" "$actual" "numeric"
}

assert_greater_or_equal() {
    local actual="$1"
    local expected="$2"
    local message="${3:-Value should be greater than or equal to expected}"
    
    local condition
    if [[ "$actual" -ge "$expected" ]] 2>/dev/null; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" ">=$expected" "$actual" "numeric"
}

assert_less_or_equal() {
    local actual="$1"
    local expected="$2"
    local message="${3:-Value should be less than or equal to expected}"
    
    local condition
    if [[ "$actual" -le "$expected" ]] 2>/dev/null; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "<=$expected" "$actual" "numeric"
}

# File system assertions
assert_file_exists() {
    local path="$1"
    local message="${2:-File should exist}"
    
    local condition
    if [[ -f "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "file_exists"
}

assert_file_not_exists() {
    local path="$1"
    local message="${2:-File should not exist}"
    
    local condition
    if [[ ! -f "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "file_not_exists"
}

assert_directory_exists() {
    local path="$1"
    local message="${2:-Directory should exist}"
    
    local condition
    if [[ -d "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "dir_exists"
}

assert_directory_not_exists() {
    local path="$1"
    local message="${2:-Directory should not exist}"
    
    local condition
    if [[ ! -d "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "dir_not_exists"
}

assert_symlink_exists() {
    local path="$1"
    local message="${2:-Symbolic link should exist}"
    
    local condition
    if [[ -L "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "symlink_exists"
}

assert_executable() {
    local path="$1"
    local message="${2:-File should be executable}"
    
    local condition
    if [[ -x "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "executable"
}

assert_readable() {
    local path="$1"
    local message="${2:-File should be readable}"
    
    local condition
    if [[ -r "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "readable"
}

assert_writable() {
    local path="$1"
    local message="${2:-File should be writable}"
    
    local condition
    if [[ -w "$path" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$path" "" "writable"
}

# File content assertions
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should contain pattern}"
    
    if [[ ! -f "$file" ]]; then
        _assert "false" "$message" "$pattern" "FILE_NOT_FOUND" "contains"
        return 1
    fi
    
    local condition
    if grep -q "$pattern" "$file"; then
        condition="true"
    else
        condition="false"
    fi
    
    local actual
    actual=$(cat "$file" 2>/dev/null | head -c 200)  # Show first 200 chars
    _assert "$condition" "$message" "$pattern" "$actual" "contains"
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should not contain pattern}"
    
    if [[ ! -f "$file" ]]; then
        _assert "true" "$message" "$pattern" "FILE_NOT_FOUND" "not_contains"
        return 0
    fi
    
    local condition
    if ! grep -q "$pattern" "$file"; then
        condition="true"
    else
        condition="false"
    fi
    
    local actual
    actual=$(cat "$file" 2>/dev/null | head -c 200)
    _assert "$condition" "$message" "$pattern" "$actual" "not_contains"
}

assert_file_equals() {
    local file1="$1"
    local file2="$2"
    local message="${3:-Files should be identical}"
    
    if [[ ! -f "$file1" ]]; then
        _assert "false" "$message" "FILE1_EXISTS" "FILE1_NOT_FOUND" "file_equals"
        return 1
    fi
    
    if [[ ! -f "$file2" ]]; then
        _assert "false" "$message" "FILE2_EXISTS" "FILE2_NOT_FOUND" "file_equals"
        return 1
    fi
    
    local condition
    if cmp -s "$file1" "$file2"; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$file1" "$file2" "file_equals"
}

# Exit code assertions (uses global EXEC_EXIT_CODE)
assert_exit_code() {
    local expected_code="$1"
    local message="${2:-Exit code should match expected}"
    local actual_code="${EXEC_EXIT_CODE:-}"
    
    if [[ -z "$actual_code" ]]; then
        _assert "false" "$message (no command executed)" "$expected_code" "NO_COMMAND" "exit_code"
        return 1
    fi
    
    local condition
    if [[ "$actual_code" -eq "$expected_code" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "$expected_code" "$actual_code" "exit_code"
}

assert_success() {
    local message="${1:-Command should succeed (exit code 0)}"
    assert_exit_code 0 "$message"
}

assert_failure() {
    local message="${1:-Command should fail (exit code != 0)}"
    local actual_code="${EXEC_EXIT_CODE:-}"
    
    if [[ -z "$actual_code" ]]; then
        _assert "false" "$message (no command executed)" "!= 0" "NO_COMMAND" "exit_code"
        return 1
    fi
    
    local condition
    if [[ "$actual_code" -ne 0 ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "!= 0" "$actual_code" "exit_code"
}

# Output assertions (uses global EXEC_OUTPUT)
assert_output_equals() {
    local expected="$1"
    local message="${2:-Output should match expected}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_equals "$expected" "$actual" "$message"
}

assert_output_contains() {
    local pattern="$1"
    local message="${2:-Output should contain pattern}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_contains "$actual" "$pattern" "$message"
}

assert_output_not_contains() {
    local pattern="$1"
    local message="${2:-Output should not contain pattern}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_not_contains "$actual" "$pattern" "$message"
}

assert_output_matches() {
    local pattern="$1"
    local message="${2:-Output should match regex pattern}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_matches "$actual" "$pattern" "$message"
}

assert_output_empty() {
    local message="${1:-Output should be empty}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_equals "" "$actual" "$message"
}

assert_output_not_empty() {
    local message="${1:-Output should not be empty}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_not_equals "" "$actual" "$message"
}

# Line count assertions
assert_line_count() {
    local expected_count="$1"
    local text="$2"
    local message="${3:-Line count should match expected}"
    
    local actual_count
    if [[ -z "$text" ]]; then
        actual_count=0
    else
        actual_count=$(printf "%s" "$text" | wc -l)
        # wc -l doesn't count the last line if it doesn't end with newline
        if [[ "$text" != *$'\n' ]] && [[ -n "$text" ]]; then
            ((actual_count++))
        fi
    fi
    
    assert_equals "$expected_count" "$actual_count" "$message"
}

assert_output_line_count() {
    local expected_count="$1"
    local message="${2:-Output line count should match expected}"
    local actual="${EXEC_OUTPUT:-}"
    
    assert_line_count "$expected_count" "$actual" "$message"
}

# Boolean assertions
assert_true() {
    local value="$1"
    local message="${2:-Value should be true}"
    
    local condition
    if [[ "$value" == "true" ]] || [[ "$value" == "1" ]] || [[ "$value" == "yes" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "true" "$value" "boolean"
}

assert_false() {
    local value="$1"
    local message="${2:-Value should be false}"
    
    local condition
    if [[ "$value" == "false" ]] || [[ "$value" == "0" ]] || [[ "$value" == "no" ]] || [[ -z "$value" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "false" "$value" "boolean"
}

# Variable existence assertions
assert_variable_set() {
    local var_name="$1"
    local message="${2:-Variable should be set}"
    
    local condition
    if [[ -n "${!var_name:-}" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "SET" "${!var_name:-UNSET}" "variable"
}

assert_variable_unset() {
    local var_name="$1"
    local message="${2:-Variable should be unset}"
    
    local condition
    if [[ -z "${!var_name:-}" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "UNSET" "${!var_name:-UNSET}" "variable"
}

# Array/list assertions
assert_array_contains() {
    local needle="$1"
    shift
    local haystack=("$@")
    local message="Array should contain value"
    
    local condition="false"
    for item in "${haystack[@]}"; do
        if [[ "$item" == "$needle" ]]; then
            condition="true"
            break
        fi
    done
    
    _assert "$condition" "$message" "$needle" "${haystack[*]}" "array_contains"
}

assert_array_length() {
    local expected_length="$1"
    shift
    local array=("$@")
    local message="${2:-Array length should match expected}"
    
    local actual_length="${#array[@]}"
    
    assert_equals "$expected_length" "$actual_length" "$message"
}

# Time-based assertions
assert_command_duration_less_than() {
    local max_seconds="$1"
    local command_func="$2"
    local message="${3:-Command should complete within time limit}"
    
    local start_time end_time duration
    start_time=$(date +%s)
    $command_func
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    local condition
    if [[ "$duration" -lt "$max_seconds" ]]; then
        condition="true"
    else
        condition="false"
    fi
    
    _assert "$condition" "$message" "<${max_seconds}s" "${duration}s" "duration"
}

# Print assertion summary
print_assertion_summary() {
    if [[ $ASSERTION_COUNT -eq 0 ]]; then
        print_info "No assertions executed"
        return 0
    fi
    
    local pass_rate=0
    if [[ $ASSERTION_COUNT -gt 0 ]]; then
        pass_rate=$((ASSERTION_PASSED * 100 / ASSERTION_COUNT))
    fi
    
    printf "  Assertions: %d total, %d passed, %d failed (%d%% pass rate)\\n" \
        "$ASSERTION_COUNT" "$ASSERTION_PASSED" "$ASSERTION_FAILED" "$pass_rate"
    
    return $ASSERTION_FAILED
}

# Export assertion functions
export ASSERTION_COUNT ASSERTION_PASSED ASSERTION_FAILED
export -f reset_assertions _assert print_assertion_summary
export -f assert_equals assert_not_equals
export -f assert_contains assert_not_contains assert_matches assert_not_matches
export -f assert_greater_than assert_less_than assert_greater_or_equal assert_less_or_equal
export -f assert_file_exists assert_file_not_exists assert_directory_exists assert_directory_not_exists
export -f assert_symlink_exists assert_executable assert_readable assert_writable
export -f assert_file_contains assert_file_not_contains assert_file_equals
export -f assert_exit_code assert_success assert_failure
export -f assert_output_equals assert_output_contains assert_output_not_contains assert_output_matches
export -f assert_output_empty assert_output_not_empty assert_line_count assert_output_line_count
export -f assert_true assert_false assert_variable_set assert_variable_unset
export -f assert_array_contains assert_array_length assert_command_duration_less_than