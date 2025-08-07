#!/bin/bash
# Check documentation coverage for all utilities
# Ensures every utility has proper documentation

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Script-specific variables
UTILITIES=""

# Show help
show_help() {
    cat << EOF
Usage: $0 [options]

Options:
  --utilities LIST     Space-separated list of utilities to check
  --ci                 Run in CI mode (no colors, structured output)
  --verbose, -v        Show detailed output
  --help, -h           Show this help

Examples:
  $0 --utilities "echo cat ls"
  $0 --ci --verbose
EOF
}

# Parse script-specific arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --utilities)
            UTILITIES="$2"
            shift 2
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

# Check coverage for single utility
check_utility_coverage() {
    local utility="$1"
    local missing=0
    
    log_debug "Checking coverage for: $utility"
    
    # Check for man page
    if [ ! -f "man/man1/${utility}.1" ]; then
        log_error "Missing man page for $utility (expected: man/man1/${utility}.1)"
        missing=$((missing + 1))
    else
        log_debug "✓ Man page exists for $utility"
    fi
    
    # Check if mentioned in README
    if ! grep -q "$utility" README.md 2>/dev/null; then
        log_warning "$utility not mentioned in README.md"
    else
        log_debug "✓ $utility mentioned in README"
    fi
    
    return $missing
}

# Main execution
main() {
    log_info "Checking documentation coverage"
    
    # Get utilities list
    if [ -z "$UTILITIES" ]; then
        # Auto-discover utilities
        UTILITIES=$(find src -name "*.zig" -not -name "common*" -not -name "main.zig" \
            -exec basename {} .zig \; | sort | tr '\n' ' ')
        log_info "Auto-discovered utilities: $UTILITIES"
    fi
    
    # Check coverage for each utility
    local total_utilities=0
    local total_missing=0
    local utilities_with_missing=()
    
    for utility in $UTILITIES; do
        total_utilities=$((total_utilities + 1))
        
        if ! check_utility_coverage "$utility"; then
            missing_count=$?
            total_missing=$((total_missing + missing_count))
            utilities_with_missing+=("$utility")
        fi
    done
    
    # Calculate coverage percentage
    local covered=$((total_utilities - ${#utilities_with_missing[@]}))
    local coverage_percent=0
    if [ $total_utilities -gt 0 ]; then
        coverage_percent=$(( (covered * 100) / total_utilities ))
    fi
    
    # Summary
    log_info "Documentation coverage: $covered/$total_utilities utilities (${coverage_percent}%)"
    
    if [ ${#utilities_with_missing[@]} -gt 0 ]; then
        log_warning "Utilities missing documentation:"
        for utility in "${utilities_with_missing[@]}"; do
            echo "  - $utility"
        done
        echo ""
        log_error "Documentation coverage incomplete: ${#utilities_with_missing[@]} utilities missing documentation"
        echo "All utilities must have man pages for release quality."
        echo "Create missing man pages using the format in existing man/man1/*.1 files."
        echo "Refer to CLAUDE.md for man page style guidelines."
        exit 1
    else
        log_success "Complete documentation coverage - all utilities have man pages"
    fi
}

# Run main function
main