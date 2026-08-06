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
}
