# vibeutils

Cross-platform Unix utilities in Zig, inspired by GNU coreutils and OpenBSD.

**MIT Licensed** • **Linux** • **macOS** • **BSD**

## Features

- 🚀 Fast, memory-safe implementations
- 🎨 Colored output with terminal detection
- 📊 Progress bars for long operations  
- 🔒 OpenBSD-inspired security and simplicity
- 💻 Full GNU compatibility for scripts

## Implemented Utilities

- ✅ `echo` - Display text
- ✅ `cat` - Concatenate files
- ✅ `ls` - List directory contents (with colors, icons, git status)
- ✅ `cp` - Copy files and directories  
- ✅ `mv` - Move/rename files
- ✅ `rm` - Remove files and directories
- ✅ `mkdir` - Create directories
- ✅ `rmdir` - Remove empty directories
- ✅ `touch` - Update file timestamps

More utilities coming soon!

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
# Run tests
zig build test

# Run specific utility
zig build run-echo -- "Hello, vibeutils!"

# Format code
make fmt
```

## License

MIT License - see [LICENSE](LICENSE) file.