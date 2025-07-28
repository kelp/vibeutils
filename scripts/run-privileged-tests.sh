#!/bin/bash
# run-privileged-tests.sh - Run tests that require privilege simulation
# This script auto-detects available tools and falls back gracefully

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
METHOD=""
FORCE_METHOD=""
VERBOSE=0
TEST_FILTER=""

# Help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Run privileged tests with automatic detection of available tools.

OPTIONS:
    -m, --method METHOD    Force specific method (fakeroot, unshare, skip)
    -f, --filter PATTERN   Run only tests matching pattern
    -v, --verbose          Enable verbose output
    -h, --help             Show this help message

EXAMPLES:
    $0                     # Auto-detect and run
    $0 -m fakeroot         # Force fakeroot (fail if unavailable)
    $0 -f "chmod"          # Run only chmod-related tests

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--method)
            FORCE_METHOD="$2"
            shift 2
            ;;
        -f|--filter)
            TEST_FILTER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect available privilege simulation method
detect_method() {
    if [[ -n "$FORCE_METHOD" ]]; then
        METHOD="$FORCE_METHOD"
        log_info "Using forced method: $METHOD"
        return
    fi

    # Check for fakeroot first (preferred on Linux)
    if command_exists fakeroot; then
        METHOD="fakeroot"
        log_success "Detected fakeroot"
        return
    fi

    # Check for unshare (Linux user namespaces)
    if command_exists unshare; then
        # Test if we can use unshare without root
        if unshare --user --map-root-user true 2>/dev/null; then
            METHOD="unshare"
            log_success "Detected unshare with user namespace support"
            return
        else
            log_warning "unshare found but user namespaces not available"
        fi
    fi

    # No method available
    METHOD="skip"
    log_warning "No privilege simulation method available"
}

# Run tests with fakeroot
run_with_fakeroot() {
    log_info "Running tests under fakeroot..."
    
    cd "$PROJECT_ROOT"
    
    # Run privileged tests under fakeroot
    if [[ -n "$TEST_FILTER" ]]; then
        # If a filter is provided, use it with the test-privileged target
        fakeroot zig build test-privileged -- --test-filter "$TEST_FILTER"
    else
        # Run all privileged tests
        fakeroot zig build test-privileged
    fi
}

# Run tests with unshare
run_with_unshare() {
    log_info "Running tests under unshare..."
    
    cd "$PROJECT_ROOT"
    
    # Run tests in user namespace
    if [[ -n "$TEST_FILTER" ]]; then
        unshare --user --map-root-user zig build test-privileged -- --test-filter "$TEST_FILTER"
    else
        unshare --user --map-root-user zig build test-privileged
    fi
}

# Skip privileged tests
skip_tests() {
    log_warning "Skipping privileged tests (no simulation method available)"
    
    # Run privileged tests without simulation - they will skip themselves
    cd "$PROJECT_ROOT"
    if [[ -n "$TEST_FILTER" ]]; then
        zig build test-privileged -- --test-filter "$TEST_FILTER"
    else
        zig build test-privileged
    fi
}

# Main execution
main() {
    log_info "Privileged test runner starting..."
    
    # Detect method
    detect_method
    
    # Execute based on method
    case "$METHOD" in
        fakeroot)
            if ! command_exists fakeroot; then
                log_error "fakeroot not found but was requested"
                exit 1
            fi
            run_with_fakeroot
            ;;
        unshare)
            if ! command_exists unshare; then
                log_error "unshare not found but was requested"
                exit 1
            fi
            run_with_unshare
            ;;
        skip)
            skip_tests
            ;;
        *)
            log_error "Unknown method: $METHOD"
            exit 1
            ;;
    esac
    
    log_success "Test run completed"
}

# Run main
main