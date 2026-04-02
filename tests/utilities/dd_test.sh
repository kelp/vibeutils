#!/usr/bin/env bash
# Comprehensive tests for dd utility
# Tests operand parsing, file copy, conversions, and statistics

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_dd() {
    local util="dd"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic copy functionality...${NC}"

    # Basic file-to-file copy
    local input_file=$(create_temp_file "Hello, dd!")
    local output_file="$TEMP_DIR/dd_output1.txt"
    "$binary" if="$input_file" of="$output_file" status=none 2>/dev/null
    local content=$(cat "$output_file")
    if [[ "$content" == "Hello, dd!" ]]; then
        print_test_result "dd basic file copy" "PASS"
    else
        print_test_result "dd basic file copy" "FAIL" "Expected 'Hello, dd!', got '$content'"
    fi

    # Copy with bs= operand
    local input_file2=$(create_temp_file "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    local output_file2="$TEMP_DIR/dd_output2.txt"
    "$binary" if="$input_file2" of="$output_file2" bs=1024 status=none 2>/dev/null
    content=$(cat "$output_file2")
    if [[ "$content" == "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ]]; then
        print_test_result "dd copy with bs=1024" "PASS"
    else
        print_test_result "dd copy with bs=1024" "FAIL" "Got '$content'"
    fi

    echo -e "${CYAN}Testing count operand...${NC}"

    # Copy with count=
    local output_file3="$TEMP_DIR/dd_output3.txt"
    "$binary" if="$input_file2" of="$output_file3" bs=5 count=2 status=none 2>/dev/null
    content=$(cat "$output_file3")
    if [[ "$content" == "ABCDEFGHIJ" ]]; then
        print_test_result "dd count=2 bs=5" "PASS"
    else
        print_test_result "dd count=2 bs=5" "FAIL" "Expected 'ABCDEFGHIJ', got '$content'"
    fi

    # count=0 copies nothing
    local output_file4="$TEMP_DIR/dd_output4.txt"
    "$binary" if="$input_file2" of="$output_file4" count=0 status=none 2>/dev/null
    if [[ ! -s "$output_file4" ]]; then
        print_test_result "dd count=0 copies nothing" "PASS"
    else
        print_test_result "dd count=0 copies nothing" "FAIL" "Output file is not empty"
    fi

    echo -e "${CYAN}Testing skip and seek operands...${NC}"

    # Test skip=
    local skip_input=$(create_temp_file "AAAABBBB")
    local skip_output="$TEMP_DIR/dd_skip.txt"
    "$binary" if="$skip_input" of="$skip_output" bs=4 skip=1 status=none 2>/dev/null
    content=$(cat "$skip_output")
    if [[ "$content" == "BBBB" ]]; then
        print_test_result "dd skip=1 bs=4" "PASS"
    else
        print_test_result "dd skip=1 bs=4" "FAIL" "Expected 'BBBB', got '$content'"
    fi

    # Test seek=
    local seek_output="$TEMP_DIR/dd_seek.txt"
    local seek_input=$(create_temp_file "DATA")
    "$binary" if="$seek_input" of="$seek_output" bs=4 seek=1 conv=notrunc status=none 2>/dev/null
    local seek_size
    seek_size=$(get_file_size "$seek_output")
    if [[ "$seek_size" -eq 8 ]]; then
        print_test_result "dd seek=1 bs=4" "PASS"
    else
        print_test_result "dd seek=1 bs=4" "FAIL" "Expected size 8, got $seek_size"
    fi

    echo -e "${CYAN}Testing conversions...${NC}"

    # Test conv=ucase
    local lcase_input=$(create_temp_file "hello world")
    local ucase_output="$TEMP_DIR/dd_ucase.txt"
    "$binary" if="$lcase_input" of="$ucase_output" conv=ucase status=none 2>/dev/null
    content=$(cat "$ucase_output")
    if [[ "$content" == "HELLO WORLD" ]]; then
        print_test_result "dd conv=ucase" "PASS"
    else
        print_test_result "dd conv=ucase" "FAIL" "Expected 'HELLO WORLD', got '$content'"
    fi

    # Test conv=lcase
    local ucase_input=$(create_temp_file "HELLO WORLD")
    local lcase_output="$TEMP_DIR/dd_lcase.txt"
    "$binary" if="$ucase_input" of="$lcase_output" conv=lcase status=none 2>/dev/null
    content=$(cat "$lcase_output")
    if [[ "$content" == "hello world" ]]; then
        print_test_result "dd conv=lcase" "PASS"
    else
        print_test_result "dd conv=lcase" "FAIL" "Expected 'hello world', got '$content'"
    fi

    echo -e "${CYAN}Testing status levels...${NC}"

    # Test status=none suppresses output
    local status_input=$(create_temp_file "test data")
    local status_output="$TEMP_DIR/dd_status.txt"
    local stderr_output
    stderr_output=$("$binary" if="$status_input" of="$status_output" status=none 2>&1)
    if [[ -z "$stderr_output" ]]; then
        print_test_result "dd status=none" "PASS"
    else
        print_test_result "dd status=none" "FAIL" "Expected no stderr, got '$stderr_output'"
    fi

    # Test default status shows statistics
    local stat_output="$TEMP_DIR/dd_stat.txt"
    stderr_output=$("$binary" if="$status_input" of="$stat_output" 2>&1)
    if echo "$stderr_output" | grep -q "records in"; then
        print_test_result "dd default status shows records" "PASS"
    else
        print_test_result "dd default status shows records" "FAIL" "Expected 'records in' in stderr"
    fi

    # Test status=noxfer
    local noxfer_output="$TEMP_DIR/dd_noxfer.txt"
    stderr_output=$("$binary" if="$status_input" of="$noxfer_output" status=noxfer 2>&1)
    if echo "$stderr_output" | grep -q "records in" && ! echo "$stderr_output" | grep -q "bytes"; then
        print_test_result "dd status=noxfer" "PASS"
    else
        print_test_result "dd status=noxfer" "FAIL" "Unexpected stderr content"
    fi

    echo -e "${CYAN}Testing stdin/stdout...${NC}"

    # Test reading from stdin
    local stdin_result
    stdin_result=$(echo "stdin test" | "$binary" bs=1024 status=none 2>/dev/null)
    if [[ "$stdin_result" == "stdin test" ]]; then
        print_test_result "dd from stdin to stdout" "PASS"
    else
        print_test_result "dd from stdin to stdout" "FAIL" "Expected 'stdin test', got '$stdin_result'"
    fi

    echo -e "${CYAN}Testing error handling...${NC}"

    # Test nonexistent input file
    if "$binary" if=/nonexistent/file of=/dev/null status=none 2>/dev/null; then
        print_test_result "dd nonexistent input" "FAIL" "Should have failed"
    else
        print_test_result "dd nonexistent input" "PASS"
    fi

    # Test invalid operand
    if "$binary" invalid=operand status=none 2>/dev/null; then
        print_test_result "dd invalid operand" "FAIL" "Should have failed"
    else
        print_test_result "dd invalid operand" "PASS"
    fi

    # Test mutually exclusive conversions
    if "$binary" conv=lcase,ucase if=/dev/null of=/dev/null status=none 2>/dev/null; then
        print_test_result "dd lcase+ucase conflict" "FAIL" "Should have failed"
    else
        print_test_result "dd lcase+ucase conflict" "PASS"
    fi

    echo -e "${CYAN}Testing byte size suffixes...${NC}"

    # Test various size suffixes
    local suffix_input=$(create_temp_file "$(printf '%02048d' 0)")
    local suffix_output="$TEMP_DIR/dd_suffix.txt"
    "$binary" if="$suffix_input" of="$suffix_output" bs=1K count=1 status=none 2>/dev/null
    local file_size
    file_size=$(get_file_size "$suffix_output")
    if [[ "$file_size" -eq 1024 ]]; then
        print_test_result "dd bs=1K suffix" "PASS"
    else
        print_test_result "dd bs=1K suffix" "FAIL" "Expected 1024 bytes, got $file_size"
    fi

    echo -e "${CYAN}Testing exit codes...${NC}"

    # Success exit code
    test_command_exit_code "dd success exit code" 0 "$binary" if=/dev/null of=/dev/null status=none

    # Failure exit code for bad input
    test_command_exit_code "dd failure exit code" 1 "$binary" if=/nonexistent/path of=/dev/null status=none 2>/dev/null || true

    # Regression test: basic copy safety net after argsFree change
    echo -e "${CYAN}Testing dd basic copy (argsFree regression)...${NC}"

    local args_input=$(create_temp_file "ABCDE")
    local args_result
    args_result=$("$binary" bs=1 count=5 status=none < "$args_input" 2>/dev/null)
    if [[ "$args_result" == "ABCDE" ]]; then
        print_test_result "dd bs=1 count=5 copies 5 bytes (argsFree safety net)" "PASS"
    else
        print_test_result "dd bs=1 count=5 copies 5 bytes (argsFree safety net)" "FAIL" \
            "Expected 'ABCDE', got '$args_result'"
    fi

    # ==================================================================
    #       AUDIT WAVE 4: FAILING INTEGRATION TESTS
    # ==================================================================

    echo -e "${CYAN}Testing audit findings (IMPORTANT)...${NC}"

    # --- conv=swab even-length ---
    local swab_input="$TEMP_DIR/dd_swab_even.bin"
    local swab_output="$TEMP_DIR/dd_swab_even_out.bin"
    printf 'ABCD' > "$swab_input"
    "$binary" if="$swab_input" of="$swab_output" conv=swab status=none 2>/dev/null
    content=$(cat "$swab_output")
    if [[ "$content" == "BADC" ]]; then
        print_test_result "dd conv=swab even length" "PASS"
    else
        print_test_result "dd conv=swab even length" "FAIL" \
            "Expected 'BADC', got '$content'"
    fi

    # --- conv=swab odd-length preserves last byte ---
    # GNU dd: odd last byte passes through unchanged.
    # "ABC" swabbed = "BA" + "C" preserved = "BAC"
    local swab_odd_input="$TEMP_DIR/dd_swab_odd.bin"
    local swab_odd_output="$TEMP_DIR/dd_swab_odd_out.bin"
    printf 'ABC' > "$swab_odd_input"
    "$binary" if="$swab_odd_input" of="$swab_odd_output" conv=swab bs=3 count=1 status=none 2>/dev/null
    content=$(cat "$swab_odd_output")
    if [[ "$content" == "BAC" ]]; then
        print_test_result "dd conv=swab odd-length preserves last byte" "PASS"
    else
        local ours_hex
        ours_hex=$(od -A n -t x1 < "$swab_odd_output" | tr -d ' \n')
        print_test_result "dd conv=swab odd-length preserves last byte" "FAIL" \
            "Expected 'BAC' (424143), got '$content' ($ours_hex)"
    fi

    # --- conv=sync+block pads with spaces, not NUL ---
    # When block is active, sync pads with spaces (0x20), not NUL (0x00).
    # Input "AB\n" (3 bytes) with ibs=10: sync-padded to 10 bytes with spaces.
    # Block conversion then processes: "AB\n" + 7 spaces.
    # Key check: the output must contain NO NUL bytes.
    local sync_block_input="$TEMP_DIR/dd_sync_block.txt"
    local sync_block_output="$TEMP_DIR/dd_sync_block_out.bin"
    printf 'AB\n' > "$sync_block_input"
    "$binary" if="$sync_block_input" of="$sync_block_output" \
        conv=sync,block cbs=10 ibs=10 obs=10 status=none 2>/dev/null
    # Must NOT contain any NUL bytes (sync should pad with spaces, not NUL)
    local sync_block_size
    sync_block_size=$(get_file_size "$sync_block_output")
    local has_nul=false
    if od -A n -t x1 < "$sync_block_output" | tr -d ' \n' | grep -q '00'; then
        has_nul=true
    fi
    if [[ "$sync_block_size" -gt 0 ]] && ! $has_nul; then
        print_test_result "dd conv=sync+block pads with spaces" "PASS"
    else
        local ours_hex
        ours_hex=$(od -A n -t x1 < "$sync_block_output" | tr -d '\n')
        print_test_result "dd conv=sync+block pads with spaces" "FAIL" \
            "Expected non-empty output with no NULs, got $sync_block_size bytes: '$ours_hex'"
    fi

    # --- conv=notrunc preserves existing file data ---
    # Write a large file, then overwrite with smaller data using notrunc.
    # The tail bytes of the original file must be preserved.
    local notrunc_file="$TEMP_DIR/dd_notrunc.bin"
    printf 'XXXXXXXXXXXXXXXXXXXX' > "$notrunc_file"  # 20 bytes of X
    local notrunc_input="$TEMP_DIR/dd_notrunc_in.txt"
    printf 'HELLO' > "$notrunc_input"
    "$binary" if="$notrunc_input" of="$notrunc_file" conv=notrunc status=none 2>/dev/null
    local notrunc_size
    notrunc_size=$(get_file_size "$notrunc_file")
    local notrunc_content
    notrunc_content=$(cat "$notrunc_file")
    if [[ "$notrunc_size" -eq 20 ]] && [[ "$notrunc_content" == "HELLOXXXXXXXXXXXXXXX" ]]; then
        print_test_result "dd conv=notrunc preserves existing data" "PASS"
    else
        print_test_result "dd conv=notrunc preserves existing data" "FAIL" \
            "Expected 20 bytes 'HELLOXXXXXXXXXXXXXXX', got $notrunc_size bytes '$notrunc_content'"
    fi

    # --- conv=ascii/ebcdic roundtrip ---
    # Convert ASCII->EBCDIC->ASCII; result must match original.
    local rt_input="$TEMP_DIR/dd_roundtrip_in.txt"
    local rt_ebcdic="$TEMP_DIR/dd_roundtrip_ebc.bin"
    local rt_output="$TEMP_DIR/dd_roundtrip_out.txt"
    printf 'Hello World 123 !@#' > "$rt_input"
    "$binary" if="$rt_input" of="$rt_ebcdic" conv=ebcdic status=none 2>/dev/null
    "$binary" if="$rt_ebcdic" of="$rt_output" conv=ascii status=none 2>/dev/null
    local rt_content
    rt_content=$(cat "$rt_output")
    if [[ "$rt_content" == "Hello World 123 !@#" ]]; then
        print_test_result "dd conv=ascii/ebcdic roundtrip" "PASS"
    else
        print_test_result "dd conv=ascii/ebcdic roundtrip" "FAIL" \
            "Expected 'Hello World 123 !@#', got '$rt_content'"
    fi

    # --- conv=ibm differs from conv=ebcdic ---
    # '^' (0x5E) maps differently: ebcdic->0x9A, ibm->0x5F in GNU dd.
    local ibm_input="$TEMP_DIR/dd_ibm_in.bin"
    local ibm_output="$TEMP_DIR/dd_ibm_out.bin"
    local ebc_output="$TEMP_DIR/dd_ebc_out.bin"
    printf '^' > "$ibm_input"
    "$binary" if="$ibm_input" of="$ebc_output" conv=ebcdic status=none 2>/dev/null
    "$binary" if="$ibm_input" of="$ibm_output" conv=ibm status=none 2>/dev/null
    local ours_ebc_hex
    ours_ebc_hex=$(od -A n -t x1 < "$ebc_output" | tr -d ' \n')
    local ours_ibm_hex
    ours_ibm_hex=$(od -A n -t x1 < "$ibm_output" | tr -d ' \n')
    # GNU dd maps '^' (0x5E): ebcdic->0x9a, ibm->0x5f
    if [[ "$ours_ebc_hex" == "9a" ]] && [[ "$ours_ibm_hex" == "5f" ]]; then
        print_test_result "dd conv=ibm differs from conv=ebcdic" "PASS"
    else
        print_test_result "dd conv=ibm differs from conv=ebcdic" "FAIL" \
            "Expected ebcdic=9a ibm=5f, got ebcdic=$ours_ebc_hex ibm=$ours_ibm_hex"
    fi

    # --- conv=block+cbs= pads records (behavioral) ---
    # Input "ab\ncd\n" with cbs=5: two newline-terminated records
    # Record 1: "ab" padded to 5 bytes = "ab   " (0x61 0x62 0x20 0x20 0x20)
    # Record 2: "cd" padded to 5 bytes = "cd   " (0x63 0x64 0x20 0x20 0x20)
    # Output should be exactly 10 bytes.
    local block_input="$TEMP_DIR/dd_block_in.txt"
    local block_output="$TEMP_DIR/dd_block_out.bin"
    printf 'ab\ncd\n' > "$block_input"
    "$binary" if="$block_input" of="$block_output" cbs=5 conv=block status=none 2>/dev/null
    local ours_hex
    ours_hex=$(od -A n -t x1 < "$block_output" | tr -d ' \n')
    local expected_hex="61622020206364202020"
    # GNU dd may emit a trailing newline record; check first 10 bytes match
    local block_size
    block_size=$(get_file_size "$block_output")
    if [[ "$ours_hex" == "$expected_hex" ]] && [[ "$block_size" -eq 10 ]]; then
        print_test_result "dd conv=block+cbs= pads records" "PASS"
    else
        print_test_result "dd conv=block+cbs= pads records" "FAIL" \
            "Expected 10 bytes hex=$expected_hex, got $block_size bytes hex=$ours_hex"
    fi

    # --- conv=unblock+cbs= converts records (behavioral) ---
    # Input: "ab   cd   " (two 5-byte fixed records)
    # Unblock strips trailing spaces and appends newline:
    # Record 1: "ab   " -> "ab\n"
    # Record 2: "cd   " -> "cd\n"
    # Expected output: "ab\ncd\n" (6 bytes: 0x61 0x62 0x0a 0x63 0x64 0x0a)
    local unblock_input="$TEMP_DIR/dd_unblock_in.bin"
    local unblock_output="$TEMP_DIR/dd_unblock_out.txt"
    printf 'ab   cd   ' > "$unblock_input"  # two 5-byte records
    "$binary" if="$unblock_input" of="$unblock_output" cbs=5 conv=unblock status=none 2>/dev/null
    local ours_hex
    ours_hex=$(od -A n -t x1 < "$unblock_output" | tr -d ' \n')
    local expected_hex="61620a63640a"
    if [[ "$ours_hex" == "$expected_hex" ]]; then
        print_test_result "dd conv=unblock+cbs= converts records" "PASS"
    else
        print_test_result "dd conv=unblock+cbs= converts records" "FAIL" \
            "Expected hex=$expected_hex, got hex=$ours_hex"
    fi

    # --- ibs=/obs= separate path ---
    # Use different ibs and obs values; output must match input.
    local ibs_obs_input="$TEMP_DIR/dd_ibsobs_in.txt"
    local ibs_obs_output="$TEMP_DIR/dd_ibsobs_out.txt"
    printf 'ABCDEFGHIJKLMNOP' > "$ibs_obs_input"
    "$binary" if="$ibs_obs_input" of="$ibs_obs_output" ibs=3 obs=7 status=none 2>/dev/null
    content=$(cat "$ibs_obs_output")
    if [[ "$content" == "ABCDEFGHIJKLMNOP" ]]; then
        print_test_result "dd ibs/obs separate path preserves data" "PASS"
    else
        print_test_result "dd ibs/obs separate path preserves data" "FAIL" \
            "Expected 'ABCDEFGHIJKLMNOP', got '$content'"
    fi

    # ==================================================================
    #       ADDITIONAL MUST-TIER conv= INTEGRATION TESTS
    # ==================================================================

    echo -e "${CYAN}Testing additional MUST-tier conv= values...${NC}"

    # --- conv=sync pads short input block to ibs with NUL ---
    # Input "AB" (2 bytes) with bs=4 conv=sync: padded to 4 bytes with NUL.
    # Expected: 0x41 0x42 0x00 0x00
    local sync_input="$TEMP_DIR/dd_sync_in.bin"
    local sync_output="$TEMP_DIR/dd_sync_out.bin"
    printf 'AB' > "$sync_input"
    "$binary" if="$sync_input" of="$sync_output" bs=4 conv=sync count=1 status=none 2>/dev/null
    local sync_hex
    sync_hex=$(od -A n -t x1 < "$sync_output" | tr -d ' \n')
    if [[ "$sync_hex" == "41420000" ]]; then
        print_test_result "dd conv=sync pads short block with NUL" "PASS"
    else
        print_test_result "dd conv=sync pads short block with NUL" "FAIL" \
            "Expected hex=41420000, got hex=$sync_hex"
    fi

    # --- conv=sync with full block does not pad ---
    # Input "ABCD" (4 bytes) with bs=4 conv=sync: no padding needed.
    local sync_full_input="$TEMP_DIR/dd_sync_full_in.bin"
    local sync_full_output="$TEMP_DIR/dd_sync_full_out.bin"
    printf 'ABCD' > "$sync_full_input"
    "$binary" if="$sync_full_input" of="$sync_full_output" bs=4 conv=sync count=1 status=none 2>/dev/null
    content=$(cat "$sync_full_output")
    if [[ "$content" == "ABCD" ]]; then
        print_test_result "dd conv=sync full block unchanged" "PASS"
    else
        print_test_result "dd conv=sync full block unchanged" "FAIL" \
            "Expected 'ABCD', got '$content'"
    fi

    # --- conv=notrunc does not truncate larger existing file ---
    # Already tested above; this tests the default (without notrunc) DOES truncate.
    local trunc_file="$TEMP_DIR/dd_trunc.bin"
    printf 'XXXXXXXXXXXXXXXXXXXX' > "$trunc_file"  # 20 bytes of X
    local trunc_input="$TEMP_DIR/dd_trunc_in.txt"
    printf 'HI' > "$trunc_input"
    "$binary" if="$trunc_input" of="$trunc_file" status=none 2>/dev/null
    local trunc_size
    trunc_size=$(get_file_size "$trunc_file")
    if [[ "$trunc_size" -eq 2 ]]; then
        print_test_result "dd default truncates output file" "PASS"
    else
        print_test_result "dd default truncates output file" "FAIL" \
            "Expected 2 bytes after truncation, got $trunc_size"
    fi

    # --- conv=fsync does not error ---
    # conv=fsync should flush to disk; verify it completes without error.
    local fsync_input="$TEMP_DIR/dd_fsync_in.txt"
    local fsync_output="$TEMP_DIR/dd_fsync_out.txt"
    printf 'fsync test data' > "$fsync_input"
    if "$binary" if="$fsync_input" of="$fsync_output" conv=fsync status=none 2>/dev/null; then
        content=$(cat "$fsync_output")
        if [[ "$content" == "fsync test data" ]]; then
            print_test_result "dd conv=fsync completes and preserves data" "PASS"
        else
            print_test_result "dd conv=fsync completes and preserves data" "FAIL" \
                "Expected 'fsync test data', got '$content'"
        fi
    else
        print_test_result "dd conv=fsync completes and preserves data" "FAIL" \
            "Command exited with non-zero status"
    fi

    # --- conv=osync pads final output block ---
    # Input "AB" (2 bytes), ibs=2 obs=4 conv=osync: final block padded to obs size.
    # Expected: 4 bytes (0x41 0x42 0x00 0x00)
    local osync_input="$TEMP_DIR/dd_osync_in.bin"
    local osync_output="$TEMP_DIR/dd_osync_out.bin"
    printf 'AB' > "$osync_input"
    "$binary" if="$osync_input" of="$osync_output" ibs=2 obs=4 conv=osync status=none 2>/dev/null
    local osync_size
    osync_size=$(get_file_size "$osync_output")
    local osync_hex
    osync_hex=$(od -A n -t x1 < "$osync_output" | tr -d ' \n')
    if [[ "$osync_size" -eq 4 ]] && [[ "$osync_hex" == "41420000" ]]; then
        print_test_result "dd conv=osync pads final output block" "PASS"
    else
        print_test_result "dd conv=osync pads final output block" "FAIL" \
            "Expected 4 bytes hex=41420000, got $osync_size bytes hex=$osync_hex"
    fi

    # --- conv=ascii converts EBCDIC to ASCII (standalone) ---
    # EBCDIC 0xC1 = ASCII 'A' (0x41), verify single byte.
    local ascii_input="$TEMP_DIR/dd_ascii_in.bin"
    local ascii_output="$TEMP_DIR/dd_ascii_out.bin"
    printf '\xC1' > "$ascii_input"
    "$binary" if="$ascii_input" of="$ascii_output" conv=ascii status=none 2>/dev/null
    content=$(cat "$ascii_output")
    if [[ "$content" == "A" ]]; then
        print_test_result "dd conv=ascii converts EBCDIC to ASCII" "PASS"
    else
        local ascii_hex
        ascii_hex=$(od -A n -t x1 < "$ascii_output" | tr -d ' \n')
        print_test_result "dd conv=ascii converts EBCDIC to ASCII" "FAIL" \
            "Expected 'A' (0x41), got hex=$ascii_hex"
    fi

    # --- conv=ebcdic converts ASCII to EBCDIC (standalone) ---
    # ASCII 'A' (0x41) -> EBCDIC 0xC1
    local ebcdic_input="$TEMP_DIR/dd_ebcdic_in.bin"
    local ebcdic_output="$TEMP_DIR/dd_ebcdic_out.bin"
    printf 'A' > "$ebcdic_input"
    "$binary" if="$ebcdic_input" of="$ebcdic_output" conv=ebcdic status=none 2>/dev/null
    local ebcdic_hex
    ebcdic_hex=$(od -A n -t x1 < "$ebcdic_output" | tr -d ' \n')
    if [[ "$ebcdic_hex" == "c1" ]]; then
        print_test_result "dd conv=ebcdic converts ASCII to EBCDIC" "PASS"
    else
        print_test_result "dd conv=ebcdic converts ASCII to EBCDIC" "FAIL" \
            "Expected hex=c1, got hex=$ebcdic_hex"
    fi

    # --- conv=ibm converts ASCII to IBM EBCDIC (standalone) ---
    # ASCII '~' (0x7E) -> IBM EBCDIC: 0xA1 (differs from standard ebcdic 0x5F at caret)
    # Use '!' (0x21) which maps to 0x5A in both tables
    local ibm_solo_input="$TEMP_DIR/dd_ibm_solo_in.bin"
    local ibm_solo_output="$TEMP_DIR/dd_ibm_solo_out.bin"
    printf '!' > "$ibm_solo_input"
    "$binary" if="$ibm_solo_input" of="$ibm_solo_output" conv=ibm status=none 2>/dev/null
    local ibm_solo_hex
    ibm_solo_hex=$(od -A n -t x1 < "$ibm_solo_output" | tr -d ' \n')
    if [[ "$ibm_solo_hex" == "5a" ]]; then
        print_test_result "dd conv=ibm converts ASCII to IBM EBCDIC" "PASS"
    else
        print_test_result "dd conv=ibm converts ASCII to IBM EBCDIC" "FAIL" \
            "Expected hex=5a, got hex=$ibm_solo_hex"
    fi

    # --- conv=noerror continues after read error ---
    # Use /dev/null as input (EOF, no error), just verify noerror is accepted.
    test_command_exit_code "dd conv=noerror accepted" 0 \
        "$binary" if=/dev/null of=/dev/null conv=noerror status=none
}
