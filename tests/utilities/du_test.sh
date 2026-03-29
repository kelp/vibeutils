#!/usr/bin/env bash
# Integration tests for du utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_du() {
    local util="du"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Create temp directory structure for testing
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/subdir"
    echo "hello world" > "$tmpdir/file1.txt"
    echo "test data here" > "$tmpdir/subdir/file2.txt"

    # Default output should produce non-empty output
    local output
    output=$("$binary" "$tmpdir" 2>/dev/null)
    local exit_code=$?
    if [[ $exit_code -eq 0 && -n "$output" ]]; then
        print_test_result "du default output is non-empty" "PASS"
    else
        print_test_result "du default output is non-empty" "FAIL" \
            "Exit code: $exit_code, output: '$output'"
    fi

    echo -e "${CYAN}Testing -s (summarize)...${NC}"

    output=$("$binary" -s "$tmpdir" 2>/dev/null)
    local line_count
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    if [[ "$line_count" -eq 1 ]]; then
        print_test_result "du -s produces single line" "PASS"
    else
        print_test_result "du -s produces single line" "FAIL" \
            "Expected 1 line, got $line_count"
    fi

    echo -e "${CYAN}Testing -h (human-readable)...${NC}"

    output=$("$binary" -sh "$tmpdir" 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 0 && -n "$output" ]]; then
        print_test_result "du -h produces output" "PASS"
    else
        print_test_result "du -h produces output" "FAIL" \
            "Exit code: $exit_code"
    fi

    echo -e "${CYAN}Testing -b (bytes/apparent size)...${NC}"

    # Create a file with known size
    echo -n "12345" > "$tmpdir/exact.txt"
    output=$("$binary" -b "$tmpdir/exact.txt" 2>/dev/null)
    if [[ "$output" =~ ^5 ]]; then
        print_test_result "du -b shows apparent size in bytes" "PASS"
    else
        print_test_result "du -b shows apparent size in bytes" "FAIL" \
            "Expected output starting with 5, got: '$output'"
    fi

    echo -e "${CYAN}Testing -c (total)...${NC}"

    output=$("$binary" -c "$tmpdir" 2>/dev/null)
    if echo "$output" | grep -q "total"; then
        print_test_result "du -c shows total line" "PASS"
    else
        print_test_result "du -c shows total line" "FAIL" \
            "Output missing 'total': '$output'"
    fi

    echo -e "${CYAN}Testing -a (all files)...${NC}"

    output=$("$binary" -a "$tmpdir" 2>/dev/null)
    if echo "$output" | grep -q "file1.txt"; then
        print_test_result "du -a shows individual files" "PASS"
    else
        print_test_result "du -a shows individual files" "FAIL" \
            "Output missing file1.txt"
    fi

    echo -e "${CYAN}Testing -d (max-depth)...${NC}"

    output=$("$binary" -d 0 "$tmpdir" 2>/dev/null)
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    if [[ "$line_count" -eq 1 ]]; then
        print_test_result "du -d 0 produces single line" "PASS"
    else
        print_test_result "du -d 0 produces single line" "FAIL" \
            "Expected 1 line, got $line_count"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "du invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    # Nonexistent path exits with code 1
    test_command_exit_code "du nonexistent path exits 1" 1 \
        "$binary" /nonexistent/path/xyz

    echo -e "${CYAN}Testing hardlink dedup...${NC}"

    # Use separate directories to avoid directory metadata size changes
    local hldir_hardlink
    hldir_hardlink=$(mktemp -d)
    local hldir_copy
    hldir_copy=$(mktemp -d)

    # Create identical content: one with hardlink, one with copy
    dd if=/dev/urandom bs=1024 count=1 of="$hldir_hardlink/original.dat" 2>/dev/null
    ln "$hldir_hardlink/original.dat" "$hldir_hardlink/link.dat"
    cp "$hldir_hardlink/original.dat" "$hldir_copy/original.dat"
    cp "$hldir_hardlink/original.dat" "$hldir_copy/copy.dat"

    local size_hardlink
    size_hardlink=$("$binary" -sb "$hldir_hardlink" 2>/dev/null | tail -1 | awk '{print $1}')
    local size_copy
    size_copy=$("$binary" -sb "$hldir_copy" 2>/dev/null | tail -1 | awk '{print $1}')

    # Hardlink dir should be smaller (file counted once); copy dir counts both
    if [[ "$size_hardlink" -lt "$size_copy" ]]; then
        print_test_result "du deduplicates hardlinks" "PASS"
    else
        print_test_result "du deduplicates hardlinks" "FAIL" \
            "Hardlink dir: $size_hardlink, copy dir: $size_copy (expected hardlink < copy)"
    fi

    rm -rf "$hldir_hardlink" "$hldir_copy"

    echo -e "${CYAN}Testing --color option...${NC}"

    # --color=never produces no ANSI escapes
    output=$("$binary" --color=never -s "$tmpdir" 2>/dev/null)
    if ! printf '%s' "$output" | grep -q $'\033\['; then
        print_test_result "du --color=never produces no ANSI escapes" "PASS"
    else
        print_test_result "du --color=never produces no ANSI escapes" "FAIL" \
            "Output contains ANSI escapes: '$output'"
    fi

    # --color=always produces ANSI escapes
    output=$("$binary" --color=always -s "$tmpdir" 2>/dev/null)
    if printf '%s' "$output" | grep -q $'\033\['; then
        print_test_result "du --color=always produces ANSI escapes" "PASS"
    else
        print_test_result "du --color=always produces ANSI escapes" "FAIL" \
            "Output missing ANSI escapes: '$output'"
    fi

    # --color=auto in a non-TTY context produces no ANSI escapes
    output=$("$binary" --color=auto -s "$tmpdir" 2>/dev/null)
    if ! printf '%s' "$output" | grep -q $'\033\['; then
        print_test_result "du --color=auto (non-TTY) produces no ANSI escapes" "PASS"
    else
        print_test_result "du --color=auto (non-TTY) produces no ANSI escapes" "FAIL" \
            "Output contains ANSI escapes in non-TTY context: '$output'"
    fi

    # Invalid --color value exits with error
    test_command_exit_code "du --color=invalid exits 2" 2 \
        "$binary" --color=invalid

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: du on a temp directory should produce output
    # Safety net for allocator change (arena allocator migration)
    local reg_tmpdir
    reg_tmpdir=$(mktemp -d)
    echo "regression test data" > "$reg_tmpdir/regfile.txt"
    local reg_output
    reg_output=$("$binary" "$reg_tmpdir" 2>/dev/null)
    local reg_exit=$?
    if [[ $reg_exit -eq 0 && -n "$reg_output" ]]; then
        print_test_result "du basic operation after allocator change (regression)" "PASS"
    else
        print_test_result "du basic operation after allocator change (regression)" "FAIL" \
            "Exit code: $reg_exit, output: '$reg_output'"
    fi
    rm -rf "$reg_tmpdir"

    # ================================================================
    # F22: du -L should not double-count symlink targets
    # ================================================================
    echo -e "${CYAN}Testing -L symlink dedup (F22)...${NC}"

    local f22_dir
    f22_dir=$(mktemp -d)
    echo -n "AAAAAAAAAA" > "$f22_dir/realfile.txt"   # exactly 10 bytes
    ln -s realfile.txt "$f22_dir/linkfile.txt"

    # GNU du -L -b -s counts the file once through both paths
    local gnu_size vibe_size
    gnu_size=$(du -L -b -s "$f22_dir" 2>/dev/null | awk '{print $1}')
    vibe_size=$("$binary" -L -b -s "$f22_dir" 2>/dev/null | awk '{print $1}')

    if [[ "$vibe_size" -eq "$gnu_size" ]]; then
        print_test_result "du -L does not double-count symlink targets" "PASS"
    else
        print_test_result "du -L does not double-count symlink targets" "FAIL" \
            "Expected $gnu_size (GNU), got $vibe_size (vibeutils)"
    fi
    rm -rf "$f22_dir"

    # ================================================================
    # F23: du -b should not inflate directory size with metadata
    # ================================================================
    echo -e "${CYAN}Testing -b directory apparent size (F23)...${NC}"

    local f23_dir
    f23_dir=$(mktemp -d)
    echo -n "AAAAAAAAAA" > "$f23_dir/file.txt"   # exactly 10 bytes

    gnu_size=$(du -b -s "$f23_dir" 2>/dev/null | awk '{print $1}')
    vibe_size=$("$binary" -b -s "$f23_dir" 2>/dev/null | awk '{print $1}')

    if [[ "$vibe_size" -eq "$gnu_size" ]]; then
        print_test_result "du -b directory total matches GNU (no dir metadata)" "PASS"
    else
        print_test_result "du -b directory total matches GNU (no dir metadata)" "FAIL" \
            "Expected $gnu_size (GNU), got $vibe_size (vibeutils)"
    fi
    rm -rf "$f23_dir"

    # ================================================================
    # F24: du -S should show sum of direct files, not dir inode size
    # ================================================================
    echo -e "${CYAN}Testing -S separate-dirs (F24)...${NC}"

    local f24_dir
    f24_dir=$(mktemp -d)
    mkdir "$f24_dir/sub"
    echo -n "AAAAAAAAAA" > "$f24_dir/topfile.txt"       # 10 bytes
    echo -n "BBBBBBBBBB" > "$f24_dir/sub/subfile.txt"    # 10 bytes

    # Compare -S output for top-level directory
    local gnu_top vibe_top
    gnu_top=$(du -S -b "$f24_dir" 2>/dev/null | grep "$f24_dir$" | awk '{print $1}')
    vibe_top=$("$binary" -S -b "$f24_dir" 2>/dev/null | grep "$f24_dir$" | awk '{print $1}')

    if [[ "$vibe_top" -eq "$gnu_top" ]]; then
        print_test_result "du -S top dir shows direct file sum (matches GNU)" "PASS"
    else
        print_test_result "du -S top dir shows direct file sum (matches GNU)" "FAIL" \
            "Expected $gnu_top (GNU), got $vibe_top (vibeutils)"
    fi

    # Compare -S output for subdirectory
    local gnu_sub vibe_sub
    gnu_sub=$(du -S -b "$f24_dir/sub" 2>/dev/null | grep "sub$" | awk '{print $1}')
    vibe_sub=$("$binary" -S -b "$f24_dir" 2>/dev/null | grep "sub$" | awk '{print $1}')

    if [[ "$vibe_sub" -eq "$gnu_sub" ]]; then
        print_test_result "du -S subdir shows direct file sum (matches GNU)" "PASS"
    else
        print_test_result "du -S subdir shows direct file sum (matches GNU)" "FAIL" \
            "Expected $gnu_sub (GNU), got $vibe_sub (vibeutils)"
    fi
    rm -rf "$f24_dir"

    # Cleanup
    rm -rf "$tmpdir"
}
