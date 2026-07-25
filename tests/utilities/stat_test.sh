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

    # -f shows file system info, and a successful run emits no hint
    local stat_f_cmd stat_f_out stat_f_err stat_f_exit
    run_command stat_f_cmd stat_f_out stat_f_err stat_f_exit "$binary" -f "$tmpfile"
    if [[ $stat_f_exit -eq 0 && "$stat_f_out" =~ "Block" && "$stat_f_err" != *"hint:"* ]]; then
        print_test_result "stat -f shows file system info" "PASS"
    else
        print_test_result "stat -f shows file system info" "FAIL" \
            "Exit code: $stat_f_exit, stderr: '$stat_f_err'"
    fi

    # --- F67: BSD 'stat -f FORMAT' misuse hint (issue #79) ---
    # GNU spells -f as --file-system; BSD spells -f as the format flag, so a
    # BSD script silently changes meaning here. stat emits a non-fatal hint on
    # stderr, and must not touch stdout or the exit status doing so.
    echo -e "${CYAN}Testing BSD -f format misuse hint (F67)...${NC}"

    local bsd_hint_cmd bsd_hint_out bsd_hint_err bsd_hint_exit
    run_command bsd_hint_cmd bsd_hint_out bsd_hint_err bsd_hint_exit \
        "$binary" -f '%Sm' "$tmpfile"
    if [[ "$bsd_hint_err" == *"hint:"* && "$bsd_hint_err" == *"stat -c FORMAT"* ]]; then
        print_test_result "stat -f '%Sm' hints that -f is --file-system" "PASS"
    else
        print_test_result "stat -f '%Sm' hints that -f is --file-system" "FAIL" \
            "Expected hint in stderr, got: '$bsd_hint_err'"
    fi

    # Parity regression: the reference run fails the same way but earns no
    # hint; the exit status must match, and nothing may leak onto stdout.
    #
    # This is deliberately NOT a byte-for-byte stdout compare: the free-block
    # and free-inode counts come from two separate statfs calls and drift on a
    # busy runner. Equal line counts plus the absence of hint text on stdout
    # still catch a hint routed to (or appended after) stdout.
    local bsd_ref_cmd bsd_ref_out bsd_ref_err bsd_ref_exit
    run_command bsd_ref_cmd bsd_ref_out bsd_ref_err bsd_ref_exit \
        "$binary" -f /nonexistent-bsd-hint-probe "$tmpfile"
    local bsd_hint_lines bsd_ref_lines
    bsd_hint_lines=$(printf '%s' "$bsd_hint_out" | wc -l)
    bsd_ref_lines=$(printf '%s' "$bsd_ref_out" | wc -l)
    if [[ "$bsd_hint_lines" -eq "$bsd_ref_lines" && "$bsd_hint_exit" == "$bsd_ref_exit" &&
        $bsd_hint_exit -eq 1 && "$bsd_hint_out" != *"hint"* &&
        "$bsd_hint_out" != *"-f means"* && "$bsd_ref_err" != *"hint:"* ]]; then
        print_test_result "stat -f BSD hint leaves stdout and exit status unchanged" "PASS"
    else
        print_test_result "stat -f BSD hint leaves stdout and exit status unchanged" "FAIL" \
            "exit $bsd_hint_exit/$bsd_ref_exit, lines $bsd_hint_lines/$bsd_ref_lines (hint/ref)"
    fi

    # An ordinary missing file must not trigger the hint.
    local bsd_plain_cmd bsd_plain_out bsd_plain_err bsd_plain_exit
    run_command bsd_plain_cmd bsd_plain_out bsd_plain_err bsd_plain_exit \
        "$binary" -f /nonexistent/plain
    if [[ $bsd_plain_exit -eq 1 && "$bsd_plain_err" != *"hint:"* ]]; then
        print_test_result "stat -f missing file does not hint" "PASS"
    else
        print_test_result "stat -f missing file does not hint" "FAIL" \
            "Exit code: $bsd_plain_exit, stderr: '$bsd_plain_err'"
    fi

    # The clustered BSD spelling dies in the parser; hint there too, with the
    # misuse exit code and empty stdout preserved.
    local bsd_clust_cmd bsd_clust_out bsd_clust_err bsd_clust_exit
    run_command bsd_clust_cmd bsd_clust_out bsd_clust_err bsd_clust_exit \
        "$binary" -f%z "$tmpfile"
    if [[ $bsd_clust_exit -eq 2 && "$bsd_clust_err" == *"hint:"* && -z "$bsd_clust_out" ]]; then
        print_test_result "stat -f%z hints on the misuse path" "PASS"
    else
        print_test_result "stat -f%z hints on the misuse path" "FAIL" \
            "Exit code: $bsd_clust_exit, stdout: '$bsd_clust_out', stderr: '$bsd_clust_err'"
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

    local stat_fc_cmd stat_fc_out stat_fc_err stat_fc_exit
    run_command stat_fc_cmd stat_fc_out stat_fc_err stat_fc_exit \
        "$binary" -f -c '%n' "$tmpfile"
    # -c already selects the GNU format flag, so -f cannot have been meant as
    # BSD's format flag: no hint here (F67).
    if [[ "$stat_fc_out" == "$tmpfile" && "$stat_fc_err" != *"hint:"* ]]; then
        print_test_result "stat -f -c '%n' outputs file name" "PASS"
    else
        print_test_result "stat -f -c '%n' outputs file name" "FAIL" \
            "Expected '$tmpfile', got '$stat_fc_out' (stderr: '$stat_fc_err')"
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

    # Cleanup
    rm -f "$tmpfile" "$tmplink"
}
