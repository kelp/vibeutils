# vibeutils

Memory-safe Unix utilities written in Zig, inspired by GNU coreutils and OpenBSD.

**MIT Licensed** • **Linux** • **macOS** • **BSD**

## Features

- 🎨 Colored output with terminal detection
- 🚀 Fast, memory-safe implementations
- 💻 GNU compatibility for scripts
- 🔒 OpenBSD-inspired security and simplicity
- 📊 Progress bars for long operations

## Project Status

**Pre-1.0**: Expect breaking changes as we refine the design. 24 utilities implemented with comprehensive test coverage.

### Implemented Utilities

- ✅ `basename` - Strip directory and suffix from filenames
- ✅ `cat` - Concatenate and display files
- ✅ `chmod` - Change file permissions
- ✅ `chown` - Change file ownership
- ✅ `cp` - Copy files and directories with progress indication
- ✅ `dirname` - Extract directory from path
- ✅ `echo` - Display text
- ✅ `false` - Return unsuccessful exit status
- ✅ `head` - Display first lines of files
- ✅ `ln` - Create links (hard and symbolic)
- ✅ `ls` - List directory contents with colors and icons
- ✅ `mkdir` - Create directories
- ✅ `mv` - Move/rename files and directories
- ✅ `pwd` - Print working directory
- ✅ `rm` - Remove files and directories safely
- ✅ `rmdir` - Remove empty directories
- ✅ `sleep` - Delay for specified time
- ✅ `tail` - Display last lines of files
- ✅ `tee` - Write to stdout and files simultaneously
- ✅ `test` - Evaluate conditional expressions
- ✅ `touch` - Update file timestamps
- ✅ `true` - Return successful exit status
- ✅ `wc` - Count lines, words, and characters
- ✅ `yes` - Output string repeatedly until killed

### Coming Soon
Text processing utilities (sort, uniq) and file information tools (stat, du, df).

## Installation

### Build from source

Requirements: Zig 0.15.2 or later

```bash
git clone https://github.com/kelp/vibeutils.git
cd vibeutils
zig build -Doptimize=ReleaseSafe
```

Find binaries in `zig-out/bin/`.

### macOS (Homebrew) - Coming Soon

```bash
brew install kelp/tap/vibeutils
```

Commands install with a `v` prefix (vls, vcp, vmv) to avoid conflicts with system utilities.

Use without prefix:
```bash
# Add vibebin to PATH
export PATH="$(brew --prefix)/opt/vibeutils/libexec/vibebin:$PATH"

# Or create aliases
alias ls='vls'
alias cp='vcp'
```

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

# Run tests
make test

# Run tests with coverage
make coverage  # Report: coverage/index.html

# Run privileged tests (requires fakeroot)
make test-privileged-local

# Run specific utility
make run-echo ARGS="Hello, vibeutils!"

# Format code
make fmt

# See all targets
make help
```

### Testing

- Cross-platform testing on BSD, Linux, and macOS
- Privileged operation tests using fakeroot
- Target: 90%+ coverage via kcov
- Unit tests embedded in source files

## License

MIT License - see [LICENSE](LICENSE) file.
