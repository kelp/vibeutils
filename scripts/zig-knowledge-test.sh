#!/usr/bin/env bash
# zig-knowledge-test.sh - Compile-test Zig code from knowledge probes
#
# Tests .zig files produced by Claude in response to the prompts
# in zig-knowledge-prompts.md. Each file is compiled with
# `zig test` (for test blocks) or `zig build-obj` (for non-test
# code) to see if it compiles on the current Zig version.
#
# Usage:
#   ./scripts/zig-knowledge-test.sh <directory>
#   ./scripts/zig-knowledge-test.sh probes/
#
# Each .zig file is tested independently. Results show which
# patterns Claude got right vs. wrong.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <directory-of-zig-files>"
    exit 2
fi

DIR="$1"

if [[ ! -d "$DIR" ]]; then
    echo "Error: $DIR is not a directory"
    exit 2
fi

# Color support
if [[ -z "${NO_COLOR:-}" ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN='' RED='' BOLD='' DIM='' RESET=''
fi

COMPILE_PASS=0
COMPILE_FAIL=0

echo ""
printf "${BOLD}Zig Knowledge Test${RESET}\n"
printf "${DIM}Compiling probes against zig %s${RESET}\n" "$(zig version)"
echo ""

for file in "$DIR"/*.zig; do
    [[ -f "$file" ]] || continue
    name=$(basename "$file" .zig)

    # Detect if file has test blocks or a main function
    if grep -q 'test "' "$file" 2>/dev/null; then
        cmd="zig test"
    else
        cmd="zig build-obj"
    fi

    TMPDIR_OBJ=$(mktemp -d)
    if $cmd "$file" --color off \
        -femit-bin="$TMPDIR_OBJ/out" \
        2>"$TMPDIR_OBJ/stderr" 1>/dev/null; then
        printf "  ${GREEN}COMPILES${RESET}  %s\n" "$name"
        COMPILE_PASS=$((COMPILE_PASS + 1))
    else
        printf "  ${RED}FAILS${RESET}     %s\n" "$name"
        # Show first 5 lines of error
        head -5 "$TMPDIR_OBJ/stderr" | while IFS= read -r line; do
            printf "  ${DIM}  %s${RESET}\n" "$line"
        done
        COMPILE_FAIL=$((COMPILE_FAIL + 1))
    fi
    rm -rf "$TMPDIR_OBJ"
done

total=$((COMPILE_PASS + COMPILE_FAIL))
echo ""
printf "${BOLD}Summary${RESET}: %d files, " "$total"
printf "${GREEN}%d compile${RESET}, " "$COMPILE_PASS"
printf "${RED}%d fail${RESET}\n" "$COMPILE_FAIL"

if [[ $total -eq 0 ]]; then
    echo "No .zig files found in $DIR"
    exit 2
fi

if [[ $COMPILE_FAIL -gt 0 ]]; then
    echo ""
    echo "Failures indicate Claude's base knowledge is outdated"
    echo "for those patterns. The corrective docs are needed."
fi
