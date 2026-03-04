#!/usr/bin/env bash
# Enhanced integration test script for vibeutils
# Uses new comprehensive testing architecture with per-utility tests
#
# Requires: bash 4.0+ (install with: brew install bash)

set -euo pipefail

# Check bash version
if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    echo "Error: This script requires bash 4.0 or later. Current version: $BASH_VERSION"
    echo "Install modern bash with: brew install bash"
    echo "Then ensure /usr/local/bin is in your PATH before /bin"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$PROJECT_ROOT/zig-out/bin"

# Source the new test infrastructure
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/test_runner.sh"

# Print usage information
print_usage() {
    echo "Usage: $0 [OPTION] [UTILITY]"
    echo ""
    echo "Run integration tests for vibeutils."
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -l, --list     List available utilities for testing"
    echo "  -v, --verbose  Enable verbose output"
    echo ""
    echo "Arguments:"
    echo "  UTILITY        Test only the specified utility (e.g., echo, cat, chmod)"
    echo ""
    echo "Examples:"
    echo "  $0             Run tests for all utilities"
    echo "  $0 echo        Run comprehensive tests for echo only"
    echo "  $0 --list      Show all available utilities"
    echo ""
    echo "Environment Variables:"
    echo "  NO_COLOR       Set to disable colored output"
    echo "  UTIL           Alternative way to specify utility (for Makefile)"
}

# Parse command line arguments
parse_arguments() {
    VERBOSE=false
    TARGET_UTILITY=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_usage
                exit 0
                ;;
            -l|--list)
                list_available_utilities
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                echo "Unknown option: $1" >&2
                print_usage >&2
                exit 1
                ;;
            *)
                if [[ -n "$TARGET_UTILITY" ]]; then
                    echo "Error: Multiple utilities specified" >&2
                    print_usage >&2
                    exit 1
                fi
                TARGET_UTILITY="$1"
                shift
                ;;
        esac
    done
    
    # Check for UTIL environment variable (used by Makefile)
    if [[ -n "${UTIL:-}" ]] && [[ -z "$TARGET_UTILITY" ]]; then
        TARGET_UTILITY="$UTIL"
    fi
}

# Run legacy smoke tests for basic compatibility
run_legacy_smoke_tests() {
    echo -e "${BLUE}Legacy Compatibility Tests${NC}"
    echo "=========================="
    
    init_test_session
    
    # Quick smoke tests for all utilities
    echo -e "${CYAN}Testing basic utility functionality...${NC}"
    
    # Status utilities
    test_command_exit_code "true exit code" 0 "$BIN_DIR/true"
    test_command_exit_code "false exit code" 1 "$BIN_DIR/false"
    
    # Path utilities
    test_command_succeeds "pwd basic" "$BIN_DIR/pwd"
    test_command_output "basename basic" "file.txt" "$BIN_DIR/basename" "/path/to/file.txt"
    test_command_output "dirname basic" "/path/to" "$BIN_DIR/dirname" "/path/to/file.txt"
    
    # Text utilities basic tests
    test_command_output "echo basic" "hello" "$BIN_DIR/echo" "hello"
    echo "test" | test_command_output "cat stdin" "test" "$BIN_DIR/cat"
    
    # File system utilities (basic help tests)
    for util in mkdir rmdir rm cp mv ln chmod chown touch; do
        if [[ -x "$BIN_DIR/$util" ]]; then
            test_command_succeeds "$util --help" "$BIN_DIR/$util" --help
        fi
    done
    
    # Other utilities
    for util in sleep ls wc yes; do
        if [[ -x "$BIN_DIR/$util" ]]; then
            test_command_succeeds "$util --help" "$BIN_DIR/$util" --help
        fi
    done

    # test utility treats --help as string expression (POSIX compliance)
    if [[ -x "$BIN_DIR/test" ]]; then
        test_command_exit_code "test --help" 0 "$BIN_DIR/test" --help
    fi
    
    print_test_summary "Legacy Smoke Tests"
}

# Main test execution
main() {
    parse_arguments "$@"
    
    echo -e "${BLUE}vibeutils Integration Tests${NC}"
    echo "$(printf '=%.0s' {1..29})"
    echo -e "${CYAN}Architecture: Comprehensive per-utility testing${NC}"
    echo -e "${CYAN}Target: ${TARGET_UTILITY:-All utilities}${NC}"
    echo ""
    
    # Verify binary directory exists
    if [[ ! -d "$BIN_DIR" ]]; then
        echo -e "${RED}Error: Binary directory not found at $BIN_DIR${NC}"
        echo "Run 'make build' first"
        exit 1
    fi
    
    local overall_result=0
    
    if [[ -n "$TARGET_UTILITY" ]]; then
        # Test specific utility
        echo -e "${YELLOW}Running comprehensive tests for: $TARGET_UTILITY${NC}"
        echo ""
        
        if ! run_utility_tests "$TARGET_UTILITY"; then
            overall_result=1
        fi
        
    else
        # Test all utilities
        echo -e "${YELLOW}Running comprehensive tests for all utilities${NC}"
        echo ""
        
        # First run legacy smoke tests for quick verification
        if ! run_legacy_smoke_tests; then
            echo -e "${RED}Legacy smoke tests failed - basic functionality broken${NC}"
            overall_result=1
        fi

        # Run help consistency validation
        echo ""
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}Running help text consistency checks${NC}"
        echo -e "${YELLOW}========================================${NC}"

        init_test_session
        source "$SCRIPT_DIR/utilities/help_consistency_checks.sh"
        test_help_consistency
        if ! print_test_summary "Help Consistency"; then
            overall_result=1
        fi

        echo ""
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}Running comprehensive per-utility tests${NC}"
        echo -e "${YELLOW}========================================${NC}"
        
        # Then run comprehensive tests
        if ! run_all_utility_tests; then
            overall_result=1
        fi
    fi
    
    # Final summary
    echo ""
    echo -e "${BLUE}Integration Test Session Complete${NC}"
    echo "================================="
    
    if [[ $overall_result -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed successfully!${NC}"
        echo -e "${CYAN}The vibeutils implementation is ready for use.${NC}"
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        echo -e "${YELLOW}Check the output above for details on failed tests.${NC}"
        echo -e "${CYAN}Failed commands are shown to help with debugging.${NC}"
    fi
    
    exit $overall_result
}

# Handle signals gracefully
trap cleanup_test_session EXIT

main "$@"