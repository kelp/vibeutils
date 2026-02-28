#!/usr/bin/env bash
# Comprehensive tests for readlink utility
# Tests symlink reading, canonicalize modes, output formatting, and
# error handling
#
# This file is sourced by test_runner.sh, so common.sh is already loaded

test_readlink() {
    local util="readlink"
    local binary="$BIN_DIR/$util"

    # Helper to get canonical path for comparison
    # On macOS, /var is a symlink to /private/var, so readlink -f
    # returns /private/var/... while $TMPDIR contains /var/...
    _canon() {
        /usr/bin/readlink -f "$1" 2>/dev/null \
            || realpath "$1" 2>/dev/null \
            || echo "$1"
    }

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic symlink reading...${NC}"

    # Create target files and symlinks for testing
    local target1=$(create_temp_file "target content 1")
    local link1="$TEMP_DIR/readlink_basic"
    ln -s "$target1" "$link1"

    # Basic readlink: should print symlink target
    local basic_out=""
    local basic_err=""
    local basic_exit=""
    run_command basic_cmd basic_out basic_err basic_exit "$binary" "$link1"
    if [[ $basic_exit -eq 0 && "$basic_out" == "$target1" ]]; then
        print_test_result "readlink basic symlink" "PASS"
    else
        print_test_result "readlink basic symlink" "FAIL" \
            "Expected '$target1', got '$basic_out' (exit: $basic_exit)"
    fi

    # Relative symlink
    local rel_target=$(create_temp_file "relative target")
    local rel_base
    rel_base=$(basename "$rel_target")
    local rel_link="$TEMP_DIR/readlink_relative"
    ln -s "$rel_base" "$rel_link"

    local rel_out=""
    local rel_err=""
    local rel_exit=""
    run_command rel_cmd rel_out rel_err rel_exit "$binary" "$rel_link"
    if [[ $rel_exit -eq 0 && "$rel_out" == "$rel_base" ]]; then
        print_test_result "readlink relative symlink" "PASS"
    else
        print_test_result "readlink relative symlink" "FAIL" \
            "Expected '$rel_base', got '$rel_out'"
    fi

    # Dangling symlink (target does not exist)
    local dangle_link="$TEMP_DIR/readlink_dangling"
    ln -s "/nonexistent/target/path" "$dangle_link"

    local dangle_out=""
    local dangle_err=""
    local dangle_exit=""
    run_command dangle_cmd dangle_out dangle_err dangle_exit \
        "$binary" "$dangle_link"
    if [[ $dangle_exit -eq 0 && \
          "$dangle_out" == "/nonexistent/target/path" ]]; then
        print_test_result "readlink dangling symlink" "PASS"
    else
        print_test_result "readlink dangling symlink" "FAIL" \
            "Expected '/nonexistent/target/path', got '$dangle_out'"
    fi

    echo -e "${CYAN}Testing non-symlink errors...${NC}"

    # Regular file (not a symlink) should fail
    local regular_file=$(create_temp_file "not a symlink")
    test_command_exit_code "readlink regular file fails" 1 \
        "$binary" "$regular_file"

    # Nonexistent file should fail
    test_command_exit_code "readlink nonexistent file fails" 1 \
        "$binary" "/tmp/definitely_nonexistent_readlink_$$"

    # Directory should fail (not a symlink)
    local test_dir=$(create_temp_dir)
    test_command_exit_code "readlink directory fails" 1 \
        "$binary" "$test_dir"

    echo -e "${CYAN}Testing canonicalize (-f)...${NC}"

    # Canonicalize a symlink
    local canon_target=$(create_temp_file "canon content")
    local canon_link="$TEMP_DIR/readlink_canon"
    ln -s "$canon_target" "$canon_link"

    local canon_out=""
    local canon_err=""
    local canon_exit=""
    run_command canon_cmd canon_out canon_err canon_exit \
        "$binary" -f "$canon_link"
    local canon_expected
    canon_expected=$(_canon "$canon_target")
    if [[ $canon_exit -eq 0 && "$canon_out" == "$canon_expected" ]]; then
        print_test_result "readlink -f symlink" "PASS"
    else
        print_test_result "readlink -f symlink" "FAIL" \
            "Expected '$canon_expected', got '$canon_out'"
    fi

    # Canonicalize a regular file (should succeed with -f)
    local reg_target=$(create_temp_file "regular canon")
    local reg_out=""
    local reg_err=""
    local reg_exit=""
    run_command reg_cmd reg_out reg_err reg_exit \
        "$binary" -f "$reg_target"
    local reg_expected
    reg_expected=$(_canon "$reg_target")
    if [[ $reg_exit -eq 0 && "$reg_out" == "$reg_expected" ]]; then
        print_test_result "readlink -f regular file" "PASS"
    else
        print_test_result "readlink -f regular file" "FAIL" \
            "Expected '$reg_expected', got '$reg_out'"
    fi

    # --canonicalize long option
    local long_canon_out=""
    local long_canon_err=""
    local long_canon_exit=""
    run_command long_canon_cmd long_canon_out long_canon_err \
        long_canon_exit "$binary" --canonicalize "$reg_target"
    if [[ $long_canon_exit -eq 0 ]]; then
        print_test_result "readlink --canonicalize" "PASS"
    else
        print_test_result "readlink --canonicalize" "FAIL" \
            "Exit code: $long_canon_exit"
    fi

    # Canonicalize nonexistent path (should fail with -f)
    test_command_exit_code "readlink -f nonexistent fails" 1 \
        "$binary" -f "/tmp/nonexistent_readlink_canon_$$"

    echo -e "${CYAN}Testing canonicalize-existing (-e)...${NC}"

    # -e on existing file
    local ce_target=$(create_temp_file "ce content")
    local ce_out=""
    local ce_err=""
    local ce_exit=""
    run_command ce_cmd ce_out ce_err ce_exit \
        "$binary" -e "$ce_target"
    local ce_expected
    ce_expected=$(_canon "$ce_target")
    if [[ $ce_exit -eq 0 && "$ce_out" == "$ce_expected" ]]; then
        print_test_result "readlink -e existing file" "PASS"
    else
        print_test_result "readlink -e existing file" "FAIL" \
            "Expected '$ce_expected', got '$ce_out'"
    fi

    # -e on nonexistent path (should fail)
    test_command_exit_code "readlink -e nonexistent fails" 1 \
        "$binary" -e "/tmp/nonexistent_readlink_ce_$$"

    # --canonicalize-existing long option
    local long_ce_out=""
    local long_ce_err=""
    local long_ce_exit=""
    run_command long_ce_cmd long_ce_out long_ce_err long_ce_exit \
        "$binary" --canonicalize-existing "$ce_target"
    if [[ $long_ce_exit -eq 0 ]]; then
        print_test_result "readlink --canonicalize-existing" "PASS"
    else
        print_test_result "readlink --canonicalize-existing" "FAIL" \
            "Exit code: $long_ce_exit"
    fi

    echo -e "${CYAN}Testing canonicalize-missing (-m)...${NC}"

    # -m on existing file
    local cm_target=$(create_temp_file "cm content")
    local cm_out=""
    local cm_err=""
    local cm_exit=""
    run_command cm_cmd cm_out cm_err cm_exit \
        "$binary" -m "$cm_target"
    local cm_expected
    cm_expected=$(_canon "$cm_target")
    if [[ $cm_exit -eq 0 && "$cm_out" == "$cm_expected" ]]; then
        print_test_result "readlink -m existing file" "PASS"
    else
        print_test_result "readlink -m existing file" "FAIL" \
            "Expected '$cm_expected', got '$cm_out'"
    fi

    # -m on nonexistent path (should succeed)
    local cm_nonexist_out=""
    local cm_nonexist_err=""
    local cm_nonexist_exit=""
    run_command cm_nonexist_cmd cm_nonexist_out cm_nonexist_err \
        cm_nonexist_exit \
        "$binary" -m "$TEMP_DIR/nonexistent_dir/nonexistent_file"
    if [[ $cm_nonexist_exit -eq 0 && -n "$cm_nonexist_out" ]]; then
        print_test_result "readlink -m nonexistent path succeeds" "PASS"
    else
        print_test_result "readlink -m nonexistent path succeeds" "FAIL" \
            "Exit: $cm_nonexist_exit, output: '$cm_nonexist_out'"
    fi

    # --canonicalize-missing long option
    local long_cm_out=""
    local long_cm_err=""
    local long_cm_exit=""
    run_command long_cm_cmd long_cm_out long_cm_err long_cm_exit \
        "$binary" --canonicalize-missing \
        "$TEMP_DIR/nonexistent_also/file.txt"
    if [[ $long_cm_exit -eq 0 && -n "$long_cm_out" ]]; then
        print_test_result "readlink --canonicalize-missing" "PASS"
    else
        print_test_result "readlink --canonicalize-missing" "FAIL" \
            "Exit: $long_cm_exit, output: '$long_cm_out'"
    fi

    echo -e "${CYAN}Testing no-newline flag (-n)...${NC}"

    local nn_target=$(create_temp_file "nn target")
    local nn_link="$TEMP_DIR/readlink_nn"
    ln -s "$nn_target" "$nn_link"

    local nn_file="$TEMP_DIR/readlink_nn_output"
    "$binary" -n "$nn_link" > "$nn_file"
    local nn_content
    nn_content=$(cat "$nn_file")
    # Check no trailing newline by comparing file size
    local expected_len=${#nn_target}
    local actual_len
    actual_len=$(wc -c < "$nn_file" | tr -d ' ')
    if [[ "$actual_len" -eq "$expected_len" ]]; then
        print_test_result "readlink -n no trailing newline" "PASS"
    else
        print_test_result "readlink -n no trailing newline" "FAIL" \
            "Expected length $expected_len, got $actual_len"
    fi
    rm -f "$nn_file"

    echo -e "${CYAN}Testing zero delimiter (-z)...${NC}"

    local z_target=$(create_temp_file "zero target")
    local z_link="$TEMP_DIR/readlink_zero"
    ln -s "$z_target" "$z_link"

    local z_file="$TEMP_DIR/readlink_zero_output"
    "$binary" -z "$z_link" > "$z_file"
    # Should end with NUL byte, not newline
    local last_byte
    last_byte=$(tail -c 1 "$z_file" | od -An -tx1 | tr -d ' ')
    if [[ "$last_byte" == "00" ]]; then
        print_test_result "readlink -z NUL terminator" "PASS"
    else
        print_test_result "readlink -z NUL terminator" "FAIL" \
            "Expected NUL byte, got: $last_byte"
    fi
    rm -f "$z_file"

    # --zero long option
    test_command_exit_code "readlink --zero flag accepted" 0 \
        "$binary" --zero "$z_link"

    echo -e "${CYAN}Testing verbose flag (-v)...${NC}"

    # Verbose on error should show message
    local v_out=""
    local v_err=""
    local v_exit=""
    run_command v_cmd v_out v_err v_exit \
        "$binary" -v "/tmp/nonexistent_readlink_verbose_$$"
    if [[ $v_exit -ne 0 && -n "$v_err" ]]; then
        print_test_result "readlink -v shows error" "PASS"
    else
        print_test_result "readlink -v shows error" "FAIL" \
            "Expected error output, exit: $v_exit, err: '$v_err'"
    fi

    echo -e "${CYAN}Testing quiet flag (-q)...${NC}"

    # Quiet should suppress error messages
    local q_out=""
    local q_err=""
    local q_exit=""
    run_command q_cmd q_out q_err q_exit \
        "$binary" -q "/tmp/nonexistent_readlink_quiet_$$"
    if [[ $q_exit -ne 0 && -z "$q_err" ]]; then
        print_test_result "readlink -q suppresses errors" "PASS"
    else
        print_test_result "readlink -q suppresses errors" "FAIL" \
            "Expected no error output, err: '$q_err'"
    fi

    echo -e "${CYAN}Testing multiple files...${NC}"

    local m_target1=$(create_temp_file "multi 1")
    local m_target2=$(create_temp_file "multi 2")
    local m_link1="$TEMP_DIR/readlink_multi1"
    local m_link2="$TEMP_DIR/readlink_multi2"
    ln -s "$m_target1" "$m_link1"
    ln -s "$m_target2" "$m_link2"

    local multi_out=""
    local multi_err=""
    local multi_exit=""
    run_command multi_cmd multi_out multi_err multi_exit \
        "$binary" "$m_link1" "$m_link2"
    if [[ $multi_exit -eq 0 ]]; then
        print_test_result "readlink multiple symlinks" "PASS"
    else
        print_test_result "readlink multiple symlinks" "FAIL" \
            "Exit: $multi_exit"
    fi

    # Mixed success and failure
    local mixed_out=""
    local mixed_err=""
    local mixed_exit=""
    local mixed_regular=$(create_temp_file "not a link")
    run_command mixed_cmd mixed_out mixed_err mixed_exit \
        "$binary" "$m_link1" "$mixed_regular"
    if [[ $mixed_exit -ne 0 ]]; then
        print_test_result "readlink mixed success/failure exit code" "PASS"
    else
        print_test_result "readlink mixed success/failure exit code" "FAIL" \
            "Expected non-zero exit"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments
    test_command_exit_code "readlink no arguments" 2 "$binary"

    # Invalid flag
    test_command_exit_code "readlink invalid flag" 2 \
        "$binary" --invalid-flag 2>/dev/null

    echo -e "${CYAN}Testing help and version...${NC}"

    # Help output
    local help_out
    help_out=$("$binary" --help)
    if [[ "$help_out" =~ "Usage:" && "$help_out" =~ "--canonicalize" ]]; then
        print_test_result "readlink help output" "PASS"
    else
        print_test_result "readlink help output" "FAIL" \
            "Missing expected help content"
    fi

    # Version output
    local ver_out
    ver_out=$("$binary" --version)
    if [[ "$ver_out" =~ "readlink" ]]; then
        print_test_result "readlink version output" "PASS"
    else
        print_test_result "readlink version output" "FAIL" \
            "Version: '$ver_out'"
    fi

    echo -e "${CYAN}Testing chain of symlinks...${NC}"

    # Symlink chain: link3 -> link2 -> link1 -> target
    local chain_target=$(create_temp_file "chain end")
    local chain_link1="$TEMP_DIR/readlink_chain1"
    local chain_link2="$TEMP_DIR/readlink_chain2"
    local chain_link3="$TEMP_DIR/readlink_chain3"
    ln -s "$chain_target" "$chain_link1"
    ln -s "$chain_link1" "$chain_link2"
    ln -s "$chain_link2" "$chain_link3"

    # Without canonicalize, should just show immediate target
    local chain_out=""
    local chain_err=""
    local chain_exit=""
    run_command chain_cmd chain_out chain_err chain_exit \
        "$binary" "$chain_link3"
    if [[ $chain_exit -eq 0 && "$chain_out" == "$chain_link2" ]]; then
        print_test_result "readlink chain immediate target" "PASS"
    else
        print_test_result "readlink chain immediate target" "FAIL" \
            "Expected '$chain_link2', got '$chain_out'"
    fi

    # With -f, should resolve to final target
    local chain_f_out=""
    local chain_f_err=""
    local chain_f_exit=""
    run_command chain_f_cmd chain_f_out chain_f_err chain_f_exit \
        "$binary" -f "$chain_link3"
    local chain_expected
    chain_expected=$(_canon "$chain_target")
    if [[ $chain_f_exit -eq 0 && "$chain_f_out" == "$chain_expected" ]]; then
        print_test_result "readlink -f chain resolves to end" "PASS"
    else
        print_test_result "readlink -f chain resolves to end" "FAIL" \
            "Expected '$chain_expected', got '$chain_f_out'"
    fi
}
