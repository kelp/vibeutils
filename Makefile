# vibeutils Makefile

# Variables and Configuration
BUILD_CMD := zig build
TEST_CMD := zig build test
DOCKER_COMPOSE := $(shell command -v docker-compose 2>/dev/null || echo "docker compose")
LINUX_ONLY := @[ "$$(uname -s)" = "Linux" ] || (echo "Linux required. Use docker target." && exit 1)
IS_MACOS := $(shell [ "$$(uname -s)" = "Darwin" ] && echo "true")
HAS_DOCKER := $(shell command -v docker >/dev/null 2>&1 && echo "true")
HAS_FAKEROOT := $(shell command -v fakeroot >/dev/null 2>&1 && echo "true")

# All .PHONY targets in one line
.PHONY: all build test test-privileged test-privileged-local test-all clean install coverage coverage-kcov fmt fmt-check lint-man lint-man-strict lint-man-verbose lint-actions ci-validate docs help test-linux test-linux-all test-linux-privileged test-linux-coverage docker-build docker-shell docker-shell-debian docker-clean docs-html docs-serve docs-open run debug build-release release it test-integration-validate it-list

# Core Targets
all: build

build:
ifdef UTIL
	@echo "Building $(UTIL) utility..."
	@if $(BUILD_CMD) 2>&1 | grep -E "error.*$(UTIL)\.zig"; then \
		echo "❌ Build failed for $(UTIL)"; \
		exit 1; \
	else \
		echo "✓ Build completed"; \
	fi
	@[ -f zig-out/bin/$(UTIL) ] && echo "✓ Binary: zig-out/bin/$(UTIL)" || echo "⚠ Binary not found (may not be a valid utility name)"
else
	$(BUILD_CMD)
endif

test:
ifdef UTIL
	@echo "Testing $(UTIL) utility..."
	@echo "----------------------------------------"
	@echo "Note: Unit tests require the full build system."
	@echo "Running: zig build test 2>&1 | grep $(UTIL)"
	@$(TEST_CMD) 2>&1 | grep -E "$(UTIL)\.zig|All.*tests passed" || echo "See full output with: make test"
	@echo "----------------------------------------"
	@echo "Binary smoke test:"
	@if [ -f zig-out/bin/$(UTIL) ]; then \
		./zig-out/bin/$(UTIL) --version 2>/dev/null && echo "✓ --version works" || true; \
		echo ""; \
		echo "Help output (first 5 lines):"; \
		./zig-out/bin/$(UTIL) --help 2>/dev/null | head -5 || true; \
	else \
		echo "⚠ Binary not found. Run 'make build' first."; \
	fi
else
	$(TEST_CMD)
endif

test-privileged:
ifeq ($(HAS_FAKEROOT),true)
	@echo "Running privileged tests with fakeroot..."
	@fakeroot zig build test-privileged
else
	@echo "Error: fakeroot is required but not installed"
	@echo "Install with: sudo apt-get install fakeroot (Debian/Ubuntu)"
	@echo "           or: brew install fakeroot (macOS - may not work)"
	@exit 1
endif

test-privileged-local:
	@echo "Running privileged tests with best available method..."
	@scripts/run-privileged-tests.sh

test-all:
ifeq ($(IS_MACOS),true)
	@echo "Running macOS + Linux Docker tests..."
	@$(MAKE) test && $(MAKE) test-privileged-local
	@if [ "$(HAS_DOCKER)" = "true" ]; then $(MAKE) test-linux-all && $(MAKE) test-linux-privileged; fi
else
	@echo "Running native Linux tests..."
	@$(MAKE) test && $(MAKE) test-privileged-local
endif

coverage:
	zig build coverage

coverage-kcov:
	zig build coverage -Dcoverage-backend=kcov

clean:
	zig build clean

install:
	zig build -Doptimize=ReleaseSafe
	@echo "Binaries installed to: zig-out/bin/"

# Utility Execution
run:
ifdef UTIL
	@echo "Running $(UTIL) utility..."
	@zig build run-$(UTIL) -- $(ARGS) 2>&1 || echo "Error: Failed to run $(UTIL). It may need to be migrated to Zig 0.15.1 first."
else
	@echo "Usage: make run UTIL=<name> ARGS='<arguments>'"
	@echo "Example: make run UTIL=echo ARGS='hello world'"
endif

debug:
	zig build -Doptimize=Debug

build-release:
	zig build -Doptimize=ReleaseSmall

release:
ifndef VERSION
	@echo "Usage: make release VERSION=<semver>"
	@echo "Example: make release VERSION=0.7.0"
	@exit 1
endif
	@scripts/release.sh $(VERSION)

fmt:
	zig build fmt

fmt-check:
	zig build fmt-check

lint-man:
	@echo "Linting man pages..."
	@./scripts/lint-man-pages.sh

lint-man-strict:
	@echo "Linting man pages (strict mode)..."
	@./scripts/lint-man-pages.sh --fail-on-warnings

lint-man-verbose:
	@echo "Linting man pages (verbose)..."
	@./scripts/lint-man-pages.sh --verbose

lint-actions:
	@echo "Linting GitHub Actions workflows..."
	@actionlint .github/workflows/*.yml

ci-validate:
	zig build ci-validate -Dci=true

docs:
	zig build docs
	./scripts/generate-docs-index.sh
	@echo "API documentation generated in zig-out/docs/"

docs-html: docs
	@echo "Generating full HTML documentation site..."
	@./scripts/generate-docs.sh

docs-serve: docs-html
	@echo "Starting local documentation server on http://localhost:8000"
	@cd docs/html && python3 -m http.server 8000

docs-open: docs-html
	@echo "Opening documentation in browser..."
	@./scripts/generate-docs.sh --open

# Docker/Linux Testing
test-linux:
	@echo "Running tests in Ubuntu 24.04 container..."
	@scripts/test-linux.sh

test-linux-all:
	@echo "Running tests on all Linux distributions..."
	@scripts/test-linux.sh --all

test-linux-privileged:
	@echo "Running privileged tests in Ubuntu 24.04 container..."
	@scripts/test-linux.sh --privileged

test-linux-coverage:
	@echo "Running coverage tests in Ubuntu 24.04 container..."
	@scripts/test-linux.sh --coverage

docker-build:
	@echo "Building Docker test images..."
	@scripts/test-linux.sh --build-only

docker-shell:
	@echo "Starting interactive shell in Ubuntu 24.04 container..."
	@scripts/test-linux.sh --shell

docker-shell-debian:
	@echo "Starting interactive shell in Debian 12 container..."
	@scripts/test-linux.sh --shell --distro debian-12

docker-clean:
	@echo "Cleaning Docker test containers and volumes..."
	@$(DOCKER_COMPOSE) -f docker/docker-compose.test.yml down -v
	@docker rmi vibeutils-test:ubuntu-24.04 vibeutils-test:ubuntu-latest vibeutils-test:debian-12 vibeutils-test:alpine 2>/dev/null || true

# Help System
help:
	@echo "vibeutils - Modern implementation of GNU coreutils in Zig"
	@echo ""
	@echo "Common Targets:"
	@echo "  make build                 Build all utilities (debug mode)"
	@echo "  make build UTIL=<name>     Build a specific utility (e.g., make build UTIL=chown)"
	@echo "  make test                  Run all tests"
	@echo "  make test UTIL=<name>      Test a specific utility (e.g., make test UTIL=chown)"
	@echo "  make test-all              Run tests on all platforms (native + Docker if available)"
	@echo "  make install               Install utilities to ~/.local/bin"
	@echo "  make clean                 Remove build artifacts"
	@echo ""
	@echo "Testing:"
	@echo "  make test-privileged       Run tests requiring elevated permissions (fakeroot)"
	@echo "  make coverage              Generate test coverage report"
	@echo "  make test-linux            Run tests in Ubuntu Docker container"
	@echo ""
	@echo "Integration Testing:"
	@echo "  make it                    Run all integration tests"
	@echo "  make it UTIL=<name>        Run tests for specific utility"
	@echo "  make it-list               List available test utilities"
	@echo ""
	@echo "Development:"
	@echo "  make run UTIL=<name> ARGS= Run a specific utility (e.g., make run UTIL=echo ARGS='hello')"
	@echo "  make fmt                   Format all Zig code"
	@echo "  make docs                  Generate HTML documentation"
	@echo "  make docker-shell          Open shell in test container"
	@echo ""
	@echo "Release:"
	@echo "  make release VERSION=X.Y.Z Bump version, tag, push, trigger CI release"
	@echo "  make build-release         Build optimized binaries (ReleaseSmall)"
	@echo ""
	@echo "For more details on any target, see the Makefile or run 'make <target>'"

# Integration Testing - Comprehensive Architecture
it: build
ifdef UTIL
	@echo "Running comprehensive tests for $(UTIL) utility..."
	@tests/integration.sh $(UTIL)
else
	@echo "Running integration tests for all utilities..."
	@tests/integration.sh
endif

it-list: build
	@echo "Listing available utilities for testing..."
	@tests/integration.sh --list

test-integration-validate: build
	@echo "Validating integration test infrastructure..."
	@echo "Testing that help flag works for key utilities..."
	@for util in echo cat chmod; do \
		if [ -x zig-out/bin/$$util ]; then \
			echo "✓ Testing $$util --help"; \
			zig-out/bin/$$util --help >/dev/null 2>&1 || echo "⚠ $$util --help failed"; \
		else \
			echo "⚠ $$util binary not found"; \
		fi; \
	done


benchmark: build
	@echo "Running performance benchmarks..."
	@RUN_BENCHMARKS=1 zig test src/integration_tests.zig --main-mod-path . --deps common --test-filter "benchmark"
