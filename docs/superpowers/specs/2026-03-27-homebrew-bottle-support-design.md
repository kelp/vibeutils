# Homebrew Bottle Support

## Problem

The Homebrew formula in `kelp/homebrew-tap` has two bugs:

1. **Version detection**: URL ends in `darwin-arm64.tar.gz`,
   so Homebrew parses `64` from `arm64` as the version.
2. **Build failure**: The formula downloads a pre-built
   binary tarball but runs `zig build`, which needs source
   code. The tarball has no `build.zig`.

## Solution

Switch the formula to a source-based formula with a
pre-built bottle. By default `brew install` uses the bottle
(fast, no zig). `brew install --build-from-source` compiles
from source.

## Scope

- ARM64 macOS only (no Intel bottles)
- Existing Linux and x86_64-macos binary tarballs remain
  as release assets
- CI updates formula automatically (no manual steps)

## Formula Design

The formula URL changes from the binary tarball to the
GitHub source archive:

```
https://github.com/kelp/vibeutils/archive/refs/tags/v{TAG}.tar.gz
```

A `bottle do` block points to the bottle hosted on GitHub
Releases:

```ruby
bottle do
  root_url "https://github.com/kelp/vibeutils/releases/download/v{VERSION}"
  sha256 cellar: :any_skip_relocation, arm64_sequoia: "BOTTLE_SHA"
end
```

`cellar: :any_skip_relocation` because zig produces static
binaries with no dynamic linking.

The `install` method stays the same — `zig build` plus
`v`-prefixed binary installation and `vibebin` symlinks.

## Bottle Format

Homebrew bottles are tarballs with this structure:

```
vibeutils/{VERSION}/
  bin/vecho
  bin/vls
  ...
  libexec/vibebin/echo -> ../../bin/vecho
  ...
  share/man/man1/*.1
```

Named: `vibeutils-{VERSION}.arm64_sequoia.bottle.tar.gz`

The bottle mirrors what the formula's `install` method
produces, so `brew install` and `brew install
--build-from-source` yield identical results.

## CI Changes (release.yml)

Three changes to the `release` job:

### 1. Source tarball SHA256

Download the source archive for the tag and compute its
SHA256, replacing the current binary tarball SHA
computation.

### 2. Bottle creation

After downloading the `darwin-arm64` build artifact:

1. Extract the binary tarball
2. Repackage into bottle directory structure:
   - Copy binaries to `bin/` with `v` prefix
   - Create `libexec/vibebin/` symlinks (unprefixed)
   - Copy man pages to `share/man/man1/`
3. Create bottle tarball with correct naming
4. Compute bottle SHA256
5. Upload bottle to the GitHub release

### 3. Formula update

Expand the sed commands to update four fields:

1. `url` — source tarball URL
2. Top-level `sha256` — source tarball hash
3. `root_url` in bottle block — release URL for this tag
4. `sha256` in bottle block — bottle tarball hash

## Files Changed

**`kelp/vibeutils` (this repo):**
- `.github/workflows/release.yml`

**`kelp/homebrew-tap` (other repo):**
- `Formula/vibeutils.rb` — one-time rewrite, then CI
  maintains it

## Testing

After cutting a release:

1. `brew install kelp/tap/vibeutils` — uses bottle
2. `brew install --build-from-source kelp/tap/vibeutils`
   — builds from source
3. Verify version shows correctly (not `64`)
4. Verify installed binaries work (`vecho`, `vls`, etc.)
