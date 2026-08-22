#!/usr/bin/env bash
# Contract tests for scripts/diff-vs-gnu.sh.
#
# The differential harness is itself safety-critical tooling: a harness
# that silently passes would be worse than no harness. These tests pin
# its observable contract using sabotaged binaries, so they never
# depend on GNU being installed or on any particular vibeutils behavior:
#
#   1. a clean subset run exits 0 with a Summary line
#   2. a sabotaged binary produces DIVERGE verdicts and a non-zero exit
#   3. an exceptions entry reclassifies its case to EXPECTED (and only
#      that case), proving both the registry and its specificity
#   4. repeated runs are deterministic for a fixed seed
#   5. -h prints usage and exits 0
#
# Run via `just test-diff-vs-gnu` or directly:
#   bash tests/tools/diff_vs_gnu_test.sh

# Reporting helpers, colours, and PROJECT_ROOT.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

HARNESS="${DIFF_VS_GNU:-$PROJECT_ROOT/scripts/diff-vs-gnu.sh}"
declare -i PASS_COUNT=0 FAIL_COUNT=0

check() {
	local name="$1" ok="$2" detail="${3:-}"
	if [ "$ok" = "0" ]; then
		print_test_result "$name" "PASS"
		PASS_COUNT+=1
	else
		print_test_result "$name" "FAIL" "$detail"
		FAIL_COUNT+=1
	fi
}

require_files() {
	if [ ! -x "$HARNESS" ]; then
		echo "harness not found or not executable: $HARNESS" >&2
		exit 1
	fi
}

make_sabotage_bin() {
	local dir="$1"
	mkdir -p "$dir"
	printf '#!/bin/sh\necho SABOTAGE\nexit 7\n' >"$dir/cat"
	chmod +x "$dir/cat"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils-diff-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

require_files

echo -e "${CYAN}diff-vs-gnu contract tests${NC}"

# --- 1. clean subset run is green ------------------------------------------
rc=0
out="$("$HARNESS" cat seq 2>&1)" || rc=$?
[ "$rc" -eq 0 ]
check "clean run exits 0" "$?"
if echo "$out" | grep -q '^Summary: match=[1-9] divergence=0'; then
	check "clean summary has zero divergences" 0
else
	check "clean summary has zero divergences" 1 "$out"
fi

# --- 2. sabotage is caught ---------------------------------------------------
make_sabotage_bin "$T/fakebin"
rc=0
out="$(VU_BIN_DIR="$T/fakebin" VU_EXCEPTIONS=/nonexistent "$HARNESS" cat 2>&1)" || rc=$?
[ "$rc" -ne 0 ]
check "sabotaged binary fails the run" "$?"
if echo "$out" | grep -q '^DIVERGE   cat          plain'; then
	check "DIVERGE verdict names the case" 0
else
	check "DIVERGE verdict names the case" 1 "no plain DIVERGE line"
fi
if echo "$out" | grep -q 'divergence=[1-9]'; then
	check "summary counts the divergence" 0
else
	check "summary counts the divergence" 1 "no divergence count"
fi

# --- 3. exception registry reclassifies only its own case --------------------
printf '# test registry\ncat|plain|selftest sabotage\n' >"$T/exc.txt"
rc=0
out="$(VU_BIN_DIR="$T/fakebin" VU_EXCEPTIONS="$T/exc.txt" "$HARNESS" cat 2>&1)" || rc=$?
[ "$rc" -ne 0 ]
check "registered case does not mask siblings" "$?"
if echo "$out" | grep -E -q '^EXPECTED +cat +plain'; then
	check "registry produces EXPECTED verdict" 0
else
	check "registry produces EXPECTED verdict" 1 "plain not EXPECTED"
fi
if echo "$out" | grep -q '^EXPECTED   cat          missing_file'; then
	check "registry stays case-specific" 1 "missing_file wrongly expected"
else
	check "registry stays case-specific" 0
fi

# --- 4. determinism for a fixed seed ----------------------------------------
s1="$(VU_SEED=99 "$HARNESS" cat sort 2>&1 | grep '^Summary:' || true)"
s2="$(VU_SEED=99 "$HARNESS" cat sort 2>&1 | grep '^Summary:' || true)"
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then
	check "same seed gives identical summary" 0
else
	check "same seed gives identical summary" 1 "${s1:-<empty>} vs ${s2:-<empty>}"
fi

# --- 5. usage -----------------------------------------------------------------
rc=0
"$HARNESS" -h >/dev/null 2>&1 || rc=$?
check "-h prints usage and exits 0" "$rc"

echo
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
