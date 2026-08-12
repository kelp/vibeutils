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

    # Invalid flag exits with code 1
    test_command_exit_code "stat invalid flag exits 1" 1 \
        "$binary" --invalid-flag

    # Missing operand exits with code 1
    test_command_exit_code "stat missing operand exits 1" 1 \
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

    # --- Issue #105: %N must follow GNU's shell_escape_quoting_style,
    # not always single-quote. Pinned against GNU coreutils 9.5.
    echo -e "${CYAN}Testing %N quoting rules (issue #105)...${NC}"

    local apos_dir
    apos_dir=$(create_temp_dir)

    # Rule 2: a lone apostrophe switches to double quotes.
    local apos_file="$apos_dir/it's"
    touch -- "$apos_file"
    local apos_out
    apos_out=$("$binary" -c '%N' "$apos_file" 2>/dev/null)
    if [[ "$apos_out" == "\"$apos_file\"" ]]; then
        print_test_result "stat -c '%N' rule 2: apostrophe uses double quotes" "PASS"
    else
        print_test_result "stat -c '%N' rule 2: apostrophe uses double quotes" "FAIL" \
            "Expected \"$apos_file\", got '$apos_out'"
    fi

    # Rule 3: an apostrophe together with a $ forces the splice form,
    # NOT the naive "always double-quote on apostrophe" the issue
    # suggested -- this is the case that would trip up that fix.
    local dollar_file="$apos_dir/it's and \$var"
    touch -- "$dollar_file"
    local dollar_out
    dollar_out=$("$binary" -c '%N' "$dollar_file" 2>/dev/null)
    # Expected: 'DIR/it'\''s and $var' -- the directory prefix has no
    # apostrophe, so only the "it's" part splices.
    local dollar_expected="'$apos_dir/it'\\''s and \$var'"
    if [[ "$dollar_out" == "$dollar_expected" ]]; then
        print_test_result "stat -c '%N' rule 3: apostrophe+dollar splices single quotes" "PASS"
    else
        print_test_result "stat -c '%N' rule 3: apostrophe+dollar splices single quotes" "FAIL" \
            "Expected '$dollar_expected', got '$dollar_out'"
    fi

    # Rule 1 regression guard: a bare double quote alone does not switch
    # quote style.
    local dq_file="$apos_dir/dq\"name"
    touch -- "$dq_file"
    local dq_out
    dq_out=$("$binary" -c '%N' "$dq_file" 2>/dev/null)
    if [[ "$dq_out" == "'$dq_file'" ]]; then
        print_test_result "stat -c '%N' rule 1: lone double quote stays single-quoted" "PASS"
    else
        print_test_result "stat -c '%N' rule 1: lone double quote stays single-quoted" "FAIL" \
            "Expected '$dq_file', got '$dq_out'"
    fi

    # Symlink form: link name and target are quoted independently. Here
    # the link name has no apostrophe (rule 1) but the target does
    # (rule 2), so the two arrow sides use different quote characters.
    local apos_target="it's"
    (cd "$apos_dir" && ln -sf "$apos_target" "lnk_apos")
    local apos_link_out
    apos_link_out=$("$binary" -c '%N' "$apos_dir/lnk_apos" 2>/dev/null)
    if [[ "$apos_link_out" == "'$apos_dir/lnk_apos' -> \"$apos_target\"" ]]; then
        print_test_result "stat -c '%N' symlink quotes target independently of link name" "PASS"
    else
        print_test_result "stat -c '%N' symlink quotes target independently of link name" "FAIL" \
            "Expected '$apos_dir/lnk_apos' -> \"$apos_target\", got '$apos_link_out'"
    fi

    # Symlink form, other direction: the LINK NAME itself has an
    # apostrophe (rule 2) while the target does not (rule 1). This
    # guards against a partial fix that only quotes the target operand
    # and leaves the link name hardcoded to single quotes.
    local apos_link_name="$apos_dir/it's_link"
    (cd "$apos_dir" && ln -sf "plain" "it's_link")
    local apos_linkname_out
    apos_linkname_out=$("$binary" -c '%N' "$apos_link_name" 2>/dev/null)
    if [[ "$apos_linkname_out" == "\"$apos_link_name\" -> 'plain'" ]]; then
        print_test_result "stat -c '%N' symlink quotes link name independently of target" "PASS"
    else
        print_test_result "stat -c '%N' symlink quotes link name independently of target" "FAIL" \
            "Expected \"$apos_link_name\" -> 'plain', got '$apos_linkname_out'"
    fi

    # %N embedded inside a longer -c format string quotes identically
    # to a bare -c %N.
    local embedded_out
    embedded_out=$("$binary" -c "name=%N size=%s" "$apos_file" 2>/dev/null)
    if [[ "$embedded_out" == "name=\"$apos_file\" size=0" ]]; then
        print_test_result "stat -c 'name=%N size=%s' quotes identically to bare %N" "PASS"
    else
        print_test_result "stat -c 'name=%N size=%s' quotes identically to bare %N" "FAIL" \
            "Expected name=\"$apos_file\" size=0, got '$embedded_out'"
    fi

    # Regression guard: the default record's "File:" line stays
    # UNQUOTED even for a name that %N would quote.
    local default_line
    default_line=$("$binary" "$apos_file" 2>/dev/null | head -1)
    if [[ "$default_line" == "  File: $apos_file" ]]; then
        print_test_result "stat default 'File:' line stays unquoted for apostrophe name" "PASS"
    else
        print_test_result "stat default 'File:' line stays unquoted for apostrophe name" "FAIL" \
            "Expected '  File: $apos_file', got '$default_line'"
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
    if [[ "$qu_exit" -eq 1 && "$qu_err" == *"requires an argument"* ]]; then
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
    _test_stat_bsd_verbose_zero_birthtime_parity "$binary"
    _test_stat_dev_type_null_parity "$binary"
    _test_stat_dev_type_minor_gt255 "$binary"
    _test_stat_darwin_devfs_dev_type "$binary"
    _test_stat_default_record_parity "$binary"

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

    # A display mode plus a GNU output selector is a usage error (exit 1), never a
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
        if [[ "$x_exit" -eq 1 && "$x_err" == *"can't use format '$dc' with $sname"* ]]; then
            print_test_result "stat $dmode $sel is a usage error (exit 1)" "PASS"
        else
            print_test_result "stat $dmode $sel is a usage error (exit 1)" "FAIL" \
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

# --- BSD -x parity on a zero birthtimespec (issue #102) ------------------
#
# The parity loop above only ever sees a regular temp file, whose birth time
# is nonzero, so it cannot catch a Birth-line regression driven by the
# availability rule. /dev/null on devfs has an all-zero birthtimespec
# (`/usr/bin/stat -f '%B' /dev/null` -> 0), which gnulib's
# get_stat_birthtime treats as unavailable on BSD -- so GNU's own `gstat`
# prints " Birth: -" for it while BSD `stat -x` prints the formatted epoch
# date. -x follows the BSD spec, so it must match /usr/bin/stat here, not
# the GNU rendering.
_test_stat_bsd_verbose_zero_birthtime_parity() {
    local binary="$1"

    if [[ "$(uname)" != "Darwin" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat -x /dev/null byte-matches /usr/bin/stat" "SKIP" \
            "no BSD stat on $(uname)"
        return 0
    fi
    if [[ ! -c /dev/null ]]; then
        print_test_result "stat -x /dev/null byte-matches /usr/bin/stat" "SKIP" \
            "/dev/null is not a character device"
        return 0
    fi

    echo -e "${CYAN}Testing -x parity for /dev/null's zero birth time (issue #102)...${NC}"

    local ours theirs
    ours=$(run_with_limit 10 "$binary" -x /dev/null 2>/dev/null || true)
    theirs=$(run_with_limit 10 /usr/bin/stat -x /dev/null 2>/dev/null || true)

    # Access/Modify/Change are excluded from the comparison. The two binaries
    # run as separate processes, and /dev/null's timestamps advance under a
    # busy machine, so a whole-record byte match races: on a loaded CI runner
    # the two invocations land on either side of a second boundary and the
    # Modify/Change lines disagree by exactly 1s. Every stable field -- File,
    # Size, FileType, Mode, Uid, Gid, Device, Inode, Links and Birth -- is
    # still compared byte for byte, which is what issue #102 is about; the
    # three volatile lines carry no information this test wants.
    local ours_stable theirs_stable
    ours_stable=$(printf '%s\n' "$ours" | grep -vE '^(Access|Modify|Change):')
    theirs_stable=$(printf '%s\n' "$theirs" | grep -vE '^(Access|Modify|Change):')
    if [[ -n "$theirs_stable" && "$ours_stable" == "$theirs_stable" ]]; then
        print_test_result "stat -x /dev/null matches /usr/bin/stat on all stable fields" "PASS"
    else
        print_test_result "stat -x /dev/null matches /usr/bin/stat on all stable fields" "FAIL" \
            "ours='$ours_stable' BSD='$theirs_stable'"
    fi

    # The Birth line specifically, so a failure names the field at issue
    # instead of leaving a whole-record diff to be read by eye.
    local ours_birth theirs_birth
    ours_birth=$(printf '%s\n' "$ours" | grep '^ Birth:' || true)
    theirs_birth=$(printf '%s\n' "$theirs" | grep '^ Birth:' || true)
    if [[ -n "$theirs_birth" && "$ours_birth" == "$theirs_birth" ]]; then
        print_test_result "stat -x /dev/null Birth line formats the epoch, not '-'" "PASS"
    else
        print_test_result "stat -x /dev/null Birth line formats the epoch, not '-'" "FAIL" \
            "ours='$ours_birth' BSD='$theirs_birth'"
    fi
}

# --- Device major/minor parity against GNU stat (issue #92) --------------
#
# GNU coreutils is the oracle for the Linux-only bit layout. These skip
# outside Linux, or when the GNU reference binary is unavailable.

# /dev/null's minor (3) stays under the 8-bit truncation threshold, so this
# only proves the previously-missing "Device type:" field and the %t/%T
# plumbing -- the minor-truncation regression itself needs a node whose
# minor is >= 256, covered separately below.
_test_stat_dev_type_null_parity() {
    local binary="$1"
    echo -e "${CYAN}Testing /dev/null Device-type parity with GNU stat (issue #92)...${NC}"

    if [[ "$(uname)" != "Linux" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat /dev/null Device-type parity" "SKIP" \
            "needs GNU /usr/bin/stat (not present on $(uname))"
        return 0
    fi
    if [[ ! -c /dev/null || ! -r /dev/null ]]; then
        print_test_result "stat /dev/null Device-type parity" "SKIP" \
            "/dev/null missing or unreadable"
        return 0
    fi

    # Scoped to the Device line itself (not the whole record). Prior to
    # issue #98, the Size line had an unrelated tab-vs-space formatting
    # gap from GNU that was out of scope for issue #92 and would have kept
    # a whole-record comparison red; that gap is now fixed and covered by
    # a whole-record diff in _test_stat_default_record_parity below, but
    # this check stays scoped to the Device line as defense in depth.
    local ours theirs
    ours=$("$binary" /dev/null 2>/dev/null | grep '^Device:')
    theirs=$(/usr/bin/stat /dev/null 2>/dev/null | grep '^Device:')
    if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
        print_test_result "stat Device line for /dev/null matches GNU (Device type field)" "PASS"
    else
        print_test_result "stat Device line for /dev/null matches GNU (Device type field)" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi

    ours=$("$binary" -c '%t %T' /dev/null 2>/dev/null)
    theirs=$(/usr/bin/stat -c '%t %T' /dev/null 2>/dev/null)
    if [[ "$ours" == "$theirs" ]]; then
        print_test_result "stat -c '%t %T' for /dev/null matches GNU stat" "PASS"
    else
        print_test_result "stat -c '%t %T' for /dev/null matches GNU stat" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi

    ours=$("$binary" -t /dev/null 2>/dev/null)
    theirs=$(/usr/bin/stat -t /dev/null 2>/dev/null)
    if [[ "$ours" == "$theirs" ]]; then
        print_test_result "stat -t for /dev/null matches GNU stat" "PASS"
    else
        print_test_result "stat -t for /dev/null matches GNU stat" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi
}

# Scans /dev for a node GNU reports with rdev minor >= 256 -- the region the
# `& 0xff` mask actually truncates -- and re-runs the same three
# comparisons against it. mknod is not an option here: run-integration.sh
# drops privilege, and the kernel rejects major >= 4096 anyway, so this
# relies on whatever device nodes the runner's /dev already has.
_test_stat_dev_type_minor_gt255() {
    local binary="$1"
    echo -e "${CYAN}Testing device minor >= 256 parity with GNU stat (issue #92)...${NC}"

    if [[ "$(uname)" != "Linux" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat device-type minor>=256 parity" "SKIP" \
            "needs GNU /usr/bin/stat (not present on $(uname))"
        return 0
    fi

    # No readability filter here: stat(2) needs only search permission on
    # the containing directory, not read permission on the node itself, so
    # excluding unreadable nodes would silently skip most minor>=256 nodes
    # on a typical /dev (e.g. /dev/binder, /dev/userfaultfd) even though
    # GNU stat handles them fine.
    local node="" candidate minor_hex minor_dec
    for candidate in /dev/*; do
        [[ -b "$candidate" || -c "$candidate" ]] || continue
        minor_hex=$(/usr/bin/stat -c '%T' "$candidate" 2>/dev/null) || continue
        [[ -n "$minor_hex" ]] || continue
        minor_dec=$((16#$minor_hex))
        if ((minor_dec >= 256)); then
            node="$candidate"
            break
        fi
    done

    if [[ -z "$node" ]]; then
        print_test_result "stat device-type minor>=256 parity" "SKIP" \
            "no /dev node with minor >= 256 found on this runner"
        return 0
    fi

    # Scoped to the Device line for the same reason as the /dev/null check
    # above. The whole-record Size-line gap this used to dodge is fixed by
    # issue #98 and covered separately by
    # _test_stat_default_record_parity; this check stays scoped to the
    # Device line as defense in depth.
    local ours theirs
    ours=$("$binary" "$node" 2>/dev/null | grep '^Device:')
    theirs=$(/usr/bin/stat "$node" 2>/dev/null | grep '^Device:')
    if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
        print_test_result "stat Device line matches GNU for $node (minor>=256)" "PASS"
    else
        print_test_result "stat Device line matches GNU for $node (minor>=256)" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi

    ours=$("$binary" -c '%t %T' "$node" 2>/dev/null)
    theirs=$(/usr/bin/stat -c '%t %T' "$node" 2>/dev/null)
    if [[ "$ours" == "$theirs" ]]; then
        print_test_result "stat -c '%t %T' matches GNU for $node (minor>=256)" "PASS"
    else
        print_test_result "stat -c '%t %T' matches GNU for $node (minor>=256)" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi

    ours=$("$binary" -t "$node" 2>/dev/null)
    theirs=$(/usr/bin/stat -t "$node" 2>/dev/null)
    if [[ "$ours" == "$theirs" ]]; then
        print_test_result "stat -t matches GNU for $node (minor>=256)" "PASS"
    else
        print_test_result "stat -t matches GNU for $node (minor>=256)" "FAIL" \
            "ours='$ours' GNU='$theirs'"
    fi
}

# --- devfs parity on macOS (closes the /dev/* test gap from issue #91) ---
#
# BSD stat's %Hr/%Lr sub-field specifiers give the rdev major/minor
# straight from the kernel, independent of our own devMajor/devMinor. Ours
# is read back through -c '%t %T' (hex) and decoded, so this compares two
# different code paths' readings of the same devfs node.
_test_stat_darwin_devfs_dev_type() {
    local binary="$1"
    echo -e "${CYAN}Testing /dev/null device-type parity on Darwin (issue #92)...${NC}"

    if [[ "$(uname)" != "Darwin" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat /dev/null device-type parity (Darwin)" "SKIP" \
            "needs BSD /usr/bin/stat (not present on $(uname))"
        return 0
    fi

    local rc_cmd rc_out rc_err rc_exit
    run_command rc_cmd rc_out rc_err rc_exit "$binary" /dev/null
    if [[ "$rc_exit" -eq 0 ]]; then
        print_test_result "stat /dev/null exits 0 on Darwin" "PASS"
    else
        print_test_result "stat /dev/null exits 0 on Darwin" "FAIL" \
            "exit=$rc_exit stderr='$rc_err'"
    fi

    local ours_hex theirs ours_major_dec ours_minor_dec
    ours_hex=$(run_with_limit 10 "$binary" -c '%t %T' /dev/null 2>/dev/null || true)
    theirs=$(run_with_limit 10 /usr/bin/stat -f '%Hr,%Lr' /dev/null 2>/dev/null || true)
    if [[ -n "$ours_hex" && -n "$theirs" ]]; then
        ours_major_dec=$((16#${ours_hex%% *}))
        ours_minor_dec=$((16#${ours_hex##* }))
        if [[ "$theirs" == "${ours_major_dec},${ours_minor_dec}" ]]; then
            print_test_result "stat -c '%t %T' (decoded) matches BSD stat -f '%Hr,%Lr'" "PASS"
        else
            print_test_result "stat -c '%t %T' (decoded) matches BSD stat -f '%Hr,%Lr'" "FAIL" \
                "ours='$ours_hex' -> ${ours_major_dec},${ours_minor_dec} BSD='$theirs'"
        fi
    else
        print_test_result "stat -c '%t %T' (decoded) matches BSD stat -f '%Hr,%Lr'" "FAIL" \
            "ours_hex='$ours_hex' BSD='$theirs'"
    fi
}

# --- Whole-record default output parity with GNU stat (issue #98) ---
#
# Unlike the Device-line-only checks above (issue #92, scoped to
# `grep '^Device:'` to dodge a then-unrelated Size-line separator gap),
# this diffs the ENTIRE default record byte for byte. GNU varies the
# record shape by file type (regular file, directory, character special),
# so all three are covered separately.
_test_stat_default_record_parity() {
    local binary="$1"
    echo -e "${CYAN}Testing whole-record default output parity with GNU stat (issue #98)...${NC}"

    if [[ "$(uname)" != "Linux" || ! -x /usr/bin/stat ]]; then
        print_test_result "stat default record parity" "SKIP" \
            "needs GNU /usr/bin/stat (not present on $(uname))"
        return 0
    fi

    # Regular file. stat(2) does not update atime on read, so back-to-back
    # readings of the same file are stable.
    local reg_file ours theirs
    reg_file=$(create_temp_file "issue98 default record parity")
    ours=$("$binary" "$reg_file" 2>/dev/null)
    theirs=$(/usr/bin/stat "$reg_file" 2>/dev/null)
    if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
        print_test_result "stat default record matches GNU for a regular file" "PASS"
    else
        # Whitespace made visible: issue #98 is specifically about missing
        # tabs and vanished/folded pad spaces, which render near-identically
        # in a raw log otherwise. Substitution (not cat -A) since PATH is
        # pinned to zig-out/bin here and `cat` resolves to our own cat.
        local ours_vis=${ours//$'\t'/<TAB>}
        local theirs_vis=${theirs//$'\t'/<TAB>}
        print_test_result "stat default record matches GNU for a regular file" "FAIL" \
            "ours='$ours_vis' GNU='$theirs_vis'"
    fi

    # Directory. A fresh mktemp -d target, not /tmp itself, since other
    # concurrently-running tests perturb /tmp's mtime.
    local reg_dir
    reg_dir=$(create_temp_dir)
    ours=$("$binary" "$reg_dir" 2>/dev/null)
    theirs=$(/usr/bin/stat "$reg_dir" 2>/dev/null)
    if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
        print_test_result "stat default record matches GNU for a directory" "PASS"
    else
        local ours_vis=${ours//$'\t'/<TAB>}
        local theirs_vis=${theirs//$'\t'/<TAB>}
        print_test_result "stat default record matches GNU for a directory" "FAIL" \
            "ours='$ours_vis' GNU='$theirs_vis'"
    fi

    # Character special file: exercises the "Device type:" suffix line too.
    if [[ ! -c /dev/null || ! -r /dev/null ]]; then
        print_test_result "stat default record matches GNU for /dev/null" "SKIP" \
            "/dev/null missing or unreadable"
        return 0
    fi
    ours=$("$binary" /dev/null 2>/dev/null)
    theirs=$(/usr/bin/stat /dev/null 2>/dev/null)
    if [[ -n "$theirs" && "$ours" == "$theirs" ]]; then
        print_test_result "stat default record matches GNU for /dev/null" "PASS"
    else
        local ours_vis=${ours//$'\t'/<TAB>}
        local theirs_vis=${theirs//$'\t'/<TAB>}
        print_test_result "stat default record matches GNU for /dev/null" "FAIL" \
            "ours='$ours_vis' GNU='$theirs_vis'"
    fi
}
