#!/bin/sh
# tiger-check.sh — deterministic Tiger Style scanner for vibeutils.
#
# The reproducible core that the triage-agent pipeline, the
# pre-commit hook, and CI all call. Plain POSIX sh + awk/grep;
# no dependencies beyond coreutils and git.
#
# MODES:
#   tiger-check.sh <file>...     scan exactly those files; report ALL
#                                violations; exit 1 if any.
#   tiger-check.sh --base <ref>  scan src/**/*.zig that differ from
#                                <ref>; classify each violation NEW
#                                (offending line is ADDED in the diff)
#                                vs PRE; exit 1 ONLY if any NEW.
#   tiger-check.sh --staged      like --base but compare index to HEAD
#                                (for a pre-commit hook).
#   tiger-check.sh               (no args) scan all src/**/*.zig;
#                                report ALL; exit 1 if any.
#
# OUTPUT (stdout), one TAB-separated line per violation:
#   <rule>\t<file>:<line>\t<status>\t<detail>
# status is NEW or PRE in --base/--staged mode, "-" otherwise.
# Then exactly one summary line:
#   SUMMARY total=<N> new=<N>
#
# EXIT: --base/--staged exit 1 iff new>0; file/no-arg exit 1 iff
#   total>0; else 0. stderr is human notes only; the gate parses
#   stdout.

# Note: intentionally NOT using `set -e`. We must run to completion
# and emit the SUMMARY line even when individual files are missing
# or binary, so the gate always gets parseable output.
set -u

PROG=tiger-check
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

note() {
    # Human-readable note to stderr only.
    printf '%s: %s\n' "$PROG" "$*" >&2
}

usage() {
    cat >&2 <<'EOF'
Usage:
  tiger-check.sh <file>...        scan listed files (ALL violations)
  tiger-check.sh --base <ref>     scan changed src/**/*.zig vs <ref>
  tiger-check.sh --staged         scan staged src/**/*.zig vs HEAD
  tiger-check.sh                   scan all src/**/*.zig
EOF
}

# ---------------------------------------------------------------------------
# The awk scanner. Reads ONE file from stdin. Variables passed in:
#   FILE   display path used in output
#   STATUS_MODE  "diff" (emit NEW/PRE) or "plain" (emit "-")
#   ADDED  in diff mode, a space-delimited list like " 12 40 41 "
#          of 1-based line numbers that are ADDED lines.
# Emits violation lines to stdout. Does NOT print SUMMARY (the sh
# layer aggregates totals across files).
#
# Each violation: <rule>\t<FILE>:<lineno>\t<status>\t<detail>
# Rules: long-line, long-fn, self-recursion, compound-assert,
#        unbounded-loop, usize-arch.
# ---------------------------------------------------------------------------
SCAN_AWK='
function status_for(lineno,   key) {
    if (STATUS_MODE != "diff") return "-";
    key = " " lineno " ";
    if (index(ADDED, key) > 0) return "NEW";
    return "PRE";
}

function emit(rule, lineno, detail,   st) {
    st = status_for(lineno);
    printf "%s\t%s:%d\t%s\t%s\n", rule, FILE, lineno, st, detail;
}

# Display width: tabs expand to the next multiple of 8. UTF-8
# continuation bytes (0x80..0xBF) are skipped so a multibyte character
# counts as one display column (its lead byte). This is an
# approximation (it ignores zero-width and wide CJK), good enough and
# deterministic for the 100-column rule. mawk iterates bytes, so we
# detect continuation bytes with a precomputed lookup keyed by the
# single-byte string itself.
function display_width(s,   i, c, w, n) {
    w = 0;
    n = length(s);
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1);
        if (c == "\t") {
            w = w + (8 - (w % 8));
        } else if (c in CONTINUATION) {
            # UTF-8 continuation byte: already accounted for by its
            # lead byte; contributes zero display columns.
            continue;
        } else {
            w = w + 1;
        }
    }
    return w;
}

# Strip the content of // line comments and "..." / \x27...\x27 string
# literals from a line, replacing them with spaces so token rules
# (usize) do not match inside comments or strings. Conservative: it
# does not fully parse Zig multiline strings (\\\\) but blanks them.
function strip_comments_strings(s,   out, i, n, c, instr, inchr, prev) {
    n = length(s);
    out = "";
    instr = 0; inchr = 0;
    # Multiline string literal lines start (after optional ws) with \\.
    if (s ~ /^[ \t]*\\\\/) {
        return "";
    }
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1);
        if (instr) {
            if (c == "\\") { out = out " "; i++; out = out " "; continue; }
            if (c == "\"") { instr = 0; out = out " "; continue; }
            out = out " ";
            continue;
        }
        if (inchr) {
            if (c == "\\") { out = out " "; i++; out = out " "; continue; }
            if (c == "\x27") { inchr = 0; out = out " "; continue; }
            out = out " ";
            continue;
        }
        if (c == "/" && substr(s, i + 1, 1) == "/") {
            # Rest of line is a comment.
            break;
        }
        if (c == "\"") { instr = 1; out = out " "; continue; }
        if (c == "\x27") { inchr = 1; out = out " "; continue; }
        out = out c;
    }
    return out;
}

# Count opening minus closing braces on a code line (comments/strings
# stripped) to track brace depth for long-fn body measurement.
function brace_delta(code,   i, n, c, d) {
    d = 0;
    n = length(code);
    for (i = 1; i <= n; i++) {
        c = substr(code, i, 1);
        if (c == "{") {
            d++;
        } else if (c == "}") {
            d--;
        }
    }
    return d;
}

BEGIN {
    # Build the set of UTF-8 continuation bytes (0x80..0xBF) so
    # display_width can skip them. sprintf("%c", n) yields the raw
    # byte in mawk, giving a deterministic single-byte key.
    for (b = 128; b <= 191; b++) {
        CONTINUATION[sprintf("%c", b)] = 1;
    }
}

{
    line = $0;
    # Defensive CRLF handling: strip a trailing CR for width + content.
    sub(/\r$/, "", line);
    lineno = NR;

    # --- long-line ---------------------------------------------------
    w = display_width(line);
    if (w > 100) {
        emit("long-line", lineno, "width=" w);
    }

    code = strip_comments_strings(line);

    # --- usize-arch (token, not in comment/string) -------------------
    if (code ~ /(^|[^A-Za-z0-9_])usize([^A-Za-z0-9_]|$)/) {
        emit("usize-arch", lineno, "usize");
    }

    # --- compound-assert ---------------------------------------------
    # An assert( whose argument contains " and " or " or ". The assert
    # may be qualified (std.debug.assert(...) or a bare assert(...)), so
    # we allow a leading "." but not an identifier char before "assert".
    if (code ~ /(^|[^A-Za-z0-9_])assert[ \t]*\(/) {
        if (code ~ / and / || code ~ / or /) {
            emit("compound-assert", lineno, "compound boolean in assert");
        }
    }

    # --- unbounded-loop ----------------------------------------------
    if (code ~ /while[ \t]*\([ \t]*true[ \t]*\)/) {
        emit("unbounded-loop", lineno, "while (true)");
    }

    # --- fn tracking for long-fn + self-recursion --------------------
    # Detect a function definition header. We accept the header and any
    # continuation lines until the body-opening brace at depth 0->1.
    if (!in_fn && fn_pending == 0) {
        # Header start: optional "pub ", then "fn NAME(".
        if (match(code, /(^|[^A-Za-z0-9_])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
            # Extract the function name.
            hdr = substr(code, RSTART, RLENGTH);
            nm = hdr;
            sub(/.*[^A-Za-z0-9_]fn[ \t]+/, "", nm);
            sub(/^fn[ \t]+/, "", nm);
            sub(/[ \t]*\(.*/, "", nm);
            fn_name = nm;
            fn_start = lineno;
            fn_pending = 1;
            fn_depth = 0;
            fn_body_lines = 0;
            fn_recursed = 0;
            # Fall through: same line may contain the body brace.
        }
    }

    if (fn_pending == 1) {
        # We are between the fn header and its body-opening brace.
        # Scan this line for the first { that opens the body. Anything
        # before it (parameter list parens) is ignored for depth.
        d = brace_delta(code);
        bracepos = index(code, "{");
        semipos = index(code, ";");
        # A "fn NAME(...);" with a semicolon before any body brace is a
        # bodyless declaration (extern/export prototype, or a function-
        # type field). It has no body, so abandon the pending fn rather
        # than mis-binding the next "{" (often a later test block) to it.
        if (semipos > 0 && (bracepos == 0 || semipos < bracepos)) {
            fn_pending = 0;
            fn_name = "";
            fn_depth = 0;
            fn_body_lines = 0;
            fn_recursed = 0;
        } else if (bracepos > 0) {
            # The body has opened on this line.
            fn_pending = 0;
            in_fn = 1;
            fn_depth = d;
            fn_body_lines = 0;
            # The header (including this function-s own "fn NAME(" token)
            # precedes the body-opening brace; checking recursion on it
            # would self-match the definition. Only the remainder AFTER
            # the opening brace is genuine body content on this line.
            after_brace = substr(code, bracepos + 1);
            # If the body also closed on the same line, finalize now.
            if (fn_depth <= 0) {
                check_recursion(after_brace);
                finalize_fn(lineno);
            } else {
                check_recursion(after_brace);
            }
        }
        # If no brace yet, keep waiting (multi-line signature).
    } else if (in_fn) {
        check_recursion(code);
        d = brace_delta(code);
        fn_depth = fn_depth + d;
        fn_body_lines++;
        if (fn_depth <= 0) {
            finalize_fn(lineno);
        }
    }
}

function check_recursion(code) {
    if (fn_recursed) return;
    if (fn_name == "") return;
    # A call NAME( somewhere in the (comment/string-stripped) code.
    re = "(^|[^A-Za-z0-9_.])" fn_name "[ \t]*\\(";
    if (code ~ re) {
        fn_recursed = 1;
    }
}

function finalize_fn(end_lineno) {
    # fn_body_lines counts lines processed while in_fn: it excludes the
    # opening-brace line and includes the closing-brace line, i.e. the
    # inclusive span of body content from just after "{" through "}".
    # Per the contract, a body spanning MORE than 70 lines is a
    # violation. end_lineno is the closing-brace line (kept for clarity
    # and possible future detail reporting).
    if (fn_body_lines > 70) {
        emit("long-fn", fn_start, "body_lines=" fn_body_lines " fn=" fn_name);
    }
    if (fn_recursed) {
        emit("self-recursion", fn_start, "fn=" fn_name);
    }
    in_fn = 0;
    fn_pending = 0;
    fn_name = "";
    fn_depth = 0;
    fn_body_lines = 0;
    fn_recursed = 0;
}
'

# ---------------------------------------------------------------------------
# Helper: is a path a regular, readable, text (non-binary) file?
# Returns 0 if scannable, 1 otherwise (with a stderr note).
# ---------------------------------------------------------------------------
is_scannable() {
    f=$1
    if [ ! -f "$f" ]; then
        note "skip (not a regular file): $f"
        return 1
    fi
    if [ ! -r "$f" ]; then
        note "skip (not readable): $f"
        return 1
    fi
    # Binary detection: a NUL byte in the first 8000 bytes.
    if LC_ALL=C grep -qI . "$f" 2>/dev/null; then
        return 0
    fi
    # grep -I prints nothing and exits 1 for binary; double-check it
    # is not simply empty (empty files are scannable).
    if [ ! -s "$f" ]; then
        return 0
    fi
    note "skip (binary): $f"
    return 1
}

# ---------------------------------------------------------------------------
# Compute the set of ADDED line numbers for FILE relative to a diff.
# Args: $1 = git diff invocation selector ("base" or "staged"),
#       $2 = ref (for base), $3 = file path (repo-relative or abs).
# Echoes a space-delimited, space-bounded list like " 12 40 41 ".
# Parses unified diff hunk headers and counts added (+) lines.
# ---------------------------------------------------------------------------
added_lines_for() {
    _kind=$1
    _ref=$2
    _file=$3
    if [ "$_kind" = staged ]; then
        _diff=$(git diff --cached --no-color --no-ext-diff -U0 -- "$_file" 2>/dev/null)
    else
        _diff=$(git diff --no-color --no-ext-diff -U0 "$_ref" -- "$_file" 2>/dev/null)
    fi
    printf '%s\n' "$_diff" | awk '
        /^@@/ {
            # Hunk header: @@ -a,b +c,d @@
            hdr = $0;
            # Extract the +c,d field.
            n = split(hdr, parts, " ");
            plus = "";
            for (i = 1; i <= n; i++) {
                if (substr(parts[i], 1, 1) == "+") { plus = parts[i]; break; }
            }
            sub(/^\+/, "", plus);
            cnt = 1;
            if (index(plus, ",") > 0) {
                split(plus, cc, ",");
                cur = cc[1] + 0;
                cnt = cc[2] + 0;
            } else {
                cur = plus + 0;
                cnt = 1;
            }
            in_hunk = 1;
            next;
        }
        in_hunk && /^\+/ {
            # An added line. Its new-file line number is cur, then cur++.
            printf " %d", cur;
            cur++;
            next;
        }
        in_hunk && /^-/ {
            # Removed line: does not advance the new-file counter.
            next;
        }
        in_hunk && /^ / {
            # Context (should not appear with -U0, but be safe).
            cur++;
            next;
        }
        { in_hunk = 0; }
        END { printf " " }
    '
}

# ---------------------------------------------------------------------------
# Scan a single file. Args: file, status_mode ("plain"|"diff"),
# added_list (space-bounded). Appends violations to the global temp
# output and updates counters via the awk-emitted lines piped through.
# Writes violation lines to stdout directly; returns counts via a
# trailing "COUNT total new" line on fd that the caller reads.
# To keep aggregation simple we accumulate into temp files.
# ---------------------------------------------------------------------------

# Temp working dir for aggregation.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/tiger-check.XXXXXX") || {
    note "fatal: cannot create temp dir"
    exit 2
}
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
OUT_FILE="$WORKDIR/out"
: > "$OUT_FILE"

scan_one() {
    _file=$1
    _mode=$2
    _added=$3
    _display=$4
    if ! is_scannable "$_file"; then
        return 0
    fi
    awk -v FILE="$_display" -v STATUS_MODE="$_mode" -v ADDED="$_added" \
        "$SCAN_AWK" < "$_file" >> "$OUT_FILE"
}

# ---------------------------------------------------------------------------
# Resolve the list of src/**/*.zig files (repo-relative paths) for the
# changed-set or full-scan modes.
# ---------------------------------------------------------------------------
list_all_src() {
    # All tracked + untracked .zig under src/, deterministic order.
    find "$REPO_ROOT/src" -type f -name '*.zig' 2>/dev/null | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Argument parsing and dispatch.
# ---------------------------------------------------------------------------
MODE=""
REF=""
FILES=""

if [ $# -eq 0 ]; then
    MODE=allsrc
else
    case "$1" in
        --base)
            if [ $# -lt 2 ]; then
                note "error: --base requires a <ref>"
                usage
                exit 2
            fi
            MODE=base
            REF=$2
            ;;
        --staged)
            MODE=staged
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --*)
            note "error: unknown option: $1"
            usage
            exit 2
            ;;
        *)
            MODE=files
            FILES=$*
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Execute the selected mode.
# ---------------------------------------------------------------------------
case "$MODE" in
    files)
        # Explicit file list: scan exactly those, plain status.
        for f in "$@"; do
            scan_one "$f" plain " " "$f"
        done
        ;;
    allsrc)
        list_all_src | while IFS= read -r f; do
            # Display path relative to repo root when possible.
            disp=${f#"$REPO_ROOT"/}
            scan_one "$f" plain " " "$disp"
        done
        ;;
    base)
        # Validate ref.
        if ! git rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1; then
            note "error: not a valid git ref: $REF"
            exit 2
        fi
        # Changed src/**/*.zig vs ref (added/copied/modified/renamed).
        changed=$(git diff --name-only --diff-filter=ACMR "$REF" -- 'src/**/*.zig' 'src/*.zig' 2>/dev/null \
            | LC_ALL=C sort -u)
        if [ -z "$changed" ]; then
            note "no changed src/**/*.zig vs $REF"
        fi
        printf '%s\n' "$changed" | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            abs="$REPO_ROOT/$rel"
            added=$(added_lines_for base "$REF" "$rel")
            scan_one "$abs" diff "$added" "$rel"
        done
        ;;
    staged)
        changed=$(git diff --cached --name-only --diff-filter=ACMR -- 'src/**/*.zig' 'src/*.zig' 2>/dev/null \
            | LC_ALL=C sort -u)
        if [ -z "$changed" ]; then
            note "no staged src/**/*.zig"
        fi
        printf '%s\n' "$changed" | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            abs="$REPO_ROOT/$rel"
            added=$(added_lines_for staged "" "$rel")
            scan_one "$abs" diff "$added" "$rel"
        done
        ;;
esac

# ---------------------------------------------------------------------------
# Emit results: all violation lines (stable sort by file:line:rule),
# then the SUMMARY line. Compute totals.
# ---------------------------------------------------------------------------
# Stable, deterministic ordering: by file path, then numeric line,
# then rule name. We sort on a synthesized key to keep numeric line
# order correct.
sort_and_print() {
    # Input: violation lines. Output: same lines sorted.
    awk -F'\t' '{
        # field2 is FILE:LINE. Split into path and line for sorting.
        split($2, fl, ":");
        # Reconstruct path (may contain colons? paths here do not, but
        # be safe by taking everything before the LAST colon).
        # Simpler: line number is the final colon-delimited field.
        n = split($2, parts, ":");
        ln = parts[n] + 0;
        path = parts[1];
        for (i = 2; i < n; i++) path = path ":" parts[i];
        printf "%s\t%010d\t%s\t%s\n", path, ln, $1, $0;
    }' \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 \
        | cut -f4-
}

TOTAL=$(wc -l < "$OUT_FILE" | tr -d ' ')
[ -n "$TOTAL" ] || TOTAL=0

if [ "$MODE" = base ] || [ "$MODE" = staged ]; then
    NEW=$(awk -F'\t' '$3=="NEW"{c++} END{print c+0}' "$OUT_FILE")
else
    NEW=0
fi

# Print sorted violations then the summary.
if [ "$TOTAL" -gt 0 ]; then
    sort_and_print < "$OUT_FILE"
fi
printf 'SUMMARY total=%s new=%s\n' "$TOTAL" "$NEW"

# ---------------------------------------------------------------------------
# Exit code per the contract.
# ---------------------------------------------------------------------------
if [ "$MODE" = base ] || [ "$MODE" = staged ]; then
    [ "$NEW" -gt 0 ] && exit 1
    exit 0
else
    [ "$TOTAL" -gt 0 ] && exit 1
    exit 0
fi
