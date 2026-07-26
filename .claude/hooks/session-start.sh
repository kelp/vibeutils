#!/usr/bin/env bash
# SessionStart adapter for Claude Code remote/web sessions.
#
# All install logic lives in scripts/bootstrap.sh so that humans, CI and
# non-Claude agents run exactly the same code path. This file only adapts
# that script to the hook protocol: async declaration, $CLAUDE_ENV_FILE,
# and the rule that a hook must never abort a session.
#
# Deliberately not `set -e`: every failure here is reported as text, never
# as a non-zero exit.

set -uo pipefail

# Local sessions manage their own toolchain (direnv/gale, nix, Homebrew).
# Installing into /usr/local/bin there would shadow the pinned toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

# Tells Claude Code to start the session immediately and let this run in
# the background. The toolchain download takes ~30s on a cold container.
echo '{"async": true, "asyncTimeout": 600000}'

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
bootstrap="$root/scripts/bootstrap.sh"
log="${TMPDIR:-/tmp}/vibeutils-session-start.log"

if [ ! -x "$bootstrap" ]; then
    echo "vibeutils: $bootstrap is missing or not executable; the Zig toolchain was NOT installed."
    exit 0
fi

"$bootstrap" >"$log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    tail -n 12 "$log"
else
    echo "vibeutils bootstrap FAILED (rc=$rc). The Zig toolchain is NOT ready."
    tail -n 30 "$log"
    echo "Re-run by hand: scripts/bootstrap.sh --verbose"
fi

# Only matters when the install landed in ~/.local/bin because
# /usr/local/bin was not writable; otherwise this is a harmless no-op.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    bin_dir=$("$bootstrap" --print-bin-dir 2>/dev/null || true)
    if [ -n "$bin_dir" ]; then
        printf 'export PATH="%s:$PATH"\n' "$bin_dir" >>"$CLAUDE_ENV_FILE"
    fi
fi

exit 0
