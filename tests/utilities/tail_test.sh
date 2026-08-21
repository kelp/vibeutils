#!/usr/bin/env bash
# Optimized tests for tail utility - focused on essential functionality
# Reduced from 101 tests to ~70 tests by removing redundant variations

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_tail() {
    local util="tail"
    local binary="$BIN_DIR/$util"
    
    # Verify binary exists
    test_binary_exists "$util" || return 1
    
    # Test basic flags
    test_basic_flags "$util"
    
    echo -e "${CYAN}Testing basic functionality...${NC}"
    
    # Create test files for basic functionality
    local test_file1=$(create_temp_file "Single line file")
    local test_file2=$(create_temp_file $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15')
    local test_file3=$(create_temp_file "")  # Empty file
    local test_file4=$(create_temp_file $'A\nB\nC\nD\nE')  # Short file (5 lines)
    
    # Basic functionality tests
    test_command_output "tail default (10 lines)" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" "$test_file2"
    test_command_output "tail single line file" "Single line file" "$binary" "$test_file1"
    test_command_output "tail empty file" "" "$binary" "$test_file3"
    test_command_output "tail short file (5 lines)" $'A\nB\nC\nD\nE' "$binary" "$test_file4"
    
    echo -e "${CYAN}Testing core line count flags...${NC}"
    
    # -n flag key variations (remove redundant -n 5, -n 20)
    test_command_output "tail -n 1" "Line 15" "$binary" -n 1 "$test_file2"
    test_command_output "tail -n 10" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 10 "$test_file2"
    test_command_output "tail -n 0" "" "$binary" -n 0 "$test_file2"
    test_command_output "tail -n 20 (more than file)" $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 20 "$test_file2"
    
    # +NUM syntax (key variations only)
    test_command_output "tail -n +1" $'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n +1 "$test_file2"
    test_command_output "tail -n +10" $'Line 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n +10 "$test_file2"
    test_command_output "tail -n +20 (more than file)" "" "$binary" -n +20 "$test_file2"
    
    # --lines long option (essential tests only)
    test_command_output "tail --lines=3" $'Line 13\nLine 14\nLine 15' "$binary" --lines=3 "$test_file2"
    test_command_output "tail --lines=+3" $'Line 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" --lines=+3 "$test_file2"
    
    # Empty file edge case
    test_command_output "tail -n 10 empty file" "" "$binary" -n 10 "$test_file3"
    
    echo -e "${CYAN}Testing byte count flags...${NC}"
    
    # Create file with known byte content
    local byte_file=$(create_temp_file "1234567890ABCDEFGHIJ")  # 20 bytes
    
    # -c flag key variations (remove redundant -c 5, -c 10)
    test_command_output "tail -c 8" "CDEFGHIJ" "$binary" -c 8 "$byte_file"
    test_command_output "tail -c 0" "" "$binary" -c 0 "$byte_file"
    test_command_output "tail -c 50 (more than file)" "1234567890ABCDEFGHIJ" "$binary" -c 50 "$byte_file"
    
    # +NUM syntax for bytes (from byte N onwards, 1-indexed)
    test_command_output "tail -c +1" "1234567890ABCDEFGHIJ" "$binary" -c +1 "$byte_file"
    test_command_output "tail -c +8" "890ABCDEFGHIJ" "$binary" -c +8 "$byte_file"
    test_command_output "tail -c +25 (more than file)" "" "$binary" -c +25 "$byte_file"
    
    # --bytes long option
    test_command_output "tail --bytes=7" "DEFGHIJ" "$binary" --bytes=7 "$byte_file"
    test_command_output "tail --bytes=+8" "890ABCDEFGHIJ" "$binary" --bytes=+8 "$byte_file"
    
    # Empty file edge case
    test_command_output "tail -c 10 empty file" "" "$binary" -c 10 "$test_file3"
    
    # Bytes override lines
    test_command_output "tail -n 5 -c 8 (bytes wins)" "CDEFGHIJ" "$binary" -n 5 -c 8 "$byte_file"
    
    echo -e "${CYAN}Testing header control flags...${NC}"
    
    # Create files for multi-file tests
    local test_file_a=$(create_temp_file $'File A Line 1\nFile A Line 2\nFile A Line 3')
    local test_file_b=$(create_temp_file $'File B Line 1\nFile B Line 2\nFile B Line 3')
    
    # Default multi-file behavior (headers with full paths)
    local expected_multifile=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3\n==> '"$test_file_b"$' <==\nFile B Line 1\nFile B Line 2\nFile B Line 3'
    test_command_output "tail multiple files default headers" "$expected_multifile" "$binary" "$test_file_a" "$test_file_b"
    
    # -q flag (quiet - no headers)
    test_command_output "tail -q multiple files" $'File A Line 1\nFile A Line 2\nFile A Line 3File B Line 1\nFile B Line 2\nFile B Line 3' "$binary" -q "$test_file_a" "$test_file_b"
    test_command_output "tail --quiet multiple files" $'File A Line 1\nFile A Line 2\nFile A Line 3File B Line 1\nFile B Line 2\nFile B Line 3' "$binary" --quiet "$test_file_a" "$test_file_b"
    
    # -v flag (verbose - always show headers)
    local expected_verbose_single=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3'
    test_command_output "tail -v single file" "$expected_verbose_single" "$binary" -v "$test_file_a"
    test_command_output "tail --verbose single file" "$expected_verbose_single" "$binary" --verbose "$test_file_a"
    
    # Flag conflicts (verbose wins)
    test_command_output "tail -q -v conflict (verbose wins)" "$expected_verbose_single" "$binary" -q -v "$test_file_a"
    
    # Header control with line count
    test_command_output "tail -n 2 -q multiple files" $'File A Line 2\nFile A Line 3File B Line 2\nFile B Line 3' "$binary" -n 2 -q "$test_file_a" "$test_file_b"
    
    echo -e "${CYAN}Testing stdin functionality...${NC}"
    
    # Basic stdin tests
    test_command_output "tail from stdin" $'line3\nline4\nline5' bash -c "printf 'line1\\nline2\\nline3\\nline4\\nline5' | '$binary' -n 3"
    test_command_output "tail no args (stdin)" $'stdin3\nstdin4\nstdin5\nstdin6\nstdin7\nstdin8\nstdin9\nstdin10\nstdin11\nstdin12' bash -c "printf 'stdin1\\nstdin2\\nstdin3\\nstdin4\\nstdin5\\nstdin6\\nstdin7\\nstdin8\\nstdin9\\nstdin10\\nstdin11\\nstdin12' | '$binary'"
    test_command_output "tail dash arg (stdin)" $'dash3\ndash4\ndash5\ndash6\ndash7' bash -c "printf 'dash1\\ndash2\\ndash3\\ndash4\\ndash5\\ndash6\\ndash7' | '$binary' -n 5 -"
    
    # Stdin with byte count
    test_command_output "tail -c from stdin" "7890" bash -c "printf '1234567890' | '$binary' -c 4"
    test_command_output "tail -c +6 from stdin" "67890" bash -c "printf '1234567890' | '$binary' -c +6"
    
    # Mix files and stdin
    local expected_file_stdin=$'==> '"$test_file_a"$' <==\nFile A Line 1\nFile A Line 2\nFile A Line 3\n==> standard input <==\nstdin_content'
    test_command_output "tail file then stdin" "$expected_file_stdin" bash -c "echo 'stdin_content' | '$binary' -n 5 '$test_file_a' -"
    
    # Empty stdin
    test_command_output "tail empty stdin" "" bash -c "echo -n '' | '$binary'"
    
    echo -e "${CYAN}Testing zero-terminated flag...${NC}"
    
    # Create file with NUL separators
    local nul_file=$(create_temp_file $'record1\x00record2\x00record3\x00record4\x00record5\x00')
    
    # Test -z flag functionality
    test_command_exit_code "tail -z works" 0 "$binary" -z -n 2 "$nul_file"
    test_command_exit_code "tail --zero-terminated works" 0 "$binary" --zero-terminated -n 3 "$nul_file"
    test_command_exit_code "tail -z +NUM works" 0 "$binary" -z -n +2 "$nul_file"
    test_command_exit_code "tail -z -c works" 0 "$binary" -z -c 10 "$nul_file"
    
    echo -e "${CYAN}Testing flag combinations...${NC}"
    
    # Multiple specifications (last one wins)
    test_command_output "tail -n 2 -n 5" $'Line 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" -n 2 -n 5 "$test_file2"
    test_command_output "tail -c 5 -c 10" "ABCDEFGHIJ" "$binary" -c 5 -c 10 "$byte_file"
    
    # Zero-terminated with other flags
    test_command_exit_code "tail -z -q combination works" 0 "$binary" -z -q -n 2 "$nul_file" "$nul_file"
    
    echo -e "${CYAN}Testing follow mode (-f/-F)...${NC}"

    # Test: tail -f sees appended data
    local follow_file=$(create_temp_file "initial line")
    local follow_output="$TEMP_DIR/follow_stdout"
    "$binary" -f "$follow_file" > "$follow_output" &
    local tail_pid=$!
    sleep 1
    echo "appended line" >> "$follow_file"
    sleep 2
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    if grep -q "appended line" "$follow_output"; then
        print_test_result "tail -f sees appended data" "PASS"
    else
        print_test_result "tail -f sees appended data" "FAIL" "Expected 'appended line' in output"
    fi

    # Test: tail -f detects truncation
    local trunc_file=$(create_temp_file "this is longer original content for truncation test")
    local trunc_stdout="$TEMP_DIR/trunc_stdout"
    local trunc_stderr="$TEMP_DIR/trunc_stderr"
    "$binary" -f "$trunc_file" > "$trunc_stdout" 2>"$trunc_stderr" &
    local trunc_pid=$!
    sleep 1
    : > "$trunc_file"
    echo "short" >> "$trunc_file"
    sleep 2
    kill "$trunc_pid" 2>/dev/null || true
    wait "$trunc_pid" 2>/dev/null || true
    # GNU prints this operand unquoted: "tail: FILE: file truncated" — pin the
    # bare shape, not just the substring, so a stray quote would fail this.
    if grep -qF "$trunc_file: file truncated" "$trunc_stderr" \
        && ! grep -qF "'$trunc_file'" "$trunc_stderr"; then
        print_test_result "tail -f detects truncation" "PASS"
    else
        print_test_result "tail -f detects truncation" "FAIL" "Expected unquoted '$trunc_file: file truncated' on stderr"
    fi

    # Test: tail -F follows rotated file
    local rotate_file="$TEMP_DIR/rotate_test.log"
    echo "original content" > "$rotate_file"
    local rotate_stdout="$TEMP_DIR/rotate_stdout"
    local rotate_stderr="$TEMP_DIR/rotate_stderr"
    "$binary" -F "$rotate_file" > "$rotate_stdout" 2>"$rotate_stderr" &
    local rotate_pid=$!
    sleep 2
    mv "$rotate_file" "${rotate_file}.1"
    sleep 1
    echo "rotated content" > "$rotate_file"
    sleep 3
    kill "$rotate_pid" 2>/dev/null || true
    wait "$rotate_pid" 2>/dev/null || true
    # GNU quotes the operand for both messages: "'FILE' has become
    # inaccessible: No such file or directory" and "'FILE' has been
    # replaced;  following new file" (note the double space, matching GNU).
    if grep -q "rotated content" "$rotate_stdout" \
        && grep -qF "'$rotate_file' has become inaccessible: No such file or directory" "$rotate_stderr" \
        && grep -qF "'$rotate_file' has been replaced;  following new file" "$rotate_stderr"; then
        print_test_result "tail -F follows rotated file" "PASS"
    else
        print_test_result "tail -F follows rotated file" "FAIL" "Expected rotated content in stdout and quoted inaccessible/replaced messages on stderr"
    fi

    # Test: tail -F waits for nonexistent file to appear
    local missing_file="$TEMP_DIR/missing_file.log"
    local missing_stdout="$TEMP_DIR/missing_stdout"
    local missing_stderr="$TEMP_DIR/missing_stderr"
    "$binary" -F "$missing_file" > "$missing_stdout" 2>"$missing_stderr" &
    local missing_pid=$!
    sleep 2
    echo "file appeared" > "$missing_file"
    sleep 3
    kill "$missing_pid" 2>/dev/null || true
    wait "$missing_pid" 2>/dev/null || true
    # GNU's message for the initial missing-file wait is the same quoted
    # "cannot open 'FILE' for reading: ..." family used for a plain missing
    # operand; GNU has no separate "waiting" text at this point.
    if grep -q "file appeared" "$missing_stdout" \
        && grep -qF "cannot open '$missing_file' for reading: No such file or directory" "$missing_stderr"; then
        print_test_result "tail -F waits for nonexistent file" "PASS"
    else
        print_test_result "tail -F waits for nonexistent file" "FAIL" "Expected 'file appeared' in stdout and quoted 'cannot open ... for reading' on stderr"
    fi

    # Multi-file follow (GNU follows every real positional). Background tail
    # is killed by PID only; do not wrap it or wait in run_with_limit.

    # Test: tail -f two files sees appends to both
    local both_a=$(create_temp_file $'dump-a-init\n')
    local both_b=$(create_temp_file $'dump-b-init\n')
    local both_out="$TEMP_DIR/mf_both_stdout"
    local both_err="$TEMP_DIR/mf_both_stderr"
    "$binary" -f "$both_a" "$both_b" >"$both_out" 2>"$both_err" &
    local both_pid=$!
    local i
    for i in $(seq 1 25); do
        grep -q "dump-a-init" "$both_out" && grep -q "dump-b-init" "$both_out" && break
        sleep 0.2
    done
    echo "append-a-live" >> "$both_a"
    echo "append-b-live" >> "$both_b"
    for i in $(seq 1 25); do
        grep -q "append-a-live" "$both_out" && grep -q "append-b-live" "$both_out" && break
        sleep 0.2
    done
    kill "$both_pid" 2>/dev/null || true
    wait "$both_pid" 2>/dev/null || true
    if grep -q "append-a-live" "$both_out" && grep -q "append-b-live" "$both_out" \
        && ! grep -q "multiple-file follow not yet supported" "$both_err"; then
        print_test_result "tail -f two files sees appends to both" "PASS"
    else
        print_test_result "tail -f two files sees appends to both" "FAIL" \
            "Expected appends to both files and no multi-file warning"
    fi

    # Test: tail -f two files prints switch headers
    local hdr_a=$(create_temp_file $'dump-a-hdr\n')
    local hdr_b=$(create_temp_file $'dump-b-hdr\n')
    local hdr_out="$TEMP_DIR/mf_hdr_stdout"
    local hdr_err="$TEMP_DIR/mf_hdr_stderr"
    "$binary" -f "$hdr_a" "$hdr_b" >"$hdr_out" 2>"$hdr_err" &
    local hdr_pid=$!
    for i in $(seq 1 25); do
        grep -q "dump-a-hdr" "$hdr_out" && grep -q "dump-b-hdr" "$hdr_out" && break
        sleep 0.2
    done
    echo "append-first-only" >> "$hdr_a"
    for i in $(seq 1 25); do
        grep -q "append-first-only" "$hdr_out" && break
        sleep 0.2
    done
    kill "$hdr_pid" 2>/dev/null || true
    wait "$hdr_pid" 2>/dev/null || true
    local hdr_needle=$'\n==> '"$hdr_a"$' <==\nappend-first-only'
    if [[ "$(cat "$hdr_out")" == *"$hdr_needle"* ]]; then
        print_test_result "tail -f two files prints switch headers" "PASS"
    else
        print_test_result "tail -f two files prints switch headers" "FAIL" \
            "Expected append-first-only immediately preceded by GNU switch header for the first file"
    fi

    # Test: tail -f two files omits switch header for last dump file
    local last_a=$(create_temp_file $'dump-a-last\n')
    local last_b=$(create_temp_file $'dump-b-last\n')
    local last_out="$TEMP_DIR/mf_last_stdout"
    local last_err="$TEMP_DIR/mf_last_stderr"
    "$binary" -f "$last_a" "$last_b" >"$last_out" 2>"$last_err" &
    local last_pid=$!
    for i in $(seq 1 25); do
        grep -q "dump-a-last" "$last_out" && grep -q "dump-b-last" "$last_out" && break
        sleep 0.2
    done
    echo "append-last-only" >> "$last_b"
    for i in $(seq 1 25); do
        grep -q "append-last-only" "$last_out" && break
        sleep 0.2
    done
    kill "$last_pid" 2>/dev/null || true
    wait "$last_pid" 2>/dev/null || true
    local last_bad=$'\n==> '"$last_b"$' <==\nappend-last-only'
    if grep -q "append-last-only" "$last_out" \
        && [[ "$(cat "$last_out")" != *"$last_bad"* ]]; then
        print_test_result "tail -f two files omits switch header for last dump file" "PASS"
    else
        print_test_result "tail -f two files omits switch header for last dump file" "FAIL" \
            "Expected append-last-only without an immediate switch header for the last dump file"
    fi

    # Test: tail -fq two files omits switch headers
    local q_a=$(create_temp_file $'dump-a-quiet\n')
    local q_b=$(create_temp_file $'dump-b-quiet\n')
    local q_out="$TEMP_DIR/mf_quiet_stdout"
    local q_err="$TEMP_DIR/mf_quiet_stderr"
    "$binary" -fq "$q_a" "$q_b" >"$q_out" 2>"$q_err" &
    local q_pid=$!
    for i in $(seq 1 25); do
        grep -q "dump-a-quiet" "$q_out" && grep -q "dump-b-quiet" "$q_out" && break
        sleep 0.2
    done
    echo "quiet-first-append" >> "$q_a"
    for i in $(seq 1 25); do
        grep -q "quiet-first-append" "$q_out" && break
        sleep 0.2
    done
    kill "$q_pid" 2>/dev/null || true
    wait "$q_pid" 2>/dev/null || true
    if grep -q "dump-a-quiet" "$q_out" && grep -q "quiet-first-append" "$q_out" \
        && ! grep -q "==>" "$q_out"; then
        print_test_result "tail -fq two files omits switch headers" "PASS"
    else
        print_test_result "tail -fq two files omits switch headers" "FAIL" \
            "Expected both lines and no ==> headers under -fq"
    fi

    # Test: tail -f missing existing follows the live file
    local miss_first="$TEMP_DIR/mf_missing_first"
    local exist_second=$(create_temp_file $'exist-second-init\n')
    local me_out="$TEMP_DIR/mf_miss_exist_stdout"
    local me_err="$TEMP_DIR/mf_miss_exist_stderr"
    "$binary" -f "$miss_first" "$exist_second" >"$me_out" 2>"$me_err" &
    local me_pid=$!
    for i in $(seq 1 25); do
        grep -q "exist-second-init" "$me_out" && break
        sleep 0.2
    done
    echo "exist-second-append" >> "$exist_second"
    for i in $(seq 1 25); do
        grep -q "exist-second-append" "$me_out" && break
        sleep 0.2
    done
    kill "$me_pid" 2>/dev/null || true
    wait "$me_pid" 2>/dev/null || true
    if grep -q "exist-second-append" "$me_out" \
        && grep -q "cannot open '$miss_first'" "$me_err"; then
        print_test_result "tail -f missing existing follows the live file" "PASS"
    else
        print_test_result "tail -f missing existing follows the live file" "FAIL" \
            "Expected live-file append and cannot-open for the missing operand"
    fi

    # Test: tail -f existing missing follows the live file
    local exist_first=$(create_temp_file $'exist-first-init\n')
    local miss_second="$TEMP_DIR/mf_missing_second"
    local em_out="$TEMP_DIR/mf_exist_miss_stdout"
    local em_err="$TEMP_DIR/mf_exist_miss_stderr"
    "$binary" -f "$exist_first" "$miss_second" >"$em_out" 2>"$em_err" &
    local em_pid=$!
    for i in $(seq 1 25); do
        grep -q "exist-first-init" "$em_out" && break
        sleep 0.2
    done
    echo "exist-first-append" >> "$exist_first"
    for i in $(seq 1 25); do
        grep -q "exist-first-append" "$em_out" && break
        sleep 0.2
    done
    kill "$em_pid" 2>/dev/null || true
    wait "$em_pid" 2>/dev/null || true
    local em_needle=$'\n==> '"$exist_first"$' <==\nexist-first-append'
    if grep -q "exist-first-append" "$em_out" \
        && [[ "$(cat "$em_out")" == *"$em_needle"* ]] \
        && grep -q "cannot open '$miss_second'" "$em_err"; then
        print_test_result "tail -f existing missing follows the live file" "PASS"
    else
        print_test_result "tail -f existing missing follows the live file" "FAIL" \
            "Expected live-file append with switch header and cannot-open for missing"
    fi

    # Test: tail -F missing existing follows then both
    local F_miss="$TEMP_DIR/mf_F_missing"
    local F_exist=$(create_temp_file $'F-exist-init\n')
    local F_out="$TEMP_DIR/mf_F_stdout"
    local F_err="$TEMP_DIR/mf_F_stderr"
    "$binary" -F "$F_miss" "$F_exist" >"$F_out" 2>"$F_err" &
    local F_pid=$!
    for i in $(seq 1 25); do
        grep -q "F-exist-init" "$F_out" && break
        sleep 0.2
    done
    echo "F-exist-while-missing" >> "$F_exist"
    for i in $(seq 1 25); do
        grep -q "F-exist-while-missing" "$F_out" && break
        sleep 0.2
    done
    echo "F-missing-init" > "$F_miss"
    echo "F-missing-append" >> "$F_miss"
    for i in $(seq 1 25); do
        grep -q "F-missing-append" "$F_out" && break
        sleep 0.2
    done
    kill "$F_pid" 2>/dev/null || true
    wait "$F_pid" 2>/dev/null || true
    if grep -q "F-exist-while-missing" "$F_out" \
        && grep -q "F-missing-append" "$F_out" \
        && grep -qF "has appeared;  following new file" "$F_err"; then
        print_test_result "tail -F missing existing follows then both" "PASS"
    else
        print_test_result "tail -F missing existing follows then both" "FAIL" \
            "Expected live appends while missing, then missing appends and GNU appeared diagnostic"
    fi

    # Test: tail -F two files rotate one still follows the other
    local rot_a=$(create_temp_file $'rot-a-init\n')
    local rot_b=$(create_temp_file $'rot-b-init\n')
    local rot_out="$TEMP_DIR/mf_rot_stdout"
    local rot_err="$TEMP_DIR/mf_rot_stderr"
    "$binary" -F "$rot_a" "$rot_b" >"$rot_out" 2>"$rot_err" &
    local rot2_pid=$!
    for i in $(seq 1 25); do
        grep -q "rot-a-init" "$rot_out" && grep -q "rot-b-init" "$rot_out" && break
        sleep 0.2
    done
    mv "$rot_a" "${rot_a}.1"
    echo "rot-a-new" > "$rot_a"
    echo "rot-b-append" >> "$rot_b"
    for i in $(seq 1 25); do
        grep -q "rot-b-append" "$rot_out" && grep -q "rot-a-new" "$rot_out" && break
        sleep 0.2
    done
    kill "$rot2_pid" 2>/dev/null || true
    wait "$rot2_pid" 2>/dev/null || true
    if grep -q "rot-b-append" "$rot_out" && grep -q "rot-a-new" "$rot_out"; then
        print_test_result "tail -F two files rotate one still follows the other" "PASS"
    else
        print_test_result "tail -F two files rotate one still follows the other" "FAIL" \
            "Expected appends to the unrotated file and the replacement of the rotated file"
    fi

    # Test: tail -f duplicate operands both emit
    local dup_a=$(create_temp_file $'dup-init\n')
    local dup_out="$TEMP_DIR/mf_dup_stdout"
    local dup_err="$TEMP_DIR/mf_dup_stderr"
    "$binary" -f "$dup_a" "$dup_a" >"$dup_out" 2>"$dup_err" &
    local dup_pid=$!
    for i in $(seq 1 25); do
        grep -q "dup-init" "$dup_out" && break
        sleep 0.2
    done
    echo "dup-append" >> "$dup_a"
    for i in $(seq 1 25); do
        grep -q "dup-append" "$dup_out" && break
        sleep 0.2
    done
    kill "$dup_pid" 2>/dev/null || true
    wait "$dup_pid" 2>/dev/null || true
    local dup_count
    dup_count=$(grep -c "dup-append" "$dup_out" || true)
    local dup_needle=$'\n==> '"$dup_a"$' <==\ndup-append'
    if [[ "$dup_count" -eq 2 ]] && [[ "$(cat "$dup_out")" == *"$dup_needle"* ]]; then
        print_test_result "tail -f duplicate operands both emit" "PASS"
    else
        print_test_result "tail -f duplicate operands both emit" "FAIL" \
            "Expected dup-append twice with a switch header immediately before the second copy"
    fi

    # Test: tail -f -r is an error (mutually exclusive)
    local mutual_file=$(create_temp_file "test")
    if "$binary" -f -r "$mutual_file" 2>/dev/null; then
        print_test_result "tail -f -r mutual exclusion" "FAIL" "Expected non-zero exit"
    else
        print_test_result "tail -f -r mutual exclusion" "PASS"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"
    
    # Invalid arguments
    test_command_fails "tail invalid flag" "$binary" --invalid-flag
    test_command_fails "tail -n invalid value" "$binary" -n abc "$test_file1"
    test_command_fails "tail -c invalid value" "$binary" -c xyz "$test_file1"
    test_command_fails "tail -n negative value" "$binary" -n -5 "$test_file1"
    
    # Non-existent files
    test_command_fails "tail non-existent file" "$binary" "/path/that/does/not/exist"
    test_command_fails "tail mixed existing and non-existent" "$binary" "$test_file1" "/nonexistent"

    # GNU quotes the missing operand: "cannot open 'FILE' for reading: ..."
    local nx_command nx_stdout nx_stderr nx_exit
    run_command nx_command nx_stdout nx_stderr nx_exit "$binary" "/path/that/does/not/exist"
    if [[ "$nx_stderr" == *"cannot open '/path/that/does/not/exist' for reading: No such file or directory"* ]]; then
        print_test_result "tail non-existent file quotes operand" "PASS"
    else
        print_test_result "tail non-existent file quotes operand" "FAIL" "Expected quoted 'cannot open' message. Got: '$nx_stderr'"
    fi

    # Same "cannot open 'FILE' for reading" family under -f (plain follow,
    # no -F retry): GNU prints the identical message before "no files remaining".
    local nxf_command nxf_stdout nxf_stderr nxf_exit
    run_command nxf_command nxf_stdout nxf_stderr nxf_exit "$binary" -f "/path/that/does/not/exist"
    if [[ "$nxf_stderr" == *"cannot open '/path/that/does/not/exist' for reading: No such file or directory"* ]]; then
        print_test_result "tail -f non-existent file quotes operand" "PASS"
    else
        print_test_result "tail -f non-existent file quotes operand" "FAIL" "Expected quoted 'cannot open' message. Got: '$nxf_stderr'"
    fi

    # Directory handling
    local test_dir=$(create_temp_dir)
    test_command_fails "tail directory" "$binary" "$test_dir"

    # Permission denied
    local unreadable_file=$(create_temp_file "secret content")
    chmod 000 "$unreadable_file"
    test_command_fails "tail permission denied" "$binary" "$unreadable_file"

    local perm_command perm_stdout perm_stderr perm_exit
    run_command perm_command perm_stdout perm_stderr perm_exit "$binary" "$unreadable_file"
    if [[ "$perm_stderr" == *"cannot open '$unreadable_file' for reading: Permission denied"* ]]; then
        print_test_result "tail permission denied quotes operand" "PASS"
    else
        print_test_result "tail permission denied quotes operand" "FAIL" "Expected quoted 'cannot open' message. Got: '$perm_stderr'"
    fi
    chmod 644 "$unreadable_file"  # cleanup
    
    echo -e "${CYAN}Testing POSIX compliance...${NC}"
    
    # POSIX required behaviors
    test_command_output "POSIX: tail default 10 lines" $'Line 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\nLine 15' "$binary" "$test_file2"
    test_command_output "POSIX: tail -n lines" $'Line 13\nLine 14\nLine 15' "$binary" -n 3 "$test_file2"
    test_command_output "POSIX: tail stdin" "test" bash -c "echo 'test' | '$binary' -n 1"
    
    # POSIX exit codes
    test_command_exit_code "tail success exit code" 0 "$binary" "$test_file1"
    test_command_exit_code "tail failure exit code" 1 "$binary" "/nonexistent/file" 2>/dev/null || true
    
    # POSIX multiple file handling
    local expected_posix_multi=$'==> '"$test_file1"$' <==\nSingle line file\n==> '"$test_file4"$' <==\nA\nB\nC\nD\nE'
    test_command_output "POSIX: multiple files with headers" "$expected_posix_multi" "$binary" "$test_file1" "$test_file4"
    
    echo -e "${CYAN}Testing essential edge cases...${NC}"
    
    # Large file boundary test (keep only one large file test)
    local large_content=$(printf 'Large line %d\n' {1..100})
    local large_file=$(create_temp_file "$large_content")
    local large_expected=$(printf 'Large line %d\n' {91..100})
    large_expected="${large_expected%$'\n'}"
    test_command_output "tail large file default" "$large_expected" "$binary" "$large_file"
    
    # Binary file handling
    local binary_content=$'\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xFF\xFE\xFD\xFC'
    local binary_file=$(create_temp_file "$binary_content")
    test_command_exit_code "tail binary file works" 0 "$binary" -c 9 "$binary_file"
    
    # Files without final newlines
    local no_newline_file=$(printf "line1\nline2\nline3")
    local no_nl_file=$(create_temp_file "$no_newline_file")
    test_command_output "tail file without final newline" $'line2\nline3' "$binary" -n 2 "$no_nl_file"
    
    # Special files
    test_command_succeeds "tail /dev/null" "$binary" /dev/null
    
    # Key boundary conditions (remove redundant 11-line test)
    local exact_10_lines=$(printf 'Line %d\n' {1..10} | head -c -1)
    local exact_file=$(create_temp_file "$exact_10_lines")
    test_command_output "tail file with exactly 10 lines" "$exact_10_lines" "$binary" "$exact_file"
    
    # Very long lines (keep one test)
    local long_line_content="$(printf 'A%.0s' {1..1000})"$'\nShort line'
    local long_line_file=$(create_temp_file "$long_line_content")
    test_command_output "tail file with very long line" "$long_line_content" "$binary" -n 2 "$long_line_file"
    
    # Single character edge case
    local single_char=$(create_temp_file "X")
    test_command_output "tail single character file" "X" "$binary" "$single_char"
    test_command_output "tail -c 1 single char" "X" "$binary" -c 1 "$single_char"
    
    # Mixed file types
    local expected_mixed=$'==> '"$test_file1"$' <==\nSingle line file\n==> /dev/null <=='
    test_command_output "tail mixed normal and special" "$expected_mixed" "$binary" -n 1 "$test_file1" /dev/null

    echo -e "${CYAN}Testing block count flag (-b)...${NC}"

    # -b N: last N 512-byte blocks
    # Create a 2048-byte file (4 blocks of 512)
    local block_file="$TEMP_DIR/block_test.bin"
    dd if=/dev/zero bs=512 count=4 2>/dev/null | tr '\0' 'A' > "$block_file"
    # Overwrite second half with B's for distinguishable content
    dd if=/dev/zero bs=512 count=2 2>/dev/null | tr '\0' 'B' >> "$block_file"
    # Now file is: 2048 A's + 1024 B's = 3072 bytes = 6 blocks

    # tail -b 2 should return last 1024 bytes (2 blocks of B's)
    local block_out
    block_out=$("$binary" -b 2 "$block_file" | wc -c | tr -d ' ')
    if [[ "$block_out" -eq 1024 ]]; then
        print_test_result "tail -b 2 returns 1024 bytes" "PASS"
    else
        print_test_result "tail -b 2 returns 1024 bytes" "FAIL" \
            "Expected 1024 bytes, got $block_out"
    fi

    # tail -b 1 should return last 512 bytes
    local block_out1
    block_out1=$("$binary" -b 1 "$block_file" | wc -c | tr -d ' ')
    if [[ "$block_out1" -eq 512 ]]; then
        print_test_result "tail -b 1 returns 512 bytes" "PASS"
    else
        print_test_result "tail -b 1 returns 512 bytes" "FAIL" \
            "Expected 512 bytes, got $block_out1"
    fi

    # --blocks= long form
    local block_long_out
    block_long_out=$("$binary" --blocks=1 "$block_file" | wc -c | tr -d ' ')
    if [[ "$block_long_out" -eq 512 ]]; then
        print_test_result "tail --blocks=1 returns 512 bytes" "PASS"
    else
        print_test_result "tail --blocks=1 returns 512 bytes" "FAIL" \
            "Expected 512 bytes, got $block_long_out"
    fi
    rm -f "$block_file"

    echo -e "${CYAN}Testing reverse flag (-r)...${NC}"

    local rev_file=$(create_temp_file $'alpha\nbeta\ngamma\ndelta')

    # -r reverses all lines
    test_command_output "tail -r reverses all lines" \
        $'delta\ngamma\nbeta\nalpha' \
        "$binary" -r "$rev_file"

    # -r -n 3 reverses last 3 lines
    test_command_output "tail -r -n 3 reverses last 3" \
        $'delta\ngamma\nbeta' \
        "$binary" -r -n 3 "$rev_file"

    # -r single line file
    local rev_single=$(create_temp_file "only")
    test_command_output "tail -r single line" "only" \
        "$binary" -r "$rev_single"

    # -r from stdin
    test_command_output "tail -r from stdin" $'c\nb\na' \
        bash -c "printf 'a\nb\nc' | '$binary' -r"

    echo -e "${CYAN}Testing large -c value via stdin (OOM bug F64)...${NC}"

    # F64: tail -c with large value on empty stdin should exit 0, not OOM.
    # processInputByBytesNoSeek allocates byte_count bytes unconditionally,
    # so a large value causes OOM even when there is no data to read.

    # Large -c on /dev/null: must exit 0 (GNU behavior), not OOM crash
    test_command_exit_code "tail -c 10000000000 /dev/null exits 0" 0 bash -c "'$binary' -c 10000000000 < /dev/null"

    # Large -c on empty pipe: must exit 0
    test_command_exit_code "tail -c 10000000000 empty pipe exits 0" 0 bash -c "echo -n '' | '$binary' -c 10000000000"

    # Large -c with small input via pipe: should return all input, not OOM
    test_command_output "tail -c 1000000000 small stdin returns data" "hello" bash -c "printf 'hello' | '$binary' -c 1000000000"

    # -c 0 from stdin should produce nothing (edge case, not the OOM bug)
    test_command_output "tail -c 0 from stdin" "" bash -c "printf 'data' | '$binary' -c 0"

    echo -e "${CYAN}Testing GNU-style long-flag abbreviation, exact-match-wins (issue #128)...${NC}"

    # REGRESSION, EXACT-MATCH-WINS: "--follow" is itself a full field name
    # (a plain bool in vibeutils' TailArgs) and must resolve directly, NOT
    # be reported ambiguous against "--follow-retry" — it must still reject
    # the attached "=name" value exactly as it does today. This errors
    # before entering the follow loop, so it needs no backgrounding.
    local follow_file=$(create_temp_file "line one")
    local fnv_cmd="" fnv_out="" fnv_err="" fnv_exit=""
    run_command fnv_cmd fnv_out fnv_err fnv_exit "$binary" --follow=name "$follow_file"
    if [[ $fnv_exit -eq 1 && "$fnv_err" == "tail: option '--follow' doesn't allow an argument"* && "$fnv_err" != *ambiguous* ]]; then
        print_test_result "tail --follow=name resolves exactly (regression)" "PASS"
    else
        print_test_result "tail --follow=name resolves exactly (regression)" "FAIL" \
            "Expected \"tail: option '--follow' doesn't allow an argument\" (not ambiguous), got exit=$fnv_exit stderr='$fnv_err'"
    fi

    echo -e "${CYAN}Testing ambiguous-abbreviation candidate order (issue #128)...${NC}"

    # GNU orders an ambiguous option's candidates by its own longopts table,
    # not by vibeutils' Args field-declaration order. Re-pinned against real
    # GNU coreutils 9.4 on this host:
    #   $ LC_ALL=C /usr/bin/tail --v
    #   /usr/bin/tail: option '--v' is ambiguous; possibilities: '--verbose' '--version'
    # so '--verbose' comes FIRST; vibeutils lists '--version' first today.
    local abbrev_v_cmd="" abbrev_v_out="" abbrev_v_err="" abbrev_v_exit=""
    run_command abbrev_v_cmd abbrev_v_out abbrev_v_err abbrev_v_exit bash -c "'$binary' --v < /dev/null"
    local abbrev_v_expected="tail: option '--v' is ambiguous; possibilities: '--verbose' '--version'"$'\n'"Try 'tail --help' for more information."
    if [[ $abbrev_v_exit -eq 1 && "$abbrev_v_err" == "$abbrev_v_expected" ]]; then
        print_test_result "tail --v lists candidates in GNU longopts order" "PASS"
    else
        print_test_result "tail --v lists candidates in GNU longopts order" "FAIL" \
            "Expected: '$abbrev_v_expected', got exit=$abbrev_v_exit stderr='$abbrev_v_err'"
    fi

}
