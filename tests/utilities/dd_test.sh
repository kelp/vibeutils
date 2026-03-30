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
    # Bug: our dd zeroes it to 0x00.
    local swab_odd_input="$TEMP_DIR/dd_swab_odd.bin"
    local swab_odd_output="$TEMP_DIR/dd_swab_odd_out.bin"
    printf 'ABC' > "$swab_odd_input"
    "$binary" if="$swab_odd_input" of="$swab_odd_output" conv=swab bs=3 count=1 status=none 2>/dev/null
    # Compare against GNU dd output
    local gnu_swab_output="$TEMP_DIR/dd_swab_odd_gnu.bin"
    printf 'ABC' | /usr/bin/dd conv=swab bs=3 count=1 2>/dev/null > "$gnu_swab_output"
    if cmp -s "$swab_odd_output" "$gnu_swab_output"; then
        print_test_result "dd conv=swab odd-length preserves last byte" "PASS"
    else
        local ours_hex
        ours_hex=$(od -A n -t x1 < "$swab_odd_output" | tr -d ' \n')
        local gnu_hex
        gnu_hex=$(od -A n -t x1 < "$gnu_swab_output" | tr -d ' \n')
        print_test_result "dd conv=swab odd-length preserves last byte" "FAIL" \
            "ours='$ours_hex', GNU='$gnu_hex'"
    fi

    # --- conv=sync+block pads with spaces, not NUL ---
    # GNU dd: when block/unblock is active, sync pads with spaces (0x20).
    # Bug: our dd always pads with NUL (0x00).
    local sync_block_input="$TEMP_DIR/dd_sync_block.txt"
    local sync_block_output="$TEMP_DIR/dd_sync_block_out.bin"
    printf 'AB\n' > "$sync_block_input"
    "$binary" if="$sync_block_input" of="$sync_block_output" \
        conv=sync,block cbs=10 ibs=10 obs=10 status=none 2>/dev/null
    local gnu_sync_block="$TEMP_DIR/dd_sync_block_gnu.bin"
    printf 'AB\n' | /usr/bin/dd conv=sync,block cbs=10 ibs=10 obs=10 2>/dev/null > "$gnu_sync_block"
    if cmp -s "$sync_block_output" "$gnu_sync_block"; then
        print_test_result "dd conv=sync+block pads with spaces" "PASS"
    else
        local ours_hex
        ours_hex=$(od -A n -t x1 < "$sync_block_output" | tr -d '\n')
        local gnu_hex
        gnu_hex=$(od -A n -t x1 < "$gnu_sync_block" | tr -d '\n')
        print_test_result "dd conv=sync+block pads with spaces" "FAIL" \
            "ours='$ours_hex', GNU='$gnu_hex'"
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
    local gnu_ebc_out="$TEMP_DIR/dd_gnu_ebc.bin"
    local gnu_ibm_out="$TEMP_DIR/dd_gnu_ibm.bin"
    printf '^' | /usr/bin/dd conv=ebcdic 2>/dev/null > "$gnu_ebc_out"
    printf '^' | /usr/bin/dd conv=ibm 2>/dev/null > "$gnu_ibm_out"
    local ebc_match=false
    local ibm_match=false
    cmp -s "$ebc_output" "$gnu_ebc_out" && ebc_match=true
    cmp -s "$ibm_output" "$gnu_ibm_out" && ibm_match=true
    if $ebc_match && $ibm_match; then
        print_test_result "dd conv=ibm differs from conv=ebcdic" "PASS"
    else
        local ours_ebc_hex
        ours_ebc_hex=$(od -A n -t x1 < "$ebc_output" | tr -d ' \n')
        local gnu_ebc_hex
        gnu_ebc_hex=$(od -A n -t x1 < "$gnu_ebc_out" | tr -d ' \n')
        local ours_ibm_hex
        ours_ibm_hex=$(od -A n -t x1 < "$ibm_output" | tr -d ' \n')
        local gnu_ibm_hex
        gnu_ibm_hex=$(od -A n -t x1 < "$gnu_ibm_out" | tr -d ' \n')
        print_test_result "dd conv=ibm differs from conv=ebcdic" "FAIL" \
            "ebcdic: ours=$ours_ebc_hex gnu=$gnu_ebc_hex; ibm: ours=$ours_ibm_hex gnu=$gnu_ibm_hex"
    fi

    # --- conv=block+cbs= pads records (behavioral) ---
    local block_input="$TEMP_DIR/dd_block_in.txt"
    local block_output="$TEMP_DIR/dd_block_out.bin"
    printf 'ab\ncd\n' > "$block_input"
    "$binary" if="$block_input" of="$block_output" cbs=5 conv=block status=none 2>/dev/null
    local gnu_block_out="$TEMP_DIR/dd_block_gnu.bin"
    printf 'ab\ncd\n' | /usr/bin/dd cbs=5 conv=block 2>/dev/null > "$gnu_block_out"
    if cmp -s "$block_output" "$gnu_block_out"; then
        print_test_result "dd conv=block+cbs= pads records" "PASS"
    else
        local ours_hex
        ours_hex=$(od -A n -t x1 < "$block_output" | tr -d '\n')
        local gnu_hex
        gnu_hex=$(od -A n -t x1 < "$gnu_block_out" | tr -d '\n')
        print_test_result "dd conv=block+cbs= pads records" "FAIL" \
            "ours='$ours_hex', GNU='$gnu_hex'"
    fi

    # --- conv=unblock+cbs= converts records (behavioral) ---
    local unblock_input="$TEMP_DIR/dd_unblock_in.bin"
    local unblock_output="$TEMP_DIR/dd_unblock_out.txt"
    printf 'ab   cd   ' > "$unblock_input"  # two 5-byte records
    "$binary" if="$unblock_input" of="$unblock_output" cbs=5 conv=unblock status=none 2>/dev/null
    local gnu_unblock_out="$TEMP_DIR/dd_unblock_gnu.txt"
    printf 'ab   cd   ' | /usr/bin/dd cbs=5 conv=unblock 2>/dev/null > "$gnu_unblock_out"
    if cmp -s "$unblock_output" "$gnu_unblock_out"; then
        print_test_result "dd conv=unblock+cbs= converts records" "PASS"
    else
        local ours_content
        ours_content=$(cat "$unblock_output" | od -A n -t x1 | tr -d '\n')
        local gnu_content
        gnu_content=$(cat "$gnu_unblock_out" | od -A n -t x1 | tr -d '\n')
        print_test_result "dd conv=unblock+cbs= converts records" "FAIL" \
            "ours='$ours_content', GNU='$gnu_content'"
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
}
