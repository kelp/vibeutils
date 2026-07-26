#!/usr/bin/env bash
# Run the integration suite, dropping privileges first when we are root.
#
# Many integration tests assert that an operation is denied — an unreadable
# file, a 0o000 directory, a chown that should fail. Root bypasses DAC, so
# those assertions cannot hold and roughly two dozen tests fail for a
# reason that has nothing to do with the code. Agent containers and Docker
# images run as root; CI and dev machines do not.
#
# Rather than weaken the tests, run them the way CI does: as an
# unprivileged user. When we are already unprivileged this is a pass-through.
#
# Usage: scripts/run-integration.sh [args passed to tests/integration.sh]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$PROJECT_ROOT/tests/integration.sh"
TEST_USER="${VIBEUTILS_TEST_USER:-vibedev}"

# Not root, or explicitly told not to demote: run the suite directly.
if [ "$(id -u)" -ne 0 ] || [ -n "${VIBEUTILS_NO_DEMOTE:-}" ]; then
    exec bash "$SUITE" "$@"
fi

if ! command -v setpriv >/dev/null 2>&1; then
    echo "integration: running as root without setpriv; permission-denied tests will fail" >&2
    exec bash "$SUITE" "$@"
fi

if ! id "$TEST_USER" >/dev/null 2>&1; then
    if ! useradd -m -s /bin/bash "$TEST_USER" >/dev/null 2>&1; then
        echo "integration: could not create '$TEST_USER'; permission-denied tests will fail" >&2
        exec bash "$SUITE" "$@"
    fi
fi

test_uid="$(id -u "$TEST_USER")"
test_gid="$(id -g "$TEST_USER")"
test_home="$(getent passwd "$TEST_USER" | cut -d: -f6)"
test_tmp="${TMPDIR:-/tmp}/vibeutils-integration-$test_uid"

mkdir -p "$test_tmp"
chown "$test_uid:$test_gid" "$test_tmp"
chmod 0700 "$test_tmp"

if [ ! -d "$PROJECT_ROOT/zig-out/bin" ]; then
    echo "integration: zig-out/bin is missing — run 'just build' first" >&2
    exit 1
fi

# The test user needs to read the binaries and the test scripts, but never
# to write inside the tree — everything it creates goes under $TMPDIR — so
# the checkout stays root-owned.
chmod -R a+rX "$PROJECT_ROOT/zig-out" "$PROJECT_ROOT/tests" 2>/dev/null || true

echo "integration: dropping to '$TEST_USER' so permission-denied tests are meaningful"

# Some tests create files with relative paths, so the working directory has
# to be writable by the test user. The suite resolves its own paths from
# BASH_SOURCE, so running it from elsewhere is safe — and it stops those
# tests from littering the repo root, which is what they do today.
#
# Deliberately the home directory and not $TMPDIR: the suite deletes and
# recreates its temp root as it goes, and a shell whose cwd is pulled out
# from under it makes every later subshell emit a getcwd warning on stderr,
# which breaks the tests that compare stderr exactly.
cd "$test_home"

exec setpriv --reuid="$test_uid" --regid="$test_gid" --init-groups \
    env HOME="$test_home" TMPDIR="$test_tmp" PATH="$PATH" \
    bash "$SUITE" "$@"
