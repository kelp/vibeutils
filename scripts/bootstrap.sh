#!/usr/bin/env bash
# Install the toolchain vibeutils needs: the pinned Zig, just, and the
# optional tools (mandoc, fakeroot). Idempotent and safe to re-run.
#
# This is the single implementation. It is called by `just setup`, by
# .claude/hooks/session-start.sh in agent containers, and by humans on a
# fresh clone. Nothing duplicates its logic.
#
# Because it serializes on a lock file, running it while another copy is
# still installing simply blocks until that copy finishes and then no-ops.
# That makes it both the installer and the "wait for the installer".
#
# Usage: scripts/bootstrap.sh [--check] [--print-bin-dir] [--skip-optional]
#                             [--skip-hooks] [--verbose]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}"
LOCK_FILE="$TMP_DIR/vibeutils-bootstrap.lock"
LOG_FILE="$TMP_DIR/vibeutils-bootstrap.log"

TOOLCHAIN_DIR="${VIBEUTILS_TOOLCHAIN_DIR:-/opt/vibeutils-toolchain}"

opt_check=0
opt_print_bin_dir=0
opt_skip_optional=0
opt_skip_hooks=0
opt_verbose=0

# Every failure the user needs to hear about, collected so the summary can
# report them together instead of scattering them through the log.
warnings=()

usage() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

log() {
    printf '%s\n' "$*" >>"$LOG_FILE"
    if [ "$opt_verbose" -eq 1 ]; then
        printf '%s\n' "$*" >&2
    fi
}

say() {
    printf 'bootstrap: %s\n' "$*"
}

warn() {
    warnings+=("$1")
    log "WARN: $1"
}

die() {
    printf 'bootstrap: FAILED — %s\n' "$1" >&2
    printf 'bootstrap: full log at %s\n' "$LOG_FILE" >&2
    exit 1
}

# Resolve the directory we own for symlinks. Prefer a system-wide location
# so subprocesses and non-login shells see the tools without a PATH export.
resolve_bin_dir() {
    if [ -n "${VIBEUTILS_BIN_DIR:-}" ]; then
        mkdir -p "$VIBEUTILS_BIN_DIR"
        printf '%s\n' "$VIBEUTILS_BIN_DIR"
        return
    fi
    # The redirect here binds to `[`, not to `if` — `if` is a keyword, and the
    # list it introduces is the simple command `[ ... ] 2>/dev/null`. It reads
    # as though it were misplaced and has been "fixed" more than once; it is
    # correct as written and silences `[` on the exotic cases (a dangling
    # symlink, an unreadable parent). A missing directory is simply false.
    if [ -w /usr/local/bin ] 2>/dev/null; then
        printf '%s\n' /usr/local/bin
        return
    fi
    mkdir -p "$HOME/.local/bin"
    printf '%s\n' "$HOME/.local/bin"
}

# The pin lives in build.zig.zon and nowhere else in this script. Adding a
# copy here would create yet another version string to keep in sync.
required_zig_version() {
    local version
    version=$(grep -m1 -E '^[[:space:]]*\.minimum_zig_version[[:space:]]*=' \
        "$PROJECT_ROOT/build.zig.zon" | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$version" ]; then
        die "could not read .minimum_zig_version from build.zig.zon"
    fi
    printf '%s\n' "$version"
}

# version_ge REQUIRED HAVE -> success when HAVE is at least REQUIRED.
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

have_required_zig() {
    local want="$1" have
    command -v zig >/dev/null 2>&1 || return 1
    have=$(zig version 2>/dev/null) || return 1
    version_ge "$want" "$have"
}

# --- zig ---------------------------------------------------------------

# Zig finds its lib/ directory by resolving /proc/self/exe, so a symlink
# into the bin dir keeps the standard library discoverable.
publish_zig() {
    local zig_bin="$1" bin_dir="$2"
    ln -sfn "$zig_bin" "$bin_dir/zig"
    log "symlinked $bin_dir/zig -> $zig_bin"
}

# The Zig project publishes the full toolchain as a PyPI wheel. That is the
# only source reachable from restricted networks (many agent containers and
# corporate proxies block ziglang.org outright), and it works everywhere
# else too, so it is tried first.
install_zig_from_pypi() {
    local want="$1" bin_dir="$2"
    local stage="$TOOLCHAIN_DIR/zig-$want.stage.$$"
    local final="$TOOLCHAIN_DIR/zig-$want"

    case "$want" in
        *-dev*)
            log "zig $want is a dev build; PyPI has no such release, skipping"
            return 1
            ;;
    esac

    mkdir -p "$TOOLCHAIN_DIR"
    rm -rf "$stage"

    log "installing ziglang==$want from PyPI into $stage"
    if ! python3 -m pip install --no-cache-dir --disable-pip-version-check \
        --target "$stage" "ziglang==$want" >>"$LOG_FILE" 2>&1; then
        # Some distributions refuse to install outside a virtualenv even
        # with --target (PEP 668).
        log "pip --target failed, retrying with --break-system-packages"
        if ! python3 -m pip install --no-cache-dir --disable-pip-version-check \
            --break-system-packages --target "$stage" "ziglang==$want" \
            >>"$LOG_FILE" 2>&1; then
            rm -rf "$stage"
            return 1
        fi
    fi

    # Ask the package where its binary lives rather than guessing a layout
    # or assuming a console script was generated.
    local zig_bin
    zig_bin=$(python3 -c 'import os, sys
sys.path.insert(0, sys.argv[1])
import ziglang
print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' "$stage" \
        2>>"$LOG_FILE") || { rm -rf "$stage"; return 1; }

    if [ ! -x "$zig_bin" ]; then
        log "expected zig binary at $zig_bin but it is missing or not executable"
        rm -rf "$stage"
        return 1
    fi

    # Prove the binary runs before anything points at it.
    local got
    got=$("$zig_bin" version 2>>"$LOG_FILE") || { rm -rf "$stage"; return 1; }
    if [ "$got" != "$want" ]; then
        log "PyPI wheel reported version $got, wanted $want"
        rm -rf "$stage"
        return 1
    fi

    rm -rf "$final"
    mv "$stage" "$final"
    publish_zig "$final/ziglang/zig" "$bin_dir"
    say "zig $want installed from the PyPI ziglang wheel"
    return 0
}

install_zig_from_url() {
    local url="$1" bin_dir="$2"
    local stage="$TOOLCHAIN_DIR/url.stage.$$"

    mkdir -p "$stage"
    log "downloading zig tarball from $url"
    if ! curl -fsSL --connect-timeout 15 --max-time 600 "$url" \
        | tar -xJ -C "$stage" >>"$LOG_FILE" 2>&1; then
        rm -rf "$stage"
        return 1
    fi

    local zig_bin
    zig_bin=$(find "$stage" -maxdepth 3 -type f -name zig -perm -u+x | head -n1)
    if [ -z "$zig_bin" ]; then
        log "no zig binary found in the tarball from $url"
        rm -rf "$stage"
        return 1
    fi

    publish_zig "$zig_bin" "$bin_dir"
    say "zig installed from $url"
    return 0
}

ensure_zig() {
    local want="$1" bin_dir="$2"

    if have_required_zig "$want"; then
        say "zig $(zig version) already present"
        return 0
    fi

    if [ "$opt_check" -eq 1 ]; then
        die "zig $want is not installed (--check makes no changes)"
    fi

    if [ -n "${VIBEUTILS_ZIG_BIN:-}" ]; then
        if [ -x "$VIBEUTILS_ZIG_BIN" ]; then
            publish_zig "$VIBEUTILS_ZIG_BIN" "$bin_dir"
            say "zig taken from VIBEUTILS_ZIG_BIN"
            return 0
        fi
        warn "VIBEUTILS_ZIG_BIN=$VIBEUTILS_ZIG_BIN is not executable"
    fi

    if install_zig_from_pypi "$want" "$bin_dir"; then
        return 0
    fi
    log "PyPI install of zig $want failed"

    if [ -n "${VIBEUTILS_ZIG_URL:-}" ] \
        && install_zig_from_url "$VIBEUTILS_ZIG_URL" "$bin_dir"; then
        return 0
    fi

    # The Docker installer already handles the official mirror list, arch
    # detection and the /usr/local/bin symlink, so reuse it rather than
    # reimplementing tarball fetching here.
    if [ "$(uname -s)" = "Linux" ] \
        && [ -x "$PROJECT_ROOT/docker/scripts/install-zig.sh" ]; then
        log "falling back to docker/scripts/install-zig.sh $want"
        if "$PROJECT_ROOT/docker/scripts/install-zig.sh" "$want" \
            >>"$LOG_FILE" 2>&1; then
            say "zig $want installed from the official mirrors"
            return 0
        fi
        log "docker/scripts/install-zig.sh failed"
    fi

    if [ "$(uname -s)" != "Linux" ]; then
        die "no zig $want on this $(uname -s) host. Install it with one of:
    brew install zig     (Homebrew, check the version matches)
    nix develop          (uses the pinned flake toolchain)
    gale sync            (the .envrc path)
  See docs/TOOLCHAIN.md."
    fi

    die "could not install zig $want. Tried, in order:
    VIBEUTILS_ZIG_BIN            (${VIBEUTILS_ZIG_BIN:-unset})
    PyPI ziglang==$want          (pypi.org / files.pythonhosted.org)
    VIBEUTILS_ZIG_URL            (${VIBEUTILS_ZIG_URL:-unset})
    docker/scripts/install-zig.sh (ziglang.org + community mirrors)
  If your network blocks all of those, point VIBEUTILS_ZIG_URL at a
  reachable tarball or VIBEUTILS_ZIG_BIN at an existing zig binary.
  See docs/TOOLCHAIN.md."
}

# --- just --------------------------------------------------------------

# just is a thin wrapper over `zig build` and tests/integration.sh, so a
# missing just degrades the workflow but never blocks it.
ensure_just() {
    local bin_dir="$1"

    if command -v just >/dev/null 2>&1; then
        log "just $(just --version 2>/dev/null) already present"
        return 0
    fi
    if [ "$opt_check" -eq 1 ]; then
        warn "just is not installed"
        return 0
    fi

    if command -v npm >/dev/null 2>&1; then
        log "installing just via npm (rust-just)"
        if npm install -g rust-just >>"$LOG_FILE" 2>&1; then
            # Ask npm where it put the binary. Its global bin directory is
            # often not the one on PATH, so `command -v just` would still
            # come up empty here.
            local prefix installed
            prefix=$(npm prefix -g 2>>"$LOG_FILE" || true)
            installed="$prefix/bin/just"
            if [ -x "$installed" ]; then
                ln -sfn "$installed" "$bin_dir/just"
                say "just $("$installed" --version 2>/dev/null | awk '{print $2}') installed via npm (rust-just)"
                return 0
            fi
            log "npm reported success but no executable at $installed"
        fi
        log "npm install -g rust-just failed"
    fi

    if install_just_from_github "$bin_dir"; then
        return 0
    fi

    warn "just is unavailable — use 'zig build test' and './scripts/run-integration.sh' directly"
    return 0
}

install_just_from_github() {
    local bin_dir="$1"
    local arch tag url stage

    case "$(uname -m)" in
        x86_64) arch="x86_64-unknown-linux-musl" ;;
        aarch64 | arm64) arch="aarch64-unknown-linux-musl" ;;
        *) log "no prebuilt just for $(uname -m)"; return 1 ;;
    esac

    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 15 \
        --max-time 60 https://github.com/casey/just/releases/latest \
        2>>"$LOG_FILE" | sed 's#.*/tag/##') || return 1
    [ -n "$tag" ] || return 1

    url="https://github.com/casey/just/releases/download/$tag/just-$tag-$arch.tar.gz"
    stage=$(mktemp -d "$TMP_DIR/vibeutils-just.XXXXXX")
    log "downloading just $tag from $url"
    if curl -fsSL --connect-timeout 15 --max-time 300 "$url" \
        | tar -xz -C "$stage" just >>"$LOG_FILE" 2>&1; then
        install -m 0755 "$stage/just" "$bin_dir/just"
        rm -rf "$stage"
        say "just $tag installed from the GitHub release"
        return 0
    fi
    rm -rf "$stage"
    log "GitHub release download of just failed"
    return 1
}

# --- optional tools ----------------------------------------------------

# Only attempt apt when we are already root, which scopes this to
# containers and CI images and never prompts for sudo on a laptop.
ensure_optional_tools() {
    # command:package — hexdump ships in bsdextrautils, so the names differ.
    local wanted=(mandoc:mandoc fakeroot:fakeroot hexdump:bsdextrautils)
    local missing=() entry command package

    for entry in "${wanted[@]}"; do
        command="${entry%%:*}"
        package="${entry##*:}"
        command -v "$command" >/dev/null 2>&1 || missing+=("$package")
    done
    [ ${#missing[@]} -gt 0 ] || return 0

    if [ "$opt_skip_optional" -eq 1 ] || [ "$opt_check" -eq 1 ]; then
        warn "not installed: ${missing[*]}"
        return 0
    fi
    if [ "$(id -u)" -ne 0 ] || ! command -v apt-get >/dev/null 2>&1; then
        warn "cannot install ${missing[*]} automatically here — install them by hand (see docs/TOOLCHAIN.md)"
        return 0
    fi

    log "installing ${missing[*]} via apt-get"
    # apt output stays in the log: on a fresh container the first attempt
    # often fails only because the package lists are stale, and blocked
    # third-party PPAs make `apt-get update` noisy without being fatal.
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
        >>"$LOG_FILE" 2>&1; then
        say "installed ${missing[*]}"
        return 0
    fi
    apt-get update -qq >>"$LOG_FILE" 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
        >>"$LOG_FILE" 2>&1; then
        say "installed ${missing[*]}"
        return 0
    fi

    warn "could not install ${missing[*]} — some of 'just lint-man', 'just test-privileged' and 'just it' will not run"
    return 0
}

# --- git hooks ---------------------------------------------------------

ensure_git_hooks() {
    [ "$opt_skip_hooks" -eq 0 ] || return 0
    [ "$opt_check" -eq 0 ] || return 0
    git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local current
    current=$(git -C "$PROJECT_ROOT" config --get core.hooksPath || true)
    if [ -z "$current" ]; then
        git -C "$PROJECT_ROOT" config core.hooksPath .githooks
        log "set core.hooksPath=.githooks"
    elif [ "$current" != ".githooks" ]; then
        warn "core.hooksPath is '$current', leaving it alone"
    fi
}

# --- summary -----------------------------------------------------------

tool_line() {
    local label="$1" cmd="$2" note="$3" path
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [ -n "$path" ]; then
        printf 'bootstrap: %-10s present   %s\n' "$label" "$path"
    else
        printf 'bootstrap: %-10s MISSING   %s\n' "$label" "$note"
    fi
}

# Third state, for tools this script deliberately never installs. Reporting
# them as MISSING reads as breakage, and an agent starting a session burns a
# turn trying to install something that is absent by design and covered by CI.
optional_tool_line() {
    local label="$1" cmd="$2" note="$3" path
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [ -n "$path" ]; then
        printf 'bootstrap: %-10s present   %s\n' "$label" "$path"
    else
        printf 'bootstrap: %-10s n/a       not installed by design — %s\n' "$label" "$note"
    fi
}

summary() {
    local zig_path resolved
    zig_path=$(command -v zig || true)
    resolved=$(readlink -f "$zig_path" 2>/dev/null || printf '%s' "$zig_path")
    printf 'bootstrap: %-10s %-10s %s -> %s\n' \
        zig "$(zig version 2>/dev/null || echo unknown)" "$zig_path" "$resolved"

    if command -v just >/dev/null 2>&1; then
        printf 'bootstrap: %-10s %-10s %s\n' \
            just "$(just --version 2>/dev/null | awk '{print $2}')" "$(command -v just)"
    else
        printf 'bootstrap: %-10s MISSING   use "zig build test" and "./scripts/run-integration.sh"\n' just
    fi

    # Installed by this script, so absence really is a problem.
    tool_line fakeroot fakeroot "'just test-privileged' unavailable"
    tool_line mandoc mandoc "'just lint-man' unavailable"
    tool_line hexdump hexdump "some 'just it' tests will fail (apt: bsdextrautils)"

    # Never installed by this script. Absent is the expected state here.
    optional_tool_line kcov kcov "'just coverage' unavailable; coverage runs in CI"
    optional_tool_line gh gh "'just release-tag' unavailable; releases are cut from a dev machine"
    optional_tool_line actionlint actionlint "'just lint-actions' unavailable; CI lints the workflows"

    # The docker BINARY being present means nothing on its own: agent
    # containers ship the client with no reachable daemon, and reporting that
    # as "present" sends an agent down a road that dead-ends.
    local docker_note="'just test-linux*' and 'just docker-*' unavailable; CI covers the distro matrix"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf 'bootstrap: %-10s present   %s (daemon reachable)\n' docker "$(command -v docker)"
    elif command -v docker >/dev/null 2>&1; then
        printf 'bootstrap: %-10s n/a       client present but no daemon — %s\n' docker "$docker_note"
    else
        printf 'bootstrap: %-10s n/a       not installed by design — %s\n' docker "$docker_note"
    fi

    local hooks
    hooks=$(git -C "$PROJECT_ROOT" config --get core.hooksPath 2>/dev/null || echo unset)
    printf 'bootstrap: %-10s core.hooksPath=%s\n' hooks "$hooks"

    local warning
    for warning in ${warnings+"${warnings[@]}"}; do
        printf 'bootstrap: note      %s\n' "$warning"
    done

    say 'ready. Run: zig build test | just it'
}

# --- main --------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --check) opt_check=1 ;;
        --print-bin-dir) opt_print_bin_dir=1 ;;
        --skip-optional) opt_skip_optional=1 ;;
        --skip-hooks) opt_skip_hooks=1 ;;
        --verbose) opt_verbose=1 ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'bootstrap: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$opt_print_bin_dir" -eq 1 ]; then
    resolve_bin_dir
    exit 0
fi

# $TMPDIR is not guaranteed to exist; the log and lock both live there.
mkdir -p "$TMP_DIR"
: >"$LOG_FILE"

# Serialize against a bootstrap started elsewhere — typically the
# SessionStart hook running in the background. A second caller waits here
# and then finds everything already installed.
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    if ! flock -w 900 9; then
        die "timed out waiting for another bootstrap holding $LOCK_FILE"
    fi
fi

cd "$PROJECT_ROOT"

zig_version=$(required_zig_version)
bin_dir=$(resolve_bin_dir)
log "project=$PROJECT_ROOT zig=$zig_version bin_dir=$bin_dir"

ensure_zig "$zig_version" "$bin_dir"
export PATH="$bin_dir:$PATH"
hash -r 2>/dev/null || true

ensure_just "$bin_dir"
ensure_optional_tools
ensure_git_hooks

# Compiling the build runner proves the toolchain works end to end,
# including standard-library resolution through the symlink.
if ! zig build --list-steps >>"$LOG_FILE" 2>&1; then
    die "zig is installed but 'zig build --list-steps' failed — see the log"
fi

summary
