.PHONY: all build test test-privileged test-privileged-local test-all clean install coverage coverage-kcov fmt fmt-check lint-man lint-man-strict lint-man-verbose ci-validate docs help \
        test-linux test-linux-all test-linux-privileged test-linux-coverage docker-build docker-shell docker-shell-debian docker-clean docs-html docs-serve docs-open \
        fuzz fuzz-list fuzz-all fuzz-rotate fuzz-quick fuzz-coverage fuzz-linux fuzz-linux-all fuzz-linux-quick fuzz-linux-shell

# Default target
all: build

# Build all utilities
build:
	zig build

# Run tests
test:
	zig build test

# Run tests with privilege simulation (requires fakeroot)
test-privileged:
	@if ! command -v fakeroot >/dev/null 2>&1; then \
		echo "Error: fakeroot is required but not installed"; \
		echo "Install with: sudo apt-get install fakeroot (Debian/Ubuntu)"; \
		echo "           or: brew install fakeroot (macOS - may not work)"; \
		exit 1; \
	fi
	@echo "Running privileged tests with fakeroot..."
	@fakeroot zig build test-privileged

# Run privileged tests with available tools (graceful fallback)
test-privileged-local:
	@echo "Running privileged tests with best available method..."
	@scripts/run-privileged-tests.sh

# Run all tests across all available platforms
test-all:
	@echo "═══════════════════════════════════════════════════════════"
	@echo "Running all tests across all available platforms"
	@echo "═══════════════════════════════════════════════════════════"
	@echo ""
	@OS=$$(uname -s); \
	if [ "$$OS" = "Darwin" ]; then \
		echo "🍎 Detected macOS - will run native + Linux Docker tests"; \
		echo ""; \
		echo "▶ Running native macOS tests..."; \
		$(MAKE) test || exit 1; \
		echo ""; \
		echo "▶ Running privileged tests (with fallback)..."; \
		$(MAKE) test-privileged-local || exit 1; \
		echo ""; \
		if command -v docker >/dev/null 2>&1; then \
			echo "▶ Running Linux tests in Docker containers..."; \
			$(MAKE) test-linux-all || exit 1; \
			echo ""; \
			echo "▶ Running Linux privileged tests..."; \
			$(MAKE) test-linux-privileged || exit 1; \
		else \
			echo "⚠️  Docker not found - skipping Linux tests"; \
		fi; \
	elif [ "$$OS" = "Linux" ]; then \
		echo "🐧 Detected Linux - will run native tests only"; \
		echo ""; \
		echo "▶ Running native Linux tests..."; \
		$(MAKE) test || exit 1; \
		echo ""; \
		echo "▶ Running privileged tests..."; \
		$(MAKE) test-privileged-local || exit 1; \
	else \
		echo "❓ Unknown OS: $$OS - running basic tests only"; \
		$(MAKE) test || exit 1; \
	fi; \
	echo ""; \
	echo "═══════════════════════════════════════════════════════════"; \
	echo "✅ All tests completed successfully!"; \
	echo "═══════════════════════════════════════════════════════════"

# Run tests with native Zig coverage
coverage:
	zig build coverage

# Run tests with kcov coverage
coverage-kcov:
	zig build coverage -Dcoverage-backend=kcov

# Fuzzing targets - Selective fuzzing system for individual utilities
# All fuzzing runs in isolated /tmp directory to avoid filesystem pollution
# Usage: make fuzz          - Show fuzzing help
#        make fuzz UTIL=cat - Fuzz specific utility
#        make fuzz-all      - Fuzz all utilities sequentially
#        make fuzz-rotate   - Continuous rotation through utilities
#        make fuzz-quick    - Quick 30-second fuzz of each utility
fuzz:
ifdef UTIL
	@echo "🎯 Fuzzing $(UTIL) utility in isolated environment..."
	@if [ "$$(uname -s)" = "Linux" ]; then \
		./scripts/fuzz-utilities.sh $(UTIL); \
	else \
		echo "⚠️  Fuzzing only works on Linux. Use 'make fuzz-linux UTIL=$(UTIL)' for Docker-based fuzzing."; \
		exit 1; \
	fi
else
	@echo "Fuzzing Targets - Selective Fuzzing System"
	@echo "==========================================="
	@echo ""
	@echo "Individual utility fuzzing:"
	@echo "  make fuzz UTIL=cat       - Fuzz the cat utility"
	@echo "  make fuzz UTIL=echo      - Fuzz the echo utility"
	@echo "  make fuzz UTIL=ls        - Fuzz the ls utility"
	@echo "  (Available: basename cat chmod chown cp dirname echo false head ln ls mkdir mv pwd rm rmdir sleep tail test touch true yes)"
	@echo ""
	@echo "Batch fuzzing:"
	@echo "  make fuzz-all            - Fuzz all utilities (5 min each)"
	@echo "  make fuzz-quick          - Quick fuzz all utilities (30s each)"
	@echo "  make fuzz-rotate         - Continuous rotation (2 min each)"
	@echo ""
	@echo "⚠️  All fuzzing runs in /tmp to avoid creating junk files"
	@echo ""
	@echo "Advanced options:"
	@echo "  make fuzz-list           - List all available fuzz targets"
	@echo "  make fuzz-coverage       - Show fuzzing coverage report"
	@echo ""
	@echo "For macOS users:"
	@echo "  make fuzz-linux UTIL=cat - Run in Linux container"
	@echo ""
	@echo "Direct script usage:"
	@echo "  ./scripts/fuzz-utilities.sh -h   - See all script options"
endif

# List all available fuzz targets
fuzz-list:
	@echo "Available fuzzing targets:"
	@echo "=========================="
	@zig build --help 2>&1 | grep "fuzz-" | grep -v "fuzz-coverage" | sed 's/^/  /'

# Fuzz all utilities sequentially with default timeout
fuzz-all:
	@echo "🔄 Fuzzing all utilities sequentially (5 minutes each)..."
	@if [ "$$(uname -s)" = "Linux" ]; then \
		./scripts/fuzz-utilities.sh all; \
	else \
		echo "⚠️  Fuzzing only works on Linux. Use 'make fuzz-linux' for Docker-based fuzzing."; \
		exit 1; \
	fi

# Quick fuzzing - 30 seconds per utility
fuzz-quick:
	@echo "⚡ Quick fuzzing all utilities (30 seconds each)..."
	@if [ "$$(uname -s)" = "Linux" ]; then \
		./scripts/fuzz-utilities.sh -t 30 all; \
	else \
		echo "⚠️  Fuzzing only works on Linux. Use 'make test-linux' instead."; \
		exit 1; \
	fi

# Continuous rotation mode
fuzz-rotate:
	@echo "♻️  Starting continuous fuzzing rotation (2 minutes per utility)..."
	@echo "Press Ctrl+C to stop"
	@if [ "$$(uname -s)" = "Linux" ]; then \
		./scripts/fuzz-utilities.sh -r -t 120; \
	else \
		echo "⚠️  Fuzzing only works on Linux. Use 'make fuzz-linux' for Docker-based fuzzing."; \
		exit 1; \
	fi

# Show fuzzing coverage report
fuzz-coverage:
	@echo "📊 Fuzzing Coverage Report"
	@echo "========================="
	@zig build fuzz-coverage

# Clean build artifacts
clean:
	zig build clean

# Install utilities
install:
	zig build -Doptimize=ReleaseSafe
	@echo "Binaries installed to: zig-out/bin/"

# Run specific utility
run-%:
	zig build run-$* -- $(ARGS)

# Development build with debug info
debug:
	zig build -Doptimize=Debug

# Release build (smallest size)
release:
	zig build -Doptimize=ReleaseSmall

# Format code
fmt:
	zig build fmt

# Check code formatting
fmt-check:
	zig build fmt-check

# Man page linting
lint-man:
	@echo "Linting man pages..."
	@./scripts/lint-man-pages.sh

lint-man-strict:
	@echo "Linting man pages (strict mode)..."
	@./scripts/lint-man-pages.sh --fail-on-warnings

lint-man-verbose:
	@echo "Linting man pages (verbose)..."
	@./scripts/lint-man-pages.sh --verbose

# CI validation
ci-validate:
	zig build ci-validate -Dci=true

# Generate documentation
docs:
	zig build docs
	@echo "API documentation generated in zig-out/docs/"
	@echo "Open zig-out/docs/*/index.html in a browser to view."

docs-html: docs
	@echo "Generating full HTML documentation site..."
	@./scripts/generate-docs.sh

docs-serve: docs-html
	@echo "Starting local documentation server on http://localhost:8000"
	@cd docs/html && python3 -m http.server 8000

docs-open: docs-html
	@echo "Opening documentation in browser..."
	@./scripts/generate-docs.sh --open

# Docker-based Linux testing targets (for macOS development)
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

# Fuzzing in Linux container (for macOS development)
# Usage: make fuzz-linux          - Show fuzzing help in container
#        make fuzz-linux UTIL=cat - Fuzz specific utility in container
#        make fuzz-linux-all      - Fuzz all utilities in container
fuzz-linux:
ifdef UTIL
	@echo "🎯 Fuzzing $(UTIL) utility in Linux container..."
	@scripts/test-linux.sh "zig build fuzz-$(UTIL)"
else
	@echo "Fuzzing in Linux Container (for macOS users)"
	@echo "============================================"
	@echo ""
	@echo "Individual utility:"
	@echo "  make fuzz-linux UTIL=cat      - Fuzz cat in container"
	@echo "  make fuzz-linux UTIL=echo     - Fuzz echo in container"
	@echo ""
	@echo "Batch operations:"
	@echo "  make fuzz-linux-all           - Fuzz all utilities"
	@echo "  make fuzz-linux-quick         - Quick 30s fuzz per utility"
	@echo ""
	@echo "Interactive:"
	@echo "  make fuzz-linux-shell         - Shell for manual fuzzing"
endif

# Fuzz all utilities in Linux container
fuzz-linux-all:
	@echo "🔄 Fuzzing all utilities in Linux container (5 min each)..."
	@scripts/test-linux.sh "./scripts/fuzz-utilities.sh all"

# Quick fuzzing in Linux container
fuzz-linux-quick:
	@echo "⚡ Quick fuzzing in Linux container (30s each)..."
	@scripts/test-linux.sh "./scripts/fuzz-utilities.sh -t 30 all"

fuzz-linux-shell:
	@echo "Starting interactive shell for fuzzing in Linux container..."
	@echo "Run: ./scripts/fuzz-utilities.sh -h   for help"
	@echo "Run: zig build fuzz-<utility>        for individual fuzzing"
	@scripts/test-linux.sh --shell

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
	@if command -v docker-compose >/dev/null 2>&1; then \
		docker-compose -f docker/docker-compose.test.yml down -v; \
	else \
		docker compose -f docker/docker-compose.test.yml down -v; \
	fi
	@docker rmi vibeutils-test:ubuntu-24.04 vibeutils-test:ubuntu-latest vibeutils-test:debian-12 vibeutils-test:alpine 2>/dev/null || true

# Show help
help:
	@echo "vibeutils Makefile targets:"
	@echo ""
	@echo "Build targets:"
	@echo "  make build               - Build all utilities (default)"
	@echo "  make debug               - Build with debug info"
	@echo "  make release             - Build optimized for size"
	@echo "  make install             - Build optimized binaries"
	@echo "  make clean               - Remove build artifacts"
	@echo ""
	@echo "Test targets:"
	@echo "  make test                - Run all tests"
	@echo "  make test-all            - Run ALL tests (native + cross-platform)"
	@echo "  make test-privileged     - Run privileged tests (requires fakeroot)"
	@echo "  make test-privileged-local - Run privileged tests with fallback"
	@echo "  make coverage            - Run tests with native coverage"
	@echo "  make coverage-kcov       - Run tests with kcov coverage"
	@echo ""
	@echo "Fuzzing targets (property-based testing):"
	@echo "  make fuzz                - Show fuzzing help and available targets"
	@echo "  make fuzz UTIL=cat       - Fuzz specific utility (Linux only)"
	@echo "  make fuzz-list           - List all available fuzz targets"
	@echo "  make fuzz-all            - Fuzz all utilities (5 min each)"
	@echo "  make fuzz-quick          - Quick fuzz all utilities (30s each)"
	@echo "  make fuzz-rotate         - Continuous rotation (2 min each)"
	@echo "  make fuzz-coverage       - Show fuzzing coverage report"
	@echo ""
	@echo "Fuzzing from macOS (Docker):"
	@echo "  make fuzz-linux          - Show fuzzing help for containers"
	@echo "  make fuzz-linux UTIL=cat - Fuzz specific utility in container"
	@echo "  make fuzz-linux-all      - Fuzz all utilities in container"
	@echo "  make fuzz-linux-quick    - Quick fuzzing in container"
	@echo "  make fuzz-linux-shell    - Interactive shell for fuzzing"
	@echo ""
	@echo "Linux testing from macOS (Docker):"
	@echo "  make test-linux          - Run tests in Ubuntu 24.04 container"
	@echo "  make test-linux-all      - Run tests on all Linux distributions"
	@echo "  make test-linux-privileged - Run privileged tests in container"
	@echo "  make test-linux-coverage - Run coverage tests in container"
	@echo "  make docker-build        - Build Docker test images"
	@echo "  make docker-shell        - Interactive Ubuntu 24.04 shell"
	@echo "  make docker-shell-debian - Interactive Debian 12 shell"
	@echo "  make docker-clean        - Clean Docker containers and images"
	@echo ""
	@echo "Development tools:"
	@echo "  make run-<utility>       - Run utility (e.g., make run-echo ARGS='hello')"
	@echo "  make fmt                 - Format source code"
	@echo "  make fmt-check           - Check code formatting"
	@echo "  make lint-man            - Lint all man pages"
	@echo "  make lint-man-strict     - Lint man pages (fail on warnings)"
	@echo "  make lint-man-verbose    - Lint man pages with detailed output"
	@echo "  make ci-validate         - Run CI validation checks"
	@echo ""
	@echo "Documentation:"
	@echo "  make docs                - Generate API documentation"
	@echo "  make docs-html           - Generate full HTML documentation site"
	@echo "  make docs-serve          - Start local documentation server"
	@echo "  make docs-open           - Open documentation in browser"