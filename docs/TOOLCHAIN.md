# Toolchain Setup

How to get the tools vibeutils needs. For what to *do* with them, see
`CLAUDE.md` and `AGENTS.md`.

## What is required

| | |
| --- | --- |
| **Zig** | The version pinned by `.minimum_zig_version` in `build.zig.zon`. That file is the single authority — this doc deliberately does not repeat the number. |
| **bash 4.0+** | Integration tests only. macOS ships 3.2; `brew install bash` and put its bin directory ahead of `/bin`. |

Everything else is optional and only gates a specific `just` recipe. See
[Optional tools](#optional-tools).

## Getting Zig

Pick the row that matches where you are.

| Environment | How |
| --- | --- |
| **Agent container** (Claude Code on the web) | Automatic — a SessionStart hook runs `scripts/bootstrap.sh` in the background. Nothing to do. |
| **Linux, CI box, container, fresh clone** | `scripts/bootstrap.sh` |
| **This repo's dev shell** | `.envrc` is `use gale`; `gale` installs the pinned Zig via `gale.toml` |
| **Nix** | `nix develop` — `flake.nix` pins Zig through `mitchellh/zig-overlay` |
| **macOS, by hand** | `brew install zig` (verify the version matches the pin), or a tarball from <https://ziglang.org/download/> |
| **GitHub Actions** | `mlugg/setup-zig` — already wired into every workflow |
| **Docker images** | `docker/scripts/install-zig.sh <version>` |

## `scripts/bootstrap.sh`

One idempotent script that installs Zig, `just`, and the optional tools,
then proves the result works by running `zig build --list-steps`. Safe to
run repeatedly — a warm run finishes in under a second.

```bash
scripts/bootstrap.sh            # install everything missing
just setup                      # same thing, once just exists
scripts/bootstrap.sh --check    # report only, change nothing
scripts/bootstrap.sh --verbose  # stream the log to stderr
```

It reads the required Zig version out of `build.zig.zon` — it never carries
its own copy of the version.

### Where Zig comes from

Sources are tried in order; the first success wins.

1. `VIBEUTILS_ZIG_BIN` — an existing binary you point it at.
2. **The PyPI `ziglang` wheel** — the Zig project publishes the complete
   toolchain to PyPI. This is first among the download paths because it is
   the only source reachable from restricted networks (see
   [Agent containers](#agent-containers-claude-code-on-the-web)), and it
   works fine everywhere else. Skipped automatically for `-dev` pins, which
   have no PyPI release.
3. `VIBEUTILS_ZIG_URL` — a tarball URL you supply.
4. `docker/scripts/install-zig.sh` — the existing mirror-aware installer
   that pulls from ziglang.org and the community mirror list.

The wheel unpacks into `/opt/vibeutils-toolchain/zig-<version>/` and is
symlinked to `/usr/local/bin/zig`. The symlink is safe: Zig locates its
standard library by resolving `/proc/self/exe`, which follows symlinks.

On macOS with no Zig present the script installs nothing and tells you to
use Homebrew, `nix develop`, or `gale`.

### Knobs

| Flag | Effect |
| --- | --- |
| `--check` | Verify only; exit 1 if Zig is unusable |
| `--print-bin-dir` | Print the resolved bin directory and exit |
| `--skip-optional` | Do not touch apt |
| `--skip-hooks` | Do not set `core.hooksPath` |
| `--verbose` | Stream the log to stderr |

| Variable | Effect |
| --- | --- |
| `VIBEUTILS_ZIG_BIN` | Use this existing zig binary |
| `VIBEUTILS_ZIG_URL` | Fetch this tarball instead of using the mirror list |
| `VIBEUTILS_TOOLCHAIN_DIR` | Install root (default `/opt/vibeutils-toolchain`) |
| `VIBEUTILS_BIN_DIR` | Symlink target (default `/usr/local/bin`, else `~/.local/bin`) |

The full log is written to `$TMPDIR/vibeutils-bootstrap.log`.

### Git hooks

The script sets `core.hooksPath=.githooks` when it is unset, so the
pre-commit formatting and Tiger Style gates are active on a fresh clone
without anyone having to remember `just install-hooks`. If you already have
a custom `core.hooksPath` it is left alone.

## Optional tools

None of these block development. Each gates exactly one thing.

| Tool | Needed by | If missing |
| --- | --- | --- |
| `fakeroot` | `just test-privileged`, `just test-privileged-local` | Privileged tests cannot run |
| `mandoc` | `just lint-man*`, the man-page PostToolUse hook | Man-page lint silently no-ops |
| `hexdump` (apt: `bsdextrautils`) | `just it` — the `pwd` and `dirname` suites | Those tests fail on a bare `hexdump: command not found` |
| `kcov` | `just coverage` | Use CI, or `just test-linux-coverage` |
| `actionlint` | `just lint-actions` | Rely on CI |
| Docker daemon | `just test-linux*`, `just docker-shell*` | Rely on CI |
| `gh` | `just release-tag` | Releases cannot be cut from a container |

`scripts/bootstrap.sh` installs `fakeroot`, `mandoc` and `bsdextrautils`
via apt when it is running as root (so: containers and CI images, never
your laptop). It deliberately does **not** build `kcov` — that is a
from-source CMake build that only serves `just coverage`, which CI already
runs.

## Agent containers (Claude Code on the web)

Sessions run in a fresh, ephemeral Ubuntu container: the repo is re-cloned
each time and the container is reclaimed after inactivity. The SessionStart
hook at `.claude/hooks/session-start.sh` runs `scripts/bootstrap.sh`
**asynchronously**, so the session starts immediately while the toolchain
installs in the background.

**If you hit `zig: command not found`, run `scripts/bootstrap.sh`.** It
takes a lock, so it blocks until the background install finishes and then
no-ops. It is both the installer and the wait.

Egress is filtered by a policy proxy, which changes what works:

| Host | Status |
| --- | --- |
| `ziglang.org` and every Zig community mirror | **Blocked** (403 on CONNECT) |
| `pypi.org`, `files.pythonhosted.org` | Reachable — this is why the PyPI wheel is the primary Zig source |
| `github.com`, `registry.npmjs.org` | Reachable |
| Ubuntu main/universe apt archives | Reachable |
| Launchpad PPAs | Blocked; `apt-get update` prints warnings that are safe to ignore |

Do not spend time trying to reach ziglang.org or its mirrors from a
container — the bootstrap has already routed around them.

Other container differences:

- **You are already on Linux.** `orb -m ubuntu` does not exist here; run
  `zig build test` natively and let CI cover macOS.
- **You are running as uid 0**, and root bypasses DAC permission checks.
  This matters for any test whose premise is "this path is denied" — as
  root, nothing is denied, so the assertion cannot hold. Two mechanisms
  handle it, and both are already wired up:
  - **Integration tests**: `just it` goes through
    `scripts/run-integration.sh`, which drops to an unprivileged user
    (`vibedev`, created on demand) before running the suite. Without that,
    roughly two dozen "permission denied" tests across `cat`, `chmod`,
    `chown`, `grep`, `ls`, `rm`, `stat` and others fail for a reason that
    has nothing to do with the code. Set `VIBEUTILS_NO_DEMOTE=1` to run as
    root anyway.
  - **Unit tests**: privilege-dependent tests guard on
    `std.c.geteuid() == 0` and skip. See `src/common/walker.zig` and
    `src/common/file_ops.zig` for the pattern; add the same guard to any
    new permission-dependent test rather than letting it fail for everyone
    working in a container.

  CI runs unprivileged, so all of these still have teeth there.
- **Docker-in-container is not usable**, so `just test-linux*` and
  `just docker-shell*` will not work. CI covers those matrices.
- **Commit signing is pre-configured** by the environment (`gpg.ssh.program`
  plus a provisioned key) and works. There is no 1Password agent to wait
  for, so a signing failure here is a real problem to report, not something
  to sit out.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `zig: command not found` | `scripts/bootstrap.sh` — it waits for any in-flight install, then no-ops |
| `just: command not found` | `scripts/bootstrap.sh`, or skip it: `zig build test` and `./scripts/run-integration.sh` do the same work |
| Wrong Zig version | `scripts/bootstrap.sh --check` reports it; delete `/opt/vibeutils-toolchain` and re-run to force a reinstall |
| Bootstrap failed and named every source | Point `VIBEUTILS_ZIG_URL` at a reachable tarball or `VIBEUTILS_ZIG_BIN` at an existing binary |
| Commit aborted right after files were reformatted | Working as designed — the pre-commit hook runs `zig build fmt`, then aborts so you can review. Re-commit. |
| `just coverage` says kcov is missing | Expected; coverage runs in CI |
| Integration tests fail to start | They need bash 4.0+; macOS ships 3.2 |

## For maintainers

**CI does not use this script, on purpose.** All GitHub Actions workflows
use `mlugg/setup-zig`, which caches the toolchain across runs and is
strictly better on GitHub runners. Do not "unify" the workflows onto
`scripts/bootstrap.sh`.

The pinned Zig version is repeated in several files. `build.zig.zon` is the
authority; the rest must be updated together when it changes:

- `build.zig.zon` — `.minimum_zig_version` (authoritative)
- `flake.nix` — the `zig-overlay` package
- `gale.toml` / `gale.lock`
- `docker/test/Dockerfile.test` — `ARG ZIG_VERSION`
- `docker/configs/env.conf`
- `docker/docker-compose.test.yml`
- `.github/workflows/{test,integration,docs,release}.yml` — `mlugg/setup-zig`
