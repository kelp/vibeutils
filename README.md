# vibeutils

Modern, memory-safe Unix utilities written in Zig, inspired by GNU coreutils and OpenBSD.

**MIT Licensed** • **Linux** • **macOS** • **BSD**

## Features

- 🚀 Fast, memory-safe implementations
- 🎨 Colored output with terminal detection
- 📊 Progress bars for long operations  
- 🔒 OpenBSD-inspired security and simplicity
- 💻 Full GNU compatibility for scripts

## Project Status

**Pre-1.0**: Breaking changes are expected as we refine the design. Currently at 14 utilities with 213+ tests.

### Implemented Utilities

- ✅ `echo` - Display text
- ✅ `cat` - Concatenate and display files
- ✅ `ls` - List directory contents with colors and icons
- ✅ `cp` - Copy files and directories with progress indication
- ✅ `mv` - Move/rename files and directories
- ✅ `rm` - Remove files and directories safely
- ✅ `mkdir` - Create directories
- ✅ `rmdir` - Remove empty directories
- ✅ `touch` - Update file timestamps
- ✅ `pwd` - Print working directory
- ✅ `chmod` - Change file permissions
- ✅ `chown` - Change file ownership
- ✅ `ln` - Create links (hard and symbolic)

### Coming Soon
Text processing utilities (head, tail, wc, sort, uniq) and file information tools (stat, du, df).

## Installation

### macOS (Homebrew)

```bash
# Coming soon!
brew install kelp/tap/vibeutils
```

By default, commands are installed with a `v` prefix (vls, vcp, vmv, etc.) to avoid conflicts with system utilities.

To use vibeutils commands without the prefix:
```bash
# Option 1: Add vibebin to your PATH
export PATH="$(brew --prefix)/opt/vibeutils/libexec/vibebin:$PATH"

# Option 2: Source the activation script
source $(brew --prefix)/opt/vibeutils/libexec/activate.sh

# Option 3: Create aliases
alias ls='vls'
alias cp='vcp'
# ... etc
```

### Build from source

Requirements: Zig 0.14.1 or later

```bash
git clone https://github.com/kelp/vibeutils.git
cd vibeutils
zig build -Doptimize=ReleaseSafe
```

Binaries will be in `zig-out/bin/`.

### Install system-wide (macOS/Linux)

```bash
# Standard installation with 'v' prefix
sudo ./scripts/install-macos.sh

# Install to custom location (e.g., Homebrew on Apple Silicon)
sudo ./scripts/install-macos.sh --dir /opt/homebrew

# Install without prefix (replaces system utilities - use with caution!)
sudo ./scripts/install-macos.sh --default-names
```

## Usage

All utilities support standard GNU options plus modern enhancements:

```bash
# Colorful ls with git status
ls -la

# Copy with progress bar
cp -r large_directory/ destination/

# Safe rm with prompts
rm -i important.txt
```

## Development

```bash
# Build all utilities
make build

# Run all tests (213+ tests)
make test

# Run tests with coverage report
make coverage
# View report at coverage/index.html

# Run privileged tests (requires fakeroot)
make test-privileged-local

# Run specific utility
make run-echo ARGS="Hello, vibeutils!"
make run-ls ARGS="-la"

# Format code
make fmt

# Generate documentation
make docs

# See all available targets
make help
```

### Testing

We maintain comprehensive test coverage with 213+ tests:
- Unit tests embedded in each utility source file
- Privileged operation tests for chmod/chown (run under fakeroot)
- Cross-platform testing on Linux, macOS, and BSD
- Coverage reports via kcov showing 90%+ coverage targets

## License

MIT License - see [LICENSE](LICENSE) file.