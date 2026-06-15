#!/usr/bin/env bash
# Tag-push step of the vibeutils release flow.
#
# Run this AFTER `just release x.y.z` has landed the version bump on
# main. It enforces the MANDATORY release gate (see CLAUDE.md): it
# waits for the test.yml and integration.yml workflows to pass on the
# release commit on EVERY runner (macos-latest AND ubuntu-latest), then
# creates and pushes the tag. Pushing the tag starts the irreversible
# build/publish pipeline (immutable releases locks the tag and assets),
# so running this command IS the explicit confirmation to release.
#
# Usage: scripts/release-tag.sh <version>
# Example: scripts/release-tag.sh 0.10.1

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.10.1"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be semver (e.g., 0.10.1)"
    exit 1
fi

# Must be on main branch
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
    echo "Error: Must be on main branch (currently on '$BRANCH')"
    exit 1
fi

# Working tree must be clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: Working tree not clean. Commit or stash first."
    exit 1
fi

# Tag must not already exist locally or on the remote
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag $TAG already exists locally"
    exit 1
fi
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag $TAG already exists on origin"
    exit 1
fi

# The version bump must already be in place (i.e. release.sh has run).
ZON_VERSION=$(grep '\.version = ' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
if [ "$ZON_VERSION" != "$VERSION" ]; then
    echo "Error: build.zig.zon is at '$ZON_VERSION', not '$VERSION'."
    echo "Run 'just release $VERSION' first to land the version bump."
    exit 1
fi

# The release commit must be pushed to origin/main so CI runs on it.
git fetch origin main >/dev/null 2>&1
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "Error: HEAD ($LOCAL_SHA) does not match origin/main ($REMOTE_SHA)."
    echo "Push the release commit to main before tagging."
    exit 1
fi

# Wait for a workflow to pass on the release commit. Each workflow runs
# its full OS matrix (macos-latest + ubuntu-latest) as jobs within one
# run, so watching the run covers every runner: gh run watch returns
# non-zero if ANY matrix job fails.
wait_for_ci() {
    local sha="$1" wf="$2" run_id=""
    echo "Waiting for $wf on ${sha:0:8}..."
    # The run can take a few seconds to register after the push.
    local attempt
    for attempt in $(seq 1 30); do
        run_id=$(gh run list --workflow "$wf" --commit "$sha" \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
        [ -n "$run_id" ] && break
        sleep 5
    done
    if [ -z "$run_id" ]; then
        echo "Error: no $wf run found for $sha"
        return 1
    fi
    # Blocks until the run concludes; non-zero exit if it failed.
    gh run watch "$run_id" --exit-status
}

echo "Enforcing release gate: CI must be green on all runners."
for wf in test.yml integration.yml; do
    if ! wait_for_ci "$LOCAL_SHA" "$wf"; then
        echo ""
        echo "Error: $wf did not pass on the release commit."
        echo "Fix the failure and re-run after CI is green. Tag NOT pushed."
        exit 1
    fi
done
echo "CI is green on all runners for ${LOCAL_SHA:0:8}."

# Create and push the tag. This starts the publish pipeline.
git tag "$TAG"
echo "Created tag $TAG"

git push origin "$TAG"
echo "Pushed tag $TAG"

echo ""
echo "Release $VERSION started. GitHub Actions will:"
echo "  - Build release binaries"
echo "  - Create draft release with notes from CHANGELOG.md"
echo "  - Publish release (locks tag + assets via immutable releases)"
echo "  - Update Homebrew tap"
echo "  - Push to Cachix"
echo ""
echo "Monitor: https://github.com/kelp/vibeutils/actions"
