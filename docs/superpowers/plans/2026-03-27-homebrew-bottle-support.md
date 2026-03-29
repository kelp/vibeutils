# Homebrew Bottle Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Fix the broken Homebrew formula by switching to a
source-based formula with pre-built ARM64 bottles.

**Architecture:** The release workflow creates a Homebrew
bottle from the existing cross-compiled darwin-arm64 build
artifact, uploads it to GitHub Releases, and updates the
formula in kelp/homebrew-tap with source URL + bottle block.

**Tech Stack:** GitHub Actions, Homebrew formula (Ruby),
shell scripting

**Spec:**
`docs/superpowers/specs/2026-03-27-homebrew-bottle-support-design.md`

---

## File Map

- **Modify:** `.github/workflows/release.yml` — add bottle
  creation, change SHA computation, expand formula update
- **Modify:** `kelp/homebrew-tap:Formula/vibeutils.rb` —
  rewrite with source URL and bottle block (one-time manual
  change, then CI maintains it)

---

### Task 1: Rewrite the Homebrew formula

The formula in kelp/homebrew-tap must be rewritten before
the next release. This is a one-time manual change — after
this, CI keeps it updated.

**Files:**
- Modify: `kelp/homebrew-tap:Formula/vibeutils.rb`

- [ ] **Step 1: Clone the homebrew-tap repo**

```bash
cd /tmp
gh repo clone kelp/homebrew-tap
```

- [ ] **Step 2: Rewrite the formula**

Replace the entire contents of `Formula/vibeutils.rb` with:

```ruby
class Vibeutils < Formula
  desc "Modern Unix utilities with colors, icons, and progress bars"
  homepage "https://github.com/kelp/vibeutils"
  url "https://github.com/kelp/vibeutils/archive/refs/tags/v0.8.0.tar.gz"
  sha256 "PLACEHOLDER_SOURCE_SHA"
  license "MIT"
  head "https://github.com/kelp/vibeutils.git", branch: "main"

  bottle do
    root_url "https://github.com/kelp/vibeutils/releases/download/v0.8.0"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "PLACEHOLDER_BOTTLE_SHA"
  end

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"

    # Install all binaries from zig-out/bin with 'v' prefix
    Dir["zig-out/bin/*"].each do |file|
      base_name = File.basename(file)
      next if base_name == "["
      bin.install file => "v#{base_name}"
    end

    # Create vibebin directory with unprefixed symlinks
    (libexec/"vibebin").mkpath
    bin.children.each do |file|
      base_name = file.basename.to_s.sub(/\Av/, "")
      (libexec/"vibebin"/base_name).make_symlink(file)
    end

    # Install man pages
    man1.install Dir["man/man1/*"] if Dir.exist?("man/man1")
  end

  def caveats
    <<~EOS
      vibeutils commands are installed with a 'v' prefix:
        vls, vcp, vmv, vrm, vmkdir, vtouch, etc.

      To use without prefix, add vibebin to your PATH:
        export PATH="#{opt_libexec}/vibebin:$PATH"
    EOS
  end

  test do
    assert_match "vibeutils", shell_output("#{bin}/vecho vibeutils")
  end
end
```

The PLACEHOLDER values will be replaced by CI on the next
release. They exist so the formula has the right structure
for the sed commands to target.

- [ ] **Step 3: Commit and push**

```bash
cd /tmp/homebrew-tap
git add Formula/vibeutils.rb
git commit -m "Add source URL and bottle block for vibeutils"
git push
```

---

### Task 2: Switch build matrix to native runners

Change the build job from cross-compiling everything on
`ubuntu-latest` to building each target on its native
platform.

**Files:**
- Modify: `.github/workflows/release.yml:13-26`

- [ ] **Step 1: Update the build matrix**

Change the matrix to include per-target runners:

```yaml
  build:
    strategy:
      fail-fast: true
      matrix:
        include:
          - target: aarch64-linux-musl
            archive-name: linux-arm64
            runner: ubuntu-24.04-arm
          - target: x86_64-linux-musl
            archive-name: linux-amd64
            runner: ubuntu-latest
          - target: aarch64-macos-none
            archive-name: darwin-arm64
            runner: macos-14
          - target: x86_64-macos-none
            archive-name: darwin-amd64
            runner: macos-15-intel
    runs-on: ${{ matrix.runner }}
```

Note: `-Dtarget` is still needed for Linux musl targets.
macOS builds can keep it too for consistency (zig handles
native target fine).

---

### Task 3: Add bottle creation to release workflow

Add a step that repackages the darwin-arm64 build artifact
into Homebrew's bottle tarball format.

**Files:**
- Modify: `.github/workflows/release.yml:99-106`

- [ ] **Step 1: Add bottle creation step after "List artifacts"**

Insert the following after the "List artifacts" step (line
100) and before the "Compute SHA256 for Homebrew" step:

```yaml
      - name: Create Homebrew bottle
        id: bottle
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          BOTTLE_NAME="vibeutils-${VERSION}.arm64_sequoia.bottle.tar.gz"

          # Extract darwin-arm64 binary tarball
          mkdir -p extracted
          tar -xzf "artifacts/vibeutils-${VERSION}-darwin-arm64.tar.gz" -C extracted

          # Build bottle directory structure
          mkdir -p "bottle/vibeutils/${VERSION}/bin"
          mkdir -p "bottle/vibeutils/${VERSION}/libexec/vibebin"
          mkdir -p "bottle/vibeutils/${VERSION}/share/man/man1"

          # Install binaries with 'v' prefix
          for f in extracted/bin/*; do
            name=$(basename "$f")
            [ "$name" = "[" ] && continue
            cp "$f" "bottle/vibeutils/${VERSION}/bin/v${name}"
          done

          # Create vibebin symlinks (unprefixed -> prefixed)
          for f in bottle/vibeutils/${VERSION}/bin/v*; do
            name=$(basename "$f" | sed 's/^v//')
            ln -s "../../bin/v${name}" "bottle/vibeutils/${VERSION}/libexec/vibebin/${name}"
          done

          # Copy man pages
          if [ -d extracted/share/man/man1 ]; then
            cp extracted/share/man/man1/* "bottle/vibeutils/${VERSION}/share/man/man1/"
          fi

          # Create bottle tarball
          tar -czf "${BOTTLE_NAME}" -C bottle .

          # Move to artifacts directory so it gets uploaded
          cp "${BOTTLE_NAME}" "artifacts/${BOTTLE_NAME}"

          # Compute bottle SHA256
          BOTTLE_SHA=$(sha256sum "${BOTTLE_NAME}" | awk '{print $1}')
          echo "sha256=${BOTTLE_SHA}" >> "$GITHUB_OUTPUT"
          echo "filename=${BOTTLE_NAME}" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Verify the step references are correct**

The step uses `steps.version.outputs.version` which is
defined in the "Extract version" step (id: version) at
line 83.

---

### Task 4: Change SHA computation to use source tarball

Replace the existing "Compute SHA256 for Homebrew" step
that hashes the binary tarball with one that hashes the
source archive.

**Files:**
- Modify: `.github/workflows/release.yml:102-106`

- [ ] **Step 1: Replace the SHA computation step**

Replace the existing "Compute SHA256 for Homebrew" step
with:

```yaml
      - name: Compute source tarball SHA256 for Homebrew
        id: sha
        run: |
          TAG="${{ steps.version.outputs.tag }}"
          curl -sL "https://github.com/kelp/vibeutils/archive/refs/tags/${TAG}.tar.gz" -o source.tar.gz
          SHA=$(sha256sum source.tar.gz | awk '{print $1}')
          echo "sha256=${SHA}" >> "$GITHUB_OUTPUT"
```

---

### Task 5: Upload bottle to GitHub release

The bottle tarball must be uploaded alongside the existing
release assets.

**Files:**
- Modify: `.github/workflows/release.yml:111-116`

- [ ] **Step 1: Update the release creation step**

Change the "Create GitHub release" step to also upload
the bottle tarball. The bottle was copied to the
`artifacts/` directory in Task 2, so the existing glob
`artifacts/vibeutils-*.tar.gz` already picks it up.

Verify this by checking the glob pattern matches both:
- `artifacts/vibeutils-0.8.0-darwin-arm64.tar.gz`
- `artifacts/vibeutils-0.8.0.arm64_sequoia.bottle.tar.gz`

Both match `artifacts/vibeutils-*.tar.gz`, so **no change
is needed to the release creation step**. The bottle is
automatically included.

---

### Task 6: Update formula sed commands

Expand the "Update Homebrew formula" step to update four
fields instead of two: source URL, source SHA, bottle
root_url, and bottle SHA.

**Files:**
- Modify: `.github/workflows/release.yml:125-133`

- [ ] **Step 1: Replace the formula update step**

Replace the existing "Update Homebrew formula" step with:

```yaml
      - name: Update Homebrew formula
        run: |
          FORMULA="homebrew-tap/Formula/vibeutils.rb"
          TAG="${{ steps.version.outputs.tag }}"
          VERSION="${{ steps.version.outputs.version }}"
          SOURCE_SHA="${{ steps.sha.outputs.sha256 }}"
          BOTTLE_SHA="${{ steps.bottle.outputs.sha256 }}"

          SOURCE_URL="https://github.com/kelp/vibeutils/archive/refs/tags/${TAG}.tar.gz"
          BOTTLE_URL="https://github.com/kelp/vibeutils/releases/download/${TAG}"

          # Use awk for portable formula update (works on macOS and Linux)
          awk -v source_url="$SOURCE_URL" \
              -v source_sha="$SOURCE_SHA" \
              -v bottle_url="$BOTTLE_URL" \
              -v bottle_sha="$BOTTLE_SHA" \
          '{
            if (/^  url /) { print "  url \"" source_url "\""; next }
            if (/^  sha256 / && !in_bottle) { print "  sha256 \"" source_sha "\""; next }
            if (/^  bottle do/) { in_bottle=1 }
            if (in_bottle && /root_url/) { print "    root_url \"" bottle_url "\""; next }
            if (in_bottle && /arm64_sequoia/) { print "    sha256 cellar: :any_skip_relocation, arm64_sequoia: \"" bottle_sha "\""; next }
            if (/^  end/ && in_bottle) { in_bottle=0 }
            print
          }' "$FORMULA" > "${FORMULA}.tmp" && mv "${FORMULA}.tmp" "$FORMULA"
```

The awk approach is portable across macOS (BSD) and
Linux (GNU). It tracks whether we're inside the
`bottle do` block to distinguish the source `sha256`
from the bottle `sha256`.

---

### Task 7: Test the complete workflow

- [ ] **Step 1: Review the final release.yml**

Read through the complete file and verify:
1. Step ordering: version → artifacts → bottle creation →
   source SHA → release → bottle included → tap checkout →
   formula update → commit/push
2. All step ID references resolve correctly (`steps.version`,
   `steps.sha`, `steps.bottle`)
3. The glob `artifacts/vibeutils-*.tar.gz` picks up the
   bottle tarball

- [ ] **Step 2: Commit the workflow change**

```bash
cd /Users/tcole/code/vibeutils-project/vibeutils
git add .github/workflows/release.yml
git commit -m "Add Homebrew bottle support to release workflow

Switch formula from binary tarball to source archive URL.
Create ARM64 bottle from cross-compiled build output.
CI updates both source SHA and bottle SHA in the formula."
```

- [ ] **Step 3: Test with a release**

Either cut a real release or use workflow_dispatch to
trigger the release workflow with an existing tag. Verify:

1. Bottle tarball appears in GitHub release assets
2. Formula in homebrew-tap has correct source URL, source
   SHA, bottle root_url, and bottle SHA
3. `brew install kelp/tap/vibeutils` installs from bottle
4. `brew install --build-from-source kelp/tap/vibeutils`
   builds from source
5. Version displays correctly (not `64`)
6. Binaries work (`vecho hello`, `vls`)
