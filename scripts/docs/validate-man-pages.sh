#!/bin/bash
# Validate man pages for quality and consistency
# Modernized version with DRY error handling

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Script-specific variables
UTILITIES=""
FAIL_ON_WARNINGS=false

# Show help
show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  --utilities LIST     Space-separated list of utilities to validate
  --fail-on-warnings   Exit with error code on warnings
  --ci                 Run in CI mode (no colors, structured output)
  --verbose, -v        Show detailed output
  --help, -h           Show this help

Examples:
  $0 --utilities "echo cat ls" --verbose
  $0 --ci --fail-on-warnings
EOF
}

# Parse script-specific arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --utilities)
            UTILITIES="$2"
            shift 2
            ;;
        --fail-on-warnings)
            FAIL_ON_WARNINGS=true
            shift
            ;;
        *)
            parse_common_args "$1"
            if [ $? -eq 0 ]; then
                shift
            else
                fatal "Unknown option: $1"
            fi
            ;;
    esac
done

# Validate man page function
validate_man_page() {
    local utility="$1"
    local man_file="man/man1/${utility}.1"
    local errors=0
    local warnings=0
    
    if [ ! -f "$man_file" ]; then
        log_error "Missing man page: $man_file"
        return 1
    fi
    
    if [ ! -s "$man_file" ]; then
        log_error "Empty man page: $man_file"
        return 1
    fi
    
    # Run mandoc syntax check
    local lint_output
    lint_output=$(mandoc -T lint "$man_file" 2>&1)
    local lint_exit_code=$?
    
    # Filter false positives
    local filtered_output
    filtered_output=$(echo "$lint_output" | \
        grep -v "outdated mandoc.db" | \
        grep -v "STYLE: referenced manual not found: Xr" || true)
    
    if [ $lint_exit_code -eq 0 ] && [ -z "$filtered_output" ]; then
        log_success "$utility: Clean"
        return 0
    fi
    
    # Check for real errors vs warnings
    if echo "$filtered_output" | grep -q "ERROR:\|UNSUPP:\|FATAL:"; then
        log_error "$utility: Syntax errors found"
        errors=1
    elif [ -n "$filtered_output" ]; then
        log_warning "$utility: Warnings found"
        warnings=1
    fi
    
    if [ "$VERBOSE" = true ] && [ -n "$filtered_output" ]; then
        echo "$filtered_output" | sed 's/^/    /'
    fi
    
    # Return error code if needed
    if [ $errors -gt 0 ]; then
        return 1
    elif [ "$FAIL_ON_WARNINGS" = true ] && [ $warnings -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Main execution
main() {
    log_info "Validating man pages"
    log_info "Mode: $([ "$CI_MODE" = true ] && echo "CI" || echo "Local")"
    log_info "Fail on warnings: $([ "$FAIL_ON_WARNINGS" = true ] && echo "Yes" || echo "No")"
    
    # Require mandoc
    require_tool mandoc "Ubuntu/Debian: sudo apt-get install mandoc; macOS: brew install mandoc" || exit 1
    
    # Get utilities list
    if [ -z "$UTILITIES" ]; then
        # Auto-discover utilities
        UTILITIES=$(find src -name "*.zig" -not -name "common*" -not -name "main.zig" \
            -exec basename {} .zig \; | sort | tr '\n' ' ')
        log_info "Auto-discovered utilities: $UTILITIES"
    fi
    
    # Validate each utility
    local total_checked=0
    local failed=0
    
    for utility in $UTILITIES; do
        total_checked=$((total_checked + 1))
        if ! validate_man_page "$utility"; then
            failed=$((failed + 1))
        fi
    done
    
    # Summary
    log_info "Man pages checked: $total_checked"
    log_info "Failed validations: $failed"
    
    if [ $failed -gt 0 ]; then
        log_error "Man page validation failed"
        exit 1
    else
        log_success "All man pages validated successfully"
    fi
}

# Run main function
main