.PHONY: all build test test-privileged test-privileged-local clean install coverage help

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

# Run tests with coverage using Zig's native coverage
coverage:
	@echo "Running tests with coverage..."
	@mkdir -p coverage
	@zig build test -Dcoverage=true 2>&1 | tee coverage/test_output.log
	@echo "Coverage information saved to coverage/"
	@echo "Note: Native Zig coverage support is still evolving."
	@echo "For detailed coverage reports, consider using external tools like kcov."

# Clean build artifacts
clean:
	rm -rf zig-cache zig-out coverage

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
	zig fmt src/

# Show help
help:
	@echo "vibeutils Makefile targets:"
	@echo "  make build               - Build all utilities (default)"
	@echo "  make test                - Run all tests"
	@echo "  make test-privileged     - Run privileged tests (requires fakeroot)"
	@echo "  make test-privileged-local - Run privileged tests with fallback"
	@echo "  make coverage            - Run tests with coverage report"
	@echo "  make clean               - Remove build artifacts"
	@echo "  make install             - Build optimized binaries"
	@echo "  make run-echo            - Run echo utility (ARGS='arguments')"
	@echo "  make debug               - Build with debug info"
	@echo "  make release             - Build optimized for size"
	@echo "  make fmt                 - Format source code"