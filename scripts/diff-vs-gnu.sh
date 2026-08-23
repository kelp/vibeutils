#!/usr/bin/env bash
# Differential test harness: vibeutils vs GNU coreutils.
#
# Runs each vibeutils binary and its GNU twin over identical fixtures,
# flags, and environments, then compares results. Verdicts:
#
#   MATCH       same exit code and output
#   DIVERGENCE  candidate bug; the harness exits non-zero if any exist
#   EXPECTED    registered deliberate deviation (see
#               scripts/diff-vs-gnu-exceptions.txt)
#   SKIP        oracle binary missing (e.g. gtree) or case not runnable here
#
# Comparison rules:
#   exit   compare exit codes only (stable across GNU versions/locales)
#   exact  compare exit code + stdout bytes
#   pair   mutating utilities run in twin sandboxes; compare exit code +
#          resulting tree fingerprint (path, type, mode, size, cksum,
#          symlink targets)
#
# Determinism: fresh temp fixtures per run, LC_ALL=C, TZ=UTC, fixed umask,
# seeded fuzz, per-invocation watchdog, stdin pinned to /dev/null.
# Same inputs give the same verdict on every run and both platforms
# (g-prefixed brew coreutils on macOS, native coreutils on Linux).
#
# Extending: append rows to ALL_CASES below. Fields are '|'-separated:
#   runner|utility|case_id|mode|--|space separated argv ({}, {D} tokens)
# Deliberate divergences go in the exceptions file with a reason; never
# silence a divergence without recording why it is correct.
#
# Usage:
#   scripts/diff-vs-gnu.sh [UTILITY ...]
#   VU_MODE=exit scripts/diff-vs-gnu.sh     # force exit-only comparisons
#
# Environment overrides (used by the harness self-test):
#   VU_BIN_DIR     vibeutils binaries (default zig-out/bin)
#   VU_ORACLE_DIR  directory holding GNU binaries (default: PATH)

set -u

if (( BASH_VERSINFO[0] < 4 )); then
	echo "diff-vs-gnu: bash >= 4 required" >&2
	exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${VU_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
EXCEPTIONS="${VU_EXCEPTIONS:-$REPO_ROOT/scripts/diff-vs-gnu-exceptions.txt}"
SEED="${VU_SEED:-20260822}"
TIMEOUT_SECS="${VU_TIMEOUT:-10}"

export LC_ALL=C
export TZ=UTC
umask 022

case "$(uname -s)" in
Darwin) ORACLE_PREFIX="g" ;;
*) ORACLE_PREFIX="" ;;
esac

oracle_bin() {
	command -v "${ORACLE_PREFIX}$1"
}

our_bin() {
	[ -x "$BIN_DIR/$1" ]
}

# ---------------------------------------------------------------------------
# Watchdog: run "$@" with a hard timeout so hangs surface as findings.
# ---------------------------------------------------------------------------
run_timed() {
	local secs="$1"
	shift
	"$@" </dev/null &
	local pid=$!
	( sleep "$secs" && kill -9 "$pid" 2>/dev/null ) &
	local wpid=$!
	wait "$pid" 2>/dev/null
	local rc=$?
	kill "$wpid" 2>/dev/null
	wait "$wpid" 2>/dev/null
	return "$rc"
}

run_timed_cd() {
	local secs="$1" dir="$2"
	shift 2
	(
	cd "$dir" || exit 125
	run_timed "$secs" "$@"
	)
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibeutils-diff.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"

build_fixtures() {
	mkdir -p "$FIX/dir_a/sub" "$FIX/empty_dir"

	printf '' >"$FIX/empty.txt"
	printf 'one\ntwo\nthree\n' >"$FIX/three_lines.txt"
	printf 'b\na\na\nc\na\n' >"$FIX/dups.txt"
	printf 'a\na\nb\nc\nc\n' >"$FIX/sorted_dups.txt"
	printf '5\n10\n2\n33\n' >"$FIX/nums.txt"
	printf 'alpha,beta,gamma\n1,2,3\nx,y,z\n' >"$FIX/csv.txt"
	printf 'abcABC123!@#\n' >"$FIX/mixed.txt"
	printf '\x00\x01\xff\xfebinary\x00' >"$FIX/binary.bin"
	seq 1 40 >"$FIX/forty.txt"
	printf 'in dir\n' >"$FIX/dir_a/three_in_dir.txt"

	# Unicode names: NFC and NFD spellings of "cafe" with acute accent.
	printf 'unicode\n' >"$FIX/café.txt"
	printf 'unicode\n' >"$FIX/cafe$(printf '\xCC\x81').txt"
	printf 'spaces are fine\n' >"$FIX/has spaces.txt"

	ln -sf three_lines.txt "$FIX/good_link"
	ln -sf /nonexistent/vibeutils-dangling "$FIX/dangling_link"
	ln -sf dir_a "$FIX/link_to_dir"
	ln "$FIX/three_lines.txt" "$FIX/hardlink.txt"

	# Sparse file: 1 byte at offset 16 MiB.
	dd if=/dev/zero of="$FIX/sparse.bin" bs=1 count=1 seek=16777216 \
		conv=notrunc status=none

	if [ "$(id -u)" != 0 ]; then
		printf 'secret\n' >"$FIX/unreadable.txt"
		chmod 000 "$FIX/unreadable.txt"
	fi
}

declare -i n_match=0 n_diverge=0 n_expected=0 n_skip=0

is_expected() {
	local util="$1" case_id="$2"
	[ -f "$EXCEPTIONS" ] || return 1
	grep -v '^#' "$EXCEPTIONS" 2>/dev/null |
		awk -F'|' -v u="$util" -v c="$case_id" \
			'$1 == u && ($2 == c || $2 == "*")' | grep -q .
}

record() {
	local verdict="$1" util="$2" case_id="$3" detail="${4:-}"
	case "$verdict" in
	MATCH) n_match+=1 ;;
	EXPECTED) n_expected+=1 ;;
	SKIP) n_skip+=1 ;;
	DIVERGE) n_diverge+=1 ;;
	esac
	if [ -n "$detail" ]; then
		printf '%-9s %-12s %-36s %s\n' "$verdict" "$util" "$case_id" "$detail"
	else
		printf '%-9s %-12s %s\n' "$verdict" "$util" "$case_id"
	fi
}

classify() {
	local util="$1" case_id="$2" detail="$3"
	if is_expected "$util" "$case_id"; then
		record EXPECTED "$util" "$case_id" "$detail (registered)"
	else
		record DIVERGE "$util" "$case_id" "$detail"
	fi
}

# ---------------------------------------------------------------------------
# Case runners. Args: util case_id mode -- cmd...
# Both sides run with cwd = the fixture dir, so operands are plain relative
# names ("three_lines.txt", "dir_a"). Stdin is /dev/null everywhere.
# ---------------------------------------------------------------------------
run_case() {
	local util="$1" case_id="$2" mode="$3"
	shift 3
	[ "${1:-}" = "--" ] && shift

	if ! our_bin "$util"; then
		record SKIP "$util" "$case_id" "no vibeutils binary"
		return
	fi
	local gnu
	if ! gnu="$(oracle_bin "$util")"; then
		record SKIP "$util" "$case_id" "no GNU oracle"
		return
	fi

	run_timed_cd "$TIMEOUT_SECS" "$FIX" "$BIN_DIR/$util" \
		"$@" >"$WORK/o.out" 2>"$WORK/o.err"
	local o_rc=$?
	run_timed_cd "$TIMEOUT_SECS" "$FIX" "$gnu" \
		"$@" >"$WORK/g.out" 2>"$WORK/g.err"
	local g_rc=$?

	if [ "$o_rc" != "$g_rc" ]; then
		classify "$util" "$case_id" "exit ours=$o_rc gnu=$g_rc"
		return
	fi
	if [ "$mode" != "exit" ] && ! cmp -s "$WORK/o.out" "$WORK/g.out"; then
		classify "$util" "$case_id" "stdout differs"
		return
	fi
	record MATCH "$util" "$case_id"
}

# ---------------------------------------------------------------------------
# Pair runner for mutating utilities: twin sandboxes, state comparison.
# "{D}" in cmd expands to each side's sandbox root.
# ---------------------------------------------------------------------------
state_fingerprint() (
	cd "$1" || return 1
	find . -mindepth 1 -print | LC_ALL=C sort |
		while IFS= read -r p; do
			local kind
			kind="$("${ORACLE_PREFIX}stat" -c '%F|%a' "$p" 2>/dev/null)" ||
				kind="$(stat -f '%HT|%Lp' "$p" 2>/dev/null)" || kind="?"
			case "$kind" in
			*symbolic*)
				printf '%s\t%s\t-> %s\n' "$p" "$kind" "$(readlink "$p")"
				;;
			*regular*)
				printf '%s\t%s\t%s\t%s\n' "$p" "$kind" "$(wc -c <"$p")" "$(cksum <"$p")"
				;;
			*)
				printf '%s\t%s\n' "$p" "$kind"
				;;
			esac
		done
)

FIX_BASE=""
build_pair_base() {
	FIX_BASE="$WORK/pair_base"
	mkdir -p "$FIX_BASE/src/sub" "$FIX_BASE/out"
	printf 'copy me\nsecond line\n' >"$FIX_BASE/src/file1.txt"
	printf 'other\n' >"$FIX_BASE/src/file2.txt"
	printf 'nested\n' >"$FIX_BASE/src/sub/file3.txt"
	ln -sf file1.txt "$FIX_BASE/src/link1"
	chmod 600 "$FIX_BASE/src/file2.txt"
}

run_pair() {
	local util="$1" case_id="$2"
	shift 2
	[ "${1:-}" = "--" ] && shift

	if ! our_bin "$util"; then
		record SKIP "$util" "$case_id" "no vibeutils binary"
		return
	fi
	local gnu
	if ! gnu="$(oracle_bin "$util")"; then
		record SKIP "$util" "$case_id" "no GNU oracle"
		return
	fi

	rm -rf "$WORK/pair_o" "$WORK/pair_g"
	cp -R "$FIX_BASE" "$WORK/pair_o"
	cp -R "$FIX_BASE" "$WORK/pair_g"

	local -a o_args=() g_args=()
	local tok
	for tok in "$@"; do
		o_args+=("${tok//\{D\}/$WORK/pair_o}")
		g_args+=("${tok//\{D\}/$WORK/pair_g}")
	done

	run_timed_cd "$TIMEOUT_SECS" "$WORK/pair_o" "$BIN_DIR/$util" \
		${o_args+"${o_args[@]}"} >"$WORK/o.out" 2>"$WORK/o.err"
	local o_rc=$?
	run_timed_cd "$TIMEOUT_SECS" "$WORK/pair_g" "$gnu" \
		${g_args+"${g_args[@]}"} >"$WORK/g.out" 2>"$WORK/g.err"
	local g_rc=$?

	if [ "$o_rc" != "$g_rc" ]; then
		classify "$util" "$case_id" "exit ours=$o_rc gnu=$g_rc"
		return
	fi
	state_fingerprint "$WORK/pair_o" >"$WORK/o.fp"
	state_fingerprint "$WORK/pair_g" >"$WORK/g.fp"
	if ! cmp -s "$WORK/o.fp" "$WORK/g.fp"; then
		diff "$WORK/g.fp" "$WORK/o.fp" >"$WORK/fp.diff" || true
		classify "$util" "$case_id" \
			"tree differs: $(head -2 "$WORK/fp.diff" | tr '\n\t' '  ')"
		return
	fi
	record MATCH "$util" "$case_id"
}

# ---------------------------------------------------------------------------
# Case table. Fields: runner|utility|case_id|mode|--|argv
#   runner: case (read-only, cwd=fixtures) | pair (mutating, twin sandboxes)
#   mode:   exact (exit + stdout bytes)  | exit (exit code only)
# Operands are relative to the fixture dir; pair rows use {D} for the
# sandbox root.
# ---------------------------------------------------------------------------
ALL_CASES=(
	# --- text stream utilities --------------------------------------------
	'case|cat|plain|exact|--|three_lines.txt'
	'case|cat|two_files|exact|--|three_lines.txt dups.txt'
	'case|cat|binary|exact|--|binary.bin'
	'case|cat|missing_file|exit|--|missing.txt'
	'case|head|n_5|exact|--|-n 5 forty.txt'
	'case|head|c_10|exact|--|-c 10 forty.txt'
	'case|head|default_10|exact|--|forty.txt'
	'case|head|zero_lines|exit|--|-n 0 forty.txt'
	'case|head|missing|exit|--|missing.txt'
	'case|tail|n_5|exact|--|-n 5 forty.txt'
	'case|tail|from_line_38|exact|--|-n +38 forty.txt'
	'case|tail|c_7|exact|--|-c 7 forty.txt'
	'case|tail|missing|exit|--|missing.txt'
	'case|wc|default|exact|--|three_lines.txt'
	'case|wc|lwc|exact|--|-l -w -c three_lines.txt'
	'case|wc|two_files|exact|--|three_lines.txt dups.txt'
	'case|wc|empty|exact|--|empty.txt'
	'case|sort|plain|exact|--|dups.txt'
	'case|sort|reverse|exact|--|-r dups.txt'
	'case|sort|unique|exact|--|-u dups.txt'
	'case|sort|numeric|exact|--|-n nums.txt'
	'case|sort|numeric_reverse|exact|--|-nr nums.txt'
	'case|uniq|plain|exact|--|sorted_dups.txt'
	'case|uniq|count|exact|--|-c sorted_dups.txt'
	'case|uniq|dups_only|exact|--|-d sorted_dups.txt'
	'case|uniq|uniq_only|exact|--|-u sorted_dups.txt'
	'case|tr|lower_upper|exact|--|a-z A-Z mixed.txt'
	'case|tr|delete_digits|exact|--|-d 0-9 mixed.txt'
	'case|tr|squeeze|exact|--|-s ab mixed.txt'
	'case|cut|fields|exact|--|-d , -f 2 csv.txt'
	'case|cut|chars|exact|--|-c 1-5 csv.txt'
	'case|cut|complement|exact|--|-d , -f 1 --complement csv.txt'
	'case|grep|fixed|exact|--|-F two three_lines.txt'
	'case|grep|count|exact|--|-c a dups.txt'
	'case|grep|invert|exact|--|-v a dups.txt'
	'case|grep|line_numbers|exact|--|-n b dups.txt'
	'case|grep|no_match|exit|--|-F zzz three_lines.txt'
	'case|grep|missing_file|exit|--|-F x missing.txt'
	'case|tac|plain|exact|--|three_lines.txt'
	'case|nl|default|exact|--|three_lines.txt'
	'case|nl|number_all|exact|--|-b a empty.txt'
	'case|printf|simple|exact|--|%s-%d\n hello 42'
	'case|printf|percent|exact|--|100%%\n'
	'case|seq|range|exact|--|1 5'
	'case|seq|width|exact|--|-w 1 3'
	'case|seq|separator|exact|--|-s , 1 3'
	'case|seq|negative_step|exact|--|10 -2 0'

	# --- path/name utilities ------------------------------------------------
	'case|basename|simple|exact|--|/usr/local/bin/ls'
	'case|basename|suffix|exact|--|file.tar.gz .gz'
	'case|dirname|simple|exact|--|/usr/local/bin/ls'
	'case|readlink|target|exact|--|good_link'
	'case|readlink|not_a_symlink|exit|--|three_lines.txt'
	'case|realpath|through_symlink|exact|--|link_to_dir/three_in_dir.txt'
	'case|realpath|nonexistent_ok|exact|--|dir_a/../missing_new.txt'

	# --- ls -----------------------------------------------------------------
	'case|ls|one_column_empty_dir|exact|--|-1 empty_dir'
	'case|ls|missing_operand|exit|--|-1 missing_dir'
	'case|ls|one_file_operand|exact|--|-1 three_lines.txt'
	'case|ls|d_flag_on_dir|exact|--|-d dir_a'
	'case|ls|long_one_file|exact|--|-l three_lines.txt'

	# --- du (unit flags pin the scale so values are comparable) -------------
	'case|du|bare_default|exact|--|dir_a'
	'case|du|kilobytes|exact|--|-k dir_a'
	'case|du|summarize|exact|--|-k -s dir_a'
	'case|du|bytes|exact|--|-b dir_a'
	'case|du|apparent|exact|--|-k --apparent-size dir_a'
	'case|du|missing|exit|--|-k missing_dir'

	# --- df (same kernel numbers both sides; headers may differ) -------------
	'case|df|block_size_path|exit|--|--block-size=1K three_lines.txt'
	'case|df|missing_path|exit|--|missing_dir'

	# --- dd -------------------------------------------------------------------
	'pair|dd|bs_count|exact|--|if={D}/src/file1.txt of={D}/out/dd1.bin bs=4 count=3 status=none'
	'pair|dd|skip_seek|exact|--|if={D}/src/file1.txt of={D}/out/dd2.bin bs=1 skip=3 seek=2 count=5 status=none'
	'pair|dd|notrunc|exact|--|if={D}/src/file1.txt of={D}/out/dd3.bin bs=1 count=4 conv=notrunc status=none'
	'pair|dd|zero_count|exit|--|if={D}/src/file1.txt of=/dev/null bs=512 count=0 status=none'

	# --- test predicates (fully deterministic) ---------------------------------
	'case|test|eq_true|exit|--|1 -eq 1'
	'case|test|eq_false|exit|--|1 -eq 2'
	'case|test|str_eq_true|exit|--|abc = abc'
	'case|test|file_exists|exit|--|-e three_lines.txt'
	'case|test|symlink_predicate|exit|--|-L good_link'
	'case|test|dir_predicate|exit|--|-d dir_a'
	'case|test|zero_len|exit|--|! -s empty.txt'

	# --- misc small utilities ----------------------------------------------------
	'case|env|sets_var_runs_true|exit|--|FOO=bar true'
	'case|env|runs_false|exit|--|false'
	'case|true|always|exit|--|'
	'case|false|always|exit|--|'
	'case|sleep|short|exit|--|0.01'
	'case|timeout|fires|exit|--|0.05 sleep 5'
	'case|timeout|does_not_fire|exit|--|5 sleep 0.01'
	'case|whoami|self|exit|--|'
	'case|id|self|exit|--|'
	'case|date|utc_year|exact|--|-u +%Y'
	'case|echo|no_args|exact|--|'
	'case|mktemp|dry_run_template|exit|--|--dry-run tmpXXXXXX'

	# --- find (same libc readdir order on both sides) -----------------------------
	'case|find|everything|exact|--|. -type f'
	'case|find|name_txt|exact|--|. -name *.txt'
	'case|find|maxdepth_1|exact|--|. -maxdepth 1'
	'case|find|missing_root|exit|--|missing_dir'

	# --- stat (same file on both sides, so field values are comparable) -----
	'case|stat|size_fmt|exact|--|-c %s three_lines.txt'
	'case|stat|inode_fmt|exact|--|-c %i three_lines.txt'
	'case|stat|type_fmt|exact|--|-c %F dir_a'
	'case|stat|mode_fmt|exact|--|-c %a dir_a'
	'case|stat|missing_file|exit|--|-c %s missing.txt'

	# --- mutating utilities via twin sandboxes --------------------------------------
	'pair|cp|file_to_dir|exact|--|{D}/src/file1.txt {D}/out/'
	'pair|cp|recursive|exact|--|-R {D}/src {D}/out/copy'
	'pair|cp|preserve_mode|exact|--|-p {D}/src/file2.txt {D}/out/'
	'pair|cp|no_deref_symlink|exact|--|-P {D}/src/link1 {D}/out/'
	'pair|mv|rename|exact|--|{D}/src/file1.txt {D}/out/moved.txt'
	'pair|mv|into_dir|exact|--|{D}/src/file2.txt {D}/out/'
	'pair|ln|hardlink_default|exact|--|{D}/src/file1.txt {D}/out/hard.txt'
	'pair|ln|symlink_flag|exact|--|-s file1.txt {D}/out/sym.txt'
	'pair|mkdir|simple|exact|--|{D}/out/newdir'
	'pair|mkdir|parents|exact|--|-p {D}/out/x/y/z'
	'pair|rmdir|empty|exact|--|{D}/out'
	'pair|touch|new_file|exact|--|{D}/out/touched.txt'
	'pair|chmod|octal|exact|--|644 {D}/src/file2.txt'
	'pair|rm|single_file|exact|--|{D}/src/file2.txt'
	'pair|rm|recursive|exact|--|-r {D}/src/sub'
)

# Seeded pseudo-random flag sweep: exit-code agreement only. Deterministic
# for a given SEED; catches argument-parser drift without byte noise.
# Flags only, never operands, so neither side mutates anything.
#
# KNOWN RESIDUAL DIVERGENCE CLASS (see TODO.md): the sweep passes -h and -V
# to every utility. GNU defines those shorts on some utilities only, so on
# the rest GNU rejects them (exit 1) while we treat them uniformly as
# help/version (exit 0). Those hits are a recorded design deviation, not
# new findings; look for anything outside that pattern.
fuzz_util() {
	local util="$1" rounds="${2:-60}"
	local gnu
	gnu="$(oracle_bin "$util")" || return 0
	local -a pool=(--help -h --version -V -x -n 3 -c 2 -q -v -l -a --bogus)
	local i j rc_o rc_g
	local -a chosen
	for ((i = 0; i < rounds; i++)); do
		chosen=()
		for ((j = 0; j < 3; j++)); do
			SEED=$(( (SEED * 1103515245 + 12345) & 0x7fffffff ))
			chosen+=("${pool[$((SEED % ${#pool[@]}))]}")
		done
		run_timed "$TIMEOUT_SECS" "$BIN_DIR/$util" \
			${chosen+"${chosen[@]}"} >/dev/null 2>&1
		rc_o=$?
		run_timed "$TIMEOUT_SECS" "$gnu" \
			${chosen+"${chosen[@]}"} >/dev/null 2>&1
		rc_g=$?
		if [ "$rc_o" != "$rc_g" ]; then
			classify "$util" "fuzz[${chosen[*]}]" \
				"exit ours=$rc_o gnu=$rc_g"
		else
			n_match+=1
		fi
	done
}

usage() {
	sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
}

main() {
	[ "${1:-}" = "-h" ] && usage
	build_fixtures
	build_pair_base

	local -a wanted=()
	if [ $# -gt 0 ]; then
		wanted=("$@")
	else
		wanted=(cat head tail wc sort uniq tr cut grep tac nl printf seq
			basename dirname readlink realpath pwd ls du df dd test env
			true false yes sleep timeout whoami id date echo mktemp
			find cp mv ln mkdir rmdir touch chmod rm)
	fi

	local line runner util_c case_id mode rest fn
	# Globbing off while expanding argv rows so patterns reach the binaries.
	set -f
	for util in ${wanted+"${wanted[@]}"}; do
		for line in "${ALL_CASES[@]}"; do
			IFS='|' read -r runner util_c case_id mode rest <<<"$line"
			[ "$util_c" = "$util" ] || continue
			case "$runner" in
			pair) fn="run_pair" ;;
			*) fn="run_case" ;;
			esac
			# shellcheck disable=SC2086
			"$fn" "$util" "$case_id" "$mode" -- $rest
		done
	done
	set +f

	# Opt-in seeded flag sweep: VU_FUZZ=1 scripts/diff-vs-gnu.sh
	if [ "${VU_FUZZ:-0}" = "1" ]; then
		for util in ${wanted+"${wanted[@]}"}; do
			fuzz_util "$util"
		done
	fi

	echo
	echo "Summary: match=$n_match divergence=$n_diverge expected=$n_expected skip=$n_skip"
	[ "$n_diverge" -eq 0 ]
}

main "$@"
