#!/usr/bin/env bash
# Release script for vibeutils
#
# Updates version in build.zig.zon and flake.nix, commits,
# tags, and pushes. The push triggers CI which builds release
# binaries, creates a GitHub release, updates the Homebrew
# tap, and pushes to Cachix.
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

# Run tests
echo "Running unit tests..."
zig build test
echo "  Unit tests passed"

# Integration tests require bash 4+; skip on macOS with bash 3.
# Unit tests via 'zig build test' cover all code paths.
if bash --version 2>/dev/null | head -1 | grep -q 'version [4-9]'; then
    echo "Running integration tests..."
    just it
    echo "  Integration tests passed"
else
    echo "Skipping integration tests (bash 4+ required, run on Linux CI)"
fi
echo ""

# Update version in build.zig.zon
sed -i.bak "s/\.version = \"${CURRENT}\"/\.version = \"${VERSION}\"/" build.zig.zon && rm -f build.zig.zon.bak
echo "Updated build.zig.zon"

# Update version in flake.nix
sed -i.bak "s/version = \"${CURRENT}\"/version = \"${VERSION}\"/" flake.nix && rm -f flake.nix.bak
echo "Updated flake.nix"

# Promote "## Unreleased" to "## v${VERSION} — <date>" in CHANGELOG.md
TODAY=$(date +%Y-%m-%d)
sed -i.bak "s/^## Unreleased$/## v${VERSION} — ${TODAY}/" "$NOTES_FILE" && rm -f "$NOTES_FILE.bak"
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

# Re-extract the notes under the now-renamed heading for the GitHub release
RELEASE_NOTES=$(awk "
    /^## v${VERSION} —/ {found=1; next}
    found && /^## v/ {exit}
    found {print}
" "$NOTES_FILE")

# Commit, tag, push
git add build.zig.zon flake.nix "$NOTES_FILE"
git commit -m "Release v${VERSION}"
echo "Committed version bump"

git tag "$TAG"
echo "Created tag $TAG"

git push origin main
git push origin "$TAG"
echo "Pushed to origin"

echo ""
echo "Release $VERSION started. GitHub Actions will:"
echo "  - Build release binaries"
echo "  - Create GitHub release"
echo "  - Update Homebrew tap"
echo "  - Push to Cachix"
echo ""

# Wait for GitHub release to be created by CI, then update notes
echo "Waiting for GitHub release to appear..."
for i in $(seq 1 30); do
    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "Updating release notes..."
        gh release edit "$TAG" --notes "$RELEASE_NOTES"
        echo "Release notes updated for $TAG"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Warning: GitHub release not found after 5 minutes."
        echo "Update notes manually: gh release edit $TAG --notes-file <(echo \"\$RELEASE_NOTES\")"
        break
    fi
    sleep 10
done

echo ""
echo "Monitor: https://github.com/kelp/vibeutils/actions"
