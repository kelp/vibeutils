#!/bin/sh
# lint-changelog.sh — structural lint for CHANGELOG.md.
#
# WHY: a PR merged cleanly (no textual conflict) but landed
# unreleased entries inside the already-tagged v0.10.3 section and
# made the "## Unreleased" heading vanish entirely. Git's line-based
# merge cannot see that a released section is semantically frozen, so
# nothing caught it. This script checks the invariants a human editor
# is expected to hold: an Unreleased heading exists (except during the
# brief release-promotion window), every released section's text is
# byte-identical to what was tagged, and no conflict markers remain.
# Plain POSIX sh + awk/grep, no bashisms; deterministic output; exit 1
# on any violation, exit 0 clean. Mirrors the house style of
# scripts/tiger-check.sh.

# Note: intentionally NOT using `set -e`, matching tiger-check.sh — we
# must run every check to completion and report all violations rather
# than bailing out on the first non-zero command (e.g. a missing tag).
set -u

PROG=lint-changelog
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "$PROG: fatal: not inside a git repository" >&2
    exit 1
fi

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
if [ ! -f "$CHANGELOG" ]; then
    echo "$PROG: fatal: $CHANGELOG not found" >&2
    exit 1
fi

note() {
    # Human-readable note to stderr only.
    printf '%s: %s\n' "$PROG" "$*" >&2
}

# Temp working dir for accumulating violations/verified-count across
# subshells (pipelines spawn subshells in POSIX sh, so plain shell
# variables set inside a `| while read` do not survive it; files do).
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/lint-changelog.XXXXXX") || {
    note "fatal: cannot create temp dir"
    exit 2
}
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
VIOL_FILE="$WORKDIR/violations"
VERIFIED_FILE="$WORKDIR/verified"
: > "$VIOL_FILE"
: > "$VERIFIED_FILE"

fail() {
    # Record + print a violation line (contract: violations go to stdout).
    printf '%s\n' "$*"
    printf '%s\n' "$*" >> "$VIOL_FILE"
}

# ---------------------------------------------------------------------------
# Invariant C: no leftover merge-conflict markers. Checked first since a
# conflict marker anywhere makes the rest of the file untrustworthy.
# ---------------------------------------------------------------------------
grep -nE '^(<<<<<<< |>>>>>>> )' "$CHANGELOG" 2>/dev/null | while IFS= read -r cl; do
    fail "conflict marker left in CHANGELOG.md: $cl"
done

# ---------------------------------------------------------------------------
# Collect every "## " heading line with its line number, in file order.
# ---------------------------------------------------------------------------
HEADINGS_FILE="$WORKDIR/headings"
grep -n '^## ' "$CHANGELOG" > "$HEADINGS_FILE"
if [ ! -s "$HEADINGS_FILE" ]; then
    fail "no '## ' heading found in CHANGELOG.md (expected '## Unreleased' first)"
fi

first_heading=$(head -1 "$HEADINGS_FILE" | cut -d: -f2-)

# ---------------------------------------------------------------------------
# Invariant A: the first heading must be "## Unreleased", UNLESS it is a
# just-promoted "## vX.Y.Z — <date>" release heading whose tag does not
# exist yet (scripts/release.sh rewrites Unreleased to the version
# heading BEFORE the tag is created).
# ---------------------------------------------------------------------------
if [ -n "$first_heading" ]; then
    if [ "$first_heading" = "## Unreleased" ]; then
        :
    else
        first_version=$(printf '%s\n' "$first_heading" | sed -n 's/^## \(v[0-9][0-9.]*\).*/\1/p')
        if [ -n "$first_version" ] && ! git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$first_version" >/dev/null 2>&1; then
            note "first heading is '$first_heading' with tag $first_version not yet created; treating as release window"
        else
            fail "first '## ' heading must be 'Unreleased', found: $first_heading"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Invariant B: every released section ("## vX.Y.Z — <date>" whose tag
# exists) must be byte-identical, from its heading line to (not
# including) the next "## " heading or EOF, in the working tree versus
# the tagged commit.
# ---------------------------------------------------------------------------
total_lines=$(wc -l < "$CHANGELOG" | tr -d ' ')
heading_lines=$(cut -d: -f1 "$HEADINGS_FILE")

while IFS= read -r start; do
    [ -n "$start" ] || continue
    heading_text=$(sed -n "${start}p" "$CHANGELOG")
    version=$(printf '%s\n' "$heading_text" | sed -n 's/^## \(v[0-9][0-9.]*\).*/\1/p')
    [ -n "$version" ] || continue

    if ! git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1; then
        note "skip $version: tag does not exist yet (release window)"
        continue
    fi

    # End line: one before the next heading strictly after $start, or EOF.
    end=$(printf '%s\n' "$heading_lines" | awk -v s="$start" '$1 > s { print $1 - 1; exit }')
    [ -n "$end" ] || end="$total_lines"

    tagged_file="$WORKDIR/tagged-$version"
    if ! git -C "$REPO_ROOT" show "$version:CHANGELOG.md" > "$tagged_file" 2>/dev/null; then
        note "skip $version: git show $version:CHANGELOG.md failed (tag predates the changelog file)"
        continue
    fi
    if [ ! -s "$tagged_file" ]; then
        note "skip $version: git show $version:CHANGELOG.md failed (tag predates the changelog file)"
        continue
    fi

    tagged_start=$(grep -n "^## $version " "$tagged_file" | head -1 | cut -d: -f1)
    if [ -z "$tagged_start" ]; then
        note "skip $version: heading not found in tagged CHANGELOG.md"
        continue
    fi
    tagged_total=$(wc -l < "$tagged_file" | tr -d ' ')
    tagged_end=$(tail -n "+$((tagged_start + 1))" "$tagged_file" | grep -n '^## ' | head -1 | cut -d: -f1)
    if [ -n "$tagged_end" ]; then
        tagged_end=$((tagged_start + tagged_end - 1))
    else
        tagged_end="$tagged_total"
    fi

    working_section="$WORKDIR/working-$version"
    tagged_section="$WORKDIR/section-$version"
    sed -n "${start},${end}p" "$CHANGELOG" > "$working_section"
    sed -n "${tagged_start},${tagged_end}p" "$tagged_file" > "$tagged_section"

    if ! cmp -s "$working_section" "$tagged_section"; then
        fail "released section '$version' differs from its tag ($version) — released sections are immutable:"
        diff -u "$tagged_section" "$working_section"
    else
        printf '%s\n' "$version" >> "$VERIFIED_FILE"
    fi
done <<EOF
$heading_lines
EOF

VIOLATIONS=$(wc -l < "$VIOL_FILE" | tr -d ' ')
VERIFIED_COUNT=$(wc -l < "$VERIFIED_FILE" | tr -d ' ')

if [ "$VIOLATIONS" -gt 0 ]; then
    exit 1
fi
printf '%s: OK (%s released sections verified)\n' "$PROG" "$VERIFIED_COUNT"
exit 0
