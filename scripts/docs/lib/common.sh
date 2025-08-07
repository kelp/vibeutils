#!/bin/bash
# Common library for documentation scripts
# Provides error handling, logging, and shared utilities

# Exit on any error
set -e

# Initialize global variables
CI_MODE=false
VERBOSE=false
SCRIPT_NAME="$(basename "$0")"

# Colors for output (disable in CI)
init_colors() {
    if [ "$CI_MODE" = true ] || [ -n "$NO_COLOR" ]; then
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        NC=""
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m' # No Color
    fi
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
    if [ "$CI_MODE" = true ]; then
        echo "::warning::$*"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    if [ "$CI_MODE" = true ]; then
        echo "::error::$*"
    fi
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${NC}[DEBUG]${NC} $*" >&2
    fi
}

# Error handling
fatal() {
    log_error "$*"
    exit 1
}

# Check if running in CI
detect_ci() {
    if [ "$CI" = "true" ] || [ -n "$GITHUB_ACTIONS" ]; then
        CI_MODE=true
    fi
}

# Parse common arguments
parse_common_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ci)
                CI_MODE=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                if declare -f show_help >/dev/null 2>&1; then
                    show_help
                    exit 0
                else
                    echo "Help function not implemented for $SCRIPT_NAME"
                    exit 1
                fi
                ;;
            -*)
                return 0  # Let calling script handle unknown flags
                ;;
            *)
                return 0  # Let calling script handle positional args
                ;;
        esac
    done
}

# Tool verification
require_tool() {
    local tool="$1"
    local install_hint="$2"
    
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "$tool is not installed"
        if [ -n "$install_hint" ]; then
            echo "Install: $install_hint" >&2
        fi
        return 1
    fi
    log_debug "Found tool: $tool"
}

# File operations
ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log_debug "Creating directory: $dir"
        mkdir -p "$dir" || fatal "Failed to create directory: $dir"
    fi
}

# Cleanup trap
cleanup_temp_files() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_debug "Cleaning up temporary files: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Initialize temporary directory
init_temp_dir() {
    TEMP_DIR=$(mktemp -d) || fatal "Failed to create temporary directory"
    trap cleanup_temp_files EXIT
    log_debug "Using temporary directory: $TEMP_DIR"
}

# Initialize common settings
init_common() {
    detect_ci
    init_colors
}

# Initialize when sourced
init_common