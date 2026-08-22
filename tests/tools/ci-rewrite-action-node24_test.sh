#!/usr/bin/env bash
# Contract tests for scripts/ci-rewrite-action-node24.sh.
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a
# suite only when zig-out/bin contains a matching utility. This checks a
# CI helper script, so that runner would skip it. Invoke it with
# `just test-ci-rewrite-action-node24` and from CI.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REWRITE="${REWRITE:-$PROJECT_ROOT/scripts/ci-rewrite-action-node24.sh}"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_rewrite_node24.XXXXXX")"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

# The override exists so a stub can prove the suite fails on assertions
# rather than on a missing file. A missing default path is still a fail.
if [[ ! -x "$REWRITE" && ! -f "$REWRITE" ]]; then
    fail "rewrite helper is missing: $REWRITE"
    exit 1
fi

if [[ ! -x "$REWRITE" ]]; then
    fail "rewrite helper is not executable: $REWRITE"
    exit 1
fi

# Missing path must fail. A helper that "succeeds" on a typo would leave
# the workflow loading the unpatched node20 action.yml.
if "$REWRITE" "$TMP/does-not-exist.yml" >/dev/null 2>&1; then
    fail "missing action.yml must be a non-zero exit"
else
    pass "missing action.yml is rejected"
fi

# Already on node24 and no leftover node20: success, file unchanged.
# Idempotent so a later vmactions bump that already declares node24
# does not fail the rewrite step.
already="$TMP/already.yml"
printf '%s\n' "runs:" "  using: 'node24'" "  main: index.js" >"$already"
before="$(<"$already")"
if "$REWRITE" "$already" >/dev/null 2>&1; then
    after="$(<"$already")"
    if [[ "$after" == "$before" ]]; then
        pass "already-node24 is a no-op success"
    else
        fail "already-node24 must not rewrite the file"
    fi
else
    fail "already-node24 must exit 0"
fi

rewrite_case() {
    local name="$1"
    local using_line="$2"
    local file="$TMP/${name}.yml"

    printf '%s\n' "runs:" "  ${using_line}" "  main: index.js" >"$file"
    if ! "$REWRITE" "$file" >/dev/null 2>&1; then
        fail "${name}: rewrite exited non-zero"
        return
    fi
    if grep -q 'node20' "$file"; then
        fail "${name}: node20 remains after rewrite"
        return
    fi
    if ! grep -E -q "using:[[:space:]]*['\"]?node24['\"]?" "$file"; then
        fail "${name}: using: node24 is missing after rewrite"
        return
    fi
    pass "${name}: rewritten to node24"
}

rewrite_case "single-quoted" "using: 'node20'"
rewrite_case "double-quoted" 'using: "node20"'
rewrite_case "unquoted" "using: node20"

# Postcondition is file-wide: a leftover node20 token means GitHub can
# still see the deprecated runtime (or we rewrote the wrong line).
leftover="$TMP/leftover.yml"
printf '%s\n' "runs:" "  using: 'node20'" "  # still node20" "  main: index.js" >"$leftover"
if "$REWRITE" "$leftover" >/dev/null 2>&1; then
    fail "leftover node20 token must be a non-zero exit"
else
    pass "leftover node20 token is rejected"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

printf 'PASS: ci-rewrite-action-node24 contract holds\n'
