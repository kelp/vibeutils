#!/usr/bin/env bash
# Cloud Agent install: prepare the vibeutils toolchain and warm the build.
#
# Idempotent by design — it runs when a build snapshot is created and can be
# re-run against a cached snapshot without changing the result.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Optional system tools the `just` recipes want (privileged tests, man-page
# lint, and the pwd/dirname integration suites). scripts/bootstrap.sh only
# apt-installs these when it runs as root; the Cloud Agent install phase runs
# as an unprivileged user, so install them here via sudo. Idempotent: we only
# touch apt for packages that are actually missing.
need_apt=()
for pkg in fakeroot mandoc bsdextrautils; do
	dpkg -s "$pkg" >/dev/null 2>&1 || need_apt+=("$pkg")
done
if [ "${#need_apt[@]}" -gt 0 ]; then
	sudo apt-get update -qq || true
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_apt[@]}"
fi

# bootstrap.sh symlinks zig/just into /usr/local/bin and unpacks the Zig
# toolchain under /opt/vibeutils-toolchain. Both are root-owned on the base
# image, so grant this user ownership once. The change persists in the
# snapshot and keeps the toolchain on the default PATH for every later shell.
sudo install -d -o "$(id -un)" -g "$(id -gn)" /opt/vibeutils-toolchain
sudo chown "$(id -un)" /usr/local/bin

# Install the pinned Zig plus just, set the git hooks, and prove the toolchain
# works (bootstrap.sh runs `zig build --list-steps` before it returns).
scripts/bootstrap.sh

# Make the freshly symlinked toolchain visible in this shell, then warm the
# build cache so the first agent action is fast.
hash -r 2>/dev/null || true
zig build
