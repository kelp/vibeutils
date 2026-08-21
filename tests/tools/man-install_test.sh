#!/usr/bin/env bash
# Contract tests for the default build's man-page install behavior.
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh derives a utility binary name from each test file
# and skips the suite unless that binary exists. man-install is build-graph
# behavior, not a utility, so this suite is invoked explicitly by
# `just test-man-install` and CI.
#
# Run with bash 4+ (not sh). The build always uses a private temporary
# `--prefix`; this suite never invokes man(1) or writes under /usr.

set -uo pipefail

if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
    echo "Error: This script requires bash 4.0 or later. Current version: $BASH_VERSION"
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAN_INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_man_install.XXXXXX")"
PREFIX="$MAN_INSTALL_TMP/prefix"
MAN_DIR="$PREFIX/share/man/man1"

cleanup() {
    rm -rf "$MAN_INSTALL_TMP"
}
trap cleanup EXIT

if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED="" GREEN="" BLUE="" NC=""
fi

tests_run=0
tests_failed=0

pass() {
    tests_run=$((tests_run + 1))
    printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"
}

fail() {
    tests_run=$((tests_run + 1))
    tests_failed=$((tests_failed + 1))
    printf '%s✗%s %s\n' "$RED" "$NC" "$1"
    printf '    %s\n' "$2"
}

echo "${BLUE}Testing man-page installation${NC}"
echo "============================="
echo "prefix: $PREFIX"

if ! (cd "$PROJECT_ROOT" && zig build --prefix "$PREFIX"); then
    fail "zig build installs into the temporary prefix" \
        "zig build --prefix failed; man-page assertions cannot run"
    exit 1
fi

if [[ -s "$MAN_DIR/ls.1" ]]; then
    pass "man install puts non-empty ls.1 under share/man/man1"
else
    fail "man install puts non-empty ls.1 under share/man/man1" \
        "missing or empty: $MAN_DIR/ls.1"
fi

mapfile -t utility_names < <(
    grep -E '\.name = "[^"]+"' "$PROJECT_ROOT/build/utils.zig" |
        sed -E 's/.*\.name = "([^"]+)".*/\1/'
)

missing_pages=()
for utility_name in "${utility_names[@]}"; do
    if [[ ! -s "$MAN_DIR/$utility_name.1" ]]; then
        missing_pages+=("$utility_name.1")
    fi
done

shopt -s nullglob
source_pages=("$PROJECT_ROOT"/man/man1/*.1)
installed_pages=("$MAN_DIR"/*.1)
shopt -u nullglob

if [[ ${#utility_names[@]} -eq 0 ]]; then
    fail "man install discovers utility names from build/utils.zig" \
        "the utility-name parser returned no names"
elif [[ ${#missing_pages[@]} -ne 0 ]]; then
    fail "man install installs a page for every utility" \
        "missing: ${missing_pages[*]}"
else
    pass "man install installs a page for every utility"
fi

if [[ ${#installed_pages[@]} -eq ${#source_pages[@]} ]]; then
    pass "installed man-page count matches the source count"
else
    fail "installed man-page count matches the source count" \
        "installed=${#installed_pages[@]} source=${#source_pages[@]}"
fi

if cmp -s "$PROJECT_ROOT/man/man1/ls.1" "$MAN_DIR/ls.1"; then
    pass "installed ls.1 is byte-identical to the repo source"
else
    fail "installed ls.1 is byte-identical to the repo source" \
        "cmp differs: man/man1/ls.1 and $MAN_DIR/ls.1"
fi

printf '\nMan install summary\n'
printf '%s\n' '==================='
printf 'Tests run: %d\n' "$tests_run"
printf 'Failed: %d\n' "$tests_failed"

if [[ "$tests_failed" -ne 0 ]]; then
    exit 1
fi
