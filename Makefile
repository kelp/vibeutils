.PHONY: all build test test-privileged test-privileged-local test-all clean install coverage coverage-kcov fmt fmt-check lint-man lint-man-strict lint-man-verbose ci-validate docs help \
        test-linux test-linux-all test-linux-privileged test-linux-coverage docker-build docker-shell docker-shell-debian docker-clean docs-html docs-serve docs-open

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
		docker-compose -f docker-compose.test.yml down -v; \
	else \
		docker compose -f docker-compose.test.yml down -v; \
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