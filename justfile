# vibeutils justfile

set shell := ["bash", "-euc"]

build_cmd := "zig build"
test_cmd := "zig build test"
docker_compose := `command -v docker-compose 2>/dev/null || echo "docker compose"`

# List available recipes
default:
    @just --list

# --- Core ---

# Build all utilities (debug mode)
build:
    {{build_cmd}}

# Build a specific utility
build-util util:
    @echo "Building {{util}} utility..."
    @if {{build_cmd}} 2>&1 | grep -E "error.*{{util}}\.zig"; then \
        echo "Build failed for {{util}}"; \
        exit 1; \
    else \
        echo "Build completed"; \
    fi
    @[ -f zig-out/bin/{{util}} ] && echo "Binary: zig-out/bin/{{util}}" || echo "Binary not found (may not be a valid utility name)"

# Run all tests
test:
    {{test_cmd}}

# Test a specific utility (smoke test + binary check)
test-util util:
    @echo "Testing {{util}} utility..."
    @echo "----------------------------------------"
    @echo "Note: Unit tests require the full build system."
    @echo "Running: zig build test 2>&1 | grep {{util}}"
    @{{test_cmd}} 2>&1 | grep -E "{{util}}\.zig|All.*tests passed" || echo "See full output with: just test"
    @echo "----------------------------------------"
    @echo "Binary smoke test:"
    @if [ -f zig-out/bin/{{util}} ]; then \
        ./zig-out/bin/{{util}} --version 2>/dev/null && echo "--version works" || true; \
        echo ""; \
        echo "Help output (first 5 lines):"; \
        ./zig-out/bin/{{util}} --help 2>/dev/null | head -5 || true; \
    else \
        echo "Binary not found. Run 'just build' first."; \
    fi

# Run privileged tests with fakeroot
test-privileged:
    #!/usr/bin/env bash
    set -eu
    if command -v fakeroot &>/dev/null; then
        echo "Running privileged tests with fakeroot..."
        fakeroot zig build test-privileged
    else
        echo "Error: fakeroot is required but not installed"
        echo "Install with: sudo apt-get install fakeroot (Debian/Ubuntu)"
        echo "           or: brew install fakeroot (macOS - may not work)"
        exit 1
    fi

# Run privileged tests with best available method
test-privileged-local:
    @echo "Running privileged tests with best available method..."
    @scripts/run-privileged-tests.sh

# Run tests on all platforms (native + Docker if available)
test-all:
    #!/usr/bin/env bash
    set -eu
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Running macOS + Linux Docker tests..."
        just test && just test-privileged-local
        if command -v docker &>/dev/null; then
            just test-linux-all && just test-linux-privileged
        fi
    else
        echo "Running native Linux tests..."
        just test && just test-privileged-local
    fi

# Generate test coverage report
coverage:
    @scripts/coverage.sh

# Remove build artifacts
clean:
    zig build clean

# Install utilities to zig-out/bin/
install:
    zig build -Doptimize=ReleaseSafe
    @echo "Binaries installed to: zig-out/bin/"

# --- Utility Execution ---

# Run a specific utility with arguments
run util +args='':
    @echo "Running {{util}} utility..."
    @zig build run-{{util}} -- {{args}} 2>&1 || echo "Error: Failed to run {{util}}. It may need to be migrated to Zig 0.15.1 first."

# --- Build Modes ---

# Build with debug symbols
debug:
    zig build -Doptimize=Debug

# Build optimized binaries (ReleaseSmall)
build-release:
    zig build -Doptimize=ReleaseSmall

# --- Release ---

# Bump version, tag, push, trigger CI release
release version:
    @scripts/release.sh {{version}}

# --- Code Quality ---

# Format all Zig code
fmt:
    zig build fmt

# Check code formatting without modifying
fmt-check:
    zig build fmt-check

# Lint man pages
lint-man:
    @echo "Linting man pages..."
    @./scripts/lint-man-pages.sh

# Lint man pages (strict mode)
lint-man-strict:
    @echo "Linting man pages (strict mode)..."
    @./scripts/lint-man-pages.sh --fail-on-warnings

# Lint man pages (verbose)
lint-man-verbose:
    @echo "Linting man pages (verbose)..."
    @./scripts/lint-man-pages.sh --verbose

# Lint GitHub Actions workflows
lint-actions:
    @echo "Linting GitHub Actions workflows..."
    @actionlint .github/workflows/*.yml

# Run CI validation checks
ci-validate:
    zig build ci-validate -Dci=true

# --- Documentation ---

# Generate API documentation
docs:
    zig build docs
    ./scripts/generate-docs-index.sh
    @echo "API documentation generated in zig-out/docs/"

# Generate full HTML documentation site
docs-html: docs
    @echo "Generating full HTML documentation site..."
    @./scripts/generate-docs.sh

# Serve documentation locally on port 8000
docs-serve: docs-html
    @echo "Starting local documentation server on http://localhost:8000"
    @cd docs/html && python3 -m http.server 8000

# Open documentation in browser
docs-open: docs-html
    @echo "Opening documentation in browser..."
    @./scripts/generate-docs.sh --open

# --- Docker / Linux Testing ---

# Run tests in Ubuntu 24.04 container
test-linux:
    @echo "Running tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh

# Run tests on all Linux distributions
test-linux-all:
    @echo "Running tests on all Linux distributions..."
    @scripts/test-linux.sh --all

# Run privileged tests in Ubuntu 24.04 container
test-linux-privileged:
    @echo "Running privileged tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --privileged

# Run coverage tests in Ubuntu 24.04 container
test-linux-coverage:
    @echo "Running coverage tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --coverage

# Build Docker test images
docker-build:
    @echo "Building Docker test images..."
    @scripts/test-linux.sh --build-only

# Open interactive shell in Ubuntu 24.04 container
docker-shell:
    @echo "Starting interactive shell in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --shell

# Open interactive shell in Debian 12 container
docker-shell-debian:
    @echo "Starting interactive shell in Debian 12 container..."
    @scripts/test-linux.sh --shell --distro debian-12

# Clean Docker test containers and volumes
docker-clean:
    @echo "Cleaning Docker test containers and volumes..."
    @{{docker_compose}} -f docker/docker-compose.test.yml down -v
    @docker rmi vibeutils-test:ubuntu-24.04 vibeutils-test:ubuntu-latest vibeutils-test:debian-12 vibeutils-test:alpine 2>/dev/null || true

# --- Integration Testing ---

# Run all integration tests
it: build
    @echo "Running integration tests for all utilities..."
    @tests/integration.sh

# Run integration tests for a specific utility
it-util util: build
    @echo "Running comprehensive tests for {{util}} utility..."
    @tests/integration.sh {{util}}

# List available utilities for integration testing
it-list: build
    @echo "Listing available utilities for testing..."
    @tests/integration.sh --list

# Validate integration test infrastructure
test-integration-validate: build
    #!/usr/bin/env bash
    set -eu
    echo "Validating integration test infrastructure..."
    echo "Testing that help flag works for key utilities..."
    for util in echo cat chmod; do
        if [ -x zig-out/bin/$util ]; then
            echo "Testing $util --help"
            zig-out/bin/$util --help >/dev/null 2>&1 || echo "$util --help failed"
        else
            echo "$util binary not found"
        fi
    done

# --- Fuzzing ---

# Fuzz a specific utility (Linux only)
fuzz util:
    #!/usr/bin/env bash
    set -eu
    if [ "$(uname -s)" != "Linux" ]; then
        echo "Linux required. Use docker target."
        exit 1
    fi
    zig build fuzz-{{util}}

# --- Benchmarks ---

# Run performance benchmarks
benchmark: build
    @echo "Running performance benchmarks..."
    @RUN_BENCHMARKS=1 zig test src/integration_tests.zig --main-mod-path . --deps common --test-filter "benchmark"
