#!/bin/bash
# test-linux.sh - Run vibeutils tests in Linux containers via Docker
# This script provides an easy way to test on different Linux distributions.
#
# It is a macOS dev-box tool in practice: it needs a reachable Docker daemon.
# A Linux agent container has no nested Docker and cannot start one, so this
# script is unavailable there — run the suites natively and let CI cover the
# distro matrix.

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
DISTRO="ubuntu-24.04"
COMMAND=""
ALL_DISTROS=0
SHELL_MODE=0
BUILD_ONLY=0
VERBOSE=0
NO_CACHE=0

# Available distributions
AVAILABLE_DISTROS=("ubuntu-24.04" "ubuntu-latest" "debian-12" "alpine")

# Help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Run vibeutils tests in Linux containers via Docker (needs a running daemon).
Unavailable inside an agent container, where CI covers the distro matrix.

OPTIONS:
    -d, --distro DISTRO      Linux distribution to use (default: ubuntu-24.04)
                             Available: ${AVAILABLE_DISTROS[*]}
    -a, --all                Test on all available distributions
    -s, --shell              Start interactive shell instead of running tests
    -b, --build-only         Only build the containers, don't run tests
    -v, --verbose            Enable verbose output
    --no-cache               Build containers without cache
    --privileged             Run privileged tests
    --coverage               Run coverage tests
    -h, --help               Show this help message

COMMANDS:
    If no command is specified, runs 'just test'

    Examples of commands:
    just test                Run all tests (default)
    just test-privileged     Run privileged tests
    just coverage            Run tests with coverage
    just build               Build the project
    zig build test           Run tests directly with zig
    bash                     Start an interactive shell

EXAMPLES:
    $0                           # Run tests on Ubuntu 24.04
    $0 --distro debian-12        # Run tests on Debian 12
    $0 --all                     # Run tests on all distributions
    $0 --shell                   # Interactive Ubuntu 24.04 shell
    $0 --shell --distro alpine   # Interactive Alpine shell
    $0 --privileged              # Run privileged tests
    $0 just coverage             # Run coverage tests
    $0 --all just build          # Build on all distributions

EOF
}

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

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--distro)
            DISTRO="$2"
            shift 2
            ;;
        -a|--all)
            ALL_DISTROS=1
            shift
            ;;
        -s|--shell)
            SHELL_MODE=1
            shift
            ;;
        -b|--build-only)
            BUILD_ONLY=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        --privileged)
            COMMAND="just test-privileged"
            shift
            ;;
        --coverage)
            COMMAND="just coverage"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            # Remaining arguments are the command
            COMMAND="$*"
            break
            ;;
    esac
done

# Validate distro
validate_distro() {
    local distro=$1
    for d in "${AVAILABLE_DISTROS[@]}"; do
        if [[ "$d" == "$distro" ]]; then
            return 0
        fi
    done
    return 1
}

# Build Docker images
build_images() {
    log_info "Building Docker images..."
    
    cd "$PROJECT_ROOT"
    
    local build_args=""
    if [[ $NO_CACHE -eq 1 ]]; then
        build_args="--no-cache"
    fi
    
    if [[ $ALL_DISTROS -eq 1 ]]; then
        log_info "Building all distribution images..."
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose -f docker/docker-compose.test.yml build $build_args
        else
            docker compose -f docker/docker-compose.test.yml build $build_args
        fi
    else
        log_info "Building $DISTRO image..."
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose -f docker/docker-compose.test.yml build $build_args "$DISTRO"
        else
            docker compose -f docker/docker-compose.test.yml build $build_args "$DISTRO"
        fi
    fi
    
    log_success "Docker images built successfully"
}

# Run command in container
run_in_container() {
    local distro=$1
    local cmd=$2
    
    cd "$PROJECT_ROOT"
    
    log_info "Running in $distro: $cmd"
    
    # Determine the appropriate shell based on distro
    local shell="/bin/bash"
    if [[ "$distro" == "alpine" ]]; then
        shell="/bin/sh"
    fi
    
    # Build the docker-compose run command (handle both docker-compose and docker compose)
    local docker_cmd
    if command -v docker-compose >/dev/null 2>&1; then
        docker_cmd="docker-compose -f docker/docker-compose.test.yml run --rm --service-ports"
    else
        docker_cmd="docker compose -f docker/docker-compose.test.yml run --rm --service-ports"
    fi
    
    if [[ $VERBOSE -eq 1 ]]; then
        docker_cmd="$docker_cmd -e VERBOSE=1"
    fi
    
    if [[ $SHELL_MODE -eq 1 ]]; then
        log_info "Starting interactive shell in $distro..."
        $docker_cmd "$distro" $shell
    else
        # For non-interactive commands, use -c to execute
        $docker_cmd "$distro" $shell -c "$cmd"
    fi
}

# Run tests on a single distribution
test_single_distro() {
    local distro=$1
    
    if ! validate_distro "$distro"; then
        log_error "Invalid distribution: $distro"
        log_error "Available distributions: ${AVAILABLE_DISTROS[*]}"
        exit 1
    fi
    
    log_info "Testing on $distro..."
    
    # Default command if none specified
    local cmd="${COMMAND:-just test}"
    
    # Special handling for Alpine (no fakeroot)
    if [[ "$distro" == "alpine" && "$cmd" == *"privileged"* ]]; then
        log_warning "Skipping privileged tests on Alpine (fakeroot not available)"
        return 0
    fi
    
    run_in_container "$distro" "$cmd"
    
    log_success "Tests completed on $distro"
}

# Main execution
main() {
    log_info "vibeutils Linux test runner"
    
    # Check if Docker is usable. "Start Docker" is only actionable advice on a
    # dev machine; inside an agent container there is no daemon to start, and
    # sending an agent to look for one wastes a turn on an unsolvable problem.
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker is not installed, so this script cannot run here."
        log_error "CI covers the Linux distro matrix; run 'zig build test' and 'just it' natively."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            log_error "Docker is not running. Please start Docker and try again."
        else
            log_error "The Docker daemon is not reachable."
            log_error "Inside an agent container Docker cannot be started at all, so this script is"
            log_error "unavailable here — not merely stopped. CI covers the Linux distro matrix;"
            log_error "run 'zig build test' and 'just it' natively instead."
        fi
        exit 1
    fi
    
    # Build images
    build_images
    
    if [[ $BUILD_ONLY -eq 1 ]]; then
        log_success "Build completed. Exiting."
        exit 0
    fi
    
    # Run tests or shell
    if [[ $ALL_DISTROS -eq 1 && $SHELL_MODE -eq 0 ]]; then
        # Test on all distributions
        log_info "Running tests on all distributions..."
        
        local failed_distros=()
        
        for distro in "${AVAILABLE_DISTROS[@]}"; do
            echo ""
            echo "====================================="
            echo "Testing on $distro"
            echo "====================================="
            
            if ! test_single_distro "$distro"; then
                failed_distros+=("$distro")
            fi
        done
        
        echo ""
        echo "====================================="
        echo "Summary"
        echo "====================================="
        
        if [[ ${#failed_distros[@]} -eq 0 ]]; then
            log_success "All tests passed on all distributions!"
        else
            log_error "Tests failed on: ${failed_distros[*]}"
            exit 1
        fi
    else
        # Test on single distribution or start shell
        test_single_distro "$DISTRO"
    fi
}

# Run main
main