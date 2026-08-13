#!/usr/bin/env bash
# Integration tests for df utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_df() {
    local util="df"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should contain header fields
    local output
    output=$("$binary" 2>/dev/null)
    local exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Filesystem" && "$output" =~ "Mounted on" ]]; then
        print_test_result "df default output has expected header" "PASS"
    else
        print_test_result "df default output has expected header" "FAIL" \
            "Exit code: $exit_code"
    fi

    # Default output should show Size (human-readable is default)
    if [[ "$output" =~ "Size" ]]; then
        print_test_result "df default shows Size header" "PASS"
    else
        print_test_result "df default shows Size header" "FAIL"
    fi

    echo -e "${CYAN}Testing POSIX portability mode...${NC}"

    # -P should show 1024-blocks (POSIX mode)
    output=$("$binary" -P / 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "1024-blocks" ]]; then
        print_test_result "df -P shows 1024-blocks" "PASS"
    else
        print_test_result "df -P shows 1024-blocks" "FAIL"
    fi

    echo -e "${CYAN}Testing specific path...${NC}"

    # df / must report exactly the root filesystem: a header plus one
    # row whose last field is the mount point "/". Matching a bare "/"
    # anywhere in the output passes even when the whole mount table is
    # printed, so assert the line count and the mount-point field.
    output=$("$binary" / 2>/dev/null)
    exit_code=$?
    local line_count row_mount row_source header
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    row_mount=$(echo "$output" | sed -n '2p' | awk '{print $NF}')
    row_source=$(echo "$output" | sed -n '2p' | awk '{print $1}')
    if [[ $exit_code -eq 0 && $line_count -eq 2 && "$row_mount" == "/" &&
          -n "$row_source" ]]; then
        print_test_result "df / shows only the root filesystem" "PASS"
    else
        print_test_result "df / shows only the root filesystem" "FAIL" \
            "Exit code: $exit_code, lines: $line_count, mount: '$row_mount'"
    fi

    # The header must name the columns, not just contain a slash.
    header=$(echo "$output" | head -1)
    if [[ "$header" =~ Filesystem && "$header" =~ "Mounted on" ]]; then
        print_test_result "df / header names Filesystem and Mounted on" "PASS"
    else
        print_test_result "df / header names Filesystem and Mounted on" "FAIL" \
            "Header: $header"
    fi

    echo -e "${CYAN}Testing human-readable output...${NC}"

    # -h should show Size header instead of 1K-blocks
    output=$("$binary" -h 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Size" ]]; then
        print_test_result "df -h shows Size header" "PASS"
    else
        print_test_result "df -h shows Size header" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing type display...${NC}"

    # -T should show Type column
    output=$("$binary" -T 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Type" ]]; then
        print_test_result "df -T shows Type column" "PASS"
    else
        print_test_result "df -T shows Type column" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing inode display...${NC}"

    # -i should show Inodes header
    output=$("$binary" -i 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "Inodes" ]]; then
        print_test_result "df -i shows Inodes header" "PASS"
    else
        print_test_result "df -i shows Inodes header" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing --total flag...${NC}"

    # --total should include a "total" row
    output=$("$binary" --total 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && "$output" =~ "total" ]]; then
        print_test_result "df --total shows total row" "PASS"
    else
        print_test_result "df --total shows total row" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 1
    test_command_exit_code "df invalid flag exits 1" 1 \
        "$binary" --invalid-flag

    # Nonexistent file exits with code 1
    test_command_exit_code "df nonexistent file exits 1" 1 \
        "$binary" /nonexistent/path/file

    # ==================================================================
    # F20: POSIX -P header compliance
    # POSIX requires "1024-blocks" and "Capacity", not "1K-blocks"/"Use%"
    # ==================================================================
    echo -e "${CYAN}Testing POSIX -P header compliance...${NC}"

    output=$("$binary" -P / 2>/dev/null)
    exit_code=$?
    header=$(echo "$output" | head -1)

    # POSIX mandates "1024-blocks", not "1K-blocks"
    if [[ $exit_code -eq 0 && "$header" =~ "1024-blocks" ]]; then
        print_test_result "df -P header has POSIX 1024-blocks" "PASS"
    else
        print_test_result "df -P header has POSIX 1024-blocks" "FAIL" \
            "Header: $header"
    fi

    # POSIX mandates "Capacity", not "Use%"
    if [[ $exit_code -eq 0 && "$header" =~ "Capacity" ]]; then
        print_test_result "df -P header has POSIX Capacity" "PASS"
    else
        print_test_result "df -P header has POSIX Capacity" "FAIL" \
            "Header: $header"
    fi

    # ==================================================================
    # F21: df -n should be rejected on Linux (not a GNU flag)
    # ==================================================================
    if [[ "$(uname)" == "Linux" ]]; then
        echo -e "${CYAN}Testing -n rejected on Linux...${NC}"

        "$binary" -n / >/dev/null 2>&1
        exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            print_test_result "df -n rejected on Linux (exit 1)" "PASS"
        else
            print_test_result "df -n rejected on Linux (exit 1)" "FAIL" \
                "Exit code: $exit_code (expected 1)"
        fi
    fi

    # ==================================================================
    # F19: df -I without argument should work on macOS
    # ==================================================================
    if [[ "$(uname)" == "Darwin" ]]; then
        echo -e "${CYAN}Testing -I as boolean on macOS...${NC}"

        output=$("$binary" -I / 2>/dev/null)
        exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            print_test_result "df -I without arg succeeds on macOS" "PASS"
        else
            print_test_result "df -I without arg succeeds on macOS" "FAIL" \
                "Exit code: $exit_code (expected 0)"
        fi

        # -I must actually suppress the inode columns: BSD df resolves
        # -i/-I last-flag-wins (verified against /bin/df on macOS).
        output=$("$binary" -i -I / 2>/dev/null)
        exit_code=$?
        header=$(echo "$output" | head -1)
        if [[ $exit_code -eq 0 && ! "$header" =~ Inodes ]]; then
            print_test_result "df -i -I omits the Inodes column" "PASS"
        else
            print_test_result "df -i -I omits the Inodes column" "FAIL" \
                "Header: $header"
        fi

        output=$("$binary" -I -i / 2>/dev/null)
        header=$(echo "$output" | head -1)
        if [[ "$header" =~ Inodes ]]; then
            print_test_result "df -I -i keeps the Inodes column" "PASS"
        else
            print_test_result "df -I -i keeps the Inodes column" "FAIL" \
                "Header: $header"
        fi
    fi

    # ==================================================================
    # --output=FIELD_LIST selects and orders columns (GNU df 9.5)
    # ==================================================================
    echo -e "${CYAN}Testing --output field selection...${NC}"

    output=$("$binary" --output=source,size / 2>/dev/null)
    exit_code=$?
    header=$(echo "$output" | head -1)
    if [[ $exit_code -eq 0 && "$header" == "Filesystem"*"Size" ]]; then
        print_test_result "df --output=source,size prints only those columns" "PASS"
    else
        print_test_result "df --output=source,size prints only those columns" "FAIL" \
            "Header: $header"
    fi

    output=$("$binary" --output=target,source / 2>/dev/null)
    header=$(echo "$output" | head -1)
    if [[ "$header" == "Mounted on"*"Filesystem" ]]; then
        print_test_result "df --output honors field order" "PASS"
    else
        print_test_result "df --output honors field order" "FAIL" \
            "Header: $header"
    fi

    # Unknown field is an argument error (exit 1 by vibeutils convention)
    test_command_exit_code "df --output rejects unknown field" 1 \
        "$binary" --output=bogus /

    # -i and --output are mutually exclusive in GNU df
    test_command_exit_code "df -i --output is rejected" 1 \
        "$binary" -i --output=source /

    # ==================================================================
    # Issue #132: non-POSIX --block-size labels must follow GNU's
    # divisibility-race abbreviation (base 1000 vs 1024, ceiling
    # rounding), not the old hardcoded 512/1024/1M/1G map with a
    # "{d}B-blocks" fallback for everything else.
    #
    # Every expected value below was verified against real GNU
    # coreutils 9.4 (LC_ALL=C, native Linux host):
    #   LC_ALL=C /usr/bin/df --block-size=$n / | head -1
    # ==================================================================
    echo -e "${CYAN}Testing --block-size header label abbreviation (issue #132)...${NC}"

    # bs_cases: "block-size-arg:expected-label" pairs.
    local bs_cases=(
        "512:512B-blocks"     # regression guard (already correct today)
        "999:999B-blocks"     # regression guard
        "1024:1K-blocks"      # regression guard
        "1000:1kB-blocks"     # was 1000B-blocks
        "2000:2kB-blocks"     # was 2000B-blocks
        "2048:2K-blocks"      # was 2048B-blocks
        "65536:64K-blocks"    # was 65536B-blocks
        "1500:1.5kB-blocks"   # non-integer mantissa
        "1023:1.1kB-blocks"   # ceiling rounding, not nearest (1.0 would be wrong)
        "1536:1.6kB-blocks"   # ceiling rounding, not nearest (1.5 would be wrong)
        "9950:10kB-blocks"    # tenths carry into the integer part
        "10001:11kB-blocks"   # integer ceiling once mantissa >= 10
        "123456:124kB-blocks" # integer ceiling
        "1000000:1MB-blocks"
        # TIE CASE: exactly 1000K, but the divisibility race ties and a
        # tie goes to base 1000 -- NOT 1000K. A naive "exact multiple of
        # 1024" rule gets this backwards.
        "1024000:1.1MB-blocks"
        # ANTI-TIE: exactly 1000M, base 1024 wins outright; a 4-digit
        # base-1024 mantissa (1000) is legal here.
        "1048576000:1000M-blocks"
        "1025024:1001K-blocks"       # 4-digit base-1024 mantissa
        "999999999:1GB-blocks"       # integer ceiling carries into next exponent
        "1073741824:1G-blocks"
        "1099511627776:1T-blocks"
        "1152921504606846976:1E-blocks" # max base-1024 unit
        "1:1B-blocks"
    )

    local bs_case bs_arg bs_expected
    for bs_case in "${bs_cases[@]}"; do
        bs_arg="${bs_case%%:*}"
        bs_expected="${bs_case#*:}"
        output=$("$binary" --block-size="$bs_arg" / 2>/dev/null)
        header=$(echo "$output" | head -1)
        if [[ "$header" == *"$bs_expected"* ]]; then
            print_test_result "df --block-size=$bs_arg -> $bs_expected" "PASS"
        else
            print_test_result "df --block-size=$bs_arg -> $bs_expected" "FAIL" \
                "Header: $header"
        fi
    done

    # POSIX mode must stay unabbreviated even for a value that would
    # otherwise abbreviate outside -P.
    output=$("$binary" -P --block-size=2000 / 2>/dev/null)
    header=$(echo "$output" | head -1)
    if [[ "$header" == *"2000-blocks"* ]]; then
        print_test_result "df -P --block-size=2000 stays unabbreviated" "PASS"
    else
        print_test_result "df -P --block-size=2000 stays unabbreviated" "FAIL" \
            "Header: $header"
    fi

    # --block-size=0 is invalid: reject with exit 1 and a stderr message
    # (consistency with PR #134).
    local bs0_stdout bs0_stderr bs0_exit bs0_cmd
    run_command bs0_cmd bs0_stdout bs0_stderr bs0_exit \
        "$binary" --block-size=0 /
    if [[ $bs0_exit -eq 1 && "$bs0_stderr" == *"invalid --block-size argument"* ]]; then
        print_test_result "df --block-size=0 rejected with exit 1" "PASS"
    else
        print_test_result "df --block-size=0 rejected with exit 1" "FAIL" \
            "Exit: $bs0_exit, stderr: $bs0_stderr"
    fi

    # ==================================================================
    # Issue #138: the ceiling-divide `bytes + display_block - 1` overflows
    # u64 when display_block is near u64::MAX, so df panics with 'integer
    # overflow' instead of printing a table. Two identical-shape sites:
    # src/df.zig:1155 (formatSize, the default and --total per-fs row) and
    # src/df.zig:1873 (printTotal_formatField, only reachable via --total's
    # total row -- a fix touching only formatSize leaves this one panicking).
    #
    # Expected values pinned against real GNU coreutils 9.4, LC_ALL=C, on
    # this host:
    #   LC_ALL=C /usr/bin/df --block-size=18446744073709551615 /
    #     Filesystem     19EB-blocks  Used Available Use% Mounted on
    #     /dev/vda                 1     1         1  40% /
    #   LC_ALL=C /usr/bin/df --block-size=9223372036854775807 /
    #     Filesystem     9.3EB-blocks  Used Available Use% Mounted on
    #     /dev/vda                  1     1         1  40% /
    #   LC_ALL=C /usr/bin/df --total --block-size=18446744073709551615 /
    #     Filesystem     19EB-blocks  Used Available Use% Mounted on
    #     /dev/vda                 1     1         1  40% /
    #     total                    1     1         1  40% -
    # (size/used/avail all ceil to exactly 1 block for any nonzero byte
    # count against a block size that large; Use% varies by host disk
    # usage and is intentionally not asserted below.)
    # ==================================================================
    echo -e "${CYAN}Testing --block-size overflow safety (issue #138)...${NC}"

    local ov1_cmd ov1_stdout ov1_stderr ov1_exit
    run_command ov1_cmd ov1_stdout ov1_stderr ov1_exit \
        "$binary" --block-size=18446744073709551615 /
    if [[ $ov1_exit -eq 0 && "$ov1_stdout" == *"19EB-blocks"* && \
          "$ov1_stderr" != *"panic"* ]]; then
        print_test_result "df --block-size=u64max does not panic, exit 0" "PASS"
    else
        print_test_result "df --block-size=u64max does not panic, exit 0" "FAIL" \
            "Exit: $ov1_exit, stdout: $ov1_stdout, stderr: $ov1_stderr"
    fi

    # Ceiling rounding: size/used/avail columns must all be exactly 1 (not
    # 0, and not a wrapped garbage value from the overflow).
    local ov1_row ov1_size ov1_used ov1_avail
    ov1_row=$(sed -n '2p' <<<"$ov1_stdout")
    ov1_size=$(awk '{print $2}' <<<"$ov1_row")
    ov1_used=$(awk '{print $3}' <<<"$ov1_row")
    ov1_avail=$(awk '{print $4}' <<<"$ov1_row")
    if [[ "$ov1_size" == "1" && "$ov1_used" == "1" && "$ov1_avail" == "1" ]]; then
        print_test_result "df --block-size=u64max ceils size/used/avail to 1" "PASS"
    else
        print_test_result "df --block-size=u64max ceils size/used/avail to 1" "FAIL" \
            "Row: $ov1_row"
    fi

    local ov2_cmd ov2_stdout ov2_stderr ov2_exit
    run_command ov2_cmd ov2_stdout ov2_stderr ov2_exit \
        "$binary" --block-size=9223372036854775807 /
    if [[ $ov2_exit -eq 0 && "$ov2_stdout" == *"9.3EB-blocks"* && \
          "$ov2_stderr" != *"panic"* ]]; then
        print_test_result "df --block-size=2^63-1 does not panic, exit 0" "PASS"
    else
        print_test_result "df --block-size=2^63-1 does not panic, exit 0" "FAIL" \
            "Exit: $ov2_exit, stdout: $ov2_stdout, stderr: $ov2_stderr"
    fi

    # Pin the exact GNU columns for this boundary case too (size/used/avail
    # all ceil to 1), not just exit-0 -- otherwise this near-vacuous check
    # (it already passes on unfixed code, see the unit-test comment above)
    # would not constrain behavior at all.
    local ov2_row ov2_size ov2_used ov2_avail
    ov2_row=$(sed -n '2p' <<<"$ov2_stdout")
    ov2_size=$(awk '{print $2}' <<<"$ov2_row")
    ov2_used=$(awk '{print $3}' <<<"$ov2_row")
    ov2_avail=$(awk '{print $4}' <<<"$ov2_row")
    if [[ "$ov2_size" == "1" && "$ov2_used" == "1" && "$ov2_avail" == "1" ]]; then
        print_test_result "df --block-size=2^63-1 ceils size/used/avail to 1" "PASS"
    else
        print_test_result "df --block-size=2^63-1 ceils size/used/avail to 1" "FAIL" \
            "Row: $ov2_row"
    fi

    # --total exercises the SECOND overflow site (printTotal_formatField,
    # src/df.zig:1873), a different function from formatSize.
    local ov3_cmd ov3_stdout ov3_stderr ov3_exit
    run_command ov3_cmd ov3_stdout ov3_stderr ov3_exit \
        "$binary" --total --block-size=18446744073709551615 /
    if [[ $ov3_exit -eq 0 && "$ov3_stderr" != *"panic"* && \
          "$ov3_stdout" == *"total"* ]]; then
        print_test_result "df --total --block-size=u64max does not panic (site 2)" "PASS"
    else
        print_test_result "df --total --block-size=u64max does not panic (site 2)" "FAIL" \
            "Exit: $ov3_exit, stdout: $ov3_stdout, stderr: $ov3_stderr"
    fi

    local ov3_total_row ov3_total_size ov3_total_used ov3_total_avail
    # awk (not grep) so an empty/missing total row (today's red state,
    # where the process panics before printing anything) yields an empty
    # string instead of a nonzero exit that would abort the whole suite
    # under `set -euo pipefail` (test_runner.sh invokes test_df bare).
    ov3_total_row=$(awk '/^total/' <<<"$ov3_stdout")
    ov3_total_size=$(awk '{print $2}' <<<"$ov3_total_row")
    ov3_total_used=$(awk '{print $3}' <<<"$ov3_total_row")
    ov3_total_avail=$(awk '{print $4}' <<<"$ov3_total_row")
    if [[ "$ov3_total_size" == "1" && "$ov3_total_used" == "1" && "$ov3_total_avail" == "1" ]]; then
        print_test_result "df --total --block-size=u64max ceils total row to 1" "PASS"
    else
        print_test_result "df --total --block-size=u64max ceils total row to 1" "FAIL" \
            "Row: $ov3_total_row"
    fi

    # REGRESSION GUARD: ordinary block sizes must be unaffected by the fix.
    # Compare only stable content (header line + total-size column), not
    # the whole raw output: Used/Available come from a fresh statfs on
    # each of the two invocations and can drift by a block under
    # concurrent disk activity (e.g. sibling worktrees building at once),
    # which would make a full-output diff spuriously flaky.
    local reg1k_cmd reg1k_stdout reg1k_stderr reg1k_exit
    local regk_cmd regk_stdout regk_stderr regk_exit
    run_command reg1k_cmd reg1k_stdout reg1k_stderr reg1k_exit \
        "$binary" --block-size=1024 /
    run_command regk_cmd regk_stdout regk_stderr regk_exit \
        "$binary" -k /
    local reg1k_header regk_header reg1k_size regk_size
    reg1k_header=$(sed -n '1p' <<<"$reg1k_stdout")
    regk_header=$(sed -n '1p' <<<"$regk_stdout")
    reg1k_size=$(awk 'NR==2{print $2}' <<<"$reg1k_stdout")
    regk_size=$(awk 'NR==2{print $2}' <<<"$regk_stdout")
    if [[ "$reg1k_exit" -eq 0 && "$regk_exit" -eq 0 && \
          "$reg1k_header" == "$regk_header" && \
          "$reg1k_size" == "$regk_size" && \
          "$reg1k_header" == *"1K-blocks"* ]]; then
        print_test_result "df --block-size=1024 matches -k output (regression)" "PASS"
    else
        print_test_result "df --block-size=1024 matches -k output (regression)" "FAIL" \
            "block-size=1024 header/size: $reg1k_header / $reg1k_size | -k header/size: $regk_header / $regk_size"
    fi

    # REGRESSION GUARD: 1E block-size labeling from #132 must still work;
    # the overflow fix touches only the numeric column, not the label.
    local reg1e_cmd reg1e_stdout reg1e_stderr reg1e_exit
    run_command reg1e_cmd reg1e_stdout reg1e_stderr reg1e_exit \
        "$binary" --block-size=1152921504606846976 /
    if [[ $reg1e_exit -eq 0 && "$reg1e_stdout" == *"1E-blocks"* ]]; then
        print_test_result "df --block-size=1E still works and labels 1E-blocks (regression)" "PASS"
    else
        print_test_result "df --block-size=1E still works and labels 1E-blocks (regression)" "FAIL" \
            "Exit: $reg1e_exit, output: $reg1e_stdout"
    fi

    # REGRESSION GUARD: --total -k must be unaffected by the
    # printTotal_formatField rewrite for ordinary block sizes.
    local regtk_cmd regtk_stdout regtk_stderr regtk_exit
    run_command regtk_cmd regtk_stdout regtk_stderr regtk_exit \
        "$binary" --total -k /
    if [[ $regtk_exit -eq 0 && "$regtk_stdout" == *"total"* && "$regtk_stdout" == *"1K-blocks"* ]]; then
        print_test_result "df --total -k totals unchanged (regression)" "PASS"
    else
        print_test_result "df --total -k totals unchanged (regression)" "FAIL" \
            "Exit: $regtk_exit, output: $regtk_stdout"
    fi
}
