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

# Locked last-node20 SHAs. Current v1 tags declare using: node24; the
# workflow clones these commits and lets FORCE_JAVASCRIPT_ACTIONS_TO_NODE24
# upgrade the runtime.
FREEBSD_SHA=c9f815bc7aa0d34c9fdd0619b034a32d6ca7b57e
OPENBSD_SHA=9a8e4351a4a0dc6238e7c69276dcbf6c03bea576
NETBSD_SHA=e04aec09540429f9cebb0e7941f7cd0c0fc3b44f

# Remote-action prefix that GitHub rejects at parse time against this
# repo's SHA-exact selected-actions allowlist. Asserted as a substring
# so comments cannot sneak the same token past the check.
FORBIDDEN_REMOTE_USES='uses: vmactions/'

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

# Same two-space job-key boundary as the fakeroot assertion. Per-job
# greps are required: the locked SHAs already sit on today's remote
# uses: lines, so a file-wide SHA search would pass for the wrong reason.
job_body() {
    local want="$1"

    awk -v want="$want" '
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
        in_jobs && job == want {
            print
        }
    ' "$WORKFLOW"
}

require_job_text() {
    local job="$1"
    local description="$2"
    local needle="$3"
    local body

    body="$(job_body "$job")"
    if [[ -z "$body" ]]; then
        fail "job '$job' is missing"
        return
    fi
    if [[ "$body" != *"$needle"* ]]; then
        fail "$description"
    fi
}

require_guest_job() {
    local job="$1"
    local repo="$2"
    local sha="$3"

    require_job_text "$job" \
        "${job} job does not clone https://github.com/vmactions/${repo}" \
        "git clone https://github.com/vmactions/${repo}"
    require_job_text "$job" \
        "${job} job does not git checkout the locked SHA ${sha}" \
        "git checkout ${sha}"
    require_job_text "$job" \
        "${job} job does not use the local action ./_vmactions/${repo}" \
        "uses: ./_vmactions/${repo}"
}

if [[ ! -f "$WORKFLOW" ]]; then
    fail ".github/workflows/bsd.yml does not exist"
    exit "$FAILED"
fi

WORKFLOW_CONTENT="$(<"$WORKFLOW")"

if [[ "$WORKFLOW_CONTENT" == *"$FORBIDDEN_REMOTE_USES"* ]]; then
    fail "workflow must not contain ${FORBIDDEN_REMOTE_USES} (parse-time allowlist failure)"
fi

require_guest_job freebsd freebsd-vm "$FREEBSD_SHA"
require_guest_job openbsd openbsd-vm "$OPENBSD_SHA"
require_guest_job netbsd netbsd-vm "$NETBSD_SHA"

# OpenBSD/NetBSD stock tar cannot unpack the official Zig .tar.xz
# without the xz package. Needle is the install command, not `xz`:
# the tarball URL already contains `.tar.xz` and would false-pass.
require_job_text openbsd \
    "openbsd job does not pkg_add xz before tar extract" \
    "pkg_add xz"
require_job_text netbsd \
    "netbsd job does not pkg_add xz before tar extract" \
    "pkg_add xz"
# Base OpenBSD tar does not auto-decompress xz even after pkg_add xz.
# NetBSD may, but the same pipe is portable. `tar -xf /tmp/zig.tar.xz`
# is not sufficient — the job must decompress with `xz -dc` first.
require_job_text openbsd \
    "openbsd job does not decompress Zig tarball with xz -dc" \
    "xz -dc"
require_job_text openbsd \
    "openbsd job does not extract the Zig tarball with tar -xf" \
    "tar -xf"
require_job_text netbsd \
    "netbsd job does not decompress Zig tarball with xz -dc" \
    "xz -dc"
require_job_text netbsd \
    "netbsd job does not extract the Zig tarball with tar -xf" \
    "tar -xf"

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
