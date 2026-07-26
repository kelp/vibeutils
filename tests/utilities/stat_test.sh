#!/usr/bin/env bash
# Integration tests for stat utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_stat() {
    local util="stat"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Create a temp file for testing
    local tmpfile
    tmpfile=$(mktemp)
    echo "hello" > "$tmpfile"

    # Default output should contain key fields
    local output
    output=$("$binary" "$tmpfile" 2>/dev/null)
    local exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "File:" && "$output" =~ "Size:" && "$output" =~ "Inode:" ]]; then
        print_test_result "stat default output has expected fields" "PASS"
    else
        print_test_result "stat default output has expected fields" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing format options...${NC}"

    # -c %s shows file size
    output=$("$binary" -c '%s' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "6" ]]; then
        print_test_result "stat -c '%s' shows file size" "PASS"
    else
        print_test_result "stat -c '%s' shows file size" "FAIL" \
            "Expected '6', got '$output'"
    fi

    # -c %F shows file type
    output=$("$binary" -c '%F' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "regular file" ]]; then
        print_test_result "stat -c '%F' shows file type" "PASS"
    else
        print_test_result "stat -c '%F' shows file type" "FAIL" \
            "Expected 'regular file', got '$output'"
    fi

    # -c %n shows file name
    output=$("$binary" -c '%n' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "$tmpfile" ]]; then
        print_test_result "stat -c '%n' shows file name" "PASS"
    else
        print_test_result "stat -c '%n' shows file name" "FAIL" \
            "Expected '$tmpfile', got '$output'"
    fi

    # --format=FMT syntax
    output=$("$binary" --format='%s' "$tmpfile" 2>/dev/null)
    if [[ "$output" == "6" ]]; then
        print_test_result "stat --format='%s' syntax works" "PASS"
    else
        print_test_result "stat --format='%s' syntax works" "FAIL" \
            "Expected '6', got '$output'"
    fi

    echo -e "${CYAN}Testing symlink handling...${NC}"

    # Create a symlink
    local tmplink="${tmpfile}.link"
    ln -s "$tmpfile" "$tmplink"

    # Without -L: should show symbolic link
    output=$("$binary" -c '%F' "$tmplink" 2>/dev/null)
    if [[ "$output" == "symbolic link" ]]; then
        print_test_result "stat shows symbolic link type" "PASS"
    else
        print_test_result "stat shows symbolic link type" "FAIL" \
            "Expected 'symbolic link', got '$output'"
    fi

    # With -L: should show regular file
    output=$("$binary" -L -c '%F' "$tmplink" 2>/dev/null)
    if [[ "$output" == "regular file" ]]; then
        print_test_result "stat -L follows symlinks" "PASS"
    else
        print_test_result "stat -L follows symlinks" "FAIL" \
            "Expected 'regular file', got '$output'"
    fi

    echo -e "${CYAN}Testing terse output...${NC}"

    # -t produces terse output (single line)
    output=$("$binary" -t "$tmpfile" 2>/dev/null)
    local line_count
    line_count=$(echo "$output" | wc -l)
    if [[ $line_count -eq 1 && "$output" =~ "$tmpfile" ]]; then
        print_test_result "stat -t produces terse output" "PASS"
    else
        print_test_result "stat -t produces terse output" "FAIL" \
            "Expected 1 line, got $line_count"
    fi

    echo -e "${CYAN}Testing file system info...${NC}"

    # -f shows file system info
    output=$("$binary" -f "$tmpfile" 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Block" ]]; then
        print_test_result "stat -f shows file system info" "PASS"
    else
        print_test_result "stat -f shows file system info" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "stat invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    # Missing operand exits with code 2
    test_command_exit_code "stat missing operand exits 2" 2 \
        "$binary"

    # Nonexistent file exits with code 1
    test_command_exit_code "stat nonexistent file exits 1" 1 \
        "$binary" /nonexistent/path/file

    echo -e "${CYAN}Testing correct error messages...${NC}"

    # Regression test: stat must show correct error for each error type
    local stat_err_cmd stat_err_out stat_err_stderr stat_err_exit
    run_command stat_err_cmd stat_err_out stat_err_stderr stat_err_exit "$binary" /nonexistent
    if [[ "$stat_err_stderr" == *"No such file"* ]]; then
        print_test_result "stat nonexistent shows 'No such file'" "PASS"
    else
        print_test_result "stat nonexistent shows 'No such file'" "FAIL" \
            "Expected 'No such file' in stderr, got: '$stat_err_stderr'"
    fi

    # Regression test: stat permission denied shows correct message
    local stat_perm_dir
    stat_perm_dir=$(create_temp_dir)
    touch "$stat_perm_dir/secret"
    chmod 000 "$stat_perm_dir"
    run_command stat_err_cmd stat_err_out stat_err_stderr stat_err_exit "$binary" "$stat_perm_dir/secret"
    if [[ "$stat_err_stderr" == *"Permission denied"* ]]; then
        print_test_result "stat permission denied shows correct message" "PASS"
    else
        print_test_result "stat permission denied shows correct message" "FAIL" \
            "Expected 'Permission denied' in stderr, got: '$stat_err_stderr'"
    fi
    chmod 755 "$stat_perm_dir"
    rm -rf "$stat_perm_dir"

    # Regression test: stat reports "regular file" for a regular file
    local stat_reg_file
    stat_reg_file=$(create_temp_file "regular file test")
    local stat_reg_out="" stat_reg_err="" stat_reg_exit=""
    run_command stat_reg_cmd stat_reg_out stat_reg_err stat_reg_exit "$binary" "$stat_reg_file"
    if [[ "$stat_reg_out" == *"regular file"* ]]; then
        print_test_result "stat regular file type string" "PASS"
    else
        print_test_result "stat regular file type string" "FAIL" \
            "Expected 'regular file' in output"
    fi
    rm -f "$stat_reg_file"

    # Regression test: stat reports "directory" for a directory
    local stat_test_dir
    stat_test_dir=$(create_temp_dir)
    local stat_dir_out="" stat_dir_err="" stat_dir_exit=""
    run_command stat_dir_cmd stat_dir_out stat_dir_err stat_dir_exit "$binary" "$stat_test_dir"
    if [[ "$stat_dir_out" == *"directory"* ]]; then
        print_test_result "stat directory type string" "PASS"
    else
        print_test_result "stat directory type string" "FAIL" \
            "Expected 'directory' in output"
    fi
    rm -rf "$stat_test_dir"

    # --- F15: No spurious '+' on numeric fields in default output ---
    echo -e "${CYAN}Testing no spurious plus in default output (F15)...${NC}"

    local stat_default_out
    stat_default_out=$("$binary" "$tmpfile" 2>/dev/null)
    # Extract the Size line
    local size_line
    size_line=$(echo "$stat_default_out" | grep "Size:")
    if [[ "$size_line" != *"+"* ]]; then
        print_test_result "stat default output has no '+' in Size line" "PASS"
    else
        print_test_result "stat default output has no '+' in Size line" "FAIL" \
            "Found '+' in: $size_line"
    fi

    # --- F17: stat -f -c FORMAT should honor format string ---
    echo -e "${CYAN}Testing stat -f -c honors format string (F17)...${NC}"

    local stat_fc_out
    stat_fc_out=$("$binary" -f -c '%n' "$tmpfile" 2>/dev/null)
    if [[ "$stat_fc_out" == "$tmpfile" ]]; then
        print_test_result "stat -f -c '%n' outputs file name" "PASS"
    else
        print_test_result "stat -f -c '%n' outputs file name" "FAIL" \
            "Expected '$tmpfile', got '$stat_fc_out'"
    fi

    # --- F18: Terse output should have 16 fields like GNU stat ---
    echo -e "${CYAN}Testing terse output field count (F18)...${NC}"

    local stat_terse_out terse_field_count
    stat_terse_out=$("$binary" -t "$tmpfile" 2>/dev/null)
    terse_field_count=$(echo "$stat_terse_out" | wc -w)
    if [[ "$terse_field_count" -eq 16 ]]; then
        print_test_result "stat -t has 16 fields like GNU" "PASS"
    else
        print_test_result "stat -t has 16 fields like GNU" "FAIL" \
            "Expected 16 fields, got $terse_field_count: $stat_terse_out"
    fi

    # --- F16: stat -f block size should be sane (not garbage from wrong struct) ---
    echo -e "${CYAN}Testing stat -f block size is sane (F16)...${NC}"

    local stat_fs_out block_size_val
    stat_fs_out=$("$binary" -f "$tmpfile" 2>/dev/null)
    # Extract the block size number after "Block size:"
    block_size_val=$(echo "$stat_fs_out" | grep "Block size:" | sed 's/.*Block size: *\([0-9]*\).*/\1/')
    if [[ -n "$block_size_val" && "$block_size_val" -ge 512 && "$block_size_val" -le 1048576 ]]; then
        print_test_result "stat -f block size is sane ($block_size_val)" "PASS"
    else
        print_test_result "stat -f block size is sane" "FAIL" \
            "Block size $block_size_val is outside 512-1048576 range"
    fi

    # --- Audit: Device line format should be GNU major,minor decimal ---
    echo -e "${CYAN}Testing Device line format (GNU major,minor)...${NC}"

    local dev_line
    dev_line=$(echo "$stat_default_out" | grep "Device:")
    # GNU format: "Device: 0,31" — no letter suffixes like 'h' or 'd'
    # BSD format: "Device: 1fh/31d" — has 'h/' and 'd' suffixes
    if [[ "$dev_line" != *"h/"* ]]; then
        print_test_result "Device line has no BSD 'h/' suffix" "PASS"
    else
        print_test_result "Device line has no BSD 'h/' suffix" "FAIL" \
            "Found BSD format: $dev_line"
    fi

    # --- Audit: %N on symlink should show arrow notation ---
    echo -e "${CYAN}Testing %N format directive...${NC}"

    local n_out
    n_out=$("$binary" -c '%N' "$tmplink" 2>/dev/null)
    if [[ "$n_out" == *" -> "* ]]; then
        print_test_result "stat -c '%N' symlink shows arrow" "PASS"
    else
        print_test_result "stat -c '%N' symlink shows arrow" "FAIL" \
            "Expected arrow notation, got '$n_out'"
    fi

    # %N on regular file should be single-quoted
    local n_reg_out
    n_reg_out=$("$binary" -c '%N' "$tmpfile" 2>/dev/null)
    if [[ "$n_reg_out" == "'$tmpfile'" ]]; then
        print_test_result "stat -c '%N' regular file is quoted" "PASS"
    else
        print_test_result "stat -c '%N' regular file is quoted" "FAIL" \
            "Expected '${tmpfile}', got '$n_reg_out'"
    fi

    # --- Audit: --printf no trailing newline ---
    echo -e "${CYAN}Testing --printf no trailing newline...${NC}"

    local printf_out
    printf_out=$("$binary" --printf='%s' "$tmpfile" 2>/dev/null)
    if [[ "$printf_out" == "6" ]]; then
        print_test_result "stat --printf='%s' has no trailing newline" "PASS"
    else
        print_test_result "stat --printf='%s' has no trailing newline" "FAIL" \
            "Expected '6' (no newline), got '$printf_out'"
    fi

    # --- Audit: %x %y %z human-readable timestamp format ---
    echo -e "${CYAN}Testing %x %y %z timestamp format...${NC}"

    local mtime_human
    mtime_human=$("$binary" -c '%y' "$tmpfile" 2>/dev/null)
    # GNU format: YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ
    if [[ "$mtime_human" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        print_test_result "stat -c '%y' mtime has YYYY-MM-DD HH:MM:SS format" "PASS"
    else
        print_test_result "stat -c '%y' mtime has YYYY-MM-DD HH:MM:SS format" "FAIL" \
            "Got: '$mtime_human'"
    fi

    # --- Audit: %b blocks allocated ---
    echo -e "${CYAN}Testing %b format directive...${NC}"

    local blocks_out
    blocks_out=$("$binary" -c '%b' "$tmpfile" 2>/dev/null)
    if [[ "$blocks_out" =~ ^[0-9]+$ ]]; then
        print_test_result "stat -c '%b' blocks is numeric" "PASS"
    else
        print_test_result "stat -c '%b' blocks is numeric" "FAIL" \
            "Expected integer, got '$blocks_out'"
    fi

    # --- Audit: %G group name ---
    echo -e "${CYAN}Testing %G format directive...${NC}"

    local group_out
    group_out=$("$binary" -c '%G' "$tmpfile" 2>/dev/null)
    # Group name should not be empty and not purely numeric
    if [[ -n "$group_out" && ! "$group_out" =~ ^[0-9]+$ ]]; then
        print_test_result "stat -c '%G' group name is not numeric fallback" "PASS"
    else
        print_test_result "stat -c '%G' group name is not numeric fallback" "FAIL" \
            "Got: '$group_out'"
    fi

    # --- BSD -n flag: suppress the record-terminating newline (issue #93) ---
    echo -e "${CYAN}Testing -n suppresses trailing newline...${NC}"

    local n_off_file="$TEMP_DIR/stat_n_off_$$"
    local n_on_file="$TEMP_DIR/stat_n_on_$$"
    local n_on_exit=0

    "$binary" -c '%s' "$tmpfile" > "$n_off_file" 2>/dev/null || true
    set +e
    "$binary" -n -c '%s' "$tmpfile" > "$n_on_file" 2>/dev/null
    n_on_exit=$?
    set -e

    local n_off_bytes n_on_bytes
    n_off_bytes=$(wc -c < "$n_off_file" | tr -d ' ')
    n_on_bytes=$(wc -c < "$n_on_file" | tr -d ' ')

    if [[ "$n_on_exit" -eq 0 && "$n_on_bytes" -gt 0 &&
          $((n_off_bytes - n_on_bytes)) -eq 1 ]]; then
        print_test_result "stat -n -c '%s' drops exactly one trailing byte" "PASS"
    else
        print_test_result "stat -n -c '%s' drops exactly one trailing byte" "FAIL" \
            "exit=$n_on_exit without -n=$n_off_bytes bytes, with -n=$n_on_bytes bytes"
    fi

    # -n on the default multi-line record: only the final newline goes away.
    local n_def_off_file="$TEMP_DIR/stat_n_def_off_$$"
    local n_def_on_file="$TEMP_DIR/stat_n_def_on_$$"
    "$binary" "$tmpfile" > "$n_def_off_file" 2>/dev/null || true
    "$binary" -n "$tmpfile" > "$n_def_on_file" 2>/dev/null || true

    local n_def_off_bytes n_def_on_bytes n_def_on_lines
    n_def_off_bytes=$(wc -c < "$n_def_off_file" | tr -d ' ')
    n_def_on_bytes=$(wc -c < "$n_def_on_file" | tr -d ' ')
    # Interior newlines survive, so the record still spans multiple lines.
    n_def_on_lines=$(tr -cd '\n' < "$n_def_on_file" | wc -c | tr -d ' ')

    if [[ $((n_def_off_bytes - n_def_on_bytes)) -eq 1 && "$n_def_on_lines" -ge 7 ]]; then
        print_test_result "stat -n default output keeps interior newlines" "PASS"
    else
        print_test_result "stat -n default output keeps interior newlines" "FAIL" \
            "without -n=$n_def_off_bytes bytes, with -n=$n_def_on_bytes bytes, \
newlines=$n_def_on_lines"
    fi

    rm -f "$n_off_file" "$n_on_file" "$n_def_off_file" "$n_def_on_file"

    # --- BSD -q flag: suppress per-file diagnostics, keep exit status ---
    echo -e "${CYAN}Testing -q suppresses per-file diagnostics...${NC}"

    local q_cmd q_out q_err q_exit
    run_command q_cmd q_out q_err q_exit "$binary" -q /nonexistent/path/file
    if [[ "$q_exit" -eq 1 && -z "$q_err" ]]; then
        print_test_result "stat -q nonexistent file: silent stderr, exit 1" "PASS"
    else
        print_test_result "stat -q nonexistent file: silent stderr, exit 1" "FAIL" \
            "exit=$q_exit stderr='$q_err'"
    fi

    # -q must not silence usage errors, only per-file access failures.
    local qu_cmd qu_out qu_err qu_exit
    run_command qu_cmd qu_out qu_err qu_exit "$binary" -q -c
    if [[ "$qu_exit" -eq 2 && "$qu_err" == *"requires an argument"* ]]; then
        print_test_result "stat -q does not silence usage errors" "PASS"
    else
        print_test_result "stat -q does not silence usage errors" "FAIL" \
            "exit=$qu_exit stderr='$qu_err'"
    fi

    # -q on a successful stat changes nothing.
    local qs_cmd qs_out qs_err qs_exit
    run_command qs_cmd qs_out qs_err qs_exit "$binary" -q -c '%s' "$tmpfile"
    if [[ "$qs_exit" -eq 0 && "$qs_out" == "6" && -z "$qs_err" ]]; then
        print_test_result "stat -q leaves a successful stat unchanged" "PASS"
    else
        print_test_result "stat -q leaves a successful stat unchanged" "FAIL" \
            "exit=$qs_exit stdout='$qs_out' stderr='$qs_err'"
    fi

    # --- Regression pin (issue #79): -f takes no format argument ---
    echo -e "${CYAN}Testing stat -f '%m' is a failed operand (issue #79)...${NC}"

    local m_cmd m_out m_err m_exit
    run_command m_cmd m_out m_err m_exit "$binary" -f '%m' "$tmpfile"
    if [[ "$m_exit" -ne 0 && "$m_err" == *"%m"* && "$m_out" == *"Block size:"* ]]; then
        print_test_result "stat -f '%m' fails on '%m' but still stats the file" "PASS"
    else
        print_test_result "stat -f '%m' fails on '%m' but still stats the file" "FAIL" \
            "exit=$m_exit stderr='$m_err'"
    fi

    # --- BSD display modes: -r -s -l -F -x (plus the st_dev they rely on) ---
    _test_stat_dev_parity "$binary" "$tmpfile"
    _test_stat_raw_mode "$binary" "$tmpfile"
    _test_stat_shell_mode "$binary" "$tmpfile" "$tmplink"
    _test_stat_ls_modes "$binary" "$tmpfile" "$tmplink"
    _test_stat_verbose_mode "$binary" "$tmpfile"
    _test_stat_mode_conflicts "$binary" "$tmpfile"
    _test_stat_bsd_byte_parity "$binary" "$tmpfile"

    # Cleanup
    rm -f "$tmpfile" "$tmplink"
}

# --- st_dev must match GNU -----------------------------------------------
#
# doStat_linux composes a synthetic ((major << 32) | minor) device id, so
# `stat -c %d` prints 1090921693184 where GNU prints 65024, `%D` prints
# fe00000000 where GNU prints fe00, and the default Device: line prints 0,0
# where GNU prints 254,0. -r and -s both print st_dev, so they inherit it.
_test_stat_dev_parity() {
    local binary="$1" f="$2"
    echo -e "${CYAN}Testing st_dev matches GNU (%d, %D, Device line)...${NC}"

    if [[ "$(uname)" != "Linux" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat %d/%D/Device match GNU stat" "SKIP" \
            "needs GNU /usr/bin/stat (not present on $(uname))"
        return 0
    fi

    local ours theirs
    ours=$("$binary" -c '%d %D' "$f" 2>/dev/null)
    theirs=$(/usr/bin/stat -c '%d %D' "$f" 2>/dev/null)
    if [[ "$ours" == "$theirs" ]]; then
        print_test_result "stat -c '%d %D' matches GNU stat" "PASS"
    else
        print_test_result "stat -c '%d %D' matches GNU stat" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi

    # python's os.stat is a second, independent reading of the same dev_t.
    local py_dev
    py_dev=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$f")
    if [[ "$("$binary" -c '%d' "$f" 2>/dev/null)" == "$py_dev" ]]; then
        print_test_result "stat -c '%d' matches python os.stat().st_dev" "PASS"
    else
        print_test_result "stat -c '%d' matches python os.stat().st_dev" "FAIL" \
            "ours='$("$binary" -c '%d' "$f" 2>/dev/null)' python='$py_dev'"
    fi

    local ours_dev theirs_dev
    ours_dev=$("$binary" "$f" 2>/dev/null | grep '^Device:' | cut -f1)
    theirs_dev=$(/usr/bin/stat "$f" 2>/dev/null | grep '^Device:' | cut -f1)
    if [[ "$ours_dev" == "$theirs_dev" ]]; then
        print_test_result "stat Device line major,minor matches GNU stat" "PASS"
    else
        print_test_result "stat Device line major,minor matches GNU stat" "FAIL" \
            "ours='$ours_dev' GNU='$theirs_dev'"
    fi
}

# --- -r RAW_FORMAT: "%d %i %#p %l %u %g %r %z %a %m %c %B %k %b %f %N" ----
_test_stat_raw_mode() {
    local binary="$1" f="$2"
    echo -e "${CYAN}Testing -r raw format...${NC}"

    local r_cmd r_out r_err r_exit
    run_command r_cmd r_out r_err r_exit "$binary" -r "$f"

    local -a fields
    read -ra fields <<< "$r_out"
    if [[ "$r_exit" -eq 0 && "${#fields[@]}" -eq 16 ]]; then
        print_test_result "stat -r prints 16 raw fields" "PASS"
    else
        print_test_result "stat -r prints 16 raw fields" "FAIL" \
            "exit=$r_exit fields=${#fields[@]} out='$r_out'"
        # Pad so the per-field checks below still report, rather than
        # silently disappearing whenever the field count is wrong.
        local pad
        for pad in $(seq "${#fields[@]}" 15); do fields[$pad]="<missing>"; done
    fi

    # Ground truth straight from the kernel via python, never from our stat.
    local truth
    truth=$(python3 -c '
import os, sys
s = os.stat(sys.argv[1], follow_symlinks=False)
print(s.st_dev, s.st_ino, "0" + oct(s.st_mode)[2:], s.st_nlink, s.st_uid,
      s.st_gid, s.st_rdev, s.st_size, s.st_atime_ns // 10**9,
      s.st_mtime_ns // 10**9, s.st_ctime_ns // 10**9, s.st_blksize,
      s.st_blocks)' "$f")
    local -a t
    read -ra t <<< "$truth"

    local head_ok=1 idx
    for idx in 0 1 2 3 4 5 6 7 8 9 10; do
        [[ "${fields[$idx]}" == "${t[$idx]}" ]] || head_ok=0
    done
    if [[ $head_ok -eq 1 ]]; then
        print_test_result "stat -r fields 0-10 match os.stat()" "PASS"
    else
        print_test_result "stat -r fields 0-10 match os.stat()" "FAIL" \
            "ours='${fields[*]:0:11}' truth='${t[*]:0:11}'"
    fi

    # 11 is birthtime, 12 blksize, 13 blocks, 14 st_flags (0 off BSD), 15 name.
    if [[ "${fields[11]}" =~ ^[0-9]+$ && "${fields[12]}" == "${t[11]}" &&
          "${fields[13]}" == "${t[12]}" && "${fields[14]}" == "0" &&
          "${fields[15]}" == "$f" ]]; then
        print_test_result "stat -r tail fields (btime, blksize, blocks, flags, name)" "PASS"
    else
        print_test_result "stat -r tail fields (btime, blksize, blocks, flags, name)" "FAIL" \
            "ours='${fields[*]:11:5}' expected btime/${t[11]}/${t[12]}/0/$f"
    fi
}

# --- -s SHELL_FORMAT: fifteen assignments, eval-safe, no file name -------
_test_stat_shell_mode() {
    local binary="$1" f="$2" link="$3"
    echo -e "${CYAN}Testing -s shell format...${NC}"

    local s_cmd s_out s_err s_exit
    run_command s_cmd s_out s_err s_exit "$binary" -s "$f"

    local -a fields
    read -ra fields <<< "$s_out"
    local expected_keys="st_dev st_ino st_mode st_nlink st_uid st_gid st_rdev \
st_size st_atime st_mtime st_ctime st_birthtime st_blksize st_blocks st_flags"
    local -a want
    read -ra want <<< "$expected_keys"

    local keys_ok=1 idx
    if [[ "${#fields[@]}" -ne 15 ]]; then
        keys_ok=0
    else
        for idx in "${!want[@]}"; do
            [[ "${fields[$idx]}" == "${want[$idx]}="* ]] || keys_ok=0
        done
    fi
    if [[ "$s_exit" -eq 0 && $keys_ok -eq 1 && "$s_out" != *"$f"* ]]; then
        print_test_result "stat -s prints the 15 st_* assignments and no file name" "PASS"
    else
        print_test_result "stat -s prints the 15 st_* assignments and no file name" "FAIL" \
            "exit=$s_exit out='$s_out'"
    fi

    # The whole point of SHELL_FORMAT: `eval` must define the variables.
    local eval_size eval_ino truth_ino
    eval_size=$( (eval "$("$binary" -s "$f" 2>/dev/null)"; echo "$st_size") )
    eval_ino=$( (eval "$("$binary" -s "$f" 2>/dev/null)"; echo "$st_ino") )
    truth_ino=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$f")
    if [[ "$eval_size" == "6" && "$eval_ino" == "$truth_ino" ]]; then
        print_test_result "stat -s output is eval-safe (\$st_size, \$st_ino)" "PASS"
    else
        print_test_result "stat -s output is eval-safe (\$st_size, \$st_ino)" "FAIL" \
            "st_size='$eval_size' st_ino='$eval_ino' (want 6 / $truth_ino)"
    fi

    # A symlink reports its own size; -L reports the target's.
    local link_size deref_size want_link_size
    want_link_size=$(python3 -c \
        'import os,sys; print(os.stat(sys.argv[1], follow_symlinks=False).st_size)' "$link")
    link_size=$( (eval "$("$binary" -s "$link" 2>/dev/null)"; echo "$st_size") )
    deref_size=$( (eval "$("$binary" -L -s "$link" 2>/dev/null)"; echo "$st_size") )
    if [[ "$link_size" == "$want_link_size" && "$deref_size" == "6" ]]; then
        print_test_result "stat -s on a symlink honors -L" "PASS"
    else
        print_test_result "stat -s on a symlink honors -L" "FAIL" \
            "link='$link_size' (want $want_link_size) deref='$deref_size' (want 6)"
    fi
}

# --- -l LS_FORMAT and -F LSF_FORMAT --------------------------------------
_test_stat_ls_modes() {
    local binary="$1" f="$2" link="$3"
    echo -e "${CYAN}Testing -l and -F ls formats...${NC}"

    local ls_re='^[-dlpbcs][-rwxSsTt]{9} [0-9]+ [^ ]+ [^ ]+ [0-9]+ '
    ls_re+='[A-Z][a-z]{2} [ 0-9]?[0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} '

    local l_cmd l_out l_err l_exit
    run_command l_cmd l_out l_err l_exit "$binary" -l "$f"
    if [[ "$l_exit" -eq 0 && "$l_out" =~ $ls_re && "$l_out" == *" 6 "* &&
          "$l_out" == *"$f" ]]; then
        print_test_result "stat -l renders the ls-style line (%Z is st_size)" "PASS"
    else
        print_test_result "stat -l renders the ls-style line (%Z is st_size)" "FAIL" \
            "exit=$l_exit out='$l_out'"
    fi

    run_command l_cmd l_out l_err l_exit "$binary" -l "$link"
    if [[ "$l_exit" -eq 0 && "$l_out" == l* && "$l_out" == *" $link -> $f" ]]; then
        print_test_result "stat -l on a symlink appends ' -> target'" "PASS"
    else
        print_test_result "stat -l on a symlink appends ' -> target'" "FAIL" "out='$l_out'"
    fi

    run_command l_cmd l_out l_err l_exit "$binary" -L -l "$link"
    if [[ "$l_exit" -eq 0 && "$l_out" == -* && "$l_out" != *" -> "* &&
          "$l_out" == *"$link" ]]; then
        print_test_result "stat -L -l on a symlink drops the arrow" "PASS"
    else
        print_test_result "stat -L -l on a symlink drops the arrow" "FAIL" "out='$l_out'"
    fi

    # -F is -l plus %T, the type suffix, wedged between %N and %SY.
    local suffix_dir suffix_exe suffix_fifo
    suffix_dir=$(create_temp_dir)
    suffix_exe="$suffix_dir/runme"
    suffix_fifo="$suffix_dir/pipe"
    : > "$suffix_exe"
    chmod 755 "$suffix_exe"
    mkfifo "$suffix_fifo"

    local F_cmd F_out F_err F_exit
    run_command F_cmd F_out F_err F_exit "$binary" -F "$f"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$f" ]]; then
        print_test_result "stat -F leaves a plain file unsuffixed" "PASS"
    else
        print_test_result "stat -F leaves a plain file unsuffixed" "FAIL" "out='$F_out'"
    fi

    run_command F_cmd F_out F_err F_exit "$binary" -F "$suffix_exe"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$suffix_exe*" ]]; then
        print_test_result "stat -F suffixes an executable with '*'" "PASS"
    else
        print_test_result "stat -F suffixes an executable with '*'" "FAIL" "out='$F_out'"
    fi

    run_command F_cmd F_out F_err F_exit "$binary" -F "$suffix_dir"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$suffix_dir/" ]]; then
        print_test_result "stat -F suffixes a directory with '/'" "PASS"
    else
        print_test_result "stat -F suffixes a directory with '/'" "FAIL" "out='$F_out'"
    fi

    run_command F_cmd F_out F_err F_exit "$binary" -F "$suffix_fifo"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$suffix_fifo|" ]]; then
        print_test_result "stat -F suffixes a fifo with '|'" "PASS"
    else
        print_test_result "stat -F suffixes a fifo with '|'" "FAIL" "out='$F_out'"
    fi

    run_command F_cmd F_out F_err F_exit "$binary" -F "$link"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$link@ -> $f" ]]; then
        print_test_result "stat -F suffixes a symlink with '@' before the arrow" "PASS"
    else
        print_test_result "stat -F suffixes a symlink with '@' before the arrow" "FAIL" \
            "out='$F_out'"
    fi

    # -F alone and -F -l are the same format; neither is a conflict.
    local fl_out lf_out
    fl_out=$("$binary" -F -l "$suffix_dir" 2>/dev/null || true)
    lf_out=$("$binary" -l -F "$suffix_dir" 2>/dev/null || true)
    run_command F_cmd F_out F_err F_exit "$binary" -F "$suffix_dir"
    if [[ "$F_exit" -eq 0 && "$F_out" == *"$suffix_dir/" &&
          "$fl_out" == "$F_out" && "$lf_out" == "$F_out" ]]; then
        print_test_result "stat -F -l and -l -F render the LSF format" "PASS"
    else
        print_test_result "stat -F -l and -l -F render the LSF format" "FAIL" \
            "-F='$F_out' -F -l='$fl_out' -l -F='$lf_out'"
    fi

    rm -rf "$suffix_dir"
}

# --- -x LINUX_FORMAT: eight labelled lines with literal BSD spacing ------
_test_stat_verbose_mode() {
    local binary="$1" f="$2"
    echo -e "${CYAN}Testing -x verbose format...${NC}"

    local x_file="$TEMP_DIR/stat_x_$$"
    local x_exit=0
    set +e
    "$binary" -x "$f" > "$x_file" 2>/dev/null
    x_exit=$?
    set -e

    local x_lines
    x_lines=$(wc -l < "$x_file" | tr -d ' ')
    if [[ "$x_exit" -eq 0 && "$x_lines" -eq 8 ]]; then
        print_test_result "stat -x prints 8 lines" "PASS"
    else
        print_test_result "stat -x prints 8 lines" "FAIL" "exit=$x_exit lines=$x_lines"
    fi

    local x_out
    x_out=$(cat "$x_file")
    local labels_ok=1
    [[ "$(sed -n '1p' "$x_file")" == "  File: \"$f\"" ]] || labels_ok=0
    [[ "$(sed -n '2p' "$x_file")" == "  Size: "* ]] || labels_ok=0
    [[ "$(sed -n '3p' "$x_file")" == "  Mode: ("* ]] || labels_ok=0
    [[ "$(sed -n '4p' "$x_file")" == "Device: "* ]] || labels_ok=0
    [[ "$(sed -n '5p' "$x_file")" == "Access: "* ]] || labels_ok=0
    [[ "$(sed -n '6p' "$x_file")" == "Modify: "* ]] || labels_ok=0
    [[ "$(sed -n '7p' "$x_file")" == "Change: "* ]] || labels_ok=0
    [[ "$(sed -n '8p' "$x_file")" == " Birth: "* ]] || labels_ok=0
    if [[ $labels_ok -eq 1 ]]; then
        print_test_result "stat -x uses the 8 BSD labels in order" "PASS"
    else
        print_test_result "stat -x uses the 8 BSD labels in order" "FAIL" "out='$x_out'"
    fi

    # Literal runs from the FreeBSD format strings: "%-11z  FileType: ",
    # ")         Uid: (", ")  Gid: (", "   Inode: " and "    Links: ". The
    # size and mode come from python so the expectation tracks the real file
    # (mktemp makes it 0600, not 0644).
    local want_size want_mode
    want_size=$(python3 -c '
import os, sys
s = os.stat(sys.argv[1])
print("  Size: %-11d  FileType: Regular File" % s.st_size)' "$f")
    want_mode=$(python3 -c '
import os, stat, sys
s = os.stat(sys.argv[1])
print("  Mode: (%o%03o/%s)" % ((s.st_mode >> 9) & 7, s.st_mode & 0o777,
                               stat.filemode(s.st_mode)))' "$f")

    local spacing_ok=1
    [[ "$(sed -n '2p' "$x_file")" == "$want_size" ]] || spacing_ok=0
    [[ "$(sed -n '3p' "$x_file")" == "$want_mode"* ]] || spacing_ok=0
    [[ "$(sed -n '3p' "$x_file")" == *")         Uid: ("* ]] || spacing_ok=0
    [[ "$(sed -n '3p' "$x_file")" == *")  Gid: ("* ]] || spacing_ok=0
    [[ "$(sed -n '4p' "$x_file")" == *"   Inode: "* ]] || spacing_ok=0
    [[ "$(sed -n '4p' "$x_file")" == *"    Links: 1" ]] || spacing_ok=0
    if [[ $spacing_ok -eq 1 ]]; then
        print_test_result "stat -x reproduces the literal BSD spacing" "PASS"
    else
        print_test_result "stat -x reproduces the literal BSD spacing" "FAIL" \
            "out='$x_out' want_size='$want_size' want_mode='$want_mode'"
    fi

    # The Device line is major,minor of st_dev, so it must match the kernel.
    if [[ "$(uname)" == "Linux" ]]; then
        local want_dev
        want_dev=$(python3 -c '
import os, sys
s = os.stat(sys.argv[1])
print("Device: %d,%d" % (os.major(s.st_dev), os.minor(s.st_dev)))' "$f")
        if [[ "$(sed -n '4p' "$x_file")" == "$want_dev"* ]]; then
            print_test_result "stat -x Device line matches os.major/os.minor" "PASS"
        else
            print_test_result "stat -x Device line matches os.major/os.minor" "FAIL" \
                "ours='$(sed -n '4p' "$x_file")' want='$want_dev...'"
        fi
    fi

    # The four time lines are strftime renderings, not epoch seconds.
    local times_ok=1 n
    for n in 5 6 7 8; do
        local stamp
        stamp=$(sed -n "${n}p" "$x_file" | cut -c 9-)
        [[ "$stamp" =~ ^[A-Za-z] && "$stamp" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} &&
           "$stamp" =~ [0-9]{4} ]] || times_ok=0
    done
    if [[ $times_ok -eq 1 ]]; then
        print_test_result "stat -x time lines are strftime renderings" "PASS"
    else
        print_test_result "stat -x time lines are strftime renderings" "FAIL" "out='$x_out'"
    fi

    rm -f "$x_file"
}

# --- Mutual exclusion and cross-interface conflicts -----------------------
_test_stat_mode_conflicts() {
    local binary="$1" f="$2"
    echo -e "${CYAN}Testing display-mode conflicts...${NC}"

    # FreeBSD: two of -l -r -s -x is exit 1, "can't use format 'X' with 'Y'".
    local pair
    for pair in "-l:-r:l:r" "-r:-s:r:s" "-s:-x:s:x" "-x:-l:x:l"; do
        IFS=':' read -r first second fc sc <<< "$pair"
        local e_cmd e_out e_err e_exit
        run_command e_cmd e_out e_err e_exit "$binary" "$first" "$second" "$f"
        if [[ "$e_exit" -eq 1 && "$e_err" == *"can't use format '$fc' with '$sc'"* ]]; then
            print_test_result "stat $first $second is a conflict (exit 1)" "PASS"
        else
            print_test_result "stat $first $second is a conflict (exit 1)" "FAIL" \
                "exit=$e_exit stderr='$e_err'"
        fi
    done

    # -F only coexists with -l.
    local mode
    for mode in r s x; do
        local g_cmd g_out g_err g_exit
        run_command g_cmd g_out g_err g_exit "$binary" -F "-$mode" "$f"
        if [[ "$g_exit" -eq 1 && "$g_err" == *"can't use format '$mode' with -F"* ]]; then
            print_test_result "stat -F -$mode is a conflict (exit 1)" "PASS"
        else
            print_test_result "stat -F -$mode is a conflict (exit 1)" "FAIL" \
                "exit=$g_exit stderr='$g_err'"
        fi
    done

    # A display mode plus a GNU output selector is misuse (exit 2), never a
    # silent win for one of the two.
    local combo
    for combo in "-r:-c:%s:r:-c" "-l:--printf=%s::l:--printf" "-s:-t::s:-t" "-x:-f::x:-f"; do
        IFS=':' read -r dmode sel arg dc sname <<< "$combo"
        local x_cmd x_out x_err x_exit
        if [[ -n "$arg" ]]; then
            run_command x_cmd x_out x_err x_exit "$binary" "$dmode" "$sel" "$arg" "$f"
        else
            run_command x_cmd x_out x_err x_exit "$binary" "$dmode" "$sel" "$f"
        fi
        if [[ "$x_exit" -eq 2 && "$x_err" == *"can't use format '$dc' with $sname"* ]]; then
            print_test_result "stat $dmode $sel is misuse (exit 2)" "PASS"
        else
            print_test_result "stat $dmode $sel is misuse (exit 2)" "FAIL" \
                "exit=$x_exit stderr='$x_err'"
        fi
    done

    # -n, -q and -L never conflict with a display mode.
    local n_file="$TEMP_DIR/stat_mode_n_$$"
    local n_exit=0
    set +e
    "$binary" -l -n -q -L "$f" > "$n_file" 2>/dev/null
    n_exit=$?
    set -e
    local last_byte
    last_byte=$(tail -c 1 "$n_file" | od -An -c | tr -d ' ')
    if [[ "$n_exit" -eq 0 && "$last_byte" != '\n' ]]; then
        print_test_result "stat -l -n -q -L is accepted and drops the terminator" "PASS"
    else
        print_test_result "stat -l -n -q -L is accepted and drops the terminator" "FAIL" \
            "exit=$n_exit last_byte='$last_byte'"
    fi
    rm -f "$n_file"
}

# --- Exact parity against a real BSD stat (macOS CI is the oracle) -------
#
# There is no BSD stat on Linux, so these skip there; the macOS runner is
# what actually proves the five renderers byte-for-byte.
_test_stat_bsd_byte_parity() {
    local binary="$1" f="$2"

    if [[ "$(uname)" != "Darwin" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat -r/-s/-l/-F/-x byte-match /usr/bin/stat" "SKIP" \
            "no BSD stat on $(uname)"
        return 0
    fi

    echo -e "${CYAN}Testing byte-for-byte parity with BSD stat...${NC}"

    local flag ours theirs
    for flag in -r -s -l -F -x; do
        ours=$(run_with_limit 10 "$binary" "$flag" "$f" 2>/dev/null || true)
        theirs=$(run_with_limit 10 /usr/bin/stat "$flag" "$f" 2>/dev/null || true)
        if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
            print_test_result "stat $flag matches /usr/bin/stat byte-for-byte" "PASS"
        else
            print_test_result "stat $flag matches /usr/bin/stat byte-for-byte" "FAIL" \
                "ours='$ours' BSD='$theirs'"
        fi
    done

    # And on a directory, where -F's suffix and %Z both change.
    local par_dir
    par_dir=$(create_temp_dir)
    for flag in -l -F -x; do
        ours=$(run_with_limit 10 "$binary" "$flag" "$par_dir" 2>/dev/null || true)
        theirs=$(run_with_limit 10 /usr/bin/stat "$flag" "$par_dir" 2>/dev/null || true)
        if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
            print_test_result "stat $flag on a directory matches /usr/bin/stat" "PASS"
        else
            print_test_result "stat $flag on a directory matches /usr/bin/stat" "FAIL" \
                "ours='$ours' BSD='$theirs'"
        fi
    done
    rm -rf "$par_dir"
}
