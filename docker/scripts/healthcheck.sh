#!/bin/bash
# Health check script for vibeutils Docker containers
# Tests essential tools and environment setup

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SUCCESS_CODE=0
readonly FAILURE_CODE=1

# Colors for output (if terminal supports it)
if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" >&2
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if a command exists and log result
check_command() {
    local cmd="$1"
    local description="${2:-$cmd}"
    
    if command_exists "$cmd"; then
        local version=""
        case "$cmd" in
            "zig")
                version=$(zig version 2>/dev/null || echo "unknown")
                ;;
            "git")
                version=$(git --version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
                ;;
            "make")
                version=$(make --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' || echo "unknown")
                ;;
            "cmake")
                version=$(cmake --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
                ;;
            "kcov")
                version=$(kcov --version 2>/dev/null | head -1 | grep -o 'v[0-9]\+' || echo "unknown")
                ;;
            "fakeroot")
                version=$(fakeroot --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "available")
                ;;
            *)
                version="available"
                ;;
        esac
        log_success "$description ($version)"
        return 0
    else
        log_error "$description not found"
        return 1
    fi
}

# Check environment variable
check_env_var() {
    local var_name="$1"
    local description="${2:-$var_name}"
    local expected="${3:-}"
    
    if [ -n "${!var_name:-}" ]; then
        local value="${!var_name}"
        if [ -n "$expected" ] && [ "$value" != "$expected" ]; then
            log_warning "$description: $value (expected: $expected)"
        else
            log_success "$description: $value"
        fi
        return 0
    else
        log_error "$description not set"
        return 1
    fi
}

# Check file/directory exists
check_path() {
    local path="$1"
    local description="${2:-$path}"
    local type="${3:-file}"
    
    case "$type" in
        "file")
            if [ -f "$path" ]; then
                log_success "$description exists"
                return 0
            fi
            ;;
        "dir"|"directory")
            if [ -d "$path" ]; then
                log_success "$description exists"
                return 0
            fi
            ;;
        "any")
            if [ -e "$path" ]; then
                log_success "$description exists"
                return 0
            fi
            ;;
    esac
    
    log_error "$description does not exist"
    return 1
}

# Test Zig functionality
test_zig_functionality() {
    log_info "Testing Zig functionality..."
    
    if ! command_exists zig; then
        log_error "Zig not available for testing"
        return 1
    fi
    
    # Create a temporary test program
    local temp_dir
    temp_dir=$(mktemp -d)
    local test_file="$temp_dir/test.zig"
    
    # Cleanup function
    cleanup_zig_test() {
        rm -rf "$temp_dir"
    }
    trap cleanup_zig_test EXIT
    
    # Create simple test program
    cat > "$test_file" << 'EOF'
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Zig health check: OK\n");
}
EOF
    
    # Try to compile and run
    if zig run "$test_file" 2>/dev/null | grep -q "Zig health check: OK"; then
        log_success "Zig compilation and execution test"
        return 0
    else
        log_error "Zig compilation or execution failed"
        return 1
    fi
}

# Test build system
test_build_system() {
    log_info "Testing build system..."
    
    if [ ! -f "build.zig" ]; then
        log_warning "build.zig not found, skipping build system test"
        return 0
    fi
    
    # Test that build.zig is syntactically valid
    if zig build --help >/dev/null 2>&1; then
        log_success "build.zig syntax check"
        return 0
    else
        log_error "build.zig has syntax errors"
        return 1
    fi
}

# Check system resources
check_system_resources() {
    log_info "Checking system resources..."
    
    # Check available memory
    if [ -f "/proc/meminfo" ]; then
        local mem_kb
        mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        local mem_mb=$((mem_kb / 1024))
        
        if [ "$mem_mb" -gt 512 ]; then
            log_success "Available memory: ${mem_mb}MB"
        else
            log_warning "Low available memory: ${mem_mb}MB"
        fi
    fi
    
    # Check disk space
    local disk_usage
    disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$disk_usage" -lt 90 ]; then
        log_success "Disk usage: ${disk_usage}%"
    else
        log_warning "High disk usage: ${disk_usage}%"
    fi
    
    # Check CPU count
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo "1")
    log_success "CPU cores: $cpu_count"
}

# Main health check function
main() {
    local exit_code=0
    
    echo "=== vibeutils Docker Container Health Check ==="
    echo "Timestamp: $(date -Iseconds)"
    echo
    
    # Check essential commands
    log_info "Checking essential commands..."
    check_command "zig" "Zig compiler" || exit_code=1
    check_command "git" "Git version control" || exit_code=1
    check_command "make" "Make build tool" || exit_code=1
    check_command "bash" "Bash shell" || exit_code=1
    
    # Check optional but useful commands
    log_info "Checking optional tools..."
    check_command "cmake" "CMake build system" || true
    check_command "kcov" "kcov coverage tool" || true
    check_command "fakeroot" "fakeroot for privilege testing" || true
    check_command "valgrind" "Valgrind memory checker" || true
    
    echo
    
    # Check environment variables
    log_info "Checking environment variables..."
    check_env_var "PATH" "PATH variable" || exit_code=1
    check_env_var "FORCE_COLOR" "Color support" || true
    check_env_var "CI" "CI environment indicator" || true
    
    echo
    
    # Check important paths
    log_info "Checking important paths..."
    check_path "/usr/local/bin/zig" "Zig binary" "file" || exit_code=1
    check_path "/workspace" "Workspace directory" "dir" || true
    
    echo
    
    # Test Zig functionality
    test_zig_functionality || exit_code=1
    
    echo
    
    # Test build system if available
    test_build_system || true
    
    echo
    
    # Check system resources
    check_system_resources
    
    echo
    echo "=== Health Check Summary ==="
    
    if [ $exit_code -eq $SUCCESS_CODE ]; then
        log_success "All essential checks passed - container is healthy!"
    else
        log_error "Some essential checks failed - container may not function properly"
    fi
    
    exit $exit_code
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi