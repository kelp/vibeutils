#!/usr/bin/env bash
#
# Integration test runner for privilege simulation framework
# This script runs comprehensive integration tests for the privilege testing infrastructure

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/zig-out"
TEST_FILTER=""
VERBOSE=false
PRIVILEGED_METHOD="auto"
SKIP_BUILD=false

# Usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Run integration tests for the privilege simulation framework.

Options:
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -f, --filter PATTERN    Only run tests matching PATTERN
    -m, --method METHOD     Privilege method: auto, fakeroot, unshare, none (default: auto)
    -s, --skip-build        Skip building binaries before testing
    --core-only             Run only core infrastructure tests
    --workflow-only         Run only workflow integration tests

Examples:
    $(basename "$0")                    # Run all integration tests
    $(basename "$0") -f "mkdir"         # Run tests containing "mkdir"
    $(basename "$0") -m fakeroot        # Force use of fakeroot
    $(basename "$0") --core-only        # Run only core tests

EOF
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Parse command line arguments
parse_args() {
    local core_only=false
    local workflow_only=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--filter)
                TEST_FILTER="$2"
                shift 2
                ;;
            -m|--method)
                PRIVILEGED_METHOD="$2"
                shift 2
                ;;
            -s|--skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --core-only)
                core_only=true
                shift
                ;;
            --workflow-only)
                workflow_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Set test filter based on options
    if [[ "$core_only" == true ]] && [[ "$workflow_only" == true ]]; then
        log_error "Cannot specify both --core-only and --workflow-only"
        exit 1
    elif [[ "$core_only" == true ]]; then
        TEST_FILTER="${TEST_FILTER:+$TEST_FILTER }privilege_test_integration"
    elif [[ "$workflow_only" == true ]]; then
        TEST_FILTER="${TEST_FILTER:+$TEST_FILTER }workflow_test"
    fi
}

# Check for required tools
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v zig &> /dev/null; then
        log_error "zig compiler not found in PATH"
        exit 1
    fi
    
    # Check for privilege tools based on method
    case "$PRIVILEGED_METHOD" in
        fakeroot)
            if ! command -v fakeroot &> /dev/null; then
                log_error "fakeroot not found but explicitly requested"
                exit 1
            fi
            ;;
        unshare)
            if ! command -v unshare &> /dev/null; then
                log_error "unshare not found but explicitly requested"
                exit 1
            fi
            ;;
        auto)
            # Will be determined later
            ;;
        none)
            log_warning "Running without privilege simulation"
            ;;
        *)
            log_error "Unknown privilege method: $PRIVILEGED_METHOD"
            exit 1
            ;;
    esac
}

# Determine which privilege method to use
determine_privilege_method() {
    if [[ "$PRIVILEGED_METHOD" != "auto" ]]; then
        echo "$PRIVILEGED_METHOD"
        return
    fi
    
    # Auto-detect available method
    if command -v fakeroot &> /dev/null; then
        echo "fakeroot"
    elif command -v unshare &> /dev/null && [[ "$(uname)" == "Linux" ]]; then
        echo "unshare"
    else
        echo "none"
    fi
}

# Build the project
build_project() {
    if [[ "$SKIP_BUILD" == true ]]; then
        log_info "Skipping build (--skip-build specified)"
        return
    fi
    
    log_info "Building project..."
    cd "$PROJECT_ROOT"
    
    if [[ "$VERBOSE" == true ]]; then
        zig build
    else
        zig build 2>&1 | grep -E "(error:|warning:)" || true
    fi
    
    if [[ ! -d "$BUILD_DIR/bin" ]]; then
        log_error "Build failed: no binaries found in $BUILD_DIR/bin"
        exit 1
    fi
    
    log_success "Build completed successfully"
}

# Run core infrastructure tests
run_core_tests() {
    log_info "Running core infrastructure tests..."
    
    local test_cmd="zig test src/common/privilege_test_integration.zig"
    if [[ -n "$TEST_FILTER" ]]; then
        test_cmd="$test_cmd --test-filter \"$TEST_FILTER\""
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        log_info "Test command: $test_cmd"
    fi
    
    cd "$PROJECT_ROOT"
    if eval "$test_cmd"; then
        log_success "Core infrastructure tests passed"
        return 0
    else
        log_error "Core infrastructure tests failed"
        return 1
    fi
}

# Run workflow integration tests
run_workflow_tests() {
    local method="$1"
    log_info "Running workflow integration tests with $method..."
    
    local test_cmd="zig build test-integration"
    
    if [[ -n "$TEST_FILTER" ]]; then
        test_cmd="$test_cmd -- --test-filter \"$TEST_FILTER\""
    fi
    
    # Prepare the command based on method
    case "$method" in
        fakeroot)
            test_cmd="fakeroot $test_cmd"
            ;;
        unshare)
            test_cmd="unshare --user --map-root-user $test_cmd"
            ;;
        none)
            # Run without privilege simulation
            ;;
    esac
    
    if [[ "$VERBOSE" == true ]]; then
        log_info "Test command: $test_cmd"
    fi
    
    cd "$PROJECT_ROOT"
    if eval "$test_cmd"; then
        log_success "Workflow integration tests passed with $method"
        return 0
    else
        log_error "Workflow integration tests failed with $method"
        return 1
    fi
}

# Main test execution
main() {
    parse_args "$@"
    
    log_info "Starting privilege framework integration tests"
    log_info "Project root: $PROJECT_ROOT"
    
    check_prerequisites
    build_project
    
    local exit_code=0
    local method
    method=$(determine_privilege_method)
    
    log_info "Using privilege method: $method"
    
    # Run core infrastructure tests
    if [[ -z "$TEST_FILTER" ]] || [[ "$TEST_FILTER" == *"privilege_test_integration"* ]]; then
        if ! run_core_tests; then
            exit_code=1
        fi
    fi
    
    # Run workflow tests (skip if already under fakeroot since build system handles it)
    if [[ -z "$TEST_FILTER" ]] || [[ "$TEST_FILTER" == *"workflow_test"* ]]; then
        # When running --core-only, skip workflow tests
        if [[ "$TEST_FILTER" != *"privilege_test_integration"* ]]; then
            if ! run_workflow_tests "$method"; then
                exit_code=1
            fi
        fi
    fi
    
    # Summary
    echo
    if [[ $exit_code -eq 0 ]]; then
        log_success "All integration tests passed!"
    else
        log_error "Some integration tests failed"
    fi
    
    exit $exit_code
}

# Run main function
main "$@"