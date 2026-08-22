#!/usr/bin/env bash
# Contract test: GitHub Actions JS entrypoints we load must declare
# Node 24 so runners stop emitting the Node 20 deprecation warning.
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a
# suite only when zig-out/bin contains a utility matching its filename.
# This checks workflow configuration, not a built utility, so that
# runner would silently skip it. Invoke it with `just test-gha-node24`
# and from CI (Audit Pre-Pass).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="$PROJECT_ROOT/.github/workflows"
SETUP_ZIG_ACTION="$PROJECT_ROOT/.github/actions/setup-zig/action.yml"
FAILED=0

# Workflows that used to pin mlugg/setup-zig@<sha> remotely. Each must
# load the local wrapper instead; a remote uses: hits the SHA-exact
# allowlist and still ships upstream's using: node20.
SETUP_ZIG_WORKFLOWS=(
    docs.yml
    integration.yml
    mkdir-stress.yml
    release.yml
    test.yml
)

SETUP_ZIG_SHA=d1434d08867e3ee9daa34448df10607b98908d29
FORBIDDEN_REMOTE_SETUP_ZIG='uses: mlugg/setup-zig@'
LOCAL_SETUP_ZIG='uses: ./.github/actions/setup-zig'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=1
}

if [[ ! -d "$WORKFLOWS" ]]; then
    fail ".github/workflows does not exist"
    exit 1
fi

# A comment that names the action is fine. A uses: line that pins the
# GitHub mirror is not: that is the declaration GitHub warns about.
while IFS= read -r path; do
    if grep -q "$FORBIDDEN_REMOTE_SETUP_ZIG" "$path"; then
        fail "${path#"$PROJECT_ROOT/"} contains ${FORBIDDEN_REMOTE_SETUP_ZIG}"
    fi
done < <(find "$WORKFLOWS" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

for name in "${SETUP_ZIG_WORKFLOWS[@]}"; do
    path="$WORKFLOWS/$name"
    if [[ ! -f "$path" ]]; then
        fail "expected setup-zig caller .github/workflows/${name} is missing"
        continue
    fi
    if ! grep -q "$LOCAL_SETUP_ZIG" "$path"; then
        fail ".github/workflows/${name} does not use ${LOCAL_SETUP_ZIG}"
    fi
done

# Authored action.yml files (not a cloned tree under _setup-zig or
# _vmactions) must not declare the deprecated runtime. The wrapper
# rewrites copies at job time; the copies are not in git.
while IFS= read -r path; do
    if grep -E -q "using:[[:space:]]*['\"]?node20['\"]?" "$path"; then
        fail "${path#"$PROJECT_ROOT/"} declares using: node20"
    fi
done < <(find "$PROJECT_ROOT/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

if [[ ! -f "$SETUP_ZIG_ACTION" ]]; then
    fail ".github/actions/setup-zig/action.yml does not exist"
else
    content="$(<"$SETUP_ZIG_ACTION")"
    if [[ "$content" != *'git clone https://github.com/mlugg/setup-zig'* ]]; then
        fail "setup-zig wrapper does not clone https://github.com/mlugg/setup-zig"
    fi
    if [[ "$content" != *"git checkout ${SETUP_ZIG_SHA}"* ]]; then
        fail "setup-zig wrapper does not git checkout the locked SHA ${SETUP_ZIG_SHA}"
    fi
    if [[ "$content" != *'ci-rewrite-action-node24.sh'* ]]; then
        fail "setup-zig wrapper does not run ci-rewrite-action-node24.sh"
    fi
    if [[ "$content" != *'uses: ./_setup-zig'* ]]; then
        fail "setup-zig wrapper does not use ./_setup-zig"
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit "$FAILED"
fi

printf 'PASS: GitHub Actions Node 24 declarations are locked\n'
