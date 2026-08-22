#!/usr/bin/env bash
# Rewrite a GitHub Action action.yml so `runs.using` declares Node 24.
#
# GitHub warns (and will later refuse) JS actions that still say
# `using: node20`. Several third-party actions we pin have no Node 24
# release. We clone them into the workspace and run this helper *before*
# `uses: ./…` so the runner loads a node24 declaration. The JS already
# runs on Node 24 under FORCE_JAVASCRIPT_ACTIONS_TO_NODE24.
#
# Usage: scripts/ci-rewrite-action-node24.sh path/to/action.yml
#
# Exit 0 only when the file then contains `using: node24` and no
# `node20` token remains. A missing path, a rewrite that leaves node20
# behind, or a file that never declared node24 is a failure: the next
# `uses:` would otherwise load the deprecated runtime.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'ci-rewrite-action-node24: usage: %s ACTION.YML\n' "$0" >&2
    exit 1
fi

action_yml="$1"

if [[ ! -f "$action_yml" ]]; then
    printf 'ci-rewrite-action-node24: missing file: %s\n' "$action_yml" >&2
    exit 1
fi

# Idempotent success: already the postcondition, so a later pin that
# ships node24 does not fail this step.
if grep -E -q "using:[[:space:]]*['\"]?node24['\"]?" "$action_yml" &&
    ! grep -q 'node20' "$action_yml"; then
    exit 0
fi

tmp="${action_yml}.node24.$$"
# Three explicit substitutions, not one capture with a pattern
# backreference. macOS ships BSD sed, whose -E engine does not
# treat \2 in the pattern as "same quote as group 2"; GNU sed
# does, which is why Linux CI passed and macos-26 did not.
# Quoted forms first so the bare node20 rule cannot see inside
# quotes. Indent before `using:` is left untouched.
# Only the using: line is rewritten so a leftover node20 token
# (comment, other key) still fails below.
sed -E \
    -e "s/using:[[:space:]]*'node20'/using: 'node24'/" \
    -e 's/using:[[:space:]]*"node20"/using: "node24"/' \
    -e "s/using:[[:space:]]*node20/using: node24/" \
    "$action_yml" >"$tmp"
mv "$tmp" "$action_yml"

if ! grep -E -q "using:[[:space:]]*['\"]?node24['\"]?" "$action_yml"; then
    printf 'ci-rewrite-action-node24: %s has no using: node24 after rewrite\n' \
        "$action_yml" >&2
    exit 1
fi

if grep -q 'node20' "$action_yml"; then
    printf 'ci-rewrite-action-node24: %s still contains node20\n' \
        "$action_yml" >&2
    exit 1
fi
