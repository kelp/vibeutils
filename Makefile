.PHONY: all build test test-privileged test-privileged-local clean install coverage coverage-kcov fmt fmt-check ci-validate docs help

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

# CI validation
ci-validate:
	zig build ci-validate -Dci=true

# Generate documentation
docs:
	zig build docs
	@echo "Documentation generated in zig-out/docs/"
	@echo "Open zig-out/docs/*/index.html in a browser to view."

# Show help
help:
	@echo "vibeutils Makefile targets:"
	@echo "  make build               - Build all utilities (default)"
	@echo "  make test                - Run all tests"
	@echo "  make test-privileged     - Run privileged tests (requires fakeroot)"
	@echo "  make test-privileged-local - Run privileged tests with fallback"
	@echo "  make coverage            - Run tests with native coverage"
	@echo "  make coverage-kcov       - Run tests with kcov coverage"
	@echo "  make clean               - Remove build artifacts"
	@echo "  make install             - Build optimized binaries"
	@echo "  make run-<utility>       - Run utility (e.g., make run-echo ARGS='hello')"
	@echo "  make debug               - Build with debug info"
	@echo "  make release             - Build optimized for size"
	@echo "  make fmt                 - Format source code"
	@echo "  make fmt-check           - Check code formatting"
	@echo "  make ci-validate         - Run CI validation checks"
	@echo "  make docs                - Generate API documentation"