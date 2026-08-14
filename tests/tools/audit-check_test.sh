#!/usr/bin/env bash
# Contract tests for scripts/audit-check.sh (issue #133).
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh:133-136 globs "$TESTS_DIR/utilities/"*_test.sh and
# runs each file ONLY when [[ -x "$BIN_DIR/$util" ]] holds for the name derived
# from the filename. audit-check is a script, not a built utility, so no
# zig-out/bin/audit-check will ever exist and a file dropped in
# tests/utilities/ would be skipped silently, forever, while still looking
# like a test suite in the tree. That is the vacuous-pass failure mode this
# whole issue exists to kill. Do not "tidy" this file into tests/utilities/.
# It is invoked directly, by `just test-audit-check` and by CI.
#
# Run it with bash (not sh): it sources tests/lib/common.sh, which is bash 4+
# only. macOS needs `brew install bash`, same as every other suite here.
#
# The script under test is taken from $AUDIT_CHECK, defaulting to
# scripts/audit-check.sh. The override exists so the suite can be pointed at a
# deliberate stub to prove the tests fail on real assertions rather than on a
# missing file.
#
# Every behavioural test asserts the EXIT STATUS explicitly, and asserts the
# exact SUMMARY line. Exit status is the contract -- nothing parses the summary
# prose -- and a scanner that prints findings and exits 0, or prints nothing
# and exits 0, is precisely what is being guarded against. Neither of those
# can pass here.

# Reporting helpers, colours, and PROJECT_ROOT.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; this suite runs a command that is *expected* to exit
# non-zero on nearly every test, so -e has to go. -u and pipefail stay.
set +e

AUDIT_CHECK="${AUDIT_CHECK:-$PROJECT_ROOT/scripts/audit-check.sh}"
FIXTURES="$PROJECT_ROOT/tests/fixtures/audit"

AUDIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_audit_check.XXXXXX")"
OUT_FILE="$AUDIT_TMP/stdout"
ERR_FILE="$AUDIT_TMP/stderr"
AUDIT_STATUS=0

audit_cleanup() {
    rm -rf "$AUDIT_TMP"
}
trap audit_cleanup EXIT

# print_test_summary and print_test_result need these; init_test_session is
# deliberately not called, because it requires zig-out/bin and this suite
# needs no build at all.
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

TAB=$'\t'

# ===========================================================================
# Fixture-integrity preflight
#
# These are NOT tests. They are preconditions: if a fixture pair has drifted,
# every result below is meaningless, so the suite refuses to run rather than
# reporting a tally nobody can trust. Keeping them out of the tally also means
# a stubbed-out audit-check.sh produces a pass count of exactly zero.
# ===========================================================================

preflight_fail() {
    echo -e "${RED}fixture preflight failed:${NC} $*" >&2
    exit 2
}

# The negative fixture must differ from the positive by exactly one added
# line, in one file, containing the expected token. That is what proves the
# check moved because the planted defect moved, and not because the two trees
# are simply different files.
require_one_added_line() {
    local pair="$1" rel="$2" needle="$3"
    local pos="$FIXTURES/$pair/positive" neg="$FIXTURES/$pair/negative"
    local differing added removed line

    differing=$(diff -rq "$pos" "$neg" | grep -c .)
    [[ "$differing" == "1" ]] ||
        preflight_fail "$pair: expected 1 differing file, found $differing"

    added=$(diff "$pos/$rel" "$neg/$rel" | grep -c '^> ')
    removed=$(diff "$pos/$rel" "$neg/$rel" | grep -c '^< ')
    [[ "$added" == "1" && "$removed" == "0" ]] ||
        preflight_fail "$pair/$rel: expected +1/-0 lines, got +$added/-$removed"

    line=$(diff "$pos/$rel" "$neg/$rel" | grep '^> ')
    [[ "$line" == *"$needle"* ]] ||
        preflight_fail "$pair/$rel: added line lacks '$needle': $line"
}

# Weaker discipline for pairs where a single line cannot express the defect.
require_single_differing_file() {
    local pair="$1" rel="$2"
    local pos="$FIXTURES/$pair/positive" neg="$FIXTURES/$pair/negative"
    local report differing

    report=$(diff -rq "$pos" "$neg")
    differing=$(printf '%s' "$report" | grep -c .)
    [[ "$differing" == "1" ]] ||
        preflight_fail "$pair: expected 1 differing file, found $differing"
    [[ "$report" == *"/$rel "* ]] ||
        preflight_fail "$pair: the differing file is not $rel ($report)"
}

run_preflight() {
    [[ -d "$FIXTURES" ]] || preflight_fail "no fixtures at $FIXTURES"

    # The centrepiece: one added read of opts.unused_flag, nothing else.
    require_one_added_line stub-flag src/planted.zig "opts.unused_flag"
    require_one_added_line test-only-code src/deadly.zig "doubleWidth("
    require_one_added_line parse-only-test src/parsely.zig "opts.show_tabs"

    # toothless-assert flips one line rather than adding one.
    require_single_differing_file toothless-assert tests/utilities/toothy_test.sh
    # path-shadow flips `command chmod` to `host chmod`.
    require_single_differing_file path-shadow tests/utilities/shadowly_test.sh
    # matrix-drift moves the Ours column; unscannable adds a whole struct.
    require_single_differing_file matrix-drift docs/specs/driftly-flags.md
    require_single_differing_file unscannable src/opaquely.zig

    if [[ ! -f "$AUDIT_CHECK" ]]; then
        echo -e "${YELLOW}note:${NC} $AUDIT_CHECK does not exist yet;" \
            "every contract test below must fail." >&2
    fi
}

# ===========================================================================
# Invocation and assertion helpers
# ===========================================================================

run_audit() {
    : >"$OUT_FILE"
    : >"$ERR_FILE"
    if [[ -x "$AUDIT_CHECK" ]]; then
        "$AUDIT_CHECK" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
    else
        sh "$AUDIT_CHECK" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
    fi
    AUDIT_STATUS=$?

    # A scanner that could not be executed at all must not be able to satisfy
    # any expectation. `sh missing-file` reports "can't open" and exits 2 on
    # dash, which collides with the usage-error code and would let an absent
    # script look like a correctly-rejecting one -- the exact ambiguity
    # between "failed for the right reason" and "never ran" that this suite
    # exists to remove.
    if [[ ! -f "$AUDIT_CHECK" ]]; then
        AUDIT_STATUS="did-not-run"
    fi
}

audit_summary_line() {
    grep '^SUMMARY ' "$OUT_FILE" | head -1
}

audit_context() {
    printf 'exit=%s stdout=[%s] stderr=[%s]' \
        "$AUDIT_STATUS" \
        "$(tr '\t' '>' <"$OUT_FILE" | head -4 | tr '\n' '|')" \
        "$(head -2 <"$ERR_FILE" | tr '\n' '|')"
}

# Exit status is the contract, but a status on its own is not evidence of
# anything: a scanner that never ran also exits 0. So 0 and 1 additionally
# require the SUMMARY line that says a scan completed, and 2 requires a
# diagnostic on stderr saying what could not be scanned. Without those, this
# assertion would pass against a script that does nothing at all.
assert_status() {
    local label="$1" expected="$2"
    local ok=yes why=""

    [[ "$AUDIT_STATUS" == "$expected" ]] || { ok=no; why="wrong status"; }
    if [[ "$expected" == "0" || "$expected" == "1" ]]; then
        [[ -n "$(audit_summary_line)" ]] || { ok=no; why="$why no SUMMARY"; }
    else
        [[ -s "$ERR_FILE" ]] || { ok=no; why="$why silent stderr"; }
    fi

    if [[ "$ok" == yes ]]; then
        print_test_result "$label exits $expected" "PASS"
    else
        print_test_result "$label exits $expected" "FAIL" \
            "$why: $(audit_context)"
    fi
}

# The whole SUMMARY line, field for field. Callers pass everything after the
# word SUMMARY, e.g. "total=1 baselined=n/a new=1 unscannable=0".
assert_summary_exact() {
    local label="$1" fields="$2"
    local expected="SUMMARY $fields"
    local actual
    actual=$(audit_summary_line)
    if [[ "$actual" == "$expected" ]]; then
        print_test_result "$label summary is '$expected'" "PASS"
    else
        print_test_result "$label summary is '$expected'" "FAIL" \
            "got '$actual' ($(audit_context))"
    fi
}

audit_rows_for() {
    awk -F'\t' -v want="$1" '$1 == want' "$OUT_FILE"
}

# Exactly one row for this check, with the exact key and status. The detail
# field is implementation-chosen prose, so it is required to exist and to be
# non-empty rather than pinned to a wording the contract does not fix.
assert_single_row() {
    local label="$1" check="$2" key="$3" status="$4" match="${5:-exact}"
    local rows count line got_key got_status got_detail fields ok

    rows=$(audit_rows_for "$check")
    count=$(printf '%s' "$rows" | grep -c . )
    line=$(printf '%s\n' "$rows" | head -1)
    fields=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    got_key=$(printf '%s' "$line" | cut -d"$TAB" -f2)
    got_status=$(printf '%s' "$line" | cut -d"$TAB" -f3)
    got_detail=$(printf '%s' "$line" | cut -d"$TAB" -f4)

    ok=yes
    [[ "$count" == "1" ]] || ok=no
    [[ "$fields" == "4" ]] || ok=no
    [[ -n "$got_detail" ]] || ok=no
    [[ "$got_status" == "$status" ]] || ok=no
    if [[ "$match" == "prefix" ]]; then
        [[ "$got_key" == "$key"* ]] || ok=no
        # A prefix match must still name something beyond the prefix.
        [[ "${#got_key}" -gt "${#key}" ]] || ok=no
    else
        [[ "$got_key" == "$key" ]] || ok=no
    fi

    if [[ "$ok" == yes ]]; then
        print_test_result "$label emits $check row $key ($status)" "PASS"
    else
        print_test_result "$label emits $check row $key ($status)" "FAIL" \
            "rows=$count fields=$fields key='$got_key' status='$got_status' detail='$got_detail'"
    fi
}

# "No rows" only means "clean" when a scan actually reported, so this demands
# the SUMMARY line too. Otherwise the assertion is satisfied by silence.
assert_no_rows() {
    local label="$1" check="$2"
    local count
    count=$(audit_rows_for "$check" | grep -c .)
    if [[ "$count" == "0" && -n "$(audit_summary_line)" ]]; then
        print_test_result "$label emits no $check rows" "PASS"
    else
        print_test_result "$label emits no $check rows" "FAIL" \
            "got $count rows ($(audit_context))"
    fi
}

assert_summary_field() {
    local label="$1" field="$2" expected="$3"
    local actual
    actual=$(audit_summary_line | tr ' ' '\n' | grep "^$field=" | cut -d= -f2-)
    if [[ "$actual" == "$expected" ]]; then
        print_test_result "$label reports $field=$expected" "PASS"
    else
        print_test_result "$label reports $field=$expected" "FAIL" \
            "got '$field=$actual' ($(audit_context))"
    fi
}

assert_stderr_contains() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$ERR_FILE"; then
        print_test_result "$label names '$needle' on stderr" "PASS"
    else
        print_test_result "$label names '$needle' on stderr" "FAIL" \
            "$(audit_context)"
    fi
}

# ===========================================================================
# The planted stub flag -- the centrepiece.
#
# These three cases run over the WHOLE fixture tree with every check enabled,
# so the totals also prove the fixture is clean of the other five defects.
# ===========================================================================

test_stub_flag_positive() {
    echo -e "${CYAN}Planted stub flag: positive...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" --no-baseline
    assert_single_row "stub-flag positive" \
        stub-flag "src/planted.zig::unused_flag" NEW
    assert_summary_exact "stub-flag positive" \
        "total=1 baselined=n/a new=1 unscannable=0"
    assert_status "stub-flag positive" 1
}

test_stub_flag_negative() {
    echo -e "${CYAN}Planted stub flag: negative (one read added)...${NC}"
    run_audit --root "$FIXTURES/stub-flag/negative" --no-baseline
    assert_no_rows "stub-flag negative" stub-flag
    assert_summary_exact "stub-flag negative" \
        "total=0 baselined=n/a new=0 unscannable=0"
    assert_status "stub-flag negative" 0
}

test_stub_flag_baselined() {
    echo -e "${CYAN}Planted stub flag: baselined...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" \
        --baseline "$FIXTURES/stub-flag/baseline.tsv"
    assert_single_row "stub-flag baselined" \
        stub-flag "src/planted.zig::unused_flag" BASELINED
    assert_summary_exact "stub-flag baselined" \
        "total=1 baselined=1 new=0 unscannable=0"
    assert_status "stub-flag baselined" 0
}

# ===========================================================================
# Output shape
# ===========================================================================

test_output_shape() {
    echo -e "${CYAN}Testing output shape...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" --no-baseline

    local summary_count last
    summary_count=$(grep -c '^SUMMARY ' "$OUT_FILE")
    if [[ "$summary_count" == "1" ]]; then
        print_test_result "stdout carries exactly one SUMMARY line" "PASS"
    else
        print_test_result "stdout carries exactly one SUMMARY line" "FAIL" \
            "got $summary_count ($(audit_context))"
    fi

    last=$(tail -1 "$OUT_FILE")
    if [[ "$last" == SUMMARY\ * ]]; then
        print_test_result "SUMMARY is the last line of stdout" "PASS"
    else
        print_test_result "SUMMARY is the last line of stdout" "FAIL" \
            "last line '$last'"
    fi
}

test_output_is_deterministic() {
    echo -e "${CYAN}Testing determinism...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" --no-baseline
    cp "$OUT_FILE" "$AUDIT_TMP/first"
    run_audit --root "$FIXTURES/stub-flag/positive" --no-baseline

    if cmp -s "$AUDIT_TMP/first" "$OUT_FILE" && grep -q '^SUMMARY ' "$OUT_FILE"; then
        print_test_result "repeated runs produce identical stdout" "PASS"
    else
        print_test_result "repeated runs produce identical stdout" "FAIL" \
            "$(audit_context)"
    fi
}

# ===========================================================================
# The remaining five checks.
#
# These scope with --check so one fixture exercises one rule. parse-only-test
# and stub-flag deliberately overlap on the parse-only fixture (a field that is
# only ever asserted through parsed.opts is also a field nothing reads), which
# is exactly why the scoping matters here.
# ===========================================================================

expect_one_new_finding() {
    local label="$1" root="$2" check="$3" key="$4" unscannable="$5"
    local match="${6:-exact}"
    run_audit --root "$root" --check "$check" --no-baseline
    assert_single_row "$label" "$check" "$key" NEW "$match"
    assert_summary_exact "$label" \
        "total=1 baselined=n/a new=1 unscannable=$unscannable"
    assert_status "$label" 1
}

expect_no_findings() {
    local label="$1" root="$2" check="$3"
    run_audit --root "$root" --check "$check" --no-baseline
    assert_no_rows "$label" "$check"
    assert_summary_exact "$label" "total=0 baselined=n/a new=0 unscannable=0"
    assert_status "$label" 0
}

test_matrix_drift() {
    echo -e "${CYAN}Testing matrix-drift...${NC}"
    expect_one_new_finding "matrix-drift positive" \
        "$FIXTURES/matrix-drift/positive" matrix-drift \
        "docs/specs/driftly-flags.md::--phantom" 0
    # The negative moves Ours to column 2 and leaves the second-to-last
    # column (GNU) claiming yes for the same unresolvable flag: locating the
    # column by position instead of by name reports drift and fails here.
    expect_no_findings "matrix-drift negative" \
        "$FIXTURES/matrix-drift/negative" matrix-drift
}

test_path_shadow() {
    echo -e "${CYAN}Testing path-shadow...${NC}"
    # The key's third segment is the sub-rule name, which the contract leaves
    # to the implementation; the file and the test function are pinned.
    expect_one_new_finding "path-shadow positive" \
        "$FIXTURES/path-shadow/positive" path-shadow \
        "tests/utilities/shadowly_test.sh::test_shadowly::" 0 prefix
    expect_no_findings "path-shadow negative" \
        "$FIXTURES/path-shadow/negative" path-shadow
    expect_one_new_finding "path-shadow exec" \
        "$FIXTURES/path-shadow/positive-exec" path-shadow \
        "tests/utilities/shadowly_test.sh::test_shadowly::" 0 prefix
    expect_one_new_finding "path-shadow run_with_limit" \
        "$FIXTURES/path-shadow/positive-limit" path-shadow \
        "tests/utilities/shadowly_test.sh::test_shadowly::" 0 prefix
}

test_toothless_assert() {
    echo -e "${CYAN}Testing toothless-assert...${NC}"
    # The key's third segment is the sub-rule name, which the contract leaves
    # to the implementation; the file and the test function are pinned.
    expect_one_new_finding "toothless-assert positive" \
        "$FIXTURES/toothless-assert/positive" toothless-assert \
        "tests/utilities/toothy_test.sh::test_toothy::" 0 prefix
    expect_no_findings "toothless-assert negative" \
        "$FIXTURES/toothless-assert/negative" toothless-assert
    # The whoami self-oracle: the expected value comes from the binary under
    # test, so the comparison holds whatever the utility prints.
    expect_one_new_finding "toothless-assert oracle" \
        "$FIXTURES/toothless-assert/positive-oracle" toothless-assert \
        "tests/utilities/toothy_test.sh::test_toothy::" 0 prefix
}

test_test_only_code() {
    echo -e "${CYAN}Testing test-only-code...${NC}"
    expect_one_new_finding "test-only-code positive" \
        "$FIXTURES/test-only-code/positive" test-only-code \
        "src/deadly.zig::doubleWidth" 0
    expect_no_findings "test-only-code negative" \
        "$FIXTURES/test-only-code/negative" test-only-code
}

test_parse_only_test() {
    echo -e "${CYAN}Testing parse-only-test...${NC}"
    expect_one_new_finding "parse-only-test positive" \
        "$FIXTURES/parse-only-test/positive" parse-only-test \
        "src/parsely.zig::show_tabs" 0
    expect_no_findings "parse-only-test negative" \
        "$FIXTURES/parse-only-test/negative" parse-only-test
}

test_unscannable() {
    echo -e "${CYAN}Testing unscannable...${NC}"
    # An unscannable unit is counted in total and new, so a unit that stops
    # being parseable fails the gate instead of dropping out of coverage.
    expect_one_new_finding "unscannable positive" \
        "$FIXTURES/unscannable/positive" unscannable \
        "src/opaquely.zig::no-args-struct" 1
    expect_no_findings "unscannable negative" \
        "$FIXTURES/unscannable/negative" unscannable
}

# ===========================================================================
# --check selection
# ===========================================================================

test_check_selection_excludes() {
    echo -e "${CYAN}Testing --check selection...${NC}"
    # The matrix-drift fixture has a drifting row and a clean parser. Asking
    # only for stub-flag must report nothing at all.
    run_audit --root "$FIXTURES/matrix-drift/positive" --check stub-flag \
        --no-baseline
    assert_no_rows "--check stub-flag on a drifting tree" matrix-drift
    assert_summary_exact "--check stub-flag on a drifting tree" \
        "total=0 baselined=n/a new=0 unscannable=0"
    assert_status "--check stub-flag on a drifting tree" 0
}

test_check_is_repeatable() {
    run_audit --root "$FIXTURES/matrix-drift/positive" --check stub-flag \
        --check matrix-drift --no-baseline
    assert_single_row "repeated --check" matrix-drift \
        "docs/specs/driftly-flags.md::--phantom" NEW
    assert_summary_exact "repeated --check" \
        "total=1 baselined=n/a new=1 unscannable=0"
    assert_status "repeated --check" 1
}

test_unknown_check_name_is_usage_error() {
    run_audit --root "$FIXTURES/stub-flag/positive" --check stub-flags \
        --no-baseline
    assert_status "unknown --check name" 2
}

# ===========================================================================
# baselined= must never be an uncomputed zero
# ===========================================================================

test_no_baseline_reports_na_not_zero() {
    echo -e "${CYAN}Testing baselined=n/a discipline...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" --no-baseline
    local field
    field=$(audit_summary_line | tr ' ' '\n' | grep '^baselined=' | cut -d= -f2-)
    # With no baseline there is nothing to have been baselined against, so
    # baselined=0 would render an uncomputed value as a reassuring one. That
    # is the defect this whole scanner exists to stop shipping.
    if [[ "$field" == "n/a" ]]; then
        print_test_result "--no-baseline reports baselined=n/a" "PASS"
    else
        print_test_result "--no-baseline reports baselined=n/a" "FAIL" \
            "got 'baselined=$field' ($(audit_context))"
    fi
}

test_baseline_in_effect_reports_a_number() {
    run_audit --root "$FIXTURES/stub-flag/positive" \
        --baseline "$FIXTURES/stub-flag/baseline.tsv"
    assert_summary_field "baseline in effect" baselined 1
}

# ===========================================================================
# Baseline file handling
# ===========================================================================

test_missing_default_baseline_is_empty_not_an_error() {
    echo -e "${CYAN}Testing baseline file handling...${NC}"
    # No baseline flag at all, and the fixture tree carries no baseline file:
    # an absent default is an empty baseline, not a failure to scan.
    run_audit --root "$FIXTURES/stub-flag/positive"
    assert_single_row "absent default baseline" \
        stub-flag "src/planted.zig::unused_flag" NEW
    assert_summary_field "absent default baseline" new 1
    assert_summary_field "absent default baseline" baselined 0
    assert_status "absent default baseline" 1
}

test_missing_explicit_baseline_is_an_error() {
    run_audit --root "$FIXTURES/stub-flag/positive" \
        --baseline "$AUDIT_TMP/nonexistent-baseline.tsv"
    assert_status "explicitly named baseline that is absent" 2
}

test_baseline_with_empty_justification_is_rejected() {
    local file="$AUDIT_TMP/empty-justification.tsv"
    printf 'stub-flag\tsrc/planted.zig::unused_flag\t\n' >"$file"
    run_audit --root "$FIXTURES/stub-flag/positive" --baseline "$file"
    assert_status "baseline row with an empty justification" 2
    assert_stderr_contains "baseline row with an empty justification" \
        "src/planted.zig::unused_flag"
}

test_baseline_with_duplicate_keys_is_rejected() {
    local file="$AUDIT_TMP/duplicate-keys.tsv"
    {
        printf 'stub-flag\tsrc/planted.zig::unused_flag\tFirst reason.\n'
        printf 'stub-flag\tsrc/planted.zig::unused_flag\tSecond reason.\n'
    } >"$file"
    run_audit --root "$FIXTURES/stub-flag/positive" --baseline "$file"
    assert_status "baseline with duplicate keys" 2
    assert_stderr_contains "baseline with duplicate keys" \
        "src/planted.zig::unused_flag"
}

test_baseline_with_unknown_check_is_rejected() {
    local file="$AUDIT_TMP/unknown-check.tsv"
    # A typo'd check name would otherwise silently un-baseline nothing: the
    # row is accepted, matches no finding, and the finding stays NEW while the
    # baseline claims to cover it.
    printf 'stub-flagz\tsrc/planted.zig::unused_flag\tTypo in the check name.\n' >"$file"
    run_audit --root "$FIXTURES/stub-flag/positive" --baseline "$file"
    assert_status "baseline naming an unknown check" 2
    assert_stderr_contains "baseline naming an unknown check" "stub-flagz"
}

test_update_baseline_is_refused_under_ci() {
    echo -e "${CYAN}Testing --update-baseline refusal under CI...${NC}"
    # Rewriting the baseline from CI would let a red build launder itself
    # green, so it is a usage error there and only there.
    local saved_ci="${CI:-}"
    export CI=1
    run_audit --root "$FIXTURES/stub-flag/positive" --update-baseline
    if [[ -n "$saved_ci" ]]; then export CI="$saved_ci"; else unset CI; fi
    assert_status "--update-baseline with CI set" 2
}

# ===========================================================================
# Usage and unscannable roots
# ===========================================================================

test_unknown_option_is_usage_error() {
    echo -e "${CYAN}Testing usage errors...${NC}"
    run_audit --root "$FIXTURES/stub-flag/positive" --bogus-option
    assert_status "unknown option" 2
}

test_unreadable_root_is_an_error() {
    run_audit --root "$AUDIT_TMP/no-such-directory" --no-baseline
    assert_status "--root naming a missing directory" 2
}

test_zero_units_is_an_error() {
    # Enumerating nothing means the scan proved nothing. Exiting 0 there is a
    # green build that inspected zero files.
    run_audit --root "$FIXTURES/contract/zero-units" --no-baseline
    assert_status "a tree enumerating zero units" 2
}

# ===========================================================================
# Entry point
# ===========================================================================

main() {
    detect_platform
    run_preflight

    echo -e "${BLUE}Testing audit-check.sh${NC}"
    echo "======================"
    echo "script under test: $AUDIT_CHECK"

    test_stub_flag_positive
    test_stub_flag_negative
    test_stub_flag_baselined
    test_output_shape
    test_output_is_deterministic
    test_matrix_drift
    test_toothless_assert
    test_path_shadow
    test_test_only_code
    test_parse_only_test
    test_unscannable
    test_check_selection_excludes
    test_check_is_repeatable
    test_unknown_check_name_is_usage_error
    test_no_baseline_reports_na_not_zero
    test_baseline_in_effect_reports_a_number
    test_missing_default_baseline_is_empty_not_an_error
    test_missing_explicit_baseline_is_an_error
    test_baseline_with_empty_justification_is_rejected
    test_baseline_with_duplicate_keys_is_rejected
    test_baseline_with_unknown_check_is_rejected
    test_update_baseline_is_refused_under_ci
    test_unknown_option_is_usage_error
    test_unreadable_root_is_an_error
    test_zero_units_is_an_error

    print_test_summary "audit-check"
}

main "$@"
