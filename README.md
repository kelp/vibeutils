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

**Pre-1.0**: 47 utilities implemented with comprehensive test
coverage. Expect breaking changes as we refine the design.

### Implemented Utilities

**File Operations**
`cat` `cp` `dd` `ln` `mkdir` `mktemp` `mv` `rm` `rmdir`
`touch`

**File Information**
`df` `du` `find` `ls` `readlink` `realpath` `stat`

**Text Processing**
`cut` `grep` `head` `nl` `sort` `tac` `tail` `tee` `tr`
`uniq` `wc`

**Path & Names**
`basename` `dirname` `pwd`

**User & Permissions**
`chmod` `chown` `id` `whoami`

**System & Process**
`date` `env` `free` `seq` `sleep` `timeout`

**Output & Control**
`echo` `false` `printf` `test` `true` `yes`

## Installation

### Homebrew (macOS/Linux)

```bash
brew install kelp/tap/vibeutils
```

Commands install with a `v` prefix (vls, vcp, vmv) to avoid
conflicts with system utilities. To use without prefix:

```bash
export PATH="$(brew --prefix)/opt/vibeutils/libexec/vibebin:$PATH"
```

### Nix

```bash
# Try it out
nix shell github:kelp/vibeutils

# Build locally
nix build github:kelp/vibeutils
```

For faster installs with prebuilt binaries, use the Cachix
binary cache:

```bash
cachix use vibeutils
nix shell github:kelp/vibeutils
```

Nix installs use original names (no prefix) since Nix
environments are isolated.

### Build from source

Requirements: Zig 0.15.2 or later

```bash
git clone https://github.com/kelp/vibeutils.git
cd vibeutils
zig build -Doptimize=ReleaseSafe
```

Find binaries in `zig-out/bin/`.

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
make build          # Build all utilities
make test           # Run unit tests
make it             # Run integration tests
make coverage       # Coverage report
make fmt            # Format code
make help           # All targets

# Single utility
make build UTIL=grep
make test UTIL=grep
make run UTIL=grep ARGS="-r TODO src/"
```

### Testing

- Unit tests embedded in each source file
- Integration tests in `tests/utilities/`
- Fuzz tests for all utilities (Linux)
- Privileged tests via fakeroot
- Target: 90%+ coverage

## License

MIT License - see [LICENSE](LICENSE) file.
