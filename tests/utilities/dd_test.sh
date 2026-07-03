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

    # #63: GNU dd quotes the failing operand: "failed to open 'PATH': MESSAGE"
    local open_err_stderr
    open_err_stderr=$("$binary" if=/nonexistent/file of=/dev/null status=none 2>&1 >/dev/null)
    if [[ "$open_err_stderr" == *"failed to open '/nonexistent/file': "* ]]; then
        print_test_result "dd quotes failing operand (#63)" "PASS"
    else
        print_test_result "dd quotes failing operand (#63)" "FAIL" \
            "Expected \"failed to open '/nonexistent/file': ...\", got: '$open_err_stderr'"
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

    # Issue #43: count= must accept the same suffixes bs= does. This is
    # the exact command from the issue: bs=512 count=1k -> 512*1024 bytes.
    local count_suffix_output="$TEMP_DIR/dd_count_suffix.txt"
    "$binary" if=/dev/zero of="$count_suffix_output" bs=512 count=1k status=none 2>/dev/null
    local count_suffix_size
    count_suffix_size=$(get_file_size "$count_suffix_output")
    if [[ "$count_suffix_size" -eq 524288 ]]; then
        print_test_result "dd count=1k suffix" "PASS"
    else
        print_test_result "dd count=1k suffix" "FAIL" \
            "Expected 524288 bytes, got $count_suffix_size"
    fi

    # Issue #43: skip= suffix seeks the input by the suffixed block count.
    # Build a >1KiB input where byte at offset 1024 is known, copy 1 byte.
    local skip_suffix_input="$TEMP_DIR/dd_skip_suffix_in.txt"
    printf '%01024d' 0 > "$skip_suffix_input"
    printf 'Z' >> "$skip_suffix_input"
    local skip_suffix_output="$TEMP_DIR/dd_skip_suffix_out.txt"
    "$binary" if="$skip_suffix_input" of="$skip_suffix_output" \
        bs=1 skip=1k count=1 status=none 2>/dev/null
    local skip_suffix_content
    skip_suffix_content=$(cat "$skip_suffix_output")
    if [[ "$skip_suffix_content" == "Z" ]]; then
        print_test_result "dd skip=1k suffix" "PASS"
    else
        print_test_result "dd skip=1k suffix" "FAIL" \
            "Expected 'Z', got '$skip_suffix_content'"
    fi

    echo -e "${CYAN}Testing conv=fdatasync...${NC}"

    # Issue #43: conv=fdatasync flushes data before exit and copies
    # normally. Exact second command from the issue.
    local fdatasync_input=$(create_temp_file "fdatasync payload")
    local fdatasync_output="$TEMP_DIR/dd_fdatasync.txt"
    "$binary" if="$fdatasync_input" of="$fdatasync_output" \
        conv=fdatasync status=none 2>/dev/null
    local fdatasync_rc=$?
    local fdatasync_content
    fdatasync_content=$(cat "$fdatasync_output")
    if [[ "$fdatasync_rc" -eq 0 && "$fdatasync_content" == "fdatasync payload" ]]; then
        print_test_result "dd conv=fdatasync" "PASS"
    else
        print_test_result "dd conv=fdatasync" "FAIL" \
            "rc=$fdatasync_rc content='$fdatasync_content'"
    fi

    # conv=fdatasync,fsync combo: both syncs coexist, data intact.
    local fdcombo_input=$(create_temp_file "combo payload")
    local fdcombo_output="$TEMP_DIR/dd_fdcombo.txt"
    "$binary" if="$fdcombo_input" of="$fdcombo_output" \
        conv=fdatasync,fsync status=none 2>/dev/null
    local fdcombo_rc=$?
    local fdcombo_content
    fdcombo_content=$(cat "$fdcombo_output")
    if [[ "$fdcombo_rc" -eq 0 && "$fdcombo_content" == "combo payload" ]]; then
        print_test_result "dd conv=fdatasync,fsync" "PASS"
    else
        print_test_result "dd conv=fdatasync,fsync" "FAIL" \
            "rc=$fdcombo_rc content='$fdcombo_content'"
    fi

    echo -e "${CYAN}Testing conv=fdatasync on a pipe (issue #43, round 2)...${NC}"

    # Adversarial regression: conv=fdatasync with a pipe as the output must
    # NEVER abort the process. fdatasync(2) on a pipe returns EINVAL, and
    # the Zig std marks that errno path unreachable, so the naive
    # implementation panics (SIGABRT, rc=134). GNU coreutils 9.7 instead
    # falls back and prints "dd: fsync failed for 'standard output':
    # Invalid argument" and exits 1 (verified against GNU dd 9.7 on this
    # host). Contract: rc is 0 or 1 (never >=128, never a signal), and any
    # nonzero exit carries a sync-failure diagnostic on stderr with no
    # "panic" text. On Linux fsync/fdatasync on a pipe fails EINVAL, so the
    # pinned expectation is rc=1 plus a diagnostic.
    local fdatasync_pipe_err="$TEMP_DIR/dd_fdatasync_pipe.err"
    "$binary" if=/dev/zero count=1 conv=fdatasync status=none \
        2>"$fdatasync_pipe_err" | cat >/dev/null
    local fdatasync_pipe_rc=${PIPESTATUS[0]}
    local fdatasync_pipe_err_text
    fdatasync_pipe_err_text=$(cat "$fdatasync_pipe_err")
    if [[ "$fdatasync_pipe_rc" -eq 1 ]] \
        && ! grep -qi 'panic' "$fdatasync_pipe_err" \
        && grep -qi 'sync' "$fdatasync_pipe_err" \
        && grep -qiE 'fail|invalid' "$fdatasync_pipe_err"; then
        print_test_result "dd conv=fdatasync on pipe does not panic" "PASS"
    else
        print_test_result "dd conv=fdatasync on pipe does not panic" "FAIL" \
            "rc=$fdatasync_pipe_rc (expected 1, never >=128) stderr='$fdatasync_pipe_err_text'"
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
    # GNU dd: 'ABC' (0x41 0x42 0x43) conv=swab → 0x42 0x41 0x43.
    # Reference verified on GNU coreutils 9.5 Linux; hardcoded because
    # BSD dd on macOS does not implement conv=swab the same way.
    local swab_odd_input="$TEMP_DIR/dd_swab_odd.bin"
    local swab_odd_output="$TEMP_DIR/dd_swab_odd_out.bin"
    printf 'ABC' > "$swab_odd_input"
    "$binary" if="$swab_odd_input" of="$swab_odd_output" conv=swab bs=3 count=1 status=none 2>/dev/null
    local ours_swab_hex
    ours_swab_hex=$(od -A n -t x1 < "$swab_odd_output" | tr -d ' \n')
    if [[ "$ours_swab_hex" == "424143" ]]; then
        print_test_result "dd conv=swab odd-length preserves last byte" "PASS"
    else
        print_test_result "dd conv=swab odd-length preserves last byte" "FAIL" \
            "expected 424143, got '$ours_swab_hex'"
    fi

    # --- conv=sync+block pads with spaces, not NUL ---
    # GNU dd: when block/unblock is active, sync pads with spaces (0x20).
    # Bug: our dd always pads with NUL (0x00).
    # 'AB\n' conv=sync,block cbs=10 → "AB" + 18 space bytes (record padded
    # to 10 with spaces because block is active, then sync pads the output
    # to a full obs=10 block with another 10 spaces). Verified on Linux.
    local sync_block_input="$TEMP_DIR/dd_sync_block.txt"
    local sync_block_output="$TEMP_DIR/dd_sync_block_out.bin"
    printf 'AB\n' > "$sync_block_input"
    "$binary" if="$sync_block_input" of="$sync_block_output" \
        conv=sync,block cbs=10 ibs=10 obs=10 status=none 2>/dev/null
    local ours_sync_hex
    ours_sync_hex=$(od -A n -t x1 < "$sync_block_output" | tr -d ' \n')
    if [[ "$ours_sync_hex" == "4142202020202020202020202020202020202020" ]]; then
        print_test_result "dd conv=sync+block pads with spaces" "PASS"
    else
        print_test_result "dd conv=sync+block pads with spaces" "FAIL" \
            "expected 4142 + 18x20, got '$ours_sync_hex'"
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
    # '^' (0x5E) maps to 0x9A under ebcdic, 0x5F under ibm in GNU dd.
    # Reference verified on GNU coreutils 9.5 Linux.
    local ibm_input="$TEMP_DIR/dd_ibm_in.bin"
    local ibm_output="$TEMP_DIR/dd_ibm_out.bin"
    local ebc_output="$TEMP_DIR/dd_ebc_out.bin"
    printf '^' > "$ibm_input"
    "$binary" if="$ibm_input" of="$ebc_output" conv=ebcdic status=none 2>/dev/null
    "$binary" if="$ibm_input" of="$ibm_output" conv=ibm status=none 2>/dev/null
    local ours_ebc_hex ours_ibm_hex
    ours_ebc_hex=$(od -A n -t x1 < "$ebc_output" | tr -d ' \n')
    ours_ibm_hex=$(od -A n -t x1 < "$ibm_output" | tr -d ' \n')
    if [[ "$ours_ebc_hex" == "9a" && "$ours_ibm_hex" == "5f" ]]; then
        print_test_result "dd conv=ibm differs from conv=ebcdic" "PASS"
    else
        print_test_result "dd conv=ibm differs from conv=ebcdic" "FAIL" \
            "expected ebcdic=9a ibm=5f, got ebcdic=$ours_ebc_hex ibm=$ours_ibm_hex"
    fi

    # --- conv=block+cbs= pads records (behavioral) ---
    # 'ab\ncd\n' cbs=5 conv=block → two 5-byte records padded with spaces:
    # "ab   cd   " = 61 62 20 20 20 63 64 20 20 20.
    # Reference verified on GNU coreutils 9.5 Linux.
    local block_input="$TEMP_DIR/dd_block_in.txt"
    local block_output="$TEMP_DIR/dd_block_out.bin"
    printf 'ab\ncd\n' > "$block_input"
    "$binary" if="$block_input" of="$block_output" cbs=5 conv=block status=none 2>/dev/null
    local ours_block_hex
    ours_block_hex=$(od -A n -t x1 < "$block_output" | tr -d ' \n')
    if [[ "$ours_block_hex" == "61622020206364202020" ]]; then
        print_test_result "dd conv=block+cbs= pads records" "PASS"
    else
        print_test_result "dd conv=block+cbs= pads records" "FAIL" \
            "expected 61622020206364202020, got '$ours_block_hex'"
    fi

    # --- conv=unblock+cbs= converts records (behavioral) ---
    # 'ab   cd   ' cbs=5 conv=unblock → strip trailing spaces per record,
    # append \n → "ab\ncd\n" = 61 62 0a 63 64 0a.
    # Reference verified on GNU coreutils 9.5 Linux.
    local unblock_input="$TEMP_DIR/dd_unblock_in.bin"
    local unblock_output="$TEMP_DIR/dd_unblock_out.txt"
    printf 'ab   cd   ' > "$unblock_input"  # two 5-byte records
    "$binary" if="$unblock_input" of="$unblock_output" cbs=5 conv=unblock status=none 2>/dev/null
    local ours_unblock_hex
    ours_unblock_hex=$(od -A n -t x1 < "$unblock_output" | tr -d ' \n')
    if [[ "$ours_unblock_hex" == "61620a63640a" ]]; then
        print_test_result "dd conv=unblock+cbs= converts records" "PASS"
    else
        print_test_result "dd conv=unblock+cbs= converts records" "FAIL" \
            "expected 61620a63640a, got '$ours_unblock_hex'"
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
    #   ISSUE #44: conv=noerror must not spin on a persistent read error
    # ==================================================================
    # A directory fd yields a persistent, non-progressing read error
    # (EISDIR on Linux, ENOTSUP/EISDIR on macOS BSD read(2)) with zero
    # bytes ever consumed -- a portable stand-in for a device whose read
    # keeps failing without advancing. With conv=noerror the old copy
    # loop returned .continue_loop and re-issued the same read from the
    # same position forever, never incrementing blocks_read, so even
    # count= could not bound it. dd must terminate promptly instead of
    # spinning. We bound the run at 5s via run_with_limit (portable to
    # macOS CI, which lacks GNU timeout(1)); exit 124 is the timeout
    # sentinel, so a passing dd must exit with anything but 124.
    echo -e "${CYAN}Testing conv=noerror read-error termination (issue #44)...${NC}"

    local noerror_baddir="$TEMP_DIR/dd_noerror_baddir"
    mkdir -p "$noerror_baddir"

    # Primary case: conv=noerror WITHOUT sync. This spins forever at HEAD
    # (blocks_read never increments, so count=5 cannot bound the loop).
    local noerror_err="$TEMP_DIR/dd_noerror_err.txt"
    run_with_limit 5 "$binary" if="$noerror_baddir" of=/dev/null \
        conv=noerror bs=512 count=5 status=none 2>"$noerror_err"
    local noerror_rc=$?
    local noerror_lines
    noerror_lines=$(grep -c "read error" "$noerror_err" 2>/dev/null || true)
    if [[ "$noerror_rc" -ne 124 ]] && [[ "$noerror_lines" -le 10 ]]; then
        print_test_result "dd conv=noerror terminates on persistent read error" "PASS"
    else
        print_test_result "dd conv=noerror terminates on persistent read error" "FAIL" \
            "expected non-124 exit and <=10 read-error lines, got rc=$noerror_rc lines=$noerror_lines"
    fi

    # Secondary case: conv=noerror,sync with count=5 must also terminate
    # promptly and emit a bounded number of read-error lines. This
    # distinguishes the count= budget bounding the loop from the
    # spin-forever path above.
    local noerror_sync_err="$TEMP_DIR/dd_noerror_sync_err.txt"
    run_with_limit 5 "$binary" if="$noerror_baddir" of=/dev/null \
        conv=noerror,sync bs=512 count=5 status=none 2>"$noerror_sync_err"
    local noerror_sync_rc=$?
    local noerror_sync_lines
    noerror_sync_lines=$(grep -c "read error" "$noerror_sync_err" 2>/dev/null || true)
    if [[ "$noerror_sync_rc" -ne 124 ]] && [[ "$noerror_sync_lines" -le 10 ]]; then
        print_test_result "dd conv=noerror,sync count= bounds read-error retries" "PASS"
    else
        print_test_result "dd conv=noerror,sync count= bounds read-error retries" "FAIL" \
            "expected non-124 exit and <=10 read-error lines, got rc=$noerror_sync_rc lines=$noerror_sync_lines"
    fi

    # ==================================================================
    #   ISSUE #59: conv=noerror,sync error-synthesized block accounting
    # ==================================================================
    # A directory fd yields a persistent read error with zero bytes ever
    # consumed. With conv=noerror,sync, dd synthesizes a NUL-padded block
    # per failed read. GNU dd 9.5 counts each synthesized input block as a
    # PARTIAL record in and each padded write as a FULL record out; pinned
    # for count=5 the final stats block is "0+5 records in" / "5+0 records
    # out". The buggy code counted the synthesized block as a FULL record
    # in, printing "5+0 records in". We omit status=none so the final stats
    # block reaches stderr, then assert the LAST records-in/out lines (only
    # one stats block is emitted; unlike GNU we do not print a block per
    # attempt) match the pinned GNU output exactly.
    echo -e "${CYAN}Testing conv=noerror,sync record accounting (issue #59)...${NC}"

    local acct_err="$TEMP_DIR/dd_noerror_sync_acct.txt"
    run_with_limit 5 "$binary" if="$noerror_baddir" of=/dev/null \
        conv=noerror,sync bs=512 count=5 2>"$acct_err"
    local acct_rc=$?
    local acct_in acct_out
    acct_in=$(grep "records in" "$acct_err" 2>/dev/null | tail -1)
    acct_out=$(grep "records out" "$acct_err" 2>/dev/null | tail -1)
    if [[ "$acct_rc" -ne 124 ]] \
        && [[ "$acct_in" == "0+5 records in" ]] \
        && [[ "$acct_out" == "5+0 records out" ]]; then
        print_test_result "dd conv=noerror,sync counts synthesized blocks as partial in" "PASS"
    else
        print_test_result "dd conv=noerror,sync counts synthesized blocks as partial in" "FAIL" \
            "expected '0+5 records in'/'5+0 records out', got rc=$acct_rc in='$acct_in' out='$acct_out'"
    fi

    # Guard the non-error path: a genuine short read with conv=sync (3 bytes
    # piped in, bs=512, no read error) must still report "0+1 records in" /
    # "1+0 records out" per pinned GNU output. This ensures the issue #59
    # fix does not disturb normal conv=sync accounting.
    local sync_err="$TEMP_DIR/dd_sync_partial.txt"
    printf 'abc' | run_with_limit 5 "$binary" of=/dev/null conv=sync bs=512 2>"$sync_err"
    local sync_rc=$?
    local sync_in sync_out
    sync_in=$(grep "records in" "$sync_err" 2>/dev/null | tail -1)
    sync_out=$(grep "records out" "$sync_err" 2>/dev/null | tail -1)
    if [[ "$sync_rc" -ne 124 ]] \
        && [[ "$sync_in" == "0+1 records in" ]] \
        && [[ "$sync_out" == "1+0 records out" ]]; then
        print_test_result "dd conv=sync partial read accounting unchanged" "PASS"
    else
        print_test_result "dd conv=sync partial read accounting unchanged" "FAIL" \
            "expected '0+1 records in'/'1+0 records out', got rc=$sync_rc in='$sync_in' out='$sync_out'"
    fi

    # ==================================================================
    #   ISSUE #65: multi-character/byte suffixes (kB, B, KiB) and
    #   ISSUE #64: named "invalid number" parse-error messages.
    # ==================================================================
    # All values below are pinned against GNU coreutils 9.5 on Linux
    # (orb -m ubuntu). A trailing 'B' on count=/skip=/seek= means the
    # number is an EXACT BYTE count, independent of bs=; suffixes with
    # no trailing 'B' stay pure block-count multipliers (issue #43
    # semantics, unchanged).
    echo -e "${CYAN}Testing issue #65: byte-suffix semantics and issue #64 messages...${NC}"

    local b65_count_input="$TEMP_DIR/dd65_count_in.bin"
    head -c 4000 /dev/zero | tr '\0' 'x' > "$b65_count_input"

    # count= with a trailing-B suffix is an EXACT BYTE count.
    local b65_count_output="$TEMP_DIR/dd65_count_out.bin"
    "$binary" if="$b65_count_input" of="$b65_count_output" bs=512 count=1kB status=none 2>/dev/null
    local b65_count_size
    b65_count_size=$(get_file_size "$b65_count_output")
    if [[ "$b65_count_size" -eq 1000 ]]; then
        print_test_result "dd count=1kB is byte-exact" "PASS"
    else
        print_test_result "dd count=1kB is byte-exact" "FAIL" \
            "Expected 1000 bytes, got $b65_count_size"
    fi

    local b65_countb_output="$TEMP_DIR/dd65_countb_out.bin"
    "$binary" if="$b65_count_input" of="$b65_countb_output" bs=512 count=1B status=none 2>/dev/null
    local b65_countb_size
    b65_countb_size=$(get_file_size "$b65_countb_output")
    if [[ "$b65_countb_size" -eq 1 ]]; then
        print_test_result "dd count=1B copies exactly 1 byte" "PASS"
    else
        print_test_result "dd count=1B copies exactly 1 byte" "FAIL" \
            "Expected 1 byte, got $b65_countb_size"
    fi

    local b65_countkib_output="$TEMP_DIR/dd65_countkib_out.bin"
    "$binary" if="$b65_count_input" of="$b65_countkib_output" bs=512 count=1KiB status=none 2>/dev/null
    local b65_countkib_size
    b65_countkib_size=$(get_file_size "$b65_countkib_output")
    if [[ "$b65_countkib_size" -eq 1024 ]]; then
        print_test_result "dd count=1KiB copies exactly 1024 bytes" "PASS"
    else
        print_test_result "dd count=1KiB copies exactly 1024 bytes" "FAIL" \
            "Expected 1024 bytes, got $b65_countkib_size"
    fi

    # count=2b (no trailing B) stays a block-count multiplier: N=1024
    # blocks at bs=512 exceeds the 4000-byte input, so the WHOLE file
    # is copied (EOF-truncated), not 1024 bytes. Regression guard for
    # issue #43 -- expected to PASS both before and after the fix.
    local b65_count2b_output="$TEMP_DIR/dd65_count2b_out.bin"
    "$binary" if="$b65_count_input" of="$b65_count2b_output" bs=512 count=2b status=none 2>/dev/null
    local b65_count2b_size
    b65_count2b_size=$(get_file_size "$b65_count2b_output")
    if [[ "$b65_count2b_size" -eq 4000 ]]; then
        print_test_result "dd count=2b (no trailing B) stays block multiplier" "PASS"
    else
        print_test_result "dd count=2b (no trailing B) stays block multiplier" "FAIL" \
            "Expected 4000 bytes (whole file), got $b65_count2b_size"
    fi

    # skip= with a byte suffix seeks the EXACT byte offset, not rounded
    # to an ibs-block multiple (bs=200 does not divide 1000 evenly).
    local b65_skip_input="$TEMP_DIR/dd65_skip_in.bin"
    printf 'ABCDEFGHIJ' > "$b65_skip_input"
    head -c 990 /dev/zero >> "$b65_skip_input"
    printf 'KLMNOPQRST' >> "$b65_skip_input"
    local b65_skip_output="$TEMP_DIR/dd65_skip_out.bin"
    "$binary" if="$b65_skip_input" of="$b65_skip_output" bs=200 skip=1kB status=none 2>/dev/null
    local b65_skip_content
    b65_skip_content=$(cat "$b65_skip_output")
    if [[ "$b65_skip_content" == "KLMNOPQRST" ]]; then
        print_test_result "dd skip=1kB seeks exact byte offset" "PASS"
    else
        print_test_result "dd skip=1kB seeks exact byte offset" "FAIL" \
            "Expected 'KLMNOPQRST', got '$b65_skip_content'"
    fi

    # seek=1kB seeks exactly 1000 output bytes, then count=1 at bs=100
    # writes one 100-byte block -> 1100 total output bytes.
    local b65_seek_input="$TEMP_DIR/dd65_seek_in.bin"
    printf 'X%.0s' {1..100} > "$b65_seek_input"
    local b65_seek_output="$TEMP_DIR/dd65_seek_out.bin"
    "$binary" if="$b65_seek_input" of="$b65_seek_output" bs=100 count=1 seek=1kB status=none 2>/dev/null
    local b65_seek_size
    b65_seek_size=$(get_file_size "$b65_seek_output")
    if [[ "$b65_seek_size" -eq 1100 ]]; then
        print_test_result "dd seek=1kB seeks exact byte offset" "PASS"
    else
        print_test_result "dd seek=1kB seeks exact byte offset" "FAIL" \
            "Expected 1100 bytes, got $b65_seek_size"
    fi

    # bs=1kB uses 1000-byte blocks: a 4000-byte input yields exactly
    # "4+0 records in" (pinned on GNU dd 9.5).
    local b65_bs_err="$TEMP_DIR/dd65_bs_err.txt"
    "$binary" if="$b65_count_input" of=/dev/null bs=1kB 2>"$b65_bs_err"
    if grep -q "4+0 records in" "$b65_bs_err"; then
        print_test_result "dd bs=1kB uses 1000-byte blocks" "PASS"
    else
        print_test_result "dd bs=1kB uses 1000-byte blocks" "FAIL" \
            "Expected '4+0 records in' in stderr, got: $(cat "$b65_bs_err")"
    fi

    # count=0x10 warns that '0x' is a zero multiplier and copies nothing.
    local b65_zero_err="$TEMP_DIR/dd65_zero_err.txt"
    local b65_zero_output="$TEMP_DIR/dd65_zero_out.bin"
    "$binary" if="$b65_count_input" of="$b65_zero_output" bs=512 count=0x10 2>"$b65_zero_err"
    local b65_zero_size
    b65_zero_size=$(get_file_size "$b65_zero_output")
    if grep -qF "dd: warning: '0x' is a zero multiplier; use '00x' if that is intended" "$b65_zero_err" \
        && [[ "$b65_zero_size" -eq 0 ]]; then
        print_test_result "dd count=0x10 warns and copies nothing" "PASS"
    else
        print_test_result "dd count=0x10 warns and copies nothing" "FAIL" \
            "size=$b65_zero_size stderr='$(cat "$b65_zero_err")'"
    fi

    # Issue #64: invalid operand values must name the offending value
    # with GNU's message shape; our rc stays 2 (misuse), not GNU's rc=1.
    local b65_invnum_err="$TEMP_DIR/dd65_invnum_err.txt"
    "$binary" if=/dev/null of=/dev/null count=1m 2>"$b65_invnum_err"
    local b65_invnum_rc=$?
    if [[ "$b65_invnum_rc" -eq 2 ]] && grep -qF "dd: invalid number: '1m'" "$b65_invnum_err"; then
        print_test_result "dd count=1m names value with GNU quoting, rc=2" "PASS"
    else
        print_test_result "dd count=1m names value with GNU quoting, rc=2" "FAIL" \
            "rc=$b65_invnum_rc stderr='$(cat "$b65_invnum_err")'"
    fi

    # Garbage suffix combo rejected the same way.
    local b65_garbage_err="$TEMP_DIR/dd65_garbage_err.txt"
    "$binary" if=/dev/null of=/dev/null bs=1kBx 2>"$b65_garbage_err"
    local b65_garbage_rc=$?
    if [[ "$b65_garbage_rc" -eq 2 ]] && grep -qF "dd: invalid number: '1kBx'" "$b65_garbage_err"; then
        print_test_result "dd bs=1kBx rejected with GNU-quoted message, rc=2" "PASS"
    else
        print_test_result "dd bs=1kBx rejected with GNU-quoted message, rc=2" "FAIL" \
            "rc=$b65_garbage_rc stderr='$(cat "$b65_garbage_err")'"
    fi
}
