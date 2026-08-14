#!/bin/sh
# audit-check.sh — deterministic stage-1 audit pre-pass for vibeutils.
#
# Implements stage 1 of docs/AUDIT_SWEEP.md: the mechanical checks that
# need no model at all, run over every unit in build/utils.zig in
# seconds. Plain POSIX sh + awk; no Zig toolchain, no `just`, no git
# history.
#
# USAGE:
#   audit-check.sh [--root DIR] [--check NAME]...
#                  [--baseline FILE | --no-baseline | --update-baseline]
#
#   --root DIR          scan DIR instead of the repository root. Fixture
#                       trees carry their own build/utils.zig and
#                       docs/specs, so the real enumerator scans a planted
#                       defect without that defect entering the repo gate.
#   --check NAME        run only NAME. Repeatable. Names:
#                       stub-flag, unscannable, matrix-drift,
#                       toothless-assert, test-only-code, parse-only-test,
#                       path-shadow.
#   --baseline FILE     use FILE as the baseline. A named file that is
#                       absent is an error; the DEFAULT baseline
#                       (<root>/scripts/audit-baseline.tsv) being absent
#                       is simply an empty baseline.
#   --no-baseline       classify every finding NEW.
#   --update-baseline   rewrite the baseline from the current findings.
#                       Refused when CI is set: rewriting the baseline
#                       from CI would let a red build launder itself green.
#
# OUTPUT (stdout), one TAB-separated line per finding:
#   <check>\t<key>\t<status>\t<detail>        status is NEW or BASELINED
# then exactly one summary line:
#   SUMMARY total=<N> baselined=<N> new=<N> unscannable=<N>
# With --no-baseline, baselined= prints "n/a", never "0": there is no
# baseline to have been matched against, and rendering an uncomputed
# value as a reassuring zero is the exact defect this scanner exists to
# stop shipping.
#
# EXIT: 0 when new==0; 1 when new>0; 2 for a usage error, an unreadable
#   root, a tree that enumerates zero units, a bad baseline file, or
#   --update-baseline under CI. THE EXIT CODE IS THE CONTRACT — nothing
#   parses the summary prose. stderr is human notes only.
#
# BASELINE FORMAT: <check>\t<key>\t<justification>, one row per accepted
#   finding. Keys are line-independent by construction
#   (src/df.zig::suppress_inodes, not src/df.zig:110), so an accepted
#   finding stays accepted when the code around it moves. There is no
#   inline suppression comment: a line-local hatch inherits exactly the
#   defect class that made line-keyed suppression unreliable. An empty
#   justification, a duplicate key, or an unknown check name is a hard
#   error — an unjustified baseline row is indistinguishable from a
#   silent suppression.
#
# CHECK COVERAGE AND ITS LIMITS
#   stub-flag, unscannable, matrix-drift, toothless-assert,
#   test-only-code and path-shadow are complete for the shapes this repo
#   actually uses.
#
#   parse-only-test SHIPS DELIBERATELY INCOMPLETE. There is no reliable
#   mechanical link from a shell test to the struct field it exercises,
#   so this check implements only the tractable subset: a field asserted
#   through `parsed.opts.<field>` inside a Zig `test` block whose only
#   other appearance is its parse-site write. A flag whose behaviour is
#   pinned nowhere but which is never asserted that way is NOT reported.
#   Read a clean parse-only-test as "no instances of the narrow pattern",
#   never as "every flag has a behavioural test". The other five checks
#   do not depend on it. See docs/AUDIT_SWEEP.md.
#
#   unscannable is the anti-false-negative device that makes the rest
#   trustworthy: a unit whose args struct cannot be found, whose flag
#   matrix has no `Ours` column, or whose test file is missing is
#   REPORTED and counted toward new, so it fails CI instead of silently
#   dropping out of coverage. False positives here are cheap; a unit
#   quietly leaving the scanned set is the failure mode.

# Note: intentionally NOT using `set -e`. The scan must run to
# completion and emit the SUMMARY line even when an individual unit is
# missing or unreadable, so the gate always gets parseable output.
set -u

PROG=audit-check
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TAB=$(printf '\t')

ALL_CHECKS="stub-flag unscannable matrix-drift toothless-assert test-only-code parse-only-test path-shadow"

note() {
    # Human-readable note to stderr only.
    printf '%s: %s\n' "$PROG" "$*" >&2
}

usage() {
    cat >&2 <<'EOF'
Usage:
  audit-check.sh [--root DIR] [--check NAME]...
                 [--baseline FILE | --no-baseline | --update-baseline]

  --root DIR         scan DIR instead of the repository root
  --check NAME       run only NAME (repeatable): stub-flag, unscannable,
                     matrix-drift, toothless-assert, test-only-code,
                     parse-only-test, path-shadow
  --baseline FILE    use FILE as the baseline (must exist)
  --no-baseline      classify every finding NEW
  --update-baseline  rewrite the baseline from current findings
EOF
}

# ---------------------------------------------------------------------------
# The Zig source scanner. Reads ONE .zig file from stdin. Variables:
#   FILE   display path used in keys and output
# Emits, to stdout:
#   ROW <TAB> <check> <TAB> <key> <TAB> <detail>   a finding
#   F   <TAB> <field> <TAB> <writes> <TAB> <reads> field table
#   S   <TAB> <char>  <TAB> <field>               meta .short mapping
#   L   <TAB> <long>  <TAB> <field>               meta .long mapping
#   NOSTRUCT                                       no args struct found
# The field/meta facts are consumed by the matrix-drift pass, which must
# resolve a spec row to a parser field without re-parsing the source.
#
# Whole-file buffering (not tiger-check's single pass) is required: a
# field's reads must be counted across the ENTIRE file before the field
# can be judged, and the struct that declares it may appear after its
# first use.
# ---------------------------------------------------------------------------
SRC_AWK='
# Blank out // comments and string/char literal contents so identifier
# rules never match inside them. Same conservative approach as
# tiger-check.sh: multiline string lines are blanked wholesale.
function strip_cs(s,   out, i, n, c, instr, inchr) {
    n = length(s);
    out = ""; instr = 0; inchr = 0;
    if (s ~ /^[ \t]*\\\\/) return "";
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1);
        if (instr) {
            if (c == "\\") { out = out "  "; i++; continue; }
            if (c == "\"") { instr = 0; out = out " "; continue; }
            out = out " "; continue;
        }
        if (inchr) {
            if (c == "\\") { out = out "  "; i++; continue; }
            if (c == "\x27") { inchr = 0; out = out " "; continue; }
            out = out " "; continue;
        }
        if (c == "/" && substr(s, i + 1, 1) == "/") break;
        if (c == "\"") { instr = 1; out = out " "; continue; }
        if (c == "\x27") { inchr = 1; out = out " "; continue; }
        out = out c;
    }
    return out;
}

function brace_delta(code,   i, n, c, d) {
    d = 0; n = length(code);
    for (i = 1; i <= n; i++) {
        c = substr(code, i, 1);
        if (c == "{") d++;
        else if (c == "}") d--;
    }
    return d;
}

function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s);
    return s;
}

# Count reads and writes of args-struct fields on one code line.
# A reference is receiver-qualified (opts.foo, options.foo,
# parsed.opts.foo, ...) unless AGNOSTIC is set. Over-counting reads is
# the false-negative risk for stub-flag, so the receiver set is the
# default and the agnostic fallback only runs when the receiver-qualified
# pass found nothing at all -- a case that also reports unscannable.
function scan_refs(i, s,   pos, st, len, tok, before, after, np, parts, k, j, recv, fld, a) {
    pos = 1;
    while (match(substr(s, pos), /[A-Za-z_][A-Za-z0-9_.]*/)) {
        st = pos + RSTART - 1;
        len = RLENGTH;
        tok = substr(s, st, len);
        pos = st + len;
        while (length(tok) > 0 && substr(tok, length(tok), 1) == ".") {
            tok = substr(tok, 1, length(tok) - 1);
        }
        if (length(tok) == 0) continue;
        before = (st > 1) ? substr(s, st - 1, 1) : "";
        after = substr(s, st + length(tok));
        np = split(tok, parts, ".");
        a = after; sub(/^[ \t]*/, "", a);
        is_write = (substr(a, 1, 1) == "=" &&
                    substr(a, 2, 1) != "=" && substr(a, 2, 1) != ">");
        j = 0;
        # Find the field ANYWHERE in the dotted chain, not just at its
        # end: `opts.display.color = .off` reaches through `display`, so
        # treating only the last component as the reference would report
        # a field the program plainly uses as an unread stub.
        for (k = 1; k < np; k++) {
            if ((parts[k] in RECV || AGNOSTIC) && (parts[k + 1] in FIELD)) {
                j = k + 1;
                break;
            }
        }
        if (j > 0) {
            recv = parts[j - 1];
            fld = parts[j];
            if (IS_TEST[i]) {
                if (j >= 3 && recv == "opts") TESTPARSED[fld]++;
                continue;
            }
            TOTREF++;
            # Only a chain that ENDS at the field can assign to it; a
            # longer chain reads the field to reach a member of it.
            if (is_write && j == np) W[fld]++; else R[fld]++;
        } else if (np == 1) {
            fld = parts[1];
            # A bare ".field = value" is a struct-literal initialiser,
            # i.e. a write with no receiver to qualify.
            if (before != "." || !(fld in FIELD) || !is_write) continue;
            if (IS_TEST[i]) continue;
            TOTREF++;
            W[fld]++;
        }
    }
}

# Count uses of locally-defined functions, partitioned by whether the use
# is inside a test block. Every bare mention counts, not just `name(`:
# `common.utilityMain(init, run)` hands `run` over as a value, and a
# scanner that only recognised call syntax would report every utility`s
# real entry point as dead production code.
function scan_uses(i, s,   pos, st, len, id, before, pre) {
    pos = 1;
    while (match(substr(s, pos), /[A-Za-z_][A-Za-z0-9_]*/)) {
        st = pos + RSTART - 1;
        len = RLENGTH;
        id = substr(s, st, len);
        pos = st + len;
        before = (st > 1) ? substr(s, st - 1, 1) : "";
        pre = substr(s, 1, st - 1);
        if (before ~ /[A-Za-z0-9_.]/) continue;
        if (pre ~ /(^|[^A-Za-z0-9_])fn[ \t]+$/) continue;
        if (id in KEYWORD) continue;
        if (IS_TEST[i]) TCALL[id]++; else NCALL[id]++;
    }
}

BEGIN {
    split("opts options opt args parsed_args parsed cfg config self", rv, " ");
    for (k in rv) RECV[rv[k]] = 1;
    split("if while for switch return catch orelse try comptime defer errdefer inline and or", kw, " ");
    for (k in kw) KEYWORD[kw[k]] = 1;
    AGNOSTIC = 0;
}

{
    line = $0;
    sub(/\r$/, "", line);
    RAW[NR] = line;
    CODE[NR] = strip_cs(line);
}

END {
    n_lines = NR;
    classify();
    count_refs();
    if (TOTREF == 0 && n_fields > 0) {
        # No field of any args struct is referenced through a known
        # receiver. Rather than silently reporting "no stubs", widen to a
        # receiver-agnostic count AND report the unit unscannable.
        AGNOSTIC = 1;
        for (f in W) delete W[f];
        for (f in R) delete R[f];
        count_refs();
        printf "ROW\t%s\t%s::%s\t%s\n", "unscannable", FILE,
            "no-receiver", "args-struct fields are never referenced through a known receiver";
    }
    if (n_structs == 0) {
        print "NOSTRUCT";
        printf "ROW\t%s\t%s::%s\t%s\n", "unscannable", FILE,
            "no-args-struct", "no `const <Name>(Args|Options|Opts|Config) = struct` to build a field table from";
    }
    report();
}

# Mark test blocks and args-struct spans, and harvest the field table
# plus the meta short/long mappings.
function classify(   i, c, ld, f, r, m, t, ch) {
    gdepth = 0; mode = ""; n_structs = 0; n_fields = 0; cur_meta = ""; first_test = 0;
    in_sfn = 0; sfn_base = 0;
    for (i = 1; i <= n_lines; i++) {
        c = CODE[i];
        ld = gdepth;
        if (mode == "" && ld == 0) {
            if (c ~ /^test[ \t]*[\{"]/) {
                mode = "test";
                if (first_test == 0) first_test = i;
            } else if (c ~ /^(pub[ \t]+)?const[ \t]+[A-Za-z_][A-Za-z0-9_]*(Args|Options|Opts|Config)[ \t]*=[ \t]*struct[ \t]*\{/) {
                mode = "struct"; n_structs++; cur_meta = "";
            }
        }
        if (mode == "test") IS_TEST[i] = 1;
        if (mode == "struct") {
            IS_STRUCT[i] = 1;
            # Declarations inside the struct -- the field list and the
            # `meta` table -- must not be counted as uses of the fields
            # they name. A METHOD on the struct is different: `self.foo`
            # in a body is a genuine read, and skipping the whole span
            # would report every field a method consumes as an unread
            # stub.
            if (!in_sfn) {
                STRUCT_SKIP[i] = 1;
                if (c ~ /(^|[^A-Za-z0-9_])fn[ \t]+[A-Za-z_]/) {
                    in_sfn = 1; sfn_base = ld; STRUCT_SKIP[i] = 1;
                }
            }
            if (ld == 1 && RAW[i] ~ /^[ \t]*[a-z_][A-Za-z0-9_]*[ \t]*:/) {
                f = RAW[i];
                sub(/^[ \t]*/, "", f); sub(/[ \t]*:.*$/, "", f);
                if (f != "positionals" && !(f in FIELD)) {
                    FIELD[f] = 1; FIELD_ORDER[++n_fields] = f;
                }
            }
            if (ld >= 2) {
                r = RAW[i];
                if (match(r, /\.[a-z_][A-Za-z0-9_]*[ \t]*=[ \t]*\.\{/)) {
                    m = substr(r, RSTART + 1, RLENGTH - 1);
                    sub(/[ \t]*=.*$/, "", m);
                    cur_meta = m;
                }
                if (cur_meta != "") {
                    if (match(r, /\.short[ \t]*=[ \t]*\x27.\x27/)) {
                        ch = substr(r, RSTART + RLENGTH - 2, 1);
                        if (!(ch in META_SHORT)) META_SHORT[ch] = cur_meta;
                    }
                    if (match(r, /\.long[ \t]*=[ \t]*"[^"]*"/)) {
                        t = substr(r, RSTART, RLENGTH);
                        sub(/^[^"]*"/, "", t); sub(/"$/, "", t);
                        if (t != "" && !(t in META_LONG)) META_LONG[t] = cur_meta;
                    }
                }
            }
        }
        gdepth += brace_delta(c);
        if (in_sfn && gdepth <= sfn_base) in_sfn = 0;
        if (mode != "" && gdepth <= 0) { mode = ""; in_sfn = 0; }
        if (gdepth < 0) gdepth = 0;
    }
}

function count_refs(   i, nm, ispub, hdr) {
    TOTREF = 0;
    for (i = 1; i <= n_lines; i++) {
        if (!STRUCT_SKIP[i]) scan_refs(i, CODE[i]);
        if (AGNOSTIC) continue;
        if (IS_STRUCT[i]) continue;
        if (match(CODE[i], /(^|[^A-Za-z0-9_])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
            hdr = substr(CODE[i], RSTART, RLENGTH);
            nm = hdr;
            sub(/.*fn[ \t]+/, "", nm);
            sub(/[ \t]*\(.*/, "", nm);
            if (CODE[i] ~ /(^|[^A-Za-z0-9_])(pub|export|extern)[ \t]/) {
                PUBFN[nm] = 1;
            } else if (IS_TEST[i]) {
                PUBFN[nm] = 1;
            } else if (first_test > 0 && i > first_test) {
                # Declared below the file`s first test block, i.e. in the
                # test section. A helper written FOR the tests is not a
                # production path that decayed into a test-only one, which
                # is the defect this check is looking for.
                PUBFN[nm] = 1;
            } else if (!(nm in FNDEF)) {
                FNDEF[nm] = i; FN_ORDER[++n_fns] = nm;
            }
        }
        scan_uses(i, CODE[i]);
    }
}

function report(   k, f, nm) {
    for (k = 1; k <= n_fields; k++) {
        f = FIELD_ORDER[k];
        printf "F\t%s\t%d\t%d\n", f, W[f] + 0, R[f] + 0;
        if (W[f] + 0 > 0 && R[f] + 0 == 0) {
            printf "ROW\t%s\t%s::%s\t%s\n", "stub-flag", FILE, f,
                "written at the parse site, never read outside tests (writes=" (W[f] + 0) ")";
            if (TESTPARSED[f] + 0 > 0) {
                printf "ROW\t%s\t%s::%s\t%s\n", "parse-only-test", FILE, f,
                    "only assertion is parsed.opts." f " in a test block; no behaviour is pinned";
            }
        }
    }
    for (k in META_SHORT) printf "S\t%s\t%s\n", k, META_SHORT[k];
    for (k in META_LONG) printf "L\t%s\t%s\n", k, META_LONG[k];
    for (k = 1; k <= n_fns; k++) {
        nm = FN_ORDER[k];
        if (nm in PUBFN) continue;
        if (NCALL[nm] + 0 == 0 && TCALL[nm] + 0 > 0) {
            printf "ROW\t%s\t%s::%s\t%s\n", "test-only-code", FILE, nm,
                "private fn whose only call sites are inside test blocks (test calls=" (TCALL[nm] + 0) ")";
        }
    }
}
'

# ---------------------------------------------------------------------------
# The flag-matrix scanner. Reads the unit facts file then the spec file.
# Variables:
#   SPEC     display path of the spec file (used in keys)
#   SRCFILE  absolute path of the unit source, slurped for literal lookups
#
# The `Ours` column is located BY NAME. Its position is not fixed: df's
# table carries a POSIX column that whoami's does not, so a positional
# lookup silently reads a different column's verdict.
# ---------------------------------------------------------------------------
SPEC_AWK='
function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s);
    return s;
}

BEGIN {
    blob = "";
    while ((getline aline < SRCFILE) > 0) blob = blob aline "\n";
    close(SRCFILE);
    ours_idx = 0;
    saw_table = 0;
}

FNR == NR {
    # Facts from SRC_AWK for this unit.
    if ($1 == "F") { FIELD[$2] = 1; WR[$2] = $3; RD[$2] = $4; }
    else if ($1 == "S") SHORT[$2] = $3;
    else if ($1 == "L") LONG[$2] = $3;
    next;
}

/^[ \t]*\|/ {
    line = $0;
    ncell = split(line, cell, "|");
    # A separator row (|---|---|) carries no verdicts.
    if (line ~ /^[ \t]*\|[- :|]*$/) next;
    for (i = 2; i < ncell; i++) {
        if (trim(cell[i]) == "Ours") { ours_idx = i; saw_table = 1; header = 1; }
    }
    if (header) { header = 0; next; }
    if (ours_idx == 0) next;
    if (ours_idx >= ncell) next;
    verdict = tolower(trim(cell[ours_idx]));
    if (verdict != "yes") next;
    flag = trim(cell[2]);
    gsub(/[`*]/, "", flag);
    sub(/[ =].*$/, "", flag);
    flag = trim(flag);
    if (flag == "" || substr(flag, 1, 1) != "-") next;
    if (flag in SEEN) next;
    SEEN[flag] = 1;
    judge(flag);
}

END {
    if (!saw_table) {
        printf "ROW\t%s\t%s::%s\t%s\n", "unscannable", SPEC, "no-ours-column",
            "flag matrix has no column named Ours, so no row can be checked";
    }
}

# Resolve a matrix flag to something in the parser. Drift is "nothing
# resolves" or "resolves to a field that is itself a stub".
function judge(flag,   base, fld, ch) {
    fld = "";
    if (substr(flag, 1, 2) == "--") {
        base = substr(flag, 3);
        fld = base; gsub(/-/, "_", fld);
        if (!(fld in FIELD)) {
            if (base in LONG) {
                fld = LONG[base];
            } else if (index(blob, "\"" flag "\"") > 0 ||
                       index(blob, "\"" base "\"") > 0 ||
                       index(blob, "\"" flag "=\"") > 0 ||
                       index(blob, "\"" base "=\"") > 0) {
                # A value-taking long option is matched as the literal
                # prefix "name=" in the parser, so the bare name never
                # appears on its own.
                return;
            } else {
                drift(flag, "no parser field, no meta .long, no literal in the source");
                return;
            }
        }
    } else {
        ch = substr(flag, 2, 1);
        if (ch in SHORT) {
            fld = SHORT[ch];
        } else if (ch in FIELD) {
            fld = ch;
        } else if (index(blob, "\x27" ch "\x27") > 0 ||
                   index(blob, "\"" flag "\"") > 0) {
            return;
        } else {
            drift(flag, "no meta .short, no field, no literal in the source");
            return;
        }
    }
    if (fld != "" && (fld in FIELD) && WR[fld] + 0 > 0 && RD[fld] + 0 == 0) {
        drift(flag, "resolves to field " fld ", which is written and never read");
    }
}

function drift(flag, why) {
    printf "ROW\t%s\t%s::%s\t%s\n", "matrix-drift", SPEC, flag,
        "matrix claims Ours: yes but " why;
}
'

# ---------------------------------------------------------------------------
# The shell-test scanner. Reads one tests/utilities/<util>_test.sh.
# Variables:
#   FILE   display path used in keys
#   UNIT   the utility this suite tests
#   UTILS  space-bounded list of utility names, " ls cat df "
#
# Sub-rules, keyed <file>::<test function>::<rule>[:<subject>] so the key
# survives the assertion moving inside its function.
# ---------------------------------------------------------------------------
TOOTH_AWK='
function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s);
    return s;
}

# The key names the offending construct, not the line it sits on, so it
# survives the assertion moving inside its function. `subject` carries the
# specific oracle or pattern: keying only on the rule would let one
# baselined weak assertion in a function silently cover the next one added
# beside it, which is the false negative this whole check exists to stop.
function emit(rule, subject, why,   key) {
    key = FILE "::" (fn == "" ? "<file>" : fn) "::" rule;
    if (subject != "") key = key ":" subject;
    if (key in SEEN) return;
    SEEN[key] = 1;
    printf "ROW\t%s\t%s\t%s\n", "toothless-assert", key, why;
}

{
    line = $0;
    sub(/\r$/, "", line);
    if (line ~ /^[ \t]*#/) next;
    if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        fn = substr(line, RSTART, RLENGTH);
        sub(/[ \t]*\(\).*$/, "", fn);
    }

    # (i) An existence guard whose result is discarded runs the rest of
    # the function against a binary that may not exist.
    if (line ~ /test_binary_exists/ && line !~ /\|\|/ &&
        line !~ /^[ \t]*(function[ \t]+)?test_binary_exists[ \t]*\(\)/) {
        emit("unguarded-existence", "",
             "test_binary_exists without `|| return 1`: the rest of the test runs regardless");
    }

    # (ii) A pattern that matches any plausible output asserts nothing.
    if (match(line, /=~/)) {
        rhs = substr(line, RSTART + 2);
        sub(/\]\].*$/, "", rhs);
        rhs = trim(rhs);
        # A pattern split across a line continuation leaves the trailing
        # backslash behind; it is not part of the pattern and must not
        # become part of the key.
        sub(/\\+$/, "", rhs);
        rhs = trim(rhs);
        gsub(/^["\x27]|["\x27]$/, "", rhs);
        rhs = trim(rhs);
        core = rhs;
        sub(/^\^/, "", core);
        sub(/\$$/, "", core);
        if (core == "" || core == ".*" || core == ".+" || core == ".") {
            emit("vacuous-pattern", rhs,
                 "=~ pattern `" rhs "` matches any output");
        } else {
            probe = core;
            gsub(/\\./, "", probe);
            if (probe !~ /[A-Za-z0-9_ ]{3}/) {
                emit("vacuous-pattern", rhs,
                     "=~ pattern `" rhs "` carries no literal run of three or more characters");
            }
        }
    }

    # (iii) An oracle that resolves to a binary this repo builds. Two
    # strengths, because they are not the same defect. A substitution
    # naming the utility UNDER TEST compares the implementation with
    # itself and holds whatever it prints -- unfalsifiable wherever it
    # appears, so it is flagged in any position. A substitution naming a
    # DIFFERENT vibeutils binary only weakens the test when its value is
    # the expectation, and tests/integration.sh pins PATH to zig-out/bin
    # so that value really does come from our build; it is flagged only in
    # oracle position. Flagging every peer substitution regardless of
    # position buries the self-comparisons under ~100 rows of `$(mktemp
    # -d)` scaffolding, and a finding list nobody reads is a finding list
    # that catches nothing.
    is_oracle_ctx = 0;
    if (line ~ /^[ \t]*(local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*(expected|expect|want|reference|oracle|golden)[A-Za-z0-9_]*=/) {
        is_oracle_ctx = 1;
    }
    if (line ~ /\[\[|\[ |==|!=|=~/) is_oracle_ctx = 1;
    rest = line;
    while (match(rest, /\$\(/)) {
        inner = substr(rest, RSTART + 2);
        rest = inner;
        word = inner;
        sub(/^[ \t]*/, "", word);
        sub(/[ \t)].*$/, "", word);
        sub(/\).*$/, "", word);
        gsub(/["\x27]/, "", word);
        if (word == "") continue;
        sub(/^.*\//, "", word);
        if (word ~ /\$/) continue;
        if (index(UTILS, " " word " ") == 0) continue;
        if (word == UNIT) {
            emit("self-oracle", word,
                 "expected value comes from `" word "`, the utility under test");
        } else if (is_oracle_ctx) {
            emit("peer-oracle", word,
                 "expectation is computed by `" word "`, another binary from this build");
        }
    }
}
'

# ---------------------------------------------------------------------------
# PATH-shadow scanner. Reads one tests/utilities/<util>_test.sh.
# Variables: FILE, UNIT, UTILS — same as TOOTH_AWK.
#
# Wrappers in tests/lib/common.sh intercept a bare `chmod`. This check
# flags the lookups those wrappers cannot see: `command chmod`,
# `find -exec chmod`, `env chmod`, and `run_with_limit N chmod`.
# Absolute paths, `$binary`, `$BIN_DIR/...`, and `host chmod` are allowed.
# A substitution naming the unit under test is left to toothless-assert.
# ---------------------------------------------------------------------------
SHADOW_AWK='
function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s);
    return s;
}

function emit(rule, subject, why,   key) {
    key = FILE "::" (fn == "" ? "<file>" : fn) "::" rule;
    if (subject != "") key = key ":" subject;
    if (key in SEEN) return;
    SEEN[key] = 1;
    printf "ROW\t%s\t%s\t%s\n", "path-shadow", key, why;
}

# A PATH lookup of a shipped name that is not the unit under test, and
# is not already an absolute path, a `$binary`/`$BIN_DIR` expansion, or
# `host`.
function maybe(rule, word, why) {
    word = trim(word);
    gsub(/^["\x27]|["\x27]$/, "", word);
    if (word == "") return;
    if (word ~ /\//) return;
    if (word ~ /^\$/) return;
    if (word == "host") return;
    if (word == UNIT) return;
    if (index(UTILS, " " word " ") == 0) return;
    emit(rule, word, why);
}

{
    line = $0;
    sub(/\r$/, "", line);
    if (line ~ /^[ \t]*#/) next;
    if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        fn = substr(line, RSTART, RLENGTH);
        sub(/[ \t]*\(\).*$/, "", fn);
    }

    # Drop quoted spans so `print_test_result "find -exec true"` cannot
    # fire. `"$binary" -exec true` still has a bare `-exec` after this
    # strip; the -exec rule below ignores it when $binary precedes it.
    stripped = line;
    while (match(stripped, /"[^"]*"/)) {
        stripped = substr(stripped, 1, RSTART - 1) " " substr(stripped, RSTART + RLENGTH);
    }
    while (match(stripped, /\x27[^\x27]*\x27/)) {
        stripped = substr(stripped, 1, RSTART - 1) " " substr(stripped, RSTART + RLENGTH);
    }

    # command chmod / command -p chmod. `command -v`/`-V` is a lookup,
    # not an invocation, and must not fire (mkdir_test.sh: command -v ln).
    rest = stripped;
    while (match(rest, /(^|[ \t;|&])command[ \t]+/)) {
        rest = substr(rest, RSTART + RLENGTH);
        lookup = 0;
        while (rest ~ /^-/) {
            opt = rest;
            sub(/[ \t].*$/, "", opt);
            if (opt == "-v" || opt == "-V") { lookup = 1; break; }
            sub(/^[^ \t]+[ \t]*/, "", rest);
        }
        if (lookup) break;
        word = rest;
        sub(/[ \t].*$/, "", word);
        maybe("command", word,
              "`command " word "` bypasses the host wrapper and follows PATH into zig-out/bin");
        break;
    }

    # find -exec chmod / -execdir chmod. find execvp()s the word, so the
    # bash chmod() wrapper never runs.
    #
    # `"$binary" -exec true` is an operand of the unit under test, not a
    # fixture lookup. Quote stripping already removed `"$binary"`, so
    # consult the original line: skip when $binary / $BIN_DIR appears
    # before -exec. Fixture `find ... -exec chmod` has neither.
    rest = stripped;
    while (match(rest, /(^|[ \t])-exec(dir)?[ \t]+/)) {
        rest = substr(rest, RSTART + RLENGTH);
        before = line;
        if (match(line, /(^|[ \t])-exec(dir)?[ \t]/)) {
            before = substr(line, 1, RSTART);
        }
        if (before ~ /\$binary/ || before ~ /\$BIN_DIR/) break;
        word = rest;
        sub(/[ \t].*$/, "", word);
        maybe("exec", word,
              "`-exec " word "` is execvp()d by find and follows PATH into zig-out/bin");
        break;
    }

    # env [NAME=VAL ...] chmod. Skip env(1) options and assignments.
    rest = stripped;
    while (match(rest, /(^|[ \t;|&])env[ \t]+/)) {
        rest = substr(rest, RSTART + RLENGTH);
        while (rest != "" && rest !~ /^[ \t]*$/) {
            word = rest;
            sub(/[ \t].*$/, "", word);
            if (word ~ /^-/) { sub(/^[^ \t]+[ \t]*/, "", rest); continue; }
            if (word ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                sub(/^[^ \t]+[ \t]*/, "", rest);
                continue;
            }
            break;
        }
        word = rest;
        sub(/[ \t].*$/, "", word);
        maybe("env", word,
              "`env ... " word "` follows PATH into zig-out/bin");
        break;
    }

    # run_with_limit SECONDS CMD — python os.execvp, no bash functions.
    # The definition line `run_with_limit()` has no duration and is skipped.
    rest = stripped;
    if (match(rest, /(^|[ \t;|&])run_with_limit[ \t]+[0-9.]+[ \t]+/)) {
        rest = substr(rest, RSTART + RLENGTH);
        word = rest;
        sub(/[ \t].*$/, "", word);
        maybe("run_with_limit", word,
              "`run_with_limit` execvp()s `" word "` via PATH, bypassing the host wrapper");
    }
}
'

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
ROOT=""
CHECKS=""
BASELINE_MODE=default
BASELINE_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            if [ $# -lt 2 ]; then
                note "error: --root requires a directory"
                usage
                exit 2
            fi
            ROOT=$2
            shift 2
            ;;
        --check)
            if [ $# -lt 2 ]; then
                note "error: --check requires a check name"
                usage
                exit 2
            fi
            _found=no
            for _c in $ALL_CHECKS; do
                [ "$_c" = "$2" ] && _found=yes
            done
            if [ "$_found" = no ]; then
                note "error: unknown check name: $2"
                note "known checks: $ALL_CHECKS"
                usage
                exit 2
            fi
            CHECKS="$CHECKS $2"
            shift 2
            ;;
        --baseline)
            if [ $# -lt 2 ]; then
                note "error: --baseline requires a file"
                usage
                exit 2
            fi
            BASELINE_MODE=explicit
            BASELINE_FILE=$2
            shift 2
            ;;
        --no-baseline)
            BASELINE_MODE=none
            shift
            ;;
        --update-baseline)
            BASELINE_MODE=update
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            note "error: unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

[ -n "$ROOT" ] || ROOT=$REPO_ROOT
[ -n "$CHECKS" ] || CHECKS=" $ALL_CHECKS "
CHECKS=" $(printf '%s' "$CHECKS" | tr -s ' ') "

if [ "$BASELINE_MODE" = update ] && [ -n "${CI:-}" ]; then
    note "error: --update-baseline is refused under CI"
    note "rewriting the baseline from CI would let a red build launder itself green"
    exit 2
fi

if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ]; then
    note "error: --root is not a readable directory: $ROOT"
    exit 2
fi

MANIFEST_SRC="$ROOT/build/utils.zig"
if [ ! -r "$MANIFEST_SRC" ]; then
    note "error: cannot read the utility manifest: $MANIFEST_SRC"
    exit 2
fi

case "$BASELINE_MODE" in
    default) BASELINE_FILE="$ROOT/scripts/audit-baseline.tsv" ;;
    update) [ -n "$BASELINE_FILE" ] || BASELINE_FILE="$ROOT/scripts/audit-baseline.tsv" ;;
    explicit)
        if [ ! -r "$BASELINE_FILE" ]; then
            note "error: baseline file does not exist or is unreadable: $BASELINE_FILE"
            exit 2
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Working state.
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/audit-check.XXXXXX") || {
    note "fatal: cannot create temp dir"
    exit 2
}
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

ROWS="$WORKDIR/rows"
UNITS="$WORKDIR/units"
BLKEYS="$WORKDIR/blkeys"
: >"$ROWS"
: >"$BLKEYS"
mkdir -p "$WORKDIR/facts"

emit_row() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ROWS"
}

# ---------------------------------------------------------------------------
# Baseline: load and validate. An unjustified row, a duplicate key, or an
# unknown check name is a hard error, because each of those is a
# suppression that nobody could tell apart from a silent one.
# ---------------------------------------------------------------------------
if [ "$BASELINE_MODE" != none ] && [ -r "$BASELINE_FILE" ]; then
    if ! awk -F'\t' -v CHECKS=" $ALL_CHECKS " -v PROG="$PROG" '
        /^[ \t]*#/ { next }
        /^[ \t]*$/ { next }
        {
            if (NF < 3) {
                printf "%s: baseline error: row %d has %d fields, expected 3: %s\n",
                    PROG, NR, NF, $0 > "/dev/stderr";
                bad = 1; next;
            }
            check = $1; key = $2; why = $3;
            gsub(/^[ \t]+|[ \t]+$/, "", why);
            if (index(CHECKS, " " check " ") == 0) {
                printf "%s: baseline error: row %d names an unknown check `%s` (key %s)\n",
                    PROG, NR, check, key > "/dev/stderr";
                bad = 1; next;
            }
            if (why == "") {
                printf "%s: baseline error: row %d has an empty justification for %s\n",
                    PROG, NR, key > "/dev/stderr";
                bad = 1; next;
            }
            full = check "\t" key;
            if (full in seen) {
                printf "%s: baseline error: duplicate key %s (check %s, rows %d and %d)\n",
                    PROG, key, check, seen[full], NR > "/dev/stderr";
                bad = 1; next;
            }
            seen[full] = NR;
            print full;
        }
        END { if (bad) exit 1 }
    ' "$BASELINE_FILE" >"$BLKEYS"; then
        note "error: baseline file rejected: $BASELINE_FILE"
        exit 2
    fi
fi

# ---------------------------------------------------------------------------
# Unit enumeration. Parsed straight out of build/utils.zig: it is the one
# authority on what a unit is, and reading it needs no toolchain.
# scripts/list-utilities.sh shells out to `zig build --help`, which would
# drag a Zig install into a job that otherwise needs none.
# ---------------------------------------------------------------------------
awk '
    /\.name[ \t]*=[ \t]*"/ && /\.path[ \t]*=[ \t]*"/ {
        line = $0;
        p = index(line, ".name");
        rest = substr(line, p);
        q = index(rest, "\"");
        rest2 = substr(rest, q + 1);
        e = index(rest2, "\"");
        name = substr(rest2, 1, e - 1);
        p = index(line, ".path");
        rest = substr(line, p);
        q = index(rest, "\"");
        rest2 = substr(rest, q + 1);
        e = index(rest2, "\"");
        path = substr(rest2, 1, e - 1);
        if (name != "" && path != "") printf "%s\t%s\n", name, path;
    }
' "$MANIFEST_SRC" >"$UNITS"

UNIT_COUNT=$(awk 'NF > 0 { c++ } END { print c + 0 }' "$UNITS")
if [ "${UNIT_COUNT:-0}" -eq 0 ]; then
    note "error: enumerated zero units from $MANIFEST_SRC"
    note "a scan that inspected nothing proved nothing; refusing to report success"
    exit 2
fi

UTIL_NAMES=" $(cut -f1 "$UNITS" | tr '\n' ' ') "

facts_name() {
    printf '%s' "$1" | tr '/.' '__'
}

# ---------------------------------------------------------------------------
# Pass 1 — Zig sources, deduplicated by path. `test` and `[` share
# src/test.zig; scanning it twice would double-count every finding in it.
# ---------------------------------------------------------------------------
awk -F'\t' '!seen[$2]++' "$UNITS" | while IFS="$TAB" read -r name path; do
    [ -n "$path" ] || continue
    src="$ROOT/$path"
    fname=$(facts_name "$path")
    if [ ! -r "$src" ]; then
        emit_row unscannable "$path::missing-source" \
            "build/utils.zig lists this path but it cannot be read"
        : >"$WORKDIR/facts/$fname"
        continue
    fi
    awk -v FILE="$path" "$SRC_AWK" <"$src" >"$WORKDIR/facts/$fname"
    grep "^ROW$TAB" "$WORKDIR/facts/$fname" | cut -f2- >>"$ROWS"
done

# ---------------------------------------------------------------------------
# Pass 2 — flag matrices, per NAME (a spec file is named for the utility,
# not for the source file). `[` is the bracket spelling of `test` and has
# no spec of its own; excluding it explicitly is honest, whereas letting
# it fall through would report a permanently unfixable unscannable unit.
# ---------------------------------------------------------------------------
while IFS="$TAB" read -r name path; do
    [ -n "$name" ] || continue
    [ "$name" = "[" ] && continue
    spec="docs/specs/$name-flags.md"
    fname=$(facts_name "$path")
    [ -f "$WORKDIR/facts/$fname" ] || : >"$WORKDIR/facts/$fname"
    if [ ! -r "$ROOT/$spec" ]; then
        emit_row unscannable "$spec::no-spec-file" \
            "no flag matrix for this utility, so no matrix row can be checked"
        continue
    fi
    awk -v SPEC="$spec" -v SRCFILE="$ROOT/$path" "$SPEC_AWK" \
        "$WORKDIR/facts/$fname" "$ROOT/$spec" | cut -f2- >>"$ROWS"
done <"$UNITS"

# ---------------------------------------------------------------------------
# Pass 3 — shell test suites, per NAME. A missing test file is
# unscannable, not clean: the unit has no suite for the check to inspect.
# ---------------------------------------------------------------------------
while IFS="$TAB" read -r name path; do
    [ -n "$name" ] || continue
    tf="tests/utilities/${name}_test.sh"
    if [ ! -r "$ROOT/$tf" ]; then
        emit_row unscannable "$tf::no-test-file" \
            "no shell test suite for this utility, so its assertions cannot be inspected"
        continue
    fi
    awk -v FILE="$tf" -v UNIT="$name" -v UTILS="$UTIL_NAMES" "$TOOTH_AWK" \
        <"$ROOT/$tf" | cut -f2- >>"$ROWS"
    awk -v FILE="$tf" -v UNIT="$name" -v UTILS="$UTIL_NAMES" "$SHADOW_AWK" \
        <"$ROOT/$tf" | cut -f2- >>"$ROWS"
done <"$UNITS"

# ---------------------------------------------------------------------------
# Emit: filter to the selected checks, deduplicate on (check, key),
# classify against the baseline, sort deterministically, then SUMMARY.
# ---------------------------------------------------------------------------
FINAL="$WORKDIR/final"
awk -F'\t' -v CHECKS="$CHECKS" -v BLFILE="$BLKEYS" -v NOBL="$BASELINE_MODE" '
    BEGIN {
        while ((getline l < BLFILE) > 0) BL[l] = 1;
        close(BLFILE);
    }
    NF >= 3 {
        if (index(CHECKS, " " $1 " ") == 0) next;
        k = $1 "\t" $2;
        if (k in seen) next;
        seen[k] = 1;
        st = (NOBL == "none") ? "NEW" : ((k in BL) ? "BASELINED" : "NEW");
        printf "%s\t%s\t%s\t%s\n", $1, $2, st, $3;
    }
' "$ROWS" | LC_ALL=C sort >"$FINAL"

TOTAL=$(awk 'NF > 0 { c++ } END { print c + 0 }' "$FINAL")
NEW=$(awk -F'\t' '$3 == "NEW" { c++ } END { print c + 0 }' "$FINAL")
BASED=$(awk -F'\t' '$3 == "BASELINED" { c++ } END { print c + 0 }' "$FINAL")
UNSC=$(awk -F'\t' '$1 == "unscannable" { c++ } END { print c + 0 }' "$FINAL")

# ---------------------------------------------------------------------------
# --update-baseline: rewrite the baseline from the current findings,
# carrying existing justifications forward. New rows land with a TODO
# marker and a loud note, because a row nobody justified is a suppression
# nobody can review.
# ---------------------------------------------------------------------------
if [ "$BASELINE_MODE" = update ]; then
    NEWFILE="$WORKDIR/baseline.new"
    awk -F'\t' -v OLD="$BASELINE_FILE" '
        BEGIN {
            # Carry the file`s header comment and every existing
            # justification across the rewrite. Regenerating the baseline
            # must not quietly blank the reasons somebody wrote down.
            head = 1;
            while ((getline l < OLD) > 0) {
                if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) {
                    if (head) print l;
                    continue;
                }
                head = 0;
                n = split(l, f, "\t");
                if (n >= 3) WHY[f[1] "\t" f[2]] = f[3];
            }
            close(OLD);
        }
        {
            k = $1 "\t" $2;
            why = (k in WHY) ? WHY[k] : "TODO: replace with a one-line justification.";
            if (why == "TODO: replace with a one-line justification.") todo++;
            printf "%s\t%s\t%s\n", $1, $2, why;
        }
        END { printf "TODO %d\n", todo + 0 > "/dev/stderr" }
    ' "$FINAL" >"$NEWFILE" 2>"$WORKDIR/todo"
    if cat "$NEWFILE" >"$BASELINE_FILE"; then
        note "baseline updated: $BASELINE_FILE ($TOTAL row(s))"
        _todo=$(awk '{ print $2 }' "$WORKDIR/todo")
        if [ "${_todo:-0}" -gt 0 ]; then
            note "$_todo row(s) still carry a TODO justification; replace each before committing"
        fi
    else
        note "error: cannot write baseline: $BASELINE_FILE"
        exit 2
    fi
fi

if [ "$TOTAL" -gt 0 ]; then
    cat "$FINAL"
fi

if [ "$BASELINE_MODE" = none ]; then
    # There is no baseline to have matched anything against. Printing
    # baselined=0 would render an uncomputed value as a reassuring one.
    BASED_OUT="n/a"
else
    BASED_OUT="$BASED"
fi

printf 'SUMMARY total=%s baselined=%s new=%s unscannable=%s\n' \
    "$TOTAL" "$BASED_OUT" "$NEW" "$UNSC"

[ "$NEW" -gt 0 ] && exit 1
exit 0
