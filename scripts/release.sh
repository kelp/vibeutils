#!/usr/bin/env bash
# Release script for vibeutils
#
# Gate 1 (local) of the two-gate release flow. Runs the unit and
# integration test suites as hard gates — and when run from macOS,
# also runs both suites on Linux via OrbStack (orb -m ubuntu), so a
# release cut from the Mac must pass on BOTH platforms locally before
# anything is pushed. Then updates the version in build.zig.zon and
# flake.nix, promotes the CHANGELOG, commits the bump, and pushes it
# to main (which triggers the CI test + integration workflows). It
# does NOT create or push the tag — that is scripts/release-tag.sh,
# which waits for green CI on all runners first. See the "MANDATORY
# release gate" in CLAUDE.md.
#
# Usage: scripts/release.sh <version>
# Example: scripts/release.sh 0.7.0

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.7.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be semver (e.g., 0.7.0)"
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

# Tag must not exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag $TAG already exists"
    exit 1
fi

# Verify CHANGELOG has an Unreleased section with content to promote
NOTES_FILE="CHANGELOG.md"
if [ ! -f "$NOTES_FILE" ]; then
    echo "Error: $NOTES_FILE not found"
    exit 1
fi

if ! grep -q '^## Unreleased$' "$NOTES_FILE"; then
    echo "Error: No '## Unreleased' section in $NOTES_FILE"
    echo "Add notes under '## Unreleased' before releasing."
    exit 1
fi

# Body between "## Unreleased" and the next "## v" heading (exclusive)
UNRELEASED_BODY=$(awk '
    /^## Unreleased$/ {found=1; next}
    found && /^## v/ {exit}
    found {print}
' "$NOTES_FILE")

if [ -z "$(echo "$UNRELEASED_BODY" | tr -d '[:space:]')" ]; then
    echo "Error: '## Unreleased' section is empty in $NOTES_FILE"
    echo "Add notes under '## Unreleased' before releasing."
    exit 1
fi
echo "Found Unreleased notes to promote to v$VERSION"

# Pull latest to avoid conflicts
echo "Pulling latest from origin..."
git pull --ff-only origin main

CURRENT=$(grep '\.version = ' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
echo ""
echo "Releasing vibeutils: $CURRENT -> $VERSION"
echo ""

# Unit and integration tests are HARD gates: both must pass locally
# before the version bump is pushed to main. CI then re-runs both on
# every runner (the second gate, enforced by scripts/release-tag.sh).
echo "Running unit tests..."
zig build test
echo "  Unit tests passed"

# Integration tests require bash 4+ (macOS default is bash 3.2).
# This is a hard gate, not a skip: refuse to release without them.
if ! bash --version 2>/dev/null | head -1 | grep -q 'version [4-9]'; then
    echo "Error: integration tests require bash 4+ (have: $(bash --version 2>/dev/null | head -1))."
    echo "Install with: brew install bash (and put it ahead of /bin in PATH)."
    echo "Integration tests are a mandatory release gate and cannot be skipped."
    exit 1
fi
echo "Running integration tests..."
just it
echo "  Integration tests passed"
echo ""

# When releasing from macOS, run the full suite on Linux via OrbStack
# too. Local validation is a hard gate on BOTH platforms before the
# bump is pushed: fail fast here rather than push a commit that only
# breaks on Linux. (CI re-runs both as the second gate.)
if [ "$(uname -s)" = "Darwin" ]; then
    if ! command -v orb >/dev/null 2>&1; then
        echo "Error: orb (OrbStack) not found, but Linux validation is a"
        echo "mandatory release gate when releasing from macOS."
        echo "Install OrbStack, or cut the release from Linux."
        exit 1
    fi
    # The orb VM has zig but not the `just` task runner, so invoke the
    # underlying steps directly. `just it` is `zig build` + integration.sh;
    # integration.sh requires bash 4+ (the VM ships 5.2) and finds the repo
    # via BASH_SOURCE, so the working directory does not matter.
    echo "Running unit tests on Linux (orb -m ubuntu)..."
    orb -m ubuntu zig build test
    echo "  Linux unit tests passed"
    echo "Running integration tests on Linux (orb -m ubuntu)..."
    orb -m ubuntu zig build
    orb -m ubuntu bash tests/integration.sh
    echo "  Linux integration tests passed"
    echo ""
fi

# Update version in build.zig.zon
sed -i.bak "s/\.version = \"${CURRENT}\"/\.version = \"${VERSION}\"/" build.zig.zon && rm -f build.zig.zon.bak
echo "Updated build.zig.zon"

# Update version in flake.nix
sed -i.bak "s/version = \"${CURRENT}\"/version = \"${VERSION}\"/" flake.nix && rm -f flake.nix.bak
echo "Updated flake.nix"

# Promote "## Unreleased" to "## v${VERSION} — <date>" in CHANGELOG.md and
# reopen a fresh empty "## Unreleased" above it for the next cycle. Without
# the reopen, lint-changelog fails once the tag exists (the release-window
# exemption that lets a version heading sit first expires at tag creation).
# awk (not sed) so the newline insertion is portable across BSD and GNU.
TODAY=$(date +%Y-%m-%d)
awk -v ver="$VERSION" -v today="$TODAY" '
    !done && $0 == "## Unreleased" {
        print "## Unreleased"
        print ""
        print "## v" ver " — " today
        done = 1
        next
    }
    { print }
' "$NOTES_FILE" > "$NOTES_FILE.tmp" && mv "$NOTES_FILE.tmp" "$NOTES_FILE"
echo "Updated $NOTES_FILE"

# Verify the updates took effect
NEW_ZON=$(grep '\.version = ' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
NEW_NIX=$(grep 'version = "' flake.nix | sed 's/.*"\(.*\)".*/\1/')

if [ "$NEW_ZON" != "$VERSION" ]; then
    echo "Error: build.zig.zon update failed (got '$NEW_ZON')"
    git checkout build.zig.zon flake.nix "$NOTES_FILE"
    exit 1
fi

if [ "$NEW_NIX" != "$VERSION" ]; then
    echo "Error: flake.nix update failed (got '$NEW_NIX')"
    git checkout build.zig.zon flake.nix "$NOTES_FILE"
    exit 1
fi

if ! grep -q "^## v${VERSION} — ${TODAY}$" "$NOTES_FILE"; then
    echo "Error: $NOTES_FILE update failed (no 'v${VERSION}' heading)"
    git checkout build.zig.zon flake.nix "$NOTES_FILE"
    exit 1
fi

# Commit the version bump and push it to main. This triggers the
# test.yml and integration.yml workflows on the release commit.
git add build.zig.zon flake.nix "$NOTES_FILE"
git commit -m "Release v${VERSION}"
echo "Committed version bump"

git push origin main
echo "Pushed version bump to main"

# The tag is deliberately NOT created or pushed here. Pushing the tag
# starts the irreversible build/publish pipeline, so it lives in a
# separate command (just release-tag) that waits for green CI on all
# runners first. See the "MANDATORY release gate" in CLAUDE.md.
echo ""
echo "=============================================================="
echo "Version bump for $VERSION is on main. The tag is NOT created"
echo "yet — that is a separate, CI-gated step."
echo ""
echo "CI (test.yml + integration.yml) is now running on the release"
echo "commit. Watch it on macos-latest AND ubuntu-latest:"
echo "  https://github.com/kelp/vibeutils/actions"
echo ""
echo "Once you have confirmed this release should go out, run:"
echo ""
echo "    just release-tag $VERSION"
echo ""
echo "That command waits for CI to be green on all runners, then"
echo "creates and pushes the tag to start publishing. The tag push"
echo "is irreversible (immutable releases locks the tag and assets)."
echo "=============================================================="
