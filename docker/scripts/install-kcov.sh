#!/bin/bash
# Install kcov from source with error handling
# Usage: install-kcov.sh [version] [temp_dir]

set -euo pipefail

# Default values
KCOV_VERSION="${1:-v42}"
TEMP_DIR="${2:-/tmp/kcov}"

# Configuration
REPOSITORY="https://github.com/SimonKagstrom/kcov.git"
BUILD_JOBS=$(nproc 2>/dev/null || echo "2")

echo "Installing kcov ${KCOV_VERSION}..."

# Function to cleanup on exit
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        echo "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# Function to check if kcov is already installed
check_existing_installation() {
    if command -v kcov >/dev/null 2>&1; then
        local existing_version
        existing_version=$(kcov --version 2>&1 | head -1 || echo "unknown")
        echo "Found existing kcov installation: $existing_version"
        
        # Check if it's the version we want
        if echo "$existing_version" | grep -q "${KCOV_VERSION#v}"; then
            echo "kcov ${KCOV_VERSION} is already installed, skipping..."
            return 0
        fi
    fi
    return 1
}

# Function to verify dependencies
verify_dependencies() {
    local missing_deps=()
    
    # Check for required build tools
    for cmd in git cmake make gcc g++; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Check for required libraries (attempt to compile a test program)
    echo "Verifying development libraries..."
    local test_program='
#include <curl/curl.h>
#include <elfutils/libdw.h>
#include <zlib.h>
int main() { return 0; }
'
    
    if ! echo "$test_program" | gcc -x c - -lcurl -ldw -lz -o /dev/null 2>/dev/null; then
        echo "Warning: Some development libraries may be missing" >&2
        echo "Required packages (Ubuntu/Debian): libcurl4-openssl-dev libdw-dev zlib1g-dev" >&2
        echo "Required packages (Alpine): curl-dev elfutils-dev zlib-dev" >&2
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install them before running this script." >&2
        exit 1
    fi
}

# Function to clone repository
clone_repository() {
    echo "Cloning kcov repository..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    
    git clone --depth 1 --branch "$KCOV_VERSION" "$REPOSITORY" "$TEMP_DIR"
    if [ ! -d "$TEMP_DIR" ]; then
        echo "Error: Failed to clone repository" >&2
        exit 1
    fi
}

# Function to build kcov
build_kcov() {
    echo "Building kcov with $BUILD_JOBS parallel jobs..."
    cd "$TEMP_DIR"
    
    # Create build directory
    mkdir -p build
    cd build
    
    # Configure with cmake
    echo "Configuring build..."
    if ! cmake ..; then
        echo "Error: CMake configuration failed" >&2
        exit 1
    fi
    
    # Build
    echo "Compiling kcov..."
    if ! make -j"$BUILD_JOBS"; then
        echo "Error: Build failed" >&2
        exit 1
    fi
    
    # Install
    echo "Installing kcov..."
    if ! make install; then
        echo "Error: Installation failed" >&2
        exit 1
    fi
}

# Function to verify installation
verify_installation() {
    echo "Verifying kcov installation..."
    
    # Check if kcov is in PATH
    if ! command -v kcov >/dev/null 2>&1; then
        echo "Error: kcov not found in PATH after installation" >&2
        exit 1
    fi
    
    # Check version
    local installed_version
    installed_version=$(kcov --version 2>&1 | head -1 || echo "unknown")
    echo "Installed kcov version: $installed_version"
    
    # Basic functionality test
    echo "Testing kcov basic functionality..."
    if ! kcov --help >/dev/null 2>&1; then
        echo "Warning: kcov help command failed, installation may be incomplete" >&2
    fi
    
    echo "kcov installation completed successfully!"
}

# Main execution
main() {
    # Skip if already installed with correct version
    if check_existing_installation; then
        exit 0
    fi
    
    # Verify all dependencies are available
    verify_dependencies
    
    # Clone the repository
    clone_repository
    
    # Build and install
    build_kcov
    
    # Verify the installation
    verify_installation
}

# Run main function
main "$@"