#!/usr/bin/env bash
# Contract test for the BSD vmactions workflow.
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh globs tests/utilities/*_test.sh and runs a suite
# only when zig-out/bin contains a utility matching its filename. This checks
# workflow configuration, not a built utility, so that runner would silently
# skip it. Do not move this file into tests/utilities/. It is invoked directly,
# by `just test-bsd-workflow` and by CI.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/bsd.yml"
FAILED=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILED=1
}

require_text() {
    local description="$1"
    local needle="$2"

    if [[ "$WORKFLOW_CONTENT" != *"$needle"* ]]; then
        fail "$description"
    fi
}

if [[ ! -f "$WORKFLOW" ]]; then
    fail ".github/workflows/bsd.yml does not exist"
    exit "$FAILED"
fi

WORKFLOW_CONTENT="$(<"$WORKFLOW")"

require_text \
    "FreeBSD vmaction is not pinned to the locked SHA" \
    "83b151f58c6047089f4c80eb5ba2039d158ce093"
require_text \
    "OpenBSD vmaction is not pinned to the locked SHA" \
    "e6c68b637a12e83519688d115d57d5b0b53923cd"
require_text \
    "NetBSD vmaction is not pinned to the locked SHA" \
    "00081e82b14bc40114eb97f32b4455306828516b"
require_text "workflow does not install Zig 0.16.0" "0.16.0"
require_text "workflow does not use an Ubuntu host runner" \
    "runs-on: ubuntu-latest"

if [[ "$WORKFLOW_CONTENT" == *"continue-on-error"* ]]; then
    fail "workflow must not contain continue-on-error"
fi

# Track two-space job keys beneath `jobs:`. Any fakeroot reference must remain
# inside a job whose key names FreeBSD; OpenBSD and NetBSD do not provide it.
if ! awk '
    /^jobs:[[:space:]]*$/ {
        in_jobs = 1
        next
    }
    in_jobs && /^[^[:space:]#]/ {
        in_jobs = 0
    }
    in_jobs && /^  [[:alnum:]_-]+:[[:space:]]*(#.*)?$/ {
        job = $1
        sub(/:$/, "", job)
    }
    tolower($0) ~ /fakeroot/ &&
        (!in_jobs || tolower(job) !~ /freebsd/) {
        printf "fakeroot appears outside the FreeBSD job (job: %s)\n", job \
            > "/dev/stderr"
        bad = 1
    }
    END {
        exit bad
    }
' "$WORKFLOW"; then
    fail "fakeroot must appear only in the FreeBSD job"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit "$FAILED"
fi

printf 'PASS: BSD workflow pins and job constraints are locked\n'
