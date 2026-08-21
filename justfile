# vibeutils justfile

set shell := ["bash", "-euc"]

build_cmd := "zig build"
test_cmd := "zig build test"
docker_compose := `command -v docker-compose 2>/dev/null || echo "docker compose"`

# List available recipes
default:
    @just --list

# --- Environment guards ---

# Fail with an accurate message when an optional tool is unavailable, instead
# of a raw "command not found" or advice that cannot be followed. A Linux agent
# container has no Docker daemon and cannot start one, so telling it to "start
# Docker" sends an agent chasing a problem it cannot solve. Recipes depend on
# this rather than each rolling their own check.
_require tool:
    #!/usr/bin/env bash
    set -eu
    case "{{tool}}" in
        docker)
            if ! command -v docker >/dev/null 2>&1; then
                echo "just: docker is not installed, so this recipe is unavailable here." >&2
                echo "      Agent containers have no nested Docker. CI covers the Linux distro matrix." >&2
                exit 1
            fi
            if ! docker info >/dev/null 2>&1; then
                if [ "$(uname -s)" = "Darwin" ]; then
                    echo "just: the Docker daemon is not running. Start Docker (or OrbStack) and retry." >&2
                else
                    echo "just: the Docker daemon is not reachable. Inside an agent container Docker cannot" >&2
                    echo "      be started at all, so this recipe is unavailable here — not merely stopped." >&2
                    echo "      CI covers the Linux distro matrix; run 'zig build test' and 'just it' natively." >&2
                fi
                exit 1
            fi
            ;;
        *)
            if ! command -v "{{tool}}" >/dev/null 2>&1; then
                echo "just: {{tool}} is not installed, so this recipe is unavailable here." >&2
                echo "      scripts/bootstrap.sh does not install it by design; CI runs this check." >&2
                exit 1
            fi
            ;;
    esac

# Report the host platform and which optional tools — and therefore which
# recipes — are actually available here.
platform:
    #!/usr/bin/env bash
    set -eu
    echo "platform:  $(uname -s) $(uname -m)"
    echo "uid:       $(id -u)$([ "$(id -u)" -eq 0 ] && echo '  (root — integration tests demote via scripts/run-integration.sh)' || echo '')"
    echo ""
    echo "Optional tools:"
    report() {
        if command -v "$1" >/dev/null 2>&1; then
            printf '  %-11s present    %s\n' "$1" "$(command -v "$1")"
        else
            printf '  %-11s absent     %s\n' "$1" "$2"
        fi
    }
    report fakeroot  "'just test-privileged' unavailable"
    report mandoc    "'just lint-man*' unavailable"
    report hexdump   "some 'just it' tests fail (apt: bsdextrautils)"
    report kcov      "'just coverage' unavailable; CI runs coverage"
    report actionlint "'just lint-actions' unavailable; CI lints workflows"
    report gh        "'just release-tag' unavailable"
    report orb       "no second platform from here; CI covers macOS"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf '  %-11s present    daemon reachable\n' docker
    else
        printf '  %-11s absent     %s\n' docker "'just test-linux*' and 'just docker-*' unavailable; CI covers the distro matrix"
    fi
    echo ""
    echo "Everything not listed above works here. See docs/TOOLCHAIN.md for the full matrix."

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

# Check the macOS passwd/group ABI from any host, without a macOS runner.
#
# The layout pin in src/common/user_group.zig is a `comptime` block, so
# --test-no-exec evaluates its macOS arm while cross-compiling. The final
# cross-build is what compile-checks id.zig's macOS-only `-P` arm, which no
# Linux test run ever reaches (issue #129).
abi-macos:
    zig test --test-no-exec -lc -target aarch64-macos src/common/user_group.zig
    zig test --test-no-exec -lc -target x86_64-macos src/common/user_group.zig
    # Installs under its own prefix. The integration suites pin PATH to
    # zig-out/bin, so leaving Mach-O executables there makes every later run
    # on this host die with "Exec format error" -- the same clobber that was
    # blamed for the first observed occurrence of issue #125.
    zig build -Dtarget=aarch64-macos-none -p zig-out/macos

# Run the privilege-framework integration tests
#
# `zig build test-integration` existed but nothing invoked it — not this file,
# not CI — so its three test roots never ran (issue #95). Kept separate from
# `test` so that recipe stays a pure unit-test step. The privileged tests here
# skip cleanly without fakeroot; run `just test-privileged` for those.
test-integration:
    zig build test-integration

# Test a specific utility (smoke test + binary check)
test-util util:
    @echo "Testing {{util}} utility..."
    @echo "----------------------------------------"
    @echo "Running: zig build test -Dtest-util={{util}}"
    @{{test_cmd}} -Dtest-util={{util}}
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
    if ! command -v fakeroot &>/dev/null; then
        echo "Error: fakeroot is required but not installed"
        echo "Install with: sudo apt-get install fakeroot (Debian/Ubuntu)"
        echo "           or: brew install fakeroot (macOS - may not work)"
        exit 1
    fi
    # Linux kernel race between the Zig linker closing a freshly-built
    # test binary and the test runner exec'ing it can produce ETXTBSY
    # ("FileBusy"). Retry up to 3 times with a short delay to absorb
    # the flake. Each attempt is idempotent since the build cache
    # reuses already-compiled artifacts.
    for attempt in 1 2 3; do
        echo "Running privileged tests with fakeroot (attempt $attempt)..."
        if fakeroot zig build test-privileged; then
            exit 0
        fi
        rc=$?
        if [ "$attempt" -lt 3 ]; then
            echo "Attempt $attempt failed (rc=$rc); retrying in 2s…"
            sleep 2
        fi
    done
    echo "All 3 attempts failed"
    exit 1

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
    @zig build run-{{util}} -- {{args}}

# --- Build Modes ---

# Build with debug symbols
debug:
    zig build -Doptimize=Debug

# Build optimized binaries (ReleaseSmall)
build-release:
    zig build -Doptimize=ReleaseSmall

# --- Release ---

# Release gate 1 (local): test, bump version, push main (no tag)
release version:
    @scripts/release.sh {{version}}

# Release gate 2 (CI): wait for green CI on all runners, push tag
release-tag version:
    @scripts/release-tag.sh {{version}}

# --- Code Quality ---

# Format all Zig code
fmt:
    zig build fmt

# Check code formatting without modifying
fmt-check:
    zig build fmt-check

# Install the pinned Zig toolchain plus just, mandoc and fakeroot
setup:
    @./scripts/bootstrap.sh

# Install git hooks (pre-commit fmt gate). Run once after cloning.
install-hooks:
    git config core.hooksPath .githooks
    @echo "Installed git hooks from .githooks (pre-commit fmt gate)."

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
lint-actions: (_require "actionlint")
    @echo "Linting GitHub Actions workflows..."
    @actionlint .github/workflows/*.yml

# Scan the whole source tree for Tiger Style gating violations.
# The migration baseline is zero, so ANY violation fails. usize-arch
# is reported but non-gating. Same scanner the pre-commit hook runs.
tiger-check:
    @./scripts/tiger-check.sh

# Contract tests for scripts/tiger-check.sh. Needs no Zig build: tiger-check
# has no --root and its diff modes need real history, so every case builds a
# throwaway git repo in a temp dir. Lives in tests/tools/, which
# test_runner.sh does not glob, so it must be invoked here and from CI
# explicitly.
test-tiger-check:
    @bash tests/tools/tiger-check_test.sh

# Pin checks for the BSD vmactions workflow. Lives in tests/tools/, which
# test_runner.sh does not glob, so it must be invoked here and from CI
# explicitly.
test-bsd-workflow:
    @bash tests/tools/bsd-workflow_test.sh

# Contract tests for scripts/audit-check.sh. Needs no Zig build: every
# case points --root at a fixture tree under tests/fixtures/audit. Lives in
# tests/tools/, which test_runner.sh does not glob, so it must be invoked
# here and from CI explicitly.
test-audit-check:
    @bash tests/tools/audit-check_test.sh

# Contract tests for host/host_resolve PATH isolation (issue #167). Needs
# no Zig build: it plants a fake chmod first on PATH and sources
# tests/lib/common.sh. Lives in tests/tools/, so it needs an explicit
# invocation here and from CI.
test-host-path:
    @bash tests/tools/host_path_test.sh

# Every run gets a private working directory, so a leftover fixture can
# never change a later run's outcome. Needs a build, since it runs the real
# mkdir suite, and takes ~5 minutes — the full-suite guard is most of it.
# Also in tests/tools/, so it needs an explicit invocation.
#
# Contract tests for scripts/run-integration.sh (issue #125)
test-run-integration: build
    @bash tests/tools/run-integration_test.sh

# Stage-1 audit pre-pass over every unit in build/utils.zig. A finding
# already recorded in scripts/audit-baseline.tsv is BASELINED; anything
# else is NEW and fails. Plain sh + awk, so it needs no Zig toolchain.
audit-check:
    @./scripts/audit-check.sh

# Lint CHANGELOG structure: ## Unreleased present, released sections
# byte-identical to their git tags, no conflict markers.
lint-changelog:
    @./scripts/lint-changelog.sh

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
test-linux: (_require "docker")
    @echo "Running tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh

# Run tests on all Linux distributions
test-linux-all: (_require "docker")
    @echo "Running tests on all Linux distributions..."
    @scripts/test-linux.sh --all

# Run privileged tests in Ubuntu 24.04 container
test-linux-privileged: (_require "docker")
    @echo "Running privileged tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --privileged

# Run coverage tests in Ubuntu 24.04 container
test-linux-coverage: (_require "docker")
    @echo "Running coverage tests in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --coverage

# Build Docker test images
docker-build: (_require "docker")
    @echo "Building Docker test images..."
    @scripts/test-linux.sh --build-only

# Open interactive shell in Ubuntu 24.04 container
docker-shell: (_require "docker")
    @echo "Starting interactive shell in Ubuntu 24.04 container..."
    @scripts/test-linux.sh --shell

# Open interactive shell in Debian 12 container
docker-shell-debian: (_require "docker")
    @echo "Starting interactive shell in Debian 12 container..."
    @scripts/test-linux.sh --shell --distro debian-12

# Clean Docker test containers and volumes
docker-clean: (_require "docker")
    @echo "Cleaning Docker test containers and volumes..."
    @{{docker_compose}} -f docker/docker-compose.test.yml down -v
    @docker rmi vibeutils-test:ubuntu-24.04 vibeutils-test:ubuntu-latest vibeutils-test:debian-12 vibeutils-test:alpine 2>/dev/null || true

# --- Integration Testing ---

# Run all integration tests
it: build
    @echo "Running integration tests for all utilities..."
    @scripts/run-integration.sh

# Run integration tests for a specific utility
it-util util: build
    @echo "Running comprehensive tests for {{util}} utility..."
    @scripts/run-integration.sh {{util}}

# A SERIAL loop does not reproduce #125 — nothing contaminates the cwd
# between iterations — so use --concurrent K to probe the real mechanism:
# `just stress --concurrent 2 --iterations 20 mkdir`. A failing iteration's
# temp tree and log are kept; a passing one's are deleted.
#
# Stress one utility's integration suite, hunting working-directory contamination
stress *args: build
    @./scripts/stress-integration.sh {{args}}

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

# Fuzz a specific utility
fuzz util +args='':
    zig build fuzz-{{util}} -- {{args}}

# --- Benchmarks ---

# Run performance benchmarks
benchmark: build
    @echo "Running performance benchmarks..."
    @RUN_BENCHMARKS=1 zig test src/integration_tests.zig --main-mod-path . --deps common --test-filter "benchmark"
