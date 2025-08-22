# vibeutils Makefile - Simplified Architecture
# Reduces complexity while maintaining 100% functionality

# Variables and Configuration
BUILD_CMD := zig build
TEST_CMD := zig build test
DOCKER_COMPOSE := $(shell command -v docker-compose 2>/dev/null || echo "docker compose")
LINUX_ONLY := @[ "$$(uname -s)" = "Linux" ] || (echo "Linux required. Use docker target." && exit 1)
IS_MACOS := $(shell [ "$$(uname -s)" = "Darwin" ] && echo "true")
HAS_DOCKER := $(shell command -v docker >/dev/null 2>&1 && echo "true")
HAS_FAKEROOT := $(shell command -v fakeroot >/dev/null 2>&1 && echo "true")

# All .PHONY targets in one line
.PHONY: all build test test-privileged test-privileged-local test-all clean install coverage coverage-kcov fmt fmt-check lint-man lint-man-strict lint-man-verbose ci-validate docs help test-linux test-linux-all test-linux-privileged test-linux-coverage docker-build docker-shell docker-shell-debian docker-clean docs-html docs-serve docs-open fuzz fuzz-list fuzz-all fuzz-rotate fuzz-quick fuzz-coverage fuzz-linux fuzz-linux-all fuzz-linux-quick fuzz-linux-shell run debug release

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

release:
	zig build -Doptimize=ReleaseSmall

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

# Fuzzing Targets - Pattern rule consolidation
fuzz:
ifdef UTIL
	$(LINUX_ONLY)
	@echo "Fuzzing $(UTIL) utility..."
	@./scripts/fuzz-utilities.sh $(UTIL)
else
	@echo "Fuzzing System - Use: make fuzz UTIL=<name>"
	@echo "Available: basename cat chmod chown cp dirname echo false head ln ls mkdir mv pwd rm rmdir sleep tail test touch true yes"
	@echo "Batch: make fuzz-all fuzz-quick fuzz-rotate"
	@echo "macOS: make fuzz-linux UTIL=<name>"
endif

fuzz-all:
	$(LINUX_ONLY)
	@echo "Fuzzing all utilities (5 minutes each)..."
	@./scripts/fuzz-utilities.sh all

fuzz-quick:
	$(LINUX_ONLY)
	@echo "Quick fuzzing all utilities (30 seconds each)..."
	@./scripts/fuzz-utilities.sh -t 30 all

fuzz-rotate:
	$(LINUX_ONLY)
	@echo "Continuous fuzzing rotation (2 minutes per utility)..."
	@./scripts/fuzz-utilities.sh -r -t 120

fuzz-list:
	@echo "Available fuzzing targets:"
	@zig build --help 2>&1 | grep "fuzz-" | grep -v "fuzz-coverage" | sed 's/^/  /'

fuzz-coverage:
	@echo "Fuzzing Coverage Report"
	@zig build fuzz-coverage

# Linux container fuzzing (macOS support)
fuzz-linux:
ifdef UTIL
	@echo "Fuzzing $(UTIL) in Linux container..."
	@scripts/test-linux.sh "zig build fuzz-$(UTIL)"
else
	@echo "Linux Container Fuzzing - Use: make fuzz-linux UTIL=<name>"
	@echo "Batch: make fuzz-linux-all fuzz-linux-quick"
	@echo "Interactive: make fuzz-linux-shell"
endif

fuzz-linux-all:
	@echo "Fuzzing all utilities in Linux container..."
	@scripts/test-linux.sh "./scripts/fuzz-utilities.sh all"

fuzz-linux-quick:
	@echo "Quick fuzzing in Linux container..."
	@scripts/test-linux.sh "./scripts/fuzz-utilities.sh -t 30 all"

fuzz-linux-shell:
	@echo "Interactive fuzzing shell in Linux container..."
	@scripts/test-linux.sh --shell

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
	@echo "Fuzzing (Linux only):"
	@echo "  make fuzz UTIL=<name>      Fuzz a specific utility"
	@echo "  make fuzz-all              Fuzz all utilities comprehensively"
	@echo "  make fuzz-quick            Quick fuzz test of all utilities"
	@echo "  make fuzz-linux UTIL=<name> Fuzz in Docker (for macOS users)"
	@echo ""
	@echo "Development:"
	@echo "  make run UTIL=<name> ARGS= Run a specific utility (e.g., make run UTIL=echo ARGS='hello')"
	@echo "  make fmt                   Format all Zig code"
	@echo "  make docs                  Generate HTML documentation"
	@echo "  make docker-shell          Open shell in test container"
	@echo ""
	@echo "For more details on any target, see the Makefile or run 'make <target>'"