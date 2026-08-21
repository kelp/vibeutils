#!/usr/bin/env bash
# Run the integration suite in a private working directory, dropping
# privileges first when we are root.
#
# Many integration tests assert that an operation is denied — an unreadable
# file, a 0o000 directory, a chown that should fail. Root bypasses DAC, so
# those assertions cannot hold and roughly two dozen tests fail for a
# reason that has nothing to do with the code. Agent containers and Docker
# images run as root; CI and dev machines do not.
#
# Rather than weaken the tests, run them the way CI does: as an
# unprivileged user. When we are already unprivileged this is a
# pass-through as far as privileges go — but never as far as the working
# directory goes.
#
# THE WORKING DIRECTORY IS SHARED MUTABLE STATE (issue #125)
#
# tests/utilities/mkdir_test.sh is the only suite that builds fixtures with
# relative paths — 39 names (combo, dir1, parent, tree, …) and 46 bare
# `rm -rf <name>` cleanups — so whatever directory this script is sitting
# in becomes scratch space for the whole mkdir run. Every run therefore
# gets its own directory, on every path out of this script. A leftover
# `combo/` from an interrupted or concurrent predecessor otherwise makes
# `mkdir -pv combo/test/path` print two "created directory" lines instead
# of three, and the run fails once and then heals itself by deleting the
# contaminant — a flake with no evidence left behind.
#
# Usage: scripts/run-integration.sh [args passed to tests/integration.sh]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$PROJECT_ROOT/tests/integration.sh"
TEST_USER="${VIBEUTILS_TEST_USER:-vibedev}"

# Housekeeping only. Uniqueness is what makes the isolation correct — a
# leftover run directory can never be a later run's cwd — so this just
# stops a crashed predecessor's scratch space accumulating. -maxdepth,
# -mmin and `-exec +` are all in BSD find, so macOS is fine.
reap_stale_run_dirs() {
    local root="$1" pattern="$2"
    find "$root" -maxdepth 1 -name "$pattern" -type d -mmin +720 \
        -exec rm -rf {} + 2>/dev/null || true
}

# Run the suite from a throwaway directory and hand back its exit code.
# `set -euo pipefail` would abort on a failing suite before the cleanup,
# so the status is captured explicitly rather than left to errexit.
run_isolated() {
    local run_dir rc=0
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils-run-XXXXXX")" || return 1
    cd "$run_dir" || { rm -rf "$run_dir"; return 1; }
    bash "$SUITE" "$@" || rc=$?
    cd /
    rm -rf "$run_dir"
    return "$rc"
}

# The pass-through paths below used to `exec bash "$SUITE"`, which meant no
# cd at all: the suite ran in the caller's cwd, the repo root under
# `just it`. `exec` also replaces this process, so no cleanup could ever
# run. Both are gone.
run_isolated_and_exit() {
    local rc=0
    reap_stale_run_dirs "${TMPDIR:-/tmp}" 'vibeutils-run-*'
    run_isolated "$@" || rc=$?
    exit "$rc"
}

# Not root, or explicitly told not to demote: run the suite directly.
if [ "$(id -u)" -ne 0 ] || [ -n "${VIBEUTILS_NO_DEMOTE:-}" ]; then
    run_isolated_and_exit "$@"
fi

if ! command -v setpriv >/dev/null 2>&1; then
    echo "integration: running as root without setpriv; permission-denied tests will fail" >&2
    run_isolated_and_exit "$@"
fi

# Serialize the id-check + useradd + home-chown window for this test
# user. Two runners racing useradd can leave the home owned by a uid
# that passwd no longer has, and setpriv then dies with "uid N not
# found" (issue #150). flock(1) is Linux; mkdir is the macOS fallback.
# Hold the lock only for provisioning, never for the suite itself.
# The path is always /tmp, not $TMPDIR: useradd is machine-global, so
# two runners that share VIBEUTILS_TEST_USER but not TMPDIR must still
# serialize. /tmp is 1777, so an unprivileged runner can create the lock.
USER_LOCK_FILE="/tmp/vibeutils-useradd-${TEST_USER}.lock"
USER_LOCK_DIR="/tmp/vibeutils-useradd-${TEST_USER}.lockdir"
USER_LOCK_KIND=""

acquire_test_user_lock() {
    local i=0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$USER_LOCK_FILE" || return 1
        flock -w 15 9 || return 1
        USER_LOCK_KIND=flock
        return 0
    fi
    while [ "$i" -lt 300 ]; do
        if mkdir "$USER_LOCK_DIR" 2>/dev/null; then
            USER_LOCK_KIND=mkdir
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

release_test_user_lock() {
    if [ "$USER_LOCK_KIND" = flock ]; then
        flock -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
    elif [ "$USER_LOCK_KIND" = mkdir ]; then
        rmdir "$USER_LOCK_DIR" 2>/dev/null || true
    fi
    USER_LOCK_KIND=""
}

if ! acquire_test_user_lock; then
    echo "integration: timed out waiting to provision '$TEST_USER'" >&2
    run_isolated_and_exit "$@"
fi

if ! id "$TEST_USER" >/dev/null 2>&1; then
    if ! useradd -m -s /bin/bash "$TEST_USER" >/dev/null 2>&1; then
        release_test_user_lock
        echo "integration: could not create '$TEST_USER'; permission-denied tests will fail" >&2
        run_isolated_and_exit "$@"
    fi
fi

test_uid="$(id -u "$TEST_USER")"
test_gid="$(id -g "$TEST_USER")"
test_home="$(getent passwd "$TEST_USER" | cut -d: -f6)"
test_tmp="${TMPDIR:-/tmp}/vibeutils-integration-$test_uid"

# Repair a leftover from a predecessor that raced before this lock
# existed. Under the lock the owner should already match.
chown "$test_uid:$test_gid" "$test_home" 2>/dev/null || true
release_test_user_lock

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
# to be writable by the test user, and private to this run — see the note
# at the top of this file. The suite resolves its own paths from
# BASH_SOURCE, so running it from anywhere is safe.
#
# Deliberately a SIBLING of $TEMP_DIR and never a parent of it. The suite's
# temp root is "$TMPDIR/vibeutils_tests_$$" (tests/lib/common.sh:26) and
# cleanup_test_session deletes it wholesale; a cwd underneath it would be
# pulled out from under the shell, and every later subshell would emit a
# getcwd warning on stderr, breaking the tests that compare stderr exactly.
# "run-XXXXXX" under $test_tmp is a distinct sibling, so that cannot happen.
#
# It must also be TRAVERSABLE by the demoted user, not merely writable: if
# `cd` fails inside pwd_test.sh the whole run dies several utilities later
# with "PWD: unbound variable". $test_tmp is 0700 and owned by the test
# user, under /tmp which is 1777, so every component is traversable.
reap_stale_run_dirs "$test_tmp" 'run-*'
run_dir="$(mktemp -d "$test_tmp/run-XXXXXX")"
chown "$test_uid:$test_gid" "$run_dir"
chmod 0700 "$run_dir"
cd "$run_dir"

# No `exec`: it would replace this process and the cleanup below would
# never run. errexit would also abort on a failing suite, so capture the
# status explicitly and propagate it after tearing the directory down.
rc=0
setpriv --reuid="$test_uid" --regid="$test_gid" --init-groups \
    env HOME="$test_home" TMPDIR="$test_tmp" PATH="$PATH" \
    bash "$SUITE" "$@" || rc=$?

cd /
rm -rf "$run_dir"
exit "$rc"
