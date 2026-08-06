#!/usr/bin/env bash
# Flag parser for extracting flags from --help output
# Automatically generates test cases for every documented flag

set -euo pipefail

# Extract all flags from help output
# Returns array of flag definitions in format: "flag:description"
extract_flags_from_help() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    local flags_var=$2
    
    eval "$flags_var=()"
    
    if [[ ! -x "$binary" ]]; then
        echo "Warning: Binary $binary not found" >&2
        return 1
    fi
    
    # Get help output
    local help_output
    if ! help_output=$("$binary" --help 2>&1); then
        echo "Warning: Could not get help output for $util" >&2
        return 1
    fi
    
    # Parse flags from help output
    # Matches patterns like:
    #   -n         description
    #   -e, --enable  description  
    #   --help     description
    while IFS= read -r line; do
        # Skip empty lines and non-flag lines
        [[ "$line" =~ ^[[:space:]]*- ]] || continue
        
        # Extract flag part (everything up to first tab or multiple spaces)
        local flag_part
        if [[ "$line" =~ ^([[:space:]]*-[^[:space:]]+([[:space:]]*,[[:space:]]*--[^[:space:]]+)?)[[:space:]]{2,} ]]; then
            flag_part="${BASH_REMATCH[1]}"
        else
            continue
        fi
        
        # Clean up flag part - remove leading/trailing whitespace
        flag_part="$(echo "$flag_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        
        # Extract description (everything after flag part)
        local description
        if [[ "$line" =~ ^[[:space:]]*-[^[:space:]]+([[:space:]]*,[[:space:]]*--[^[:space:]]+)?[[:space:]]{2,}(.*) ]]; then
            description="${BASH_REMATCH[2]}"
        else
            description="(no description)"
        fi
        
        # Parse individual flags from flag_part
        # Handle both short and long flags: "-n, --number" or just "-n" or just "--help"
        local flags_in_part=()
        
        # Split on comma and extract flags
        IFS=',' read -ra flag_components <<< "$flag_part"
        for component in "${flag_components[@]}"; do
            # Clean component and extract flag
            component="$(echo "$component" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ "$component" =~ ^(-[^[:space:]]+) ]]; then
                flags_in_part+=("${BASH_REMATCH[1]}")
            fi
        done
        
        # Add each flag to the result
        for flag in "${flags_in_part[@]}"; do
            # Skip some common flags that are tested separately
            case "$flag" in
                "--help"|"--version")
                    continue
                    ;;
                *)
                    flags_ref+=("$flag:$description")
                    ;;
            esac
        done
        
    done <<< "$help_output"
}

# Get just the flag names (without descriptions)
get_flag_names() {
    local -n input_flags=$1
    local -n output_flags=$2
    
    output_flags=()
    for flag_def in "${input_flags[@]}"; do
        local flag_name="${flag_def%%:*}"
        output_flags+=("$flag_name")
    done
}

# Get flags that take arguments (heuristic based on description)
get_flags_with_args() {
    local -n input_flags=$1
    local -n output_flags=$2
    
    output_flags=()
    for flag_def in "${input_flags[@]}"; do
        local flag_name="${flag_def%%:*}"
        local description="${flag_def#*:}"
        
        # Heuristics for flags that take arguments
        if [[ "$description" =~ (use|with|specify|set|to|=|FILE|DIR|NUM|MODE|SIZE|TIME) ]] || 
           [[ "$flag_name" == "--reference" ]] ||
           [[ "$flag_name" =~ ^-[^-].* && ! "$description" =~ ^(enable|disable|show|display|suppress|do not|equivalent) ]]; then
            output_flags+=("$flag_name")
        fi
    done
}

# Exit code a utility uses for an argument or usage error.
# Most utilities use 1. ls/sort/grep/test/[ keep 2 to match GNU, and
# env/timeout use 125 so their own failures stay distinct from the exit
# code of the command they run.
usage_error_code() {
    case "$1" in
        "ls"|"sort"|"grep"|"test"|"[") echo 2 ;;
        "env"|"timeout") echo 125 ;;
        *) echo 1 ;;
    esac
}

# Generate test cases for boolean flags (no arguments)
generate_boolean_flag_tests() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    local -n flags=$2
    local -n test_cases_ref=$3
    local err_code
    err_code=$(usage_error_code "$util")
    
    test_cases_ref=()
    
    for flag in "${flags[@]}"; do
        # Basic flag test - should not error on help
        test_cases_ref+=("test_command_succeeds \"$util $flag (help check)\" \"$binary\" \"$flag\" \"--help\"")
        
        # For most utilities, test the flag by itself
        case "$util" in
            "echo"|"printf")
                # Echo-like utilities: test with some input
                test_cases_ref+=("test_command_succeeds \"$util $flag basic\" \"$binary\" \"$flag\" \"test\"")
                ;;
            "cat"|"head"|"tail"|"tee")
                # Filter utilities: test with /dev/null input
                test_cases_ref+=("test_command_succeeds \"$util $flag basic\" \"$binary\" \"$flag\" \"/dev/null\"")
                ;;
            "ls"|"find")
                # Directory utilities: test with current directory
                test_cases_ref+=("test_command_succeeds \"$util $flag basic\" \"$binary\" \"$flag\" \".\"")
                ;;
            *)
                # Generic test - just run with flag to see if it parses
                test_cases_ref+=("test_command_exit_code \"$util $flag parse\" $err_code \"$binary\" \"$flag\"")
                ;;
        esac
    done
}

# Generate test cases for flags that take arguments
generate_argument_flag_tests() {
    local util="$1"
    local binary="$BIN_DIR/$util"
    local -n flags=$2
    local -n test_cases_ref=$3
    local err_code
    err_code=$(usage_error_code "$util")
    
    test_cases_ref=()
    
    for flag in "${flags[@]}"; do
        case "$flag" in
            "--reference")
                # Reference flag: test with existing file
                test_cases_ref+=("test_command_exit_code \"$util $flag with /dev/null\" $err_code \"$binary\" \"$flag=/dev/null\"")
                ;;
            "-c"|"--changes"|"-v"|"--verbose")
                # Output flags: test with dummy file
                test_cases_ref+=("test_command_exit_code \"$util $flag with dummy\" $err_code \"$binary\" \"$flag\"")
                ;;
            *)
                # Generic argument flag: test that it requires an argument
                test_cases_ref+=("test_command_fails \"$util $flag missing arg\" \"$binary\" \"$flag\"")
                ;;
        esac
    done
}

# Debug function to print extracted flags
print_flags() {
    local util="$1"
    local -n flags=$2
    
    echo "Flags found for $util:"
    for flag_def in "${flags[@]}"; do
        local flag_name="${flag_def%%:*}"
        local description="${flag_def#*:}"
        echo "  $flag_name -> $description"
    done
}