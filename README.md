# vibeutils

Memory-safe Unix utilities written in Zig, inspired by GNU coreutils and OpenBSD.

**MIT Licensed** • **Linux** • **macOS** • **BSD**

## What's Different

vibeutils covers the 80% of GNU coreutils you actually use,
with modern terminal enhancements that activate
automatically.

**ls** gains the most:
- `--icons` — Nerd Font file type icons
- `--git` — inline git status per file
- `--time-style=relative` — "2 hours ago" instead of
  timestamps (default in long format)

![ls with icons, git status, and relative timestamps](docs/images/ls-icons.png)

![Colored help output with syntax highlighting](docs/images/cp-help.png)

**Across all utilities:**
- Colored `--help` with syntax-highlighted flags
- Smart terminal detection (NO_COLOR, 256-color, truecolor)
- Graceful degradation to plain text in pipes and dumb
  terminals

## Project Status

**Pre-1.0 (v0.8.0)**: 47 utilities with 100% POSIX flag
coverage (288 MUST + 220 SHOULD). Expect breaking changes
as we refine the design.

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

### Gale (Linux/macOS)

[Gale](https://github.com/kelp/gale) is a per-project
package manager; vibeutils ships as a recipe in the
[kelp/gale-recipes](https://github.com/kelp/gale-recipes)
repo.

```bash
# Add the recipe repo (once)
gale repo add https://github.com/kelp/gale-recipes

# Install globally
gale install -g vibeutils
```

Or pin it in a project's `gale.toml` and let direnv
activate the environment on `cd`:

```toml
[packages]
vibeutils = "0.9.3"
```

Gale installs use the original names (no prefix).

### Nix

```bash
# Try it out
nix shell github:kelp/vibeutils

# Build locally
nix build github:kelp/vibeutils
```

Prebuilt binaries are available via Cachix. Without
this, Nix builds from source (requires Zig):

```bash
cachix use vibeutils
```

#### Persistent install (nix-darwin / home-manager)

Add vibeutils as a flake input. Do **not** use
`inputs.nixpkgs.follows` — that changes the derivation
hash and forces a build from source instead of pulling
prebuilt binaries from Cachix.

```nix
# flake.nix
inputs.vibeutils.url = "github:kelp/vibeutils";
```

```nix
# home.nix
home.packages = [ inputs.vibeutils.packages.${pkgs.system}.default ];
```

The vibeutils flake lock is updated weekly via CI, so
its nixpkgs stays current.

Nix installs use original names (no prefix) since Nix
environments are isolated.

### Build from source

Requirements: the Zig version pinned in `build.zig.zon`
(`.minimum_zig_version`), currently 0.16.0.

```bash
git clone https://github.com/kelp/vibeutils.git
cd vibeutils
zig build -Doptimize=ReleaseSafe
```

Find binaries in `zig-out/bin/`.

No Zig yet? On Linux, CI, or in a container run `scripts/bootstrap.sh`. On
macOS use `brew install zig`, `nix develop`, or `gale`. See
[docs/TOOLCHAIN.md](docs/TOOLCHAIN.md).

## Development

```bash
just build          # Build all utilities
just test           # Run unit tests
just it             # Run integration tests
just coverage       # Coverage report
just fmt            # Format code
just                # List all recipes

# Single utility
just build-util grep
just test-util grep
just run grep -- -r TODO src/
```

### Testing

- Unit tests embedded in each source file
- Integration tests in `tests/utilities/`
- Privileged tests via fakeroot
- Target: 90%+ coverage

## License

MIT License - see [LICENSE](LICENSE) file.
