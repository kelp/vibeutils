#!/usr/bin/env bash
# Contract tests for scripts/tiger-check.sh (issue #131).
#
# WHY THIS LIVES IN tests/tools/ AND NOT tests/utilities/
# ------------------------------------------------------
# tests/lib/test_runner.sh:133-136 globs "$TESTS_DIR/utilities/"*_test.sh and
# runs each file ONLY when [[ -x "$BIN_DIR/$util" ]] holds for the name derived
# from the filename. tiger-check is a script, not a built utility, so no
# zig-out/bin/tiger-check will ever exist and a file dropped in
# tests/utilities/ would be skipped silently, forever, while still looking
# like a test suite in the tree. Do not "tidy" this file into tests/utilities/.
# It is invoked directly, by `just test-tiger-check` and by CI.
#
# Run it with bash (not sh): it sources tests/lib/common.sh, which is bash 4+
# only. macOS needs `brew install bash`, same as every other suite here.
#
# The script under test is taken from $TIGER_CHECK, defaulting to
# scripts/tiger-check.sh. The override exists so the suite can be pointed at a
# deliberate stub to prove the tests fail on real assertions rather than on a
# missing file.
#
# WHAT IS BEING PINNED
# --------------------
# A violation is NEW iff any line of the construct it describes was added in
# the diff. For the four line-anchored rules the construct is one line. For
# long-fn and self-recursion the construct is the whole function, from the
# "fn NAME(" line through the closing brace -- signature, parameter
# continuation lines, and body. Keying those two rules on the declaration line
# alone lets a body grow past the 70-line limit behind an unchanged signature
# and still report PRE, which the pre-commit hook (gate: new>0) waves through.
#
# The regression guards below are the other half of that contract: attributing
# the whole span must NOT degenerate into "any diff in this file is new".
# Editing an unrelated function, or deleting lines from a still-too-long one,
# stays PRE.
#
# Every case asserts the EXIT STATUS, the exact SUMMARY line, and the exact
# set of violation rows. Exit status is what the hook and CI consume, and a
# scanner that prints nothing and exits 0 must not be able to satisfy any of
# these.
#
# FIXTURES ARE THROWAWAY GIT REPOS
# --------------------------------
# tiger-check.sh has no --root: it derives REPO_ROOT from
# `git rev-parse --show-toplevel` and its --base/--staged modes need real git
# history and cwd-relative pathspecs. So each case builds its own repo under
# mktemp -d, cd's into its root, and commits with `-c commit.gpgsign=false`.
# These are scratch repos in a temp dir, never this project's history, so the
# repo's signing policy is untouched. --staged must scan the index, not the
# worktree: test_staged_violation_is_seen_when_worktree_is_clean pins that
# split (issue #149). One remaining known defect is worked around rather than
# tested: the script must run from the repo root.

# Reporting helpers, colours, and PROJECT_ROOT.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# common.sh sets -e; this suite runs a command that is *expected* to exit
# non-zero on many tests, so -e has to go. -u and pipefail stay.
set +e

TIGER_CHECK="${TIGER_CHECK:-$PROJECT_ROOT/scripts/tiger-check.sh}"

TIGER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils_tiger_check.XXXXXX")"
OUT_FILE="$TIGER_TMP/stdout"
ERR_FILE="$TIGER_TMP/stderr"
TIGER_STATUS=0

tiger_cleanup() {
    rm -rf "$TIGER_TMP"
}
trap tiger_cleanup EXIT

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
# Fixture construction
#
# All generated Zig is deliberately boring: `const xN: u8 = N;` lines trip no
# rule, so every violation a case reports is one the case planted.
# ===========================================================================

# fn_body_lines counts from just after the body-opening brace through the
# closing brace inclusive, so a function written as one signature line, N
# content lines and one closing brace measures N+1. The 80-body-line fixture
# below therefore uses 79 content lines.
BIG_CONTENT_LINES=79
BIG_BODY_LINES=80

new_repo() {
    local name="$1"
    local dir="$TIGER_TMP/$name"
    mkdir -p "$dir/src"
    (cd "$dir" && git -c init.defaultBranch=main init -q .) || return 1
    printf '%s\n' "$dir"
}

# Scratch-repo commit. gpgsign is forced off because these repos are temp
# directories with no relationship to this project's signed history, and
# --no-verify keeps a globally-configured hooks path from firing here.
repo_commit() {
    local dir="$1" msg="$2"
    (
        cd "$dir" &&
            git add -A &&
            git -c commit.gpgsign=false \
                -c user.name='vibeutils tests' \
                -c user.email='tests@example.invalid' \
                commit -q --no-verify -m "$msg"
    )
}

repo_stage() {
    local dir="$1"
    (cd "$dir" && git add -A)
}

# A single-signature-line function with `count` body content lines. The
# optional suffix goes on the signature line itself, which is where the
# tiger:allow token is documented to live.
write_fn_file() {
    local file="$1" name="$2" count="$3" suffix="${4:-}" i
    printf 'pub fn %s() void {%s\n' "$name" "$suffix" >"$file"
    for ((i = 1; i <= count; i++)); do
        printf '    const x%d: u8 = %d;\n' "$i" "$((i % 200))" >>"$file"
    done
    printf '}\n' >>"$file"
}

append_small_fn() {
    local file="$1" name="$2"
    {
        printf '\n'
        printf 'pub fn %s() void {\n' "$name"
        printf '    const y: u8 = 1;\n'
        printf '}\n'
    } >>"$file"
}

# awk, not `sed -i`: BSD sed needs an explicit -i '' argument and GNU sed
# rejects it, so an in-place sed is not portable across the two CI platforms.
insert_line_after() {
    local file="$1" after="$2" text="$3"
    awk -v n="$after" -v t="$text" '{ print } NR == n { print t }' "$file" \
        >"$file.tmp" && mv "$file.tmp" "$file"
}

replace_line() {
    local file="$1" n="$2" text="$3"
    awk -v n="$n" -v t="$text" 'NR == n { print t; next } { print }' "$file" \
        >"$file.tmp" && mv "$file.tmp" "$file"
}

delete_lines() {
    local file="$1" from="$2" to="$3"
    awk -v a="$from" -v b="$to" 'NR >= a && NR <= b { next } { print }' "$file" \
        >"$file.tmp" && mv "$file.tmp" "$file"
}

# Exactly 120 display columns: 4 spaces + "// " + 113 'a'.
long_comment_line() {
    awk 'BEGIN {
        s = "";
        for (i = 0; i < 113; i++) s = s "a";
        printf "    // %s", s;
    }'
}

# ===========================================================================
# Invocation and assertion helpers
# ===========================================================================

# The script is always run from the fixture repo root: its changed-file
# pathspecs are cwd-relative and report nothing from a subdirectory.
run_tiger() {
    local dir="$1"
    shift
    : >"$OUT_FILE"
    : >"$ERR_FILE"
    if [[ -x "$TIGER_CHECK" ]]; then
        (cd "$dir" && "$TIGER_CHECK" "$@") >"$OUT_FILE" 2>"$ERR_FILE"
    else
        (cd "$dir" && sh "$TIGER_CHECK" "$@") >"$OUT_FILE" 2>"$ERR_FILE"
    fi
    TIGER_STATUS=$?

    # A scanner that could not be executed at all must not be able to satisfy
    # any expectation. `sh missing-file` reports "can't open" and exits 2 on
    # dash, which collides with the usage-error code and would let an absent
    # script look like a correctly-rejecting one -- the exact ambiguity
    # between "failed for the right reason" and "never ran" that this suite
    # exists to remove.
    if [[ ! -f "$TIGER_CHECK" ]]; then
        TIGER_STATUS="did-not-run"
    fi
}

tiger_summary_line() {
    grep '^SUMMARY ' "$OUT_FILE" | head -1
}

tiger_context() {
    printf 'exit=%s stdout=[%s] stderr=[%s]' \
        "$TIGER_STATUS" \
        "$(tr '\t' '>' <"$OUT_FILE" | head -6 | tr '\n' '|')" \
        "$(head -2 <"$ERR_FILE" | tr '\n' '|')"
}

# One expected violation row, tab-separated exactly as the contract prints it.
row() {
    printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
}

# Exit status is the contract, but a status on its own is not evidence of
# anything: a scanner that never ran also exits 0. So 0 and 1 additionally
# require the SUMMARY line that says a scan completed, and any other status
# requires a diagnostic on stderr. Without those, this assertion would pass
# against a script that does nothing at all.
assert_status() {
    local label="$1" expected="$2"
    local ok=yes why=""

    [[ "$TIGER_STATUS" == "$expected" ]] || {
        ok=no
        why="wrong status"
    }
    if [[ "$expected" == "0" || "$expected" == "1" ]]; then
        [[ -n "$(tiger_summary_line)" ]] || {
            ok=no
            why="$why no SUMMARY"
        }
    else
        [[ -s "$ERR_FILE" ]] || {
            ok=no
            why="$why silent stderr"
        }
    fi

    if [[ "$ok" == yes ]]; then
        print_test_result "$label exits $expected" "PASS"
    else
        print_test_result "$label exits $expected" "FAIL" \
            "$why: $(tiger_context)"
    fi
}

# The whole SUMMARY line, field for field. Callers pass everything after the
# word SUMMARY, e.g. "total=1 new=1".
assert_summary_exact() {
    local label="$1" fields="$2"
    local expected="SUMMARY $fields"
    local actual
    actual=$(tiger_summary_line)
    if [[ "$actual" == "$expected" ]]; then
        print_test_result "$label summary is '$expected'" "PASS"
    else
        print_test_result "$label summary is '$expected'" "FAIL" \
            "got '$actual' ($(tiger_context))"
    fi
}

# Every violation row, in order, byte for byte -- rule, file:line, status and
# detail. Pinning the detail matters here: `body_lines=` is what says the
# scanner measured the function it is reporting on, and a NEW/PRE flip with a
# silently different span would otherwise pass. Passing no rows asserts the
# scan found nothing, and still demands the SUMMARY line so silence cannot
# satisfy it.
assert_rows_exact() {
    local label="$1"
    shift
    local expected="$TIGER_TMP/expected" actual="$TIGER_TMP/actual" r
    : >"$expected"
    for r in "$@"; do
        printf '%s\n' "$r" >>"$expected"
    done
    grep -v '^SUMMARY ' "$OUT_FILE" >"$actual"

    local want got
    want=$(tr '\t' '>' <"$expected" | tr '\n' '|')
    got=$(tr '\t' '>' <"$actual" | tr '\n' '|')

    if [[ -n "$(tiger_summary_line)" ]] && cmp -s "$expected" "$actual"; then
        print_test_result "$label emits exactly $# violation row(s)" "PASS"
    else
        print_test_result "$label emits exactly $# violation row(s)" "FAIL" \
            "want [$want] got [$got] ($(tiger_context))"
    fi
}

assert_stderr_contains() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$ERR_FILE"; then
        print_test_result "$label names '$needle' on stderr" "PASS"
    else
        print_test_result "$label names '$needle' on stderr" "FAIL" \
            "$(tiger_context)"
    fi
}

# ===========================================================================
# RED: a violation whose span was touched is NEW, wherever in the span the
# edit landed.
# ===========================================================================

# R1 -- the issue verbatim. A function one line under the limit grows two
# lines in its body; the signature bytes never change. The hook gates on
# new>0, so PRE here is a 71-line function landing unnoticed.
test_body_growth_past_limit_is_new() {
    echo -e "${CYAN}RED R1: body grows past 70 behind an unchanged signature...${NC}"
    local repo
    repo=$(new_repo grow) || return 1
    write_fn_file "$repo/src/grow.zig" grow 68
    repo_commit "$repo" "clean 69-line body"

    insert_line_after "$repo/src/grow.zig" 35 '    const grown_a: u8 = 1;'
    insert_line_after "$repo/src/grow.zig" 36 '    const grown_b: u8 = 2;'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "R1 body growth" \
        "$(row long-fn src/grow.zig:1 NEW 'body_lines=71 fn=grow')"
    assert_summary_exact "R1 body growth" "total=1 new=1"
    assert_status "R1 body growth" 1
}

# R2 -- the same growth seen through the pre-commit hook's own mode. The
# worktree is left matching the index; the index-vs-worktree split is
# test_staged_violation_is_seen_when_worktree_is_clean.
test_body_growth_past_limit_is_new_when_staged() {
    echo -e "${CYAN}RED R2: the same growth, staged...${NC}"
    local repo
    repo=$(new_repo grow_staged) || return 1
    write_fn_file "$repo/src/grow.zig" grow 68
    repo_commit "$repo" "clean 69-line body"

    insert_line_after "$repo/src/grow.zig" 35 '    const grown_a: u8 = 1;'
    insert_line_after "$repo/src/grow.zig" 36 '    const grown_b: u8 = 2;'
    repo_stage "$repo"

    run_tiger "$repo" --staged
    assert_rows_exact "R2 staged body growth" \
        "$(row long-fn src/grow.zig:1 NEW 'body_lines=71 fn=grow')"
    assert_summary_exact "R2 staged body growth" "total=1 new=1"
    assert_status "R2 staged body growth" 1
}

# Issue #149 -- --staged must report what is in the index, even when the
# worktree has been restored to HEAD. Stage the same body growth as R2, then
# restore the worktree without unstaging so only the index still carries the
# violation. Scanning the worktree here would report a clean tree.
test_staged_violation_is_seen_when_worktree_is_clean() {
    echo -e "${CYAN}RED #149: staged violation with a clean worktree...${NC}"
    local repo
    repo=$(new_repo grow_staged_clean_wt) || return 1
    write_fn_file "$repo/src/grow.zig" grow 68
    repo_commit "$repo" "clean 69-line body"

    insert_line_after "$repo/src/grow.zig" 35 '    const grown_a: u8 = 1;'
    insert_line_after "$repo/src/grow.zig" 36 '    const grown_b: u8 = 2;'
    repo_stage "$repo"

    # Restore worktree from HEAD; leave the index holding the growth.
    (cd "$repo" && git restore --source=HEAD --worktree -- src/grow.zig)

    run_tiger "$repo" --staged
    assert_rows_exact "staged vs clean worktree" \
        "$(row long-fn src/grow.zig:1 NEW 'body_lines=71 fn=grow')"
    assert_summary_exact "staged vs clean worktree" "total=1 new=1"
    assert_status "staged vs clean worktree" 1
}

# R3 -- discharges "the same reasoning applies to any other check anchored on
# a declaration". self-recursion is the second rule emitted at fn_start.
test_recursion_added_to_body_is_new() {
    echo -e "${CYAN}RED R3: recursion added to an unchanged signature...${NC}"
    local repo
    repo=$(new_repo rec) || return 1
    {
        printf 'pub fn helper(n: u8) u8 {\n'
        printf '    if (n == 0) return 0;\n'
        printf '    return n;\n'
        printf '}\n'
    } >"$repo/src/rec.zig"
    repo_commit "$repo" "non-recursive helper"

    insert_line_after "$repo/src/rec.zig" 2 '    if (n > 1) return helper(n - 1);'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "R3 recursion added" \
        "$(row self-recursion src/rec.zig:1 NEW 'fn=helper')"
    assert_summary_exact "R3 recursion added" "total=1 new=1"
    assert_status "R3 recursion added" 1
}

# R4 -- an already-too-long function whose body is edited in place. Nothing
# grew, but the commit is still touching a violating construct, so the gate
# must see it rather than inheriting the previous commit's pass.
test_edit_inside_violating_body_is_new() {
    echo -e "${CYAN}RED R4: a body line modified inside a violating fn...${NC}"
    local repo
    repo=$(new_repo modbody) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    repo_commit "$repo" "80-line body"

    replace_line "$repo/src/big.zig" 40 '    const edited: u8 = 7;'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "R4 body edit" \
        "$(row long-fn src/big.zig:1 NEW "body_lines=$BIG_BODY_LINES fn=big")"
    assert_summary_exact "R4 body edit" "total=1 new=1"
    assert_status "R4 body edit" 1
}

# R5 -- the case nobody finds by hand: a multi-line signature where the added
# line is a parameter continuation, so neither the "fn NAME(" line nor the
# body changed, yet the declaration itself did.
test_added_parameter_continuation_line_is_new() {
    echo -e "${CYAN}RED R5: a parameter line added to a multi-line signature...${NC}"
    local repo i
    repo=$(new_repo widesig) || return 1
    {
        printf 'pub fn wide(\n'
        printf '    a: u8,\n'
        printf '    b: u8,\n'
        printf ') void {\n'
        for ((i = 1; i <= 79; i++)); do
            printf '    const x%d: u8 = %d;\n' "$i" "$((i % 200))"
        done
        printf '}\n'
    } >"$repo/src/wide.zig"
    repo_commit "$repo" "80-line body, multi-line signature"

    insert_line_after "$repo/src/wide.zig" 3 '    c: u8,'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "R5 parameter line added" \
        "$(row long-fn src/wide.zig:1 NEW "body_lines=$BIG_BODY_LINES fn=wide")"
    assert_summary_exact "R5 parameter line added" "total=1 new=1"
    assert_status "R5 parameter line added" 1
}

# ===========================================================================
# GREEN GUARDS: attribution must stay narrow.
#
# G1 and G2 are load-bearing. Without them "NEW iff any line of the span was
# added" could be satisfied by "NEW iff the file changed at all", which would
# make the hook unusable on any file that already carries a violation.
# ===========================================================================

# G1 -- a pre-existing violation in a file whose *other* function is what the
# commit touches. The violation is not this commit's, and must stay PRE.
test_unrelated_function_edit_stays_pre() {
    echo -e "${CYAN}GREEN G1: editing an unrelated fn in the same file...${NC}"
    local repo
    repo=$(new_repo unrelated) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    append_small_fn "$repo/src/big.zig" other
    repo_commit "$repo" "80-line body plus a small fn"

    # Line 85 is the single body line of `other`, well past the closing brace
    # of `big` on line 81.
    replace_line "$repo/src/big.zig" 85 '    const y: u8 = 2;'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G1 unrelated fn edit" \
        "$(row long-fn src/big.zig:1 PRE "body_lines=$BIG_BODY_LINES fn=big")"
    assert_summary_exact "G1 unrelated fn edit" "total=1 new=0"
    assert_status "G1 unrelated fn edit" 0
}

# G2 -- shrinking a still-too-long function. The hunk contains only removals,
# so there is no added line anywhere in the span. Blocking this would punish
# the exact commit that is working the violation down.
test_deleting_body_lines_stays_pre() {
    echo -e "${CYAN}GREEN G2: deleting body lines from a long fn...${NC}"
    local repo
    repo=$(new_repo shrink) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    repo_commit "$repo" "80-line body"

    delete_lines "$repo/src/big.zig" 40 41

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G2 body shrink" \
        "$(row long-fn src/big.zig:1 PRE 'body_lines=78 fn=big')"
    assert_summary_exact "G2 body shrink" "total=1 new=0"
    assert_status "G2 body shrink" 0
}

# G3 -- the escape hatch. Suppression is keyed on the signature line and runs
# before any NEW/PRE decision, so a deliberate long function stays silent even
# when its body is edited.
test_inline_suppression_still_wins() {
    echo -e "${CYAN}GREEN G3: tiger:allow:long-fn on the signature line...${NC}"
    local repo
    repo=$(new_repo suppressed) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES" \
        ' // tiger:allow:long-fn'
    repo_commit "$repo" "80-line body, suppressed"

    replace_line "$repo/src/big.zig" 40 '    const edited: u8 = 7;'

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G3 suppression"
    assert_summary_exact "G3 suppression" "total=0 new=0"
    assert_status "G3 suppression" 0
    assert_stderr_contains "G3 suppression" "suppressed"
}

# G4 -- the four rules that were already keyed on the offending line keep
# reporting at that line, and usize-arch stays out of the totals (four rows,
# total=3). This is the anti-collateral guard for the other two thirds of the
# scanner.
test_line_anchored_rules_unchanged() {
    echo -e "${CYAN}GREEN G4: the four line-anchored rules...${NC}"
    local repo long_line
    repo=$(new_repo lines) || return 1
    {
        printf 'pub fn small() void {\n'
        printf '    const a: u8 = 1;\n'
        printf '}\n'
    } >"$repo/src/a.zig"
    repo_commit "$repo" "clean small fn"

    long_line=$(long_comment_line)
    insert_line_after "$repo/src/a.zig" 2 '    var n: usize = 0;'
    insert_line_after "$repo/src/a.zig" 2 '    while (true) {}'
    insert_line_after "$repo/src/a.zig" 2 '    assert(a and b);'
    insert_line_after "$repo/src/a.zig" 2 "$long_line"

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G4 line-anchored rules" \
        "$(row long-line src/a.zig:3 NEW 'width=120')" \
        "$(row compound-assert src/a.zig:4 NEW 'compound boolean (and) in assert')" \
        "$(row unbounded-loop src/a.zig:5 NEW 'while (true)')" \
        "$(row usize-arch src/a.zig:6 NEW 'usize')"
    assert_summary_exact "G4 line-anchored rules" "total=3 new=3"
    assert_status "G4 line-anchored rules" 1
}

# G5 -- a violating tree with nothing changed. The diff modes gate on new
# only, so an untouched violation is not this commit's problem.
test_no_diff_reports_nothing() {
    echo -e "${CYAN}GREEN G5: a violating tree with no diff...${NC}"
    local repo
    repo=$(new_repo nodiff) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    repo_commit "$repo" "80-line body"

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G5 no diff"
    assert_summary_exact "G5 no diff" "total=0 new=0"
    assert_status "G5 no diff" 0
    assert_stderr_contains "G5 no diff" "no changed src"
}

# G6 -- the #127 contract. Outside the diff modes there is no baseline to be
# new against, so the status column is "-" and new is n/a. Printing new=0
# there renders an uncomputed value as a reassuring one.
test_no_arg_mode_reports_na() {
    echo -e "${CYAN}GREEN G6: tree-wide mode reports new=n/a...${NC}"
    local repo
    repo=$(new_repo treewide) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    repo_commit "$repo" "80-line body"

    run_tiger "$repo"
    assert_rows_exact "G6 tree-wide" \
        "$(row long-fn src/big.zig:1 - "body_lines=$BIG_BODY_LINES fn=big")"
    assert_summary_exact "G6 tree-wide" "total=1 new=n/a"
    assert_status "G6 tree-wide" 1
}

# G7 -- same contract for an explicit file list.
test_file_mode_reports_na() {
    echo -e "${CYAN}GREEN G7: explicit file mode reports new=n/a...${NC}"
    local repo
    repo=$(new_repo filemode) || return 1
    write_fn_file "$repo/src/big.zig" big "$BIG_CONTENT_LINES"
    repo_commit "$repo" "80-line body"

    run_tiger "$repo" src/big.zig
    assert_rows_exact "G7 file mode" \
        "$(row long-fn src/big.zig:1 - "body_lines=$BIG_BODY_LINES fn=big")"
    assert_summary_exact "G7 file mode" "total=1 new=n/a"
    assert_status "G7 file mode" 1
}

# G8 -- a whole new file. Every line is added, including the signature, so
# this already reports NEW today; it is here because a span-keyed rule that
# regressed on wholesale additions would be worse than the bug.
test_new_file_is_new() {
    echo -e "${CYAN}GREEN G8: a brand-new file added wholesale...${NC}"
    local repo
    repo=$(new_repo newfile) || return 1
    {
        printf 'pub fn keep() void {\n'
        printf '    const a: u8 = 1;\n'
        printf '}\n'
    } >"$repo/src/keep.zig"
    repo_commit "$repo" "seed"

    write_fn_file "$repo/src/fresh.zig" fresh "$BIG_CONTENT_LINES"
    # git diff cannot see an untracked file, so the addition has to be staged
    # for --base HEAD to consider it at all.
    repo_stage "$repo"

    run_tiger "$repo" --base HEAD
    assert_rows_exact "G8 new file" \
        "$(row long-fn src/fresh.zig:1 NEW "body_lines=$BIG_BODY_LINES fn=fresh")"
    assert_summary_exact "G8 new file" "total=1 new=1"
    assert_status "G8 new file" 1
}

# ===========================================================================
# Entry point
# ===========================================================================

main() {
    detect_platform

    if [[ ! -f "$TIGER_CHECK" ]]; then
        echo -e "${YELLOW}note:${NC} $TIGER_CHECK does not exist;" \
            "every contract test below must fail." >&2
    fi

    echo -e "${BLUE}Testing tiger-check.sh${NC}"
    echo "======================"
    echo "script under test: $TIGER_CHECK"

    test_body_growth_past_limit_is_new
    test_body_growth_past_limit_is_new_when_staged
    test_staged_violation_is_seen_when_worktree_is_clean
    test_recursion_added_to_body_is_new
    test_edit_inside_violating_body_is_new
    test_added_parameter_continuation_line_is_new

    test_unrelated_function_edit_stays_pre
    test_deleting_body_lines_stays_pre
    test_inline_suppression_still_wins
    test_line_anchored_rules_unchanged
    test_no_diff_reports_nothing
    test_no_arg_mode_reports_na
    test_file_mode_reports_na
    test_new_file_is_new

    # A suite that built no fixtures and asserted nothing reports "all tests
    # passed", which is the same vacuous green this file exists to prevent in
    # the scanner. Refuse it here too.
    if [[ "$TESTS_RUN" -lt 44 ]]; then
        echo -e "${RED}fatal:${NC} only $TESTS_RUN assertions ran;" \
            "the suite did not complete." >&2
        print_test_summary "tiger-check"
        exit 2
    fi

    print_test_summary "tiger-check"
}

main "$@"
