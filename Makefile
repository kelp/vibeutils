.PHONY: all build test clean install coverage help

# Default target
all: build

# Build all utilities
build:
	zig build

# Run tests
test:
	zig build test

# Run tests with coverage
coverage:
	@echo "Building tests..."
	@zig build test
	@echo "Running tests with coverage..."
	@mkdir -p coverage
	@find .zig-cache -name "test" -type f -executable | while read test_file; do \
		echo "Coverage for: $$test_file"; \
		kcov --exclude-pattern=/usr/lib,/usr/include coverage "$$test_file" || true; \
	done
	@echo "Coverage report: coverage/index.html"

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
	@echo "Zutils Makefile targets:"
	@echo "  make build     - Build all utilities (default)"
	@echo "  make test      - Run all tests"
	@echo "  make coverage  - Run tests with coverage report"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make install   - Build optimized binaries"
	@echo "  make run-echo  - Run echo utility (ARGS='arguments')"
	@echo "  make debug     - Build with debug info"
	@echo "  make release   - Build optimized for size"
	@echo "  make fmt       - Format source code"