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

echo "Running integration tests..."
just it
echo "  Integration tests passed"
echo ""

# Update version in build.zig.zon
sed -i.bak "s/\.version = \"${CURRENT}\"/\.version = \"${VERSION}\"/" build.zig.zon && rm -f build.zig.zon.bak
echo "Updated build.zig.zon"

# Update version in flake.nix
sed -i.bak "s/version = \"${CURRENT}\"/version = \"${VERSION}\"/" flake.nix && rm -f flake.nix.bak
echo "Updated flake.nix"

# Verify the updates took effect
NEW_ZON=$(grep '\.version = ' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
NEW_NIX=$(grep 'version = "' flake.nix | sed 's/.*"\(.*\)".*/\1/')

if [ "$NEW_ZON" != "$VERSION" ]; then
    echo "Error: build.zig.zon update failed (got '$NEW_ZON')"
    git checkout build.zig.zon flake.nix
    exit 1
fi

if [ "$NEW_NIX" != "$VERSION" ]; then
    echo "Error: flake.nix update failed (got '$NEW_NIX')"
    git checkout build.zig.zon flake.nix
    exit 1
fi

# Commit, tag, push
git add build.zig.zon flake.nix
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
echo "Monitor: https://github.com/kelp/vibeutils/actions"
