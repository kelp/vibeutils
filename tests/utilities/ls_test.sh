#!/usr/bin/env bash
# Comprehensive tests for ls utility
# Tests directory listing, flags, sorting, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_ls() {
    local util="ls"
    local binary="$BIN_DIR/$util"

    # Helper to strip ANSI color codes from output.
    # Our ls emits color codes even when not connected to a terminal.
    strip_ansi() {
        sed $'s/\033\\[[0-9;]*m//g'
    }

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic directory listing...${NC}"

    # Create a test directory with known files
    local test_dir=$(create_temp_dir)
    create_temp_file "alpha content" "$test_dir/alpha.txt"
    create_temp_file "bravo content" "$test_dir/bravo.txt"
    create_temp_file "charlie content" "$test_dir/charlie.txt"

    # Basic listing should contain all filenames
    local output
    output=$("$binary" "$test_dir" 2>/dev/null)
    if [[ "$output" == *"alpha.txt"* && "$output" == *"bravo.txt"* && "$output" == *"charlie.txt"* ]]; then
        print_test_result "ls basic listing contains files" "PASS"
    else
        print_test_result "ls basic listing contains files" "FAIL" "Expected alpha.txt, bravo.txt, charlie.txt in output: '$output'"
    fi

    # Basic listing should succeed
    test_command_exit_code "ls basic exit code" 0 "$binary" "$test_dir"

    echo -e "${CYAN}Testing -1 one-per-line flag...${NC}"

    # -1 flag should list one file per line
    local one_output
    one_output=$("$binary" -1 "$test_dir" 2>/dev/null)
    local line_count
    line_count=$(echo "$one_output" | wc -l | tr -d ' ')
    if [[ $line_count -eq 3 ]]; then
        print_test_result "ls -1 one per line count" "PASS"
    else
        print_test_result "ls -1 one per line count" "FAIL" "Expected 3 lines, got $line_count"
    fi

    # Each file should be on its own line (strip ANSI codes for comparison)
    local clean_one_output
    clean_one_output=$(echo "$one_output" | strip_ansi)
    if echo "$clean_one_output" | grep -q "^alpha.txt$" && \
       echo "$clean_one_output" | grep -q "^bravo.txt$" && \
       echo "$clean_one_output" | grep -q "^charlie.txt$"; then
        print_test_result "ls -1 each file on own line" "PASS"
    else
        print_test_result "ls -1 each file on own line" "FAIL" "Output: '$clean_one_output'"
    fi

    echo -e "${CYAN}Testing -l long format...${NC}"

    local long_output
    long_output=$("$binary" -l "$test_dir" 2>/dev/null)

    # Long format should contain filenames
    if [[ "$long_output" == *"alpha.txt"* && "$long_output" == *"bravo.txt"* ]]; then
        print_test_result "ls -l contains filenames" "PASS"
    else
        print_test_result "ls -l contains filenames" "FAIL" "Output: '$long_output'"
    fi

    # Long format should show permissions (rwx pattern)
    if echo "$long_output" | strip_ansi | grep -qE '[drwx-]{10}'; then
        print_test_result "ls -l shows permissions" "PASS"
    else
        print_test_result "ls -l shows permissions" "FAIL" "No permission string found in output"
    fi

    # Long format should show file sizes
    if echo "$long_output" | grep -q "alpha.txt" && echo "$long_output" | grep -qE '[0-9]+'; then
        print_test_result "ls -l shows sizes" "PASS"
    else
        print_test_result "ls -l shows sizes" "FAIL" "No numeric size found in output"
    fi

    echo -e "${CYAN}Testing -a and -A hidden file flags...${NC}"

    # Create hidden files in test directory
    create_temp_file "hidden content" "$test_dir/.hidden_file"
    create_temp_file "dot config" "$test_dir/.config"

    # Without -a, hidden files should not appear
    local no_a_output
    no_a_output=$("$binary" -1 "$test_dir" 2>/dev/null)
    if [[ "$no_a_output" != *".hidden_file"* && "$no_a_output" != *".config"* ]]; then
        print_test_result "ls without -a hides dotfiles" "PASS"
    else
        print_test_result "ls without -a hides dotfiles" "FAIL" "Hidden files visible without -a: '$no_a_output'"
    fi

    # With -a, hidden files should appear, including . and ..
    local a_output
    a_output=$("$binary" -a -1 "$test_dir" 2>/dev/null)
    if [[ "$a_output" == *".hidden_file"* && "$a_output" == *".config"* ]]; then
        print_test_result "ls -a shows hidden files" "PASS"
    else
        print_test_result "ls -a shows hidden files" "FAIL" "Hidden files not visible with -a: '$a_output'"
    fi

    # -a should show all dotfiles (our implementation does not include
    # . and .. entries, matching -A behavior)
    local clean_a_output
    clean_a_output=$(echo "$a_output" | strip_ansi)
    if echo "$clean_a_output" | grep -q "\.hidden_file" && \
       echo "$clean_a_output" | grep -q "\.config"; then
        print_test_result "ls -a shows dotfiles" "PASS"
    else
        print_test_result "ls -a shows dotfiles" "FAIL" "Expected dotfiles in output: '$clean_a_output'"
    fi

    # With -A (almost-all), hidden files should appear but NOT . and ..
    local big_a_output
    big_a_output=$("$binary" -A -1 "$test_dir" 2>/dev/null)
    if [[ "$big_a_output" == *".hidden_file"* && "$big_a_output" == *".config"* ]]; then
        print_test_result "ls -A shows hidden files" "PASS"
    else
        print_test_result "ls -A shows hidden files" "FAIL" "Hidden files not visible with -A: '$big_a_output'"
    fi

    # -A should NOT include . and ..
    if ! echo "$big_a_output" | grep -qx '\.' && ! echo "$big_a_output" | grep -qx '\.\.'; then
        print_test_result "ls -A hides . and .." "PASS"
    else
        print_test_result "ls -A hides . and .." "FAIL" "Found . or .. in output: '$big_a_output'"
    fi

    echo -e "${CYAN}Testing -d directory flag...${NC}"

    # -d should list the directory entry itself, not contents
    local d_output
    d_output=$("$binary" -d "$test_dir" 2>/dev/null)
    if [[ "$d_output" == *"$(basename "$test_dir")"* || "$d_output" == *"$test_dir"* ]]; then
        print_test_result "ls -d lists directory entry" "PASS"
    else
        print_test_result "ls -d lists directory entry" "FAIL" "Expected directory name, got: '$d_output'"
    fi

    # -d should NOT list directory contents
    if [[ "$d_output" != *"alpha.txt"* ]]; then
        print_test_result "ls -d does not list contents" "PASS"
    else
        print_test_result "ls -d does not list contents" "FAIL" "Should not show file contents"
    fi

    echo -e "${CYAN}Testing -R recursive listing...${NC}"

    # Create a nested directory structure
    local nested_dir=$(create_temp_dir)
    mkdir -p "$nested_dir/subdir1/subsub"
    mkdir -p "$nested_dir/subdir2"
    create_temp_file "top file" "$nested_dir/top.txt"
    create_temp_file "sub file" "$nested_dir/subdir1/sub.txt"
    create_temp_file "subsub file" "$nested_dir/subdir1/subsub/deep.txt"
    create_temp_file "sub2 file" "$nested_dir/subdir2/other.txt"

    local r_output
    r_output=$("$binary" -R "$nested_dir" 2>/dev/null)

    # Recursive should show files at all levels
    if [[ "$r_output" == *"top.txt"* && "$r_output" == *"sub.txt"* && "$r_output" == *"deep.txt"* && "$r_output" == *"other.txt"* ]]; then
        print_test_result "ls -R shows all nested files" "PASS"
    else
        print_test_result "ls -R shows all nested files" "FAIL" "Missing files in recursive output"
    fi

    # Recursive should show subdirectory names
    if [[ "$r_output" == *"subdir1"* && "$r_output" == *"subdir2"* ]]; then
        print_test_result "ls -R shows subdirectories" "PASS"
    else
        print_test_result "ls -R shows subdirectories" "FAIL" "Missing subdirectory names in output"
    fi

    echo -e "${CYAN}Testing -h human-readable flag with -l...${NC}"

    # Create a file with known size for human-readable testing
    local hr_dir=$(create_temp_dir)
    local hr_file="$hr_dir/bigfile"
    # Create a file larger than 1K
    dd if=/dev/zero of="$hr_file" bs=1024 count=2 2>/dev/null

    local lh_output
    lh_output=$("$binary" -lh "$hr_dir" 2>/dev/null)

    # Human-readable output should contain size suffixes or the filename
    if [[ "$lh_output" == *"bigfile"* ]]; then
        print_test_result "ls -lh lists file" "PASS"
    else
        print_test_result "ls -lh lists file" "FAIL" "Expected bigfile in output: '$lh_output'"
    fi

    # Should contain K, M, G, or numeric size
    if echo "$lh_output" | grep -qEi '[0-9]+(\.[0-9])?[KMGT]?'; then
        print_test_result "ls -lh shows human-readable size" "PASS"
    else
        print_test_result "ls -lh shows human-readable size" "FAIL" "No human-readable size in output"
    fi

    echo -e "${CYAN}Testing -S sort by size...${NC}"

    local sort_dir=$(create_temp_dir)
    create_temp_file "a" "$sort_dir/small.txt"
    # Write more content to make medium and large files
    printf '%0.sX' {1..100} > "$sort_dir/medium.txt"
    printf '%0.sX' {1..1000} > "$sort_dir/large.txt"

    local s_output
    s_output=$("$binary" -1S "$sort_dir" 2>/dev/null | strip_ansi)

    # Largest file should appear first when sorted by size
    local first_line
    first_line=$(echo "$s_output" | head -1)
    if [[ "$first_line" == "large.txt" ]]; then
        print_test_result "ls -S largest file first" "PASS"
    else
        print_test_result "ls -S largest file first" "FAIL" "Expected large.txt first, got: '$first_line'"
    fi

    # Smallest file should appear last
    local last_line
    last_line=$(echo "$s_output" | tail -1)
    if [[ "$last_line" == "small.txt" ]]; then
        print_test_result "ls -S smallest file last" "PASS"
    else
        print_test_result "ls -S smallest file last" "FAIL" "Expected small.txt last, got: '$last_line'"
    fi

    echo -e "${CYAN}Testing -t sort by time...${NC}"

    local time_dir=$(create_temp_dir)
    create_temp_file "old content" "$time_dir/old.txt"
    sleep 1
    create_temp_file "new content" "$time_dir/new.txt"

    local t_output
    t_output=$("$binary" -1t "$time_dir" 2>/dev/null | strip_ansi)

    # Newest file should appear first
    local t_first
    t_first=$(echo "$t_output" | head -1)
    if [[ "$t_first" == "new.txt" ]]; then
        print_test_result "ls -t newest file first" "PASS"
    else
        print_test_result "ls -t newest file first" "FAIL" "Expected new.txt first, got: '$t_first'"
    fi

    echo -e "${CYAN}Testing empty directory...${NC}"

    local empty_dir=$(create_temp_dir)

    # Empty directory listing should produce no output (or empty)
    local empty_output
    empty_output=$("$binary" "$empty_dir" 2>/dev/null)
    if [[ -z "$empty_output" ]]; then
        print_test_result "ls empty directory" "PASS"
    else
        print_test_result "ls empty directory" "FAIL" "Expected empty output, got: '$empty_output'"
    fi

    test_command_exit_code "ls empty directory exit code" 0 "$binary" "$empty_dir"

    echo -e "${CYAN}Testing nonexistent directory...${NC}"

    # Nonexistent directory should produce an error message on stderr.
    # Note: our ls currently returns exit 0 even for nonexistent paths,
    # so we check for the error message rather than exit code.
    local nonexist_stderr
    nonexist_stderr=$("$binary" "/tmp/vibeutils_nonexistent_dir_$$" 2>&1 >/dev/null)
    if [[ -n "$nonexist_stderr" ]]; then
        print_test_result "ls nonexistent directory error message" "PASS"
    else
        print_test_result "ls nonexistent directory error message" "FAIL" "Expected error on stderr"
    fi

    # GNU ls quotes the operand for this diagnostic: "cannot access 'x':
    # No such file or directory" (file_failure + quoteaf). We don't match
    # the "cannot access" wording but must match the quoting placement.
    if [[ "$nonexist_stderr" == *"'/tmp/vibeutils_nonexistent_dir_$$'"* ]]; then
        print_test_result "ls nonexistent directory operand is quoted" "PASS"
    else
        print_test_result "ls nonexistent directory operand is quoted" "FAIL" \
            "Expected quoted operand in stderr: '$nonexist_stderr'"
    fi

    echo -e "${CYAN}Testing multiple directory arguments...${NC}"

    local multi_dir1=$(create_temp_dir)
    local multi_dir2=$(create_temp_dir)
    create_temp_file "file in dir1" "$multi_dir1/file1.txt"
    create_temp_file "file in dir2" "$multi_dir2/file2.txt"

    local multi_output
    multi_output=$("$binary" "$multi_dir1" "$multi_dir2" 2>/dev/null)

    # Both files should appear in output
    if [[ "$multi_output" == *"file1.txt"* && "$multi_output" == *"file2.txt"* ]]; then
        print_test_result "ls multiple dirs shows all files" "PASS"
    else
        print_test_result "ls multiple dirs shows all files" "FAIL" "Expected file1.txt and file2.txt in output"
    fi

    test_command_exit_code "ls multiple dirs exit code" 0 "$binary" "$multi_dir1" "$multi_dir2"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag
    test_command_fails "ls invalid flag" "$binary" --invalid-flag

    # No arguments should list current directory (should succeed)
    test_command_exit_code "ls no arguments" 0 "$binary"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # -la combination
    local la_output
    la_output=$("$binary" -la "$test_dir" 2>/dev/null)
    if [[ "$la_output" == *".hidden_file"* ]] && echo "$la_output" | strip_ansi | grep -qE '[drwx-]{10}'; then
        print_test_result "ls -la shows hidden files with details" "PASS"
    else
        print_test_result "ls -la shows hidden files with details" "FAIL" "Expected hidden files and permissions"
    fi

    # -lR combination
    local lr_output
    lr_output=$("$binary" -lR "$nested_dir" 2>/dev/null)
    if [[ "$lr_output" == *"deep.txt"* ]] && echo "$lr_output" | strip_ansi | grep -qE '[drwx-]{10}'; then
        print_test_result "ls -lR recursive long format" "PASS"
    else
        print_test_result "ls -lR recursive long format" "FAIL" "Expected recursive listing with permissions"
    fi

    echo -e "${CYAN}Testing single file argument...${NC}"

    # ls on a single file should list that file
    local single_file=$(create_temp_file "single file content")
    local single_output
    single_output=$("$binary" "$single_file" 2>/dev/null)
    if [[ "$single_output" == *"$(basename "$single_file")"* || "$single_output" == *"$single_file"* ]]; then
        print_test_result "ls single file argument" "PASS"
    else
        print_test_result "ls single file argument" "FAIL" "Expected filename in output: '$single_output'"
    fi

    test_command_exit_code "ls single file exit code" 0 "$binary" "$single_file"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # POSIX: ls with no operands lists current directory
    test_command_exit_code "POSIX: ls no args succeeds" 0 "$binary"

    # POSIX: ls with directory operand
    test_command_exit_code "POSIX: ls directory operand" 0 "$binary" "$test_dir"

    # POSIX: exit code 0 on success
    test_command_exit_code "POSIX: success exit code" 0 "$binary" "$test_dir"

    # POSIX: nonexistent path produces error on stderr.
    # Note: our ls currently returns exit 0 for nonexistent paths,
    # so we verify an error message is emitted rather than exit code.
    local posix_stderr
    posix_stderr=$("$binary" "/nonexistent_path_$$" 2>&1 >/dev/null)
    if [[ -n "$posix_stderr" ]]; then
        print_test_result "POSIX: nonexistent path error message" "PASS"
    else
        print_test_result "POSIX: nonexistent path error message" "FAIL" "Expected error on stderr"
    fi

    echo -e "${CYAN}Testing special filenames...${NC}"

    local special_dir=$(create_temp_dir)
    create_temp_file "spaces" "$special_dir/file with spaces.txt"
    create_temp_file "dashes" "$special_dir/file-with-dashes.txt"

    local special_output
    special_output=$("$binary" -1 "$special_dir" 2>/dev/null)
    if [[ "$special_output" == *"file with spaces.txt"* && "$special_output" == *"file-with-dashes.txt"* ]]; then
        print_test_result "ls files with special names" "PASS"
    else
        print_test_result "ls files with special names" "FAIL" "Expected special filenames in output"
    fi

    echo -e "${CYAN}Testing symlink display...${NC}"

    local link_dir=$(create_temp_dir)
    create_temp_file "link target" "$link_dir/target.txt"
    ln -s "$link_dir/target.txt" "$link_dir/link.txt"

    local link_output
    link_output=$("$binary" -1 "$link_dir" 2>/dev/null)
    if [[ "$link_output" == *"link.txt"* && "$link_output" == *"target.txt"* ]]; then
        print_test_result "ls shows symlinks" "PASS"
    else
        print_test_result "ls shows symlinks" "FAIL" "Expected both link and target in output"
    fi

    # -l should show symlink arrow
    local link_long_output
    link_long_output=$("$binary" -l "$link_dir" 2>/dev/null)
    if [[ "$link_long_output" == *"->"* ]]; then
        print_test_result "ls -l shows symlink arrow" "PASS"
    else
        print_test_result "ls -l shows symlink arrow" "FAIL" "Expected -> in long format for symlink"
    fi

    echo -e "${CYAN}Testing truecolor icon output...${NC}"

    local icon_dir=$(create_temp_dir)
    create_temp_file "fn main() void {}" "$icon_dir/hello.zig"
    create_temp_file "fn main() {}" "$icon_dir/hello.rs"

    # With LS_ICONS=always and COLORTERM=truecolor, long-format output
    # should contain truecolor escape sequences (38;2;R;G;B) for the
    # colorized metadata columns (sizes, dates, permissions).
    local tc_output
    tc_output=$(LS_ICONS=always COLORTERM=truecolor TERM=xterm "$binary" --color=always -l "$icon_dir" 2>/dev/null)
    if echo "$tc_output" | grep -q '38;2;'; then
        print_test_result "ls truecolor icons emit RGB sequences" "PASS"
    else
        print_test_result "ls truecolor icons emit RGB sequences" "FAIL" "No 38;2; truecolor sequence found in output"
    fi

    echo -e "${CYAN}Testing NO_COLOR suppresses escape sequences...${NC}"

    # With NO_COLOR=1, no escape sequences should appear at all.
    local nc_output
    nc_output=$(NO_COLOR=1 LS_ICONS=always "$binary" -1 "$icon_dir" 2>/dev/null)
    if echo "$nc_output" | grep -q $'\x1b\['; then
        print_test_result "ls NO_COLOR suppresses escapes" "FAIL" "Found escape sequences despite NO_COLOR=1"
    else
        print_test_result "ls NO_COLOR suppresses escapes" "PASS"
    fi

    # Regression test: NO_COLOR respected even with --color=always
    echo -e "${CYAN}Testing NO_COLOR overrides --color=always...${NC}"

    local nc_always_output
    nc_always_output=$(NO_COLOR=1 "$binary" --color=always -1 "$icon_dir" 2>/dev/null)
    if echo "$nc_always_output" | grep -q $'\x1b\['; then
        print_test_result "ls NO_COLOR overrides --color=always" "FAIL" \
            "Found ESC sequences despite NO_COLOR=1 with --color=always"
    else
        print_test_result "ls NO_COLOR overrides --color=always" "PASS"
    fi

    # ================================================================
    # F49: ls must exit 2 on nonexistent path (GNU behavior)
    # ================================================================
    echo -e "${CYAN}Testing exit code for nonexistent path (GNU compat)...${NC}"

    test_command_exit_code "ls nonexistent path exits 2" 2 \
        "$binary" "/tmp/vibeutils_nonexistent_dir_$$_f49"

    # Multiple args where one is nonexistent should also exit non-zero
    local f49_dir
    f49_dir=$(create_temp_dir)
    create_temp_file "exists" "$f49_dir/real.txt"

    "$binary" "$f49_dir" "/tmp/vibeutils_no_such_dir_$$" >/dev/null 2>&1
    local f49_mixed_exit=$?
    if [[ $f49_mixed_exit -ne 0 ]]; then
        print_test_result "ls mixed valid+invalid paths exits non-zero" "PASS"
    else
        print_test_result "ls mixed valid+invalid paths exits non-zero" "FAIL" \
            "Expected non-zero exit, got 0"
    fi

    # Permission-denied directory should also exit non-zero
    local f49_noread
    f49_noread=$(create_temp_dir)
    chmod 000 "$f49_noread"
    local f49_perm_stderr
    f49_perm_stderr=$("$binary" "$f49_noread" 2>&1 >/dev/null)
    local f49_perm_exit=$?
    chmod 755 "$f49_noread"  # restore so cleanup works
    if [[ $f49_perm_exit -ne 0 ]]; then
        print_test_result "ls permission-denied dir exits non-zero" "PASS"
    else
        print_test_result "ls permission-denied dir exits non-zero" "FAIL" \
            "Expected non-zero exit, got 0"
    fi

    # GNU ls quotes the operand for this diagnostic: "cannot open
    # directory 'x': Permission denied" (file_failure + quoteaf). We
    # don't match the "cannot open directory" wording but must match
    # the quoting placement and the mapped errno string.
    if [[ "$f49_perm_stderr" == *"'$f49_noread'"*"Permission denied"* ]]; then
        print_test_result "ls permission-denied dir operand is quoted" "PASS"
    else
        print_test_result "ls permission-denied dir operand is quoted" "FAIL" \
            "Expected quoted operand + 'Permission denied' in stderr: '$f49_perm_stderr'"
    fi

    # ================================================================
    # F50: ls -a must include . and .. entries (GNU behavior)
    # ================================================================
    echo -e "${CYAN}Testing ls -a includes . and .. entries...${NC}"

    local f50_dir
    f50_dir=$(create_temp_dir)
    create_temp_file "visible" "$f50_dir/visible.txt"
    create_temp_file "hidden" "$f50_dir/.hidden"

    local f50_output
    f50_output=$("$binary" -a -1 "$f50_dir" 2>/dev/null | strip_ansi)

    # -a output must contain literal "." and ".." lines
    if echo "$f50_output" | grep -qx '\.'; then
        print_test_result "ls -a includes . entry" "PASS"
    else
        print_test_result "ls -a includes . entry" "FAIL" \
            "Expected '.' in output: '$f50_output'"
    fi

    if echo "$f50_output" | grep -qx '\.\.'; then
        print_test_result "ls -a includes .. entry" "PASS"
    else
        print_test_result "ls -a includes .. entry" "FAIL" \
            "Expected '..' in output: '$f50_output'"
    fi

    # . and .. should be first two entries (GNU behavior)
    local f50_first
    f50_first=$(echo "$f50_output" | head -1)
    local f50_second
    f50_second=$(echo "$f50_output" | head -2 | tail -1)
    if [[ "$f50_first" == "." && "$f50_second" == ".." ]]; then
        print_test_result "ls -a . and .. are first two entries" "PASS"
    else
        print_test_result "ls -a . and .. are first two entries" "FAIL" \
            "Expected '.' then '..', got '$f50_first' then '$f50_second'"
    fi

    # -a on empty directory should still show . and ..
    local f50_empty
    f50_empty=$(create_temp_dir)
    local f50_empty_output
    f50_empty_output=$("$binary" -a -1 "$f50_empty" 2>/dev/null | strip_ansi)

    if echo "$f50_empty_output" | grep -qx '\.' && \
       echo "$f50_empty_output" | grep -qx '\.\.'; then
        print_test_result "ls -a empty dir shows . and .." "PASS"
    else
        print_test_result "ls -a empty dir shows . and .." "FAIL" \
            "Expected . and .. in empty dir output: '$f50_empty_output'"
    fi

    # -A should NOT include . and .. (verify distinction from -a)
    local f50_big_a_output
    f50_big_a_output=$("$binary" -A -1 "$f50_dir" 2>/dev/null | strip_ansi)
    if ! echo "$f50_big_a_output" | grep -qx '\.' && \
       ! echo "$f50_big_a_output" | grep -qx '\.\.'; then
        print_test_result "ls -A excludes . and .. (contrast with -a)" "PASS"
    else
        print_test_result "ls -A excludes . and .. (contrast with -a)" "FAIL" \
            "Found . or .. in -A output: '$f50_big_a_output'"
    fi

    # ================================================================
    # AUDIT F05: ls -n does not imply -l
    # GNU spec: "-n, --numeric-uid-gid: like -l, but list numeric
    # user and group IDs."
    # Bug: ls -n produces multi-column output, not long format.
    # ================================================================
    echo -e "${CYAN}Testing ls -n implies long format (F05)...${NC}"

    local f05_dir=$(create_temp_dir)
    create_temp_file "n content" "$f05_dir/nfile.txt"

    local f05_output
    f05_output=$(NO_COLOR=1 "$binary" -n "$f05_dir" 2>/dev/null | strip_ansi)

    # -n must produce long format (permissions string present)
    if echo "$f05_output" | grep -qE '^[-dlrwxst]{10}'; then
        print_test_result "ls -n implies long format" "PASS"
    else
        print_test_result "ls -n implies long format" "FAIL" \
            "Expected long format (permissions), got: '$f05_output'"
    fi

    # -n must show numeric UID/GID (all digits, no names)
    if echo "$f05_output" | grep -qE '[0-9]+[[:space:]]+[0-9]+'; then
        print_test_result "ls -n shows numeric uid/gid" "PASS"
    else
        print_test_result "ls -n shows numeric uid/gid" "FAIL" \
            "Expected numeric IDs in output: '$f05_output'"
    fi

    # ================================================================
    # AUDIT F06: ls -s with -l missing per-entry block count column
    # GNU: each long-format line begins with the block count when -s.
    # Bug: -sl output has no per-entry block count.
    # ================================================================
    echo -e "${CYAN}Testing ls -sl per-entry block count (F06)...${NC}"

    local f06_dir=$(create_temp_dir)
    dd if=/dev/zero of="$f06_dir/blockfile" bs=1024 count=4 2>/dev/null

    local f06_output
    f06_output=$(NO_COLOR=1 "$binary" -sl "$f06_dir" 2>/dev/null | strip_ansi)

    # Each file line in -sl output should start with a block count
    # (a number) followed by the permissions field.
    # Expected pattern: "  8 -rw-r--r-- ..."
    if echo "$f06_output" | grep "blockfile" | grep -qE '^ *[0-9]+ +[-dlrwxst]'; then
        print_test_result "ls -sl shows per-entry block count" "PASS"
    else
        print_test_result "ls -sl shows per-entry block count" "FAIL" \
            "Expected block count before permissions, got: $(echo "$f06_output" | grep blockfile)"
    fi

    # ================================================================
    # AUDIT F07: Multi-operand: file operands get spurious header
    # GNU: non-directory operands are listed bare (no header);
    # directory operands get "dirname:" only when mixed.
    # Bug: file operands get "filename:" header.
    # ================================================================
    echo -e "${CYAN}Testing ls multi-operand file header (F07)...${NC}"

    local f07_dir=$(create_temp_dir)
    create_temp_file "f07 content" "$f07_dir/plainfile.txt"
    mkdir -p "$f07_dir/subdir"
    create_temp_file "f07 sub" "$f07_dir/subdir/infile.txt"

    local f07_output
    f07_output=$(NO_COLOR=1 "$binary" "$f07_dir/plainfile.txt" "$f07_dir/subdir" 2>/dev/null | strip_ansi)

    # The plain file should NOT have a "plainfile.txt:" header
    if echo "$f07_output" | grep -q "plainfile.txt:"; then
        print_test_result "ls multi-operand file has no header" "FAIL" \
            "File operand has spurious header: $(echo "$f07_output" | head -3)"
    else
        print_test_result "ls multi-operand file has no header" "PASS"
    fi

    # The directory should still have its header
    if echo "$f07_output" | grep -q "subdir:"; then
        print_test_result "ls multi-operand dir has header" "PASS"
    else
        print_test_result "ls multi-operand dir has header" "FAIL" \
            "Expected 'subdir:' header in output: '$f07_output'"
    fi

    # ================================================================
    # AUDIT F08: Error messages use Zig names, not POSIX strings
    # Bug: ls /nonexistent prints "error.FileNotFound" instead of
    # "No such file or directory".
    # ================================================================
    echo -e "${CYAN}Testing ls POSIX error messages (F08)...${NC}"

    local f08_stderr
    f08_stderr=$("$binary" "/tmp/vibeutils_f08_nonexistent_$$" 2>&1 >/dev/null)

    # Should say "No such file or directory", not "error.FileNotFound"
    if [[ "$f08_stderr" =~ "No such file or directory" ]]; then
        print_test_result "ls error: No such file or directory" "PASS"
    else
        print_test_result "ls error: No such file or directory" "FAIL" \
            "Expected POSIX error string, got: '$f08_stderr'"
    fi

    # Should not contain Zig error names like "error.FileNotFound"
    if [[ "$f08_stderr" == *"error."* ]]; then
        print_test_result "ls error: no Zig error names" "FAIL" \
            "Found Zig error name in message: '$f08_stderr'"
    else
        print_test_result "ls error: no Zig error names" "PASS"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -r (reverse sort)
    # ================================================================
    echo -e "${CYAN}Testing ls -r reverse sort...${NC}"

    local r_dir=$(create_temp_dir)
    create_temp_file "a" "$r_dir/aaa.txt"
    create_temp_file "b" "$r_dir/bbb.txt"
    create_temp_file "c" "$r_dir/ccc.txt"

    local r_output
    r_output=$(NO_COLOR=1 "$binary" -1r "$r_dir" 2>/dev/null | strip_ansi)

    local r_first
    r_first=$(echo "$r_output" | head -1)
    local r_last
    r_last=$(echo "$r_output" | tail -1)

    if [[ "$r_first" == "ccc.txt" && "$r_last" == "aaa.txt" ]]; then
        print_test_result "ls -r reverse alphabetical order" "PASS"
    else
        print_test_result "ls -r reverse alphabetical order" "FAIL" \
            "Expected ccc first, aaa last; got first='$r_first' last='$r_last'"
    fi

    # -r with -t: oldest first
    local rt_dir=$(create_temp_dir)
    create_temp_file "old" "$rt_dir/old.txt"
    sleep 1
    create_temp_file "new" "$rt_dir/new.txt"

    local rt_output
    rt_output=$(NO_COLOR=1 "$binary" -1rt "$rt_dir" 2>/dev/null | strip_ansi)
    local rt_first
    rt_first=$(echo "$rt_output" | head -1)

    if [[ "$rt_first" == "old.txt" ]]; then
        print_test_result "ls -rt oldest first" "PASS"
    else
        print_test_result "ls -rt oldest first" "FAIL" \
            "Expected old.txt first, got '$rt_first'"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -F (classify)
    # ================================================================
    echo -e "${CYAN}Testing ls -F classify indicators...${NC}"

    local F_dir=$(create_temp_dir)
    create_temp_file "regular" "$F_dir/regular.txt"
    mkdir -p "$F_dir/subdir"
    ln -s "$F_dir/regular.txt" "$F_dir/symlink.txt"
    chmod +x "$F_dir/regular.txt"

    local F_output
    F_output=$(NO_COLOR=1 "$binary" -1F "$F_dir" 2>/dev/null | strip_ansi)

    # Directories should have trailing /
    if echo "$F_output" | grep -q "subdir/"; then
        print_test_result "ls -F directory has /" "PASS"
    else
        print_test_result "ls -F directory has /" "FAIL" \
            "Expected 'subdir/' in output: '$F_output'"
    fi

    # Symlinks should have trailing @
    if echo "$F_output" | grep -q "symlink.txt@"; then
        print_test_result "ls -F symlink has @" "PASS"
    else
        print_test_result "ls -F symlink has @" "FAIL" \
            "Expected 'symlink.txt@' in output: '$F_output'"
    fi

    # Executable files should have trailing *
    if echo "$F_output" | grep -q "regular.txt\*"; then
        print_test_result "ls -F executable has *" "PASS"
    else
        print_test_result "ls -F executable has *" "FAIL" \
            "Expected 'regular.txt*' in output: '$F_output'"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -m (comma-separated)
    # ================================================================
    echo -e "${CYAN}Testing ls -m comma-separated...${NC}"

    local m_dir=$(create_temp_dir)
    create_temp_file "a" "$m_dir/alpha.txt"
    create_temp_file "b" "$m_dir/beta.txt"
    create_temp_file "c" "$m_dir/gamma.txt"

    local m_output
    m_output=$(NO_COLOR=1 "$binary" -m "$m_dir" 2>/dev/null | strip_ansi)

    # Output should be comma-separated on one line
    if [[ "$m_output" == *"alpha.txt"*","*"beta.txt"*","*"gamma.txt"* ]]; then
        print_test_result "ls -m comma-separated output" "PASS"
    else
        print_test_result "ls -m comma-separated output" "FAIL" \
            "Expected comma-separated list, got: '$m_output'"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -i (inode numbers)
    # ================================================================
    echo -e "${CYAN}Testing ls -i inode numbers...${NC}"

    local i_dir=$(create_temp_dir)
    create_temp_file "inode content" "$i_dir/inodefile.txt"

    local i_output
    i_output=$(NO_COLOR=1 "$binary" -i -1 "$i_dir" 2>/dev/null | strip_ansi)

    # Output should have a numeric inode before the filename
    if echo "$i_output" | grep -qE '^[[:space:]]*[0-9]+ inodefile.txt$'; then
        print_test_result "ls -i shows inode number" "PASS"
    else
        print_test_result "ls -i shows inode number" "FAIL" \
            "Expected inode number before filename, got: '$i_output'"
    fi

    # Inode should match system stat
    local i_expected_inode
    i_expected_inode=$(stat -c %i "$i_dir/inodefile.txt" 2>/dev/null \
        || /usr/bin/stat -f %i "$i_dir/inodefile.txt" 2>/dev/null)
    if echo "$i_output" | grep -q "$i_expected_inode"; then
        print_test_result "ls -i inode matches stat" "PASS"
    else
        print_test_result "ls -i inode matches stat" "FAIL" \
            "Expected inode $i_expected_inode in output: '$i_output'"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -s (block size)
    # ================================================================
    echo -e "${CYAN}Testing ls -s block sizes...${NC}"

    local s_dir=$(create_temp_dir)
    dd if=/dev/zero of="$s_dir/sfile" bs=1024 count=8 2>/dev/null

    local s_output
    s_output=$(NO_COLOR=1 "$binary" -s -1 "$s_dir" 2>/dev/null | strip_ansi)

    # Should show a "total" line
    if echo "$s_output" | grep -qE '^total [0-9]+'; then
        print_test_result "ls -s shows total line" "PASS"
    else
        print_test_result "ls -s shows total line" "FAIL" \
            "Expected 'total NNN' line, got: '$s_output'"
    fi

    # Each entry should have a block count prefix
    if echo "$s_output" | grep "sfile" | grep -qE '^ *[0-9]+'; then
        print_test_result "ls -s shows per-entry block count" "PASS"
    else
        print_test_result "ls -s shows per-entry block count" "FAIL" \
            "Expected block count for sfile, got: $(echo "$s_output" | grep sfile)"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -c (ctime display)
    # ================================================================
    echo -e "${CYAN}Testing ls -c ctime display...${NC}"

    local c_dir=$(create_temp_dir)
    create_temp_file "c content" "$c_dir/cfile.txt"
    # Set mtime to a known past date
    touch -t 202001010000 "$c_dir/cfile.txt"

    local c_output
    c_output=$(NO_COLOR=1 "$binary" -lc "$c_dir" 2>/dev/null | strip_ansi)

    # -c shows ctime, which should be recent (not Jan 2020 mtime).
    # The ctime is set when we create the file, so it should show
    # current year/month, not "Jan  1  2020".
    if echo "$c_output" | grep "cfile" | grep -q "Jan  1  2020"; then
        print_test_result "ls -lc shows ctime not mtime" "FAIL" \
            "Shows mtime (Jan 2020) instead of ctime"
    else
        print_test_result "ls -lc shows ctime not mtime" "PASS"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -u (atime display)
    # ================================================================
    echo -e "${CYAN}Testing ls -u atime display...${NC}"

    local u_dir=$(create_temp_dir)
    create_temp_file "u content" "$u_dir/ufile.txt"
    # Set both atime and mtime to known past date
    touch -t 202501150000 "$u_dir/ufile.txt"

    local u_output
    u_output=$(NO_COLOR=1 "$binary" -lu "$u_dir" 2>/dev/null | strip_ansi)

    # -u shows atime. touch -t sets both atime and mtime,
    # so output should reflect Jan 15 2025.
    if echo "$u_output" | grep "ufile" | grep -q "Jan"; then
        print_test_result "ls -lu shows access time" "PASS"
    else
        print_test_result "ls -lu shows access time" "FAIL" \
            "Expected Jan date for atime, got: $(echo "$u_output" | grep ufile)"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -p (append / to directories)
    # ================================================================
    echo -e "${CYAN}Testing ls -p directory indicator...${NC}"

    local p_dir=$(create_temp_dir)
    create_temp_file "p content" "$p_dir/pfile.txt"
    mkdir -p "$p_dir/psubdir"

    local p_output
    p_output=$(NO_COLOR=1 "$binary" -1p "$p_dir" 2>/dev/null | strip_ansi)

    # Directories should have trailing /
    if echo "$p_output" | grep -q "psubdir/"; then
        print_test_result "ls -p appends / to directory" "PASS"
    else
        print_test_result "ls -p appends / to directory" "FAIL" \
            "Expected 'psubdir/' in output: '$p_output'"
    fi

    # Regular files should NOT have trailing /
    if echo "$p_output" | grep -q "pfile.txt/"; then
        print_test_result "ls -p no / on regular file" "FAIL" \
            "Regular file has trailing slash"
    else
        print_test_result "ls -p no / on regular file" "PASS"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -k (block size in KB)
    # ================================================================
    echo -e "${CYAN}Testing ls -k kilobyte block size...${NC}"

    local k_dir=$(create_temp_dir)
    dd if=/dev/zero of="$k_dir/kfile" bs=1024 count=8 2>/dev/null

    # -sk should show blocks in 1K units
    local k_output
    k_output=$(NO_COLOR=1 "$binary" -sk -1 "$k_dir" 2>/dev/null | strip_ansi)

    # Block count for an 8K file should be around 8 in 1K blocks
    local k_blocks
    k_blocks=$(echo "$k_output" | grep "kfile" | awk '{print $1}')
    if [[ -n "$k_blocks" && "$k_blocks" -ge 8 && "$k_blocks" -le 16 ]]; then
        print_test_result "ls -sk shows 1K block count" "PASS"
    else
        print_test_result "ls -sk shows 1K block count" "FAIL" \
            "Expected ~8 blocks for 8K file, got: '$k_blocks' (line: $(echo "$k_output" | grep kfile))"
    fi

    # -k with -l should also show per-entry blocks
    local kl_output
    kl_output=$(NO_COLOR=1 "$binary" -slk "$k_dir" 2>/dev/null | strip_ansi)

    if echo "$kl_output" | grep "kfile" | grep -qE '^ *[0-9]+ +[-dlrwxst]'; then
        print_test_result "ls -slk shows per-entry 1K blocks" "PASS"
    else
        print_test_result "ls -slk shows per-entry 1K blocks" "FAIL" \
            "Expected block count before permissions: $(echo "$kl_output" | grep kfile)"
    fi

    # ================================================================
    # AUDIT: Test gap coverage for -n (numeric IDs, long format)
    # Verifies -n shows numeric UID/GID instead of names.
    # ================================================================
    echo -e "${CYAN}Testing ls -n numeric ID format...${NC}"

    local n_dir=$(create_temp_dir)
    create_temp_file "n content" "$n_dir/nfile.txt"

    local n_output
    n_output=$(NO_COLOR=1 "$binary" -n "$n_dir" 2>/dev/null | strip_ansi)

    # Should show numeric UID and GID (not username/groupname)
    # The UID/GID fields should be all digits
    local n_line
    n_line=$(echo "$n_output" | grep "nfile.txt")

    # Extract owner and group fields (fields 3 and 4 in long format)
    local n_owner n_group
    n_owner=$(echo "$n_line" | awk '{print $3}')
    n_group=$(echo "$n_line" | awk '{print $4}')

    if [[ "$n_owner" =~ ^[0-9]+$ && "$n_group" =~ ^[0-9]+$ ]]; then
        print_test_result "ls -n shows numeric owner and group" "PASS"
    else
        print_test_result "ls -n shows numeric owner and group" "FAIL" \
            "Expected numeric IDs, got owner='$n_owner' group='$n_group' (line: '$n_line')"
    fi

    # ================================================================
    # Issue #104: ls -l renders mtime in the local timezone, not UTC.
    #
    # These fixtures use vibeutils' own touch -d/--date, which parses
    # ISO-8601-with-Z reliably on both macOS (BSD touch does not
    # reliably accept a "... UTC" suffix) and Linux. All expected
    # values are pinned against GNU coreutils 9.5.
    #
    # Prerequisite: TZ=America/Los_Angeles below resolves through the
    # system tzdata zoneinfo database. On a stripped container without
    # tzdata, libc silently falls back to UTC and these tests fail with
    # output identical to the bug being fixed (no offset applied) --
    # if a run goes red with UTC-looking output despite the TZ
    # override, check tzdata is installed before suspecting the fix.
    # ================================================================
    echo -e "${CYAN}Testing ls -l timezone handling (issue #104)...${NC}"
    local touch_bin="$BIN_DIR/touch"

    if [[ ! -x "$touch_bin" ]]; then
        print_test_result "ls -l timezone tests (issue #104) setup" "FAIL" \
            "touch binary not found or not executable at '$touch_bin' -- cannot build TZ fixtures; check the vibeutils build, not ls"
    else

    # Fixtures use --time-style=iso ("YYYY-MM-DD HH:MM") for behaviors 1
    # and 2 instead of the plain (default) style. The default style's
    # output depends on the 6-month recency window measured against the
    # CURRENT clock (formatter.zig:270-271); a fixed mtime pinned to this
    # session's date would silently flip from the recent-showing form to
    # the year-showing form roughly 6 months after this test was written.
    # --time-style=iso has no such recency dependency, so its expected
    # value never goes stale.

    # --- Behavior 1 (regression guard): TZ=UTC keeps rendering UTC wall
    #     time ---
    local tz1_dir=$(create_temp_dir)
    "$touch_bin" -d "2026-07-15T12:00:00Z" "$tz1_dir/recent.txt"

    local tz1_output
    tz1_output=$(env TZ=UTC "$binary" -l --time-style=iso "$tz1_dir" 2>/dev/null | strip_ansi)
    if echo "$tz1_output" | grep "recent.txt" | grep -q "2026-07-15 12:00"; then
        print_test_result "ls -l with TZ=UTC shows UTC wall time" "PASS"
    else
        print_test_result "ls -l with TZ=UTC shows UTC wall time" "FAIL" \
            "Expected '2026-07-15 12:00' for TZ=UTC, got: $(echo "$tz1_output" | grep recent.txt)"
    fi

    # --- Behavior 2: TZ=America/Los_Angeles shifts the wall time ---
    local tz2_output
    tz2_output=$(env TZ=America/Los_Angeles "$binary" -l --time-style=iso "$tz1_dir" 2>/dev/null | strip_ansi)
    if echo "$tz2_output" | grep "recent.txt" | grep -q "2026-07-15 05:00"; then
        print_test_result "ls -l with TZ=America/Los_Angeles shows local wall time" "PASS"
    else
        print_test_result "ls -l with TZ=America/Los_Angeles shows local wall time" "FAIL" \
            "Expected '2026-07-15 05:00' (PDT, UTC-7) for TZ=America/Los_Angeles, got: $(echo "$tz2_output" | grep recent.txt)"
    fi

    # --- Behavior 3: offset is resolved per timestamp across a DST
    #     transition, not captured once per run. Uses --full-time, whose
    #     layout is vibeutils' .full style ("Mon DD HH:MM:SS YYYY"), NOT
    #     GNU's long-iso layout -- see formatTimeWithStyle_full. ---
    local tz3_dir=$(create_temp_dir)
    "$touch_bin" -d "2026-01-15T12:00:00Z" "$tz3_dir/winter"
    "$touch_bin" -d "2026-07-15T12:00:00Z" "$tz3_dir/summer"

    local tz3_output
    tz3_output=$(env TZ=America/Los_Angeles "$binary" -l --full-time "$tz3_dir" 2>/dev/null | strip_ansi)
    if echo "$tz3_output" | grep "winter" | grep -q "Jan 15 04:00:00 2026" && \
       echo "$tz3_output" | grep "summer" | grep -q "Jul 15 05:00:00 2026"; then
        print_test_result "ls -l --full-time resolves offset per timestamp across DST" "PASS"
    else
        print_test_result "ls -l --full-time resolves offset per timestamp across DST" "FAIL" \
            "Expected winter 'Jan 15 04:00:00 2026' (PST) and summer 'Jul 15 05:00:00 2026' (PDT), got: $tz3_output"
    fi

    # --- Behavior 4: local and UTC calendar dates differ. Also uses the
    #     .full style, matching behavior 3 above. ---
    local tz4_dir=$(create_temp_dir)
    "$touch_bin" -d "2026-07-30T03:44:48Z" "$tz4_dir/crossdate"

    local tz4_la_output tz4_utc_output
    tz4_la_output=$(env TZ=America/Los_Angeles "$binary" -l --full-time "$tz4_dir" 2>/dev/null | strip_ansi)
    tz4_utc_output=$(env TZ=UTC "$binary" -l --full-time "$tz4_dir" 2>/dev/null | strip_ansi)
    if echo "$tz4_la_output" | grep "crossdate" | grep -q "Jul 29 20:44:48 2026" && \
       echo "$tz4_utc_output" | grep "crossdate" | grep -q "Jul 30 03:44:48 2026"; then
        print_test_result "ls -l --full-time renders local calendar date, not UTC date" "PASS"
    else
        print_test_result "ls -l --full-time renders local calendar date, not UTC date" "FAIL" \
            "Expected LA 'Jul 29 20:44:48 2026' and UTC 'Jul 30 03:44:48 2026', got LA: '$(echo "$tz4_la_output" | grep crossdate)' UTC: '$(echo "$tz4_utc_output" | grep crossdate)'"
    fi

    # --- Behavior 5: recent-vs-old (6 month) heuristic renders the local
    #     calendar date for an "old" file, not the UTC date. The age
    #     comparison itself (formatter.zig:271-272) diffs two absolute
    #     epoch-nanosecond values, so it cannot flip sides with TZ; only
    #     the rendered calendar date needs the localtime fix, which is
    #     what this test pins. ---
    local tz5_dir=$(create_temp_dir)
    # More than 6 months old regardless of when this suite runs, so it
    # always lands in the year-showing bucket. The early UTC hour puts
    # Los Angeles local time (PST, UTC-8) on the previous calendar day.
    "$touch_bin" -d "2024-01-15T03:44:48Z" "$tz5_dir/oldfile"

    local tz5_output
    tz5_output=$(env TZ=America/Los_Angeles "$binary" -l "$tz5_dir" 2>/dev/null | strip_ansi)
    if echo "$tz5_output" | grep "oldfile" | grep -q "Jan 14  2024"; then
        print_test_result "ls -l old-file heuristic renders local calendar date" "PASS"
    else
        print_test_result "ls -l old-file heuristic renders local calendar date" "FAIL" \
            "Expected 'Jan 14  2024' (local date, PST), got: $(echo "$tz5_output" | grep oldfile)"
    fi

    # --- Behavior 5b: the "old" branch takes its YEAR from local time
    #     too, not only its month and day. A fix that prints the year
    #     from the UTC decode while taking month/day from localtime
    #     still passes behavior 5, because both decoders agree on 2024
    #     for that stamp; only a year-crossing stamp separates the two
    #     sources. PST (UTC-8) puts 2024-01-01T04:00:00Z on
    #     2023-12-31 locally, one day AND one year earlier. ---
    local tz5b_dir=$(create_temp_dir)
    "$touch_bin" -d "2024-01-01T04:00:00Z" "$tz5b_dir/yearcross"

    local tz5b_output
    tz5b_output=$(env TZ=America/Los_Angeles "$binary" -l "$tz5b_dir" 2>/dev/null | strip_ansi)
    if echo "$tz5b_output" | grep "yearcross" | grep -q "Dec 31  2023"; then
        print_test_result "ls -l old-file across a year boundary uses local year" "PASS"
    else
        print_test_result "ls -l old-file across a year boundary uses local year" "FAIL" \
            "Expected 'Dec 31  2023' (local date and year, PST), got: $(echo "$tz5b_output" | grep yearcross)"
    fi

    # --- Behavior 6 (regression guard): --time-style=long-iso also
    #     resolves the real per-timestamp offset instead of the hardcoded
    #     "+0000" literal, since it goes through the same formatter call
    #     sites as the other styles ---
    local tz6_output
    tz6_output=$(env TZ=America/Los_Angeles "$binary" -l --time-style=long-iso "$tz3_dir" 2>/dev/null | strip_ansi)
    if echo "$tz6_output" | grep "winter" | grep -q "2026-01-15 04:00:00.000000000 -0800"; then
        print_test_result "ls -l --time-style=long-iso shows real TZ offset, not +0000" "PASS"
    else
        print_test_result "ls -l --time-style=long-iso shows real TZ offset, not +0000" "FAIL" \
            "Expected '2026-01-15 04:00:00.000000000 -0800', got: $(echo "$tz6_output" | grep winter)"
    fi

    # --- Behavior 7: the default style's RECENT branch (a file inside
    #     the 6-month window) prints a local clock time "Mon DD HH:MM",
    #     not a UTC one. Behaviors 1 and 2 pin the clock field only for
    #     --time-style=iso, and behaviors 5/5b exercise the default
    #     style's OLD branch, which prints a year and no clock at all --
    #     so this is the only case covering the default recent branch.
    #
    #     The mtime must be "now" to stay inside the recency window
    #     whenever this suite runs, so the expected value is derived
    #     rather than hardcoded. Both the fixture and the expectation
    #     come from ONE captured instant ($tz7_now), so a minute
    #     rolling over mid-test cannot make them disagree. ---
    local date_bin="$BIN_DIR/date"
    local tz7_now tz7_expected_la tz7_expected_utc
    tz7_now=$("$date_bin" -u "+%Y-%m-%dT%H:%M:%SZ")
    tz7_expected_la=$(env TZ=America/Los_Angeles "$date_bin" -d "$tz7_now" "+%H:%M")
    tz7_expected_utc=$(env TZ=UTC "$date_bin" -d "$tz7_now" "+%H:%M")

    local tz7_dir=$(create_temp_dir)
    "$touch_bin" -d "$tz7_now" "$tz7_dir/nowfile"

    local tz7_output
    tz7_output=$(env TZ=America/Los_Angeles "$binary" -l "$tz7_dir" 2>/dev/null | strip_ansi)
    if [[ -z "$tz7_expected_la" || "$tz7_expected_la" == "$tz7_expected_utc" ]]; then
        # Los Angeles is never at UTC+0, so identical values mean the
        # zone did not resolve (missing tzdata) and this assertion would
        # pass vacuously against the very bug it guards.
        print_test_result "ls -l recent file shows local clock time" "FAIL" \
            "TZ=America/Los_Angeles did not resolve (LA='$tz7_expected_la' UTC='$tz7_expected_utc') -- check tzdata is installed"
    elif echo "$tz7_output" | grep -q " $tz7_expected_la nowfile"; then
        print_test_result "ls -l recent file shows local clock time" "PASS"
    else
        print_test_result "ls -l recent file shows local clock time" "FAIL" \
            "Expected local time '$tz7_expected_la' (UTC would be '$tz7_expected_utc') for mtime $tz7_now, got: $(echo "$tz7_output" | grep nowfile)"
    fi

    fi

    # ================================================================
    # AUDIT F09 (issue #103): non-directory operands are mishandled two
    # ways: (a) printed as their basename instead of the operand exactly
    # as given, breaking pipelines like `ls dir/*.jsonl`; and (b) the
    # operand LIST itself is never sorted, so -t/-S/-r and the default
    # name sort are silently ignored (only -U/-f may preserve argv
    # order). Directory CONTENTS already sort correctly -- this bug is
    # specific to the top-level operand list.
    # ================================================================
    echo -e "${CYAN}Testing ls non-directory operand handling (issue #103)...${NC}"

    # --- Bug A: operand echoed exactly as given, not basename'd ---
    local f09_dir=$(create_temp_dir)
    mkdir -p "$f09_dir/subdir"
    create_temp_file "f09 content" "$f09_dir/subdir/file.txt"

    local f09a_output
    f09a_output=$(NO_COLOR=1 "$binary" "$f09_dir/subdir/file.txt" 2>/dev/null | strip_ansi)
    if [[ "$f09a_output" == "$f09_dir/subdir/file.txt" ]]; then
        print_test_result "ls operand echoed exactly, not basename (short format)" "PASS"
    else
        print_test_result "ls operand echoed exactly, not basename (short format)" "FAIL" \
            "Expected '$f09_dir/subdir/file.txt', got: '$f09a_output'"
    fi

    local f09al_output
    f09al_output=$(NO_COLOR=1 "$binary" -l "$f09_dir/subdir/file.txt" 2>/dev/null | strip_ansi)
    if [[ "$f09al_output" == *"$f09_dir/subdir/file.txt" ]]; then
        print_test_result "ls -l operand echoed exactly, not basename (long format)" "PASS"
    else
        print_test_result "ls -l operand echoed exactly, not basename (long format)" "FAIL" \
            "Expected line ending in '$f09_dir/subdir/file.txt', got: '$f09al_output'"
    fi

    # --- Bug B: the file-operand LIST is sorted like directory contents ---
    local f09s_dir=$(create_temp_dir)
    create_temp_file "small" "$f09s_dir/z_file"
    create_temp_file "small" "$f09s_dir/a_file"

    local f09_default_output
    f09_default_output=$(NO_COLOR=1 "$binary" -1 "$f09s_dir/z_file" "$f09s_dir/a_file" 2>/dev/null | strip_ansi)
    local f09_default_first
    f09_default_first=$(echo "$f09_default_output" | head -1)
    local f09_default_last
    f09_default_last=$(echo "$f09_default_output" | tail -1)
    if [[ "$f09_default_first" == "$f09s_dir/a_file" && "$f09_default_last" == "$f09s_dir/z_file" ]]; then
        print_test_result "ls file operands: default name sort ignores argv order" "PASS"
    else
        print_test_result "ls file operands: default name sort ignores argv order" "FAIL" \
            "Expected '$f09s_dir/a_file' then '$f09s_dir/z_file', got: '$f09_default_output'"
    fi

    local f09_u_output
    f09_u_output=$(NO_COLOR=1 "$binary" -1U "$f09s_dir/z_file" "$f09s_dir/a_file" 2>/dev/null | strip_ansi)
    local f09_u_first
    f09_u_first=$(echo "$f09_u_output" | head -1)
    local f09_u_last
    f09_u_last=$(echo "$f09_u_output" | tail -1)
    if [[ "$f09_u_first" == "$f09s_dir/z_file" && "$f09_u_last" == "$f09s_dir/a_file" ]]; then
        print_test_result "ls -U preserves argv order for file operands" "PASS"
    else
        print_test_result "ls -U preserves argv order for file operands" "FAIL" \
            "Expected '$f09s_dir/z_file' then '$f09s_dir/a_file' (argv order), got: '$f09_u_output'"
    fi

    # Names are chosen so name order ("a_older" < "z_newer") DISAGREES
    # with time order (z_newer is the newer file). An f_old/f_new style
    # fixture would let a fix that always name-sorts -- ignoring -t
    # entirely -- pass by coincidence (name order matches time order
    # there); this fixture cannot pass that way.
    local f09t_dir=$(create_temp_dir)
    create_temp_file "old" "$f09t_dir/a_older"
    sleep 1
    create_temp_file "new" "$f09t_dir/z_newer"

    local f09t_output
    f09t_output=$(NO_COLOR=1 "$binary" -1t "$f09t_dir/a_older" "$f09t_dir/z_newer" 2>/dev/null | strip_ansi)
    local f09t_first
    f09t_first=$(echo "$f09t_output" | head -1)
    local f09t_last
    f09t_last=$(echo "$f09t_output" | tail -1)
    if [[ "$f09t_first" == "$f09t_dir/z_newer" && "$f09t_last" == "$f09t_dir/a_older" ]]; then
        print_test_result "ls -t sorts file operands newest first" "PASS"
    else
        print_test_result "ls -t sorts file operands newest first" "FAIL" \
            "Expected '$f09t_dir/z_newer' then '$f09t_dir/a_older', got: '$f09t_output'"
    fi

    # Names are chosen so name order ("a_small" < "z_big") DISAGREES with
    # size order (z_big is the bigger file), for the same reason as -t
    # above.
    local f09sz_dir=$(create_temp_dir)
    create_temp_file "a" "$f09sz_dir/a_small"
    printf '%0.sX' {1..1000} >"$f09sz_dir/z_big"

    local f09sz_output
    f09sz_output=$(NO_COLOR=1 "$binary" -1S "$f09sz_dir/a_small" "$f09sz_dir/z_big" 2>/dev/null | strip_ansi)
    local f09sz_first
    f09sz_first=$(echo "$f09sz_output" | head -1)
    local f09sz_last
    f09sz_last=$(echo "$f09sz_output" | tail -1)
    if [[ "$f09sz_first" == "$f09sz_dir/z_big" && "$f09sz_last" == "$f09sz_dir/a_small" ]]; then
        print_test_result "ls -S sorts file operands largest first" "PASS"
    else
        print_test_result "ls -S sorts file operands largest first" "FAIL" \
            "Expected '$f09sz_dir/z_big' then '$f09sz_dir/a_small', got: '$f09sz_output'"
    fi

    local f09r_dir=$(create_temp_dir)
    create_temp_file "b" "$f09r_dir/big"
    create_temp_file "s" "$f09r_dir/small"

    local f09r_output
    f09r_output=$(NO_COLOR=1 "$binary" -1r "$f09r_dir/big" "$f09r_dir/small" 2>/dev/null | strip_ansi)
    local f09r_first
    f09r_first=$(echo "$f09r_output" | head -1)
    local f09r_last
    f09r_last=$(echo "$f09r_output" | tail -1)
    if [[ "$f09r_first" == "$f09r_dir/small" && "$f09r_last" == "$f09r_dir/big" ]]; then
        print_test_result "ls -r reverses default name sort for file operands" "PASS"
    else
        print_test_result "ls -r reverses default name sort for file operands" "FAIL" \
            "Expected '$f09r_dir/small' then '$f09r_dir/big', got: '$f09r_output'"
    fi

    # --- Bug B also affects the directory-operand pass: headers should be
    # emitted in name order, not argv order ---
    local f09d_base=$(create_temp_dir)
    mkdir -p "$f09d_base/b_dir" "$f09d_base/a_dir"
    create_temp_file "x" "$f09d_base/a_dir/x"
    create_temp_file "y" "$f09d_base/b_dir/y"

    local f09d_output
    f09d_output=$(NO_COLOR=1 "$binary" "$f09d_base/b_dir" "$f09d_base/a_dir" 2>/dev/null | strip_ansi)
    local a_dir_pos b_dir_pos
    a_dir_pos=$(echo "$f09d_output" | grep -nFx "$f09d_base/a_dir:" | head -1 | cut -d: -f1)
    b_dir_pos=$(echo "$f09d_output" | grep -nFx "$f09d_base/b_dir:" | head -1 | cut -d: -f1)
    if [[ -n "$a_dir_pos" && -n "$b_dir_pos" && "$a_dir_pos" -lt "$b_dir_pos" ]]; then
        print_test_result "ls sorts directory operands (a_dir before b_dir) regardless of argv order" "PASS"
    else
        print_test_result "ls sorts directory operands (a_dir before b_dir) regardless of argv order" "FAIL" \
            "Expected 'a_dir:' header before 'b_dir:' header, got: '$f09d_output'"
    fi

    # --- Fixing Bug A also fixes git-status lookups on operands inside a
    # subdirectory: getFileStatus is keyed on entry.name, which was the
    # truncated basename before the fix, so it missed the real
    # status_map key ("subdir/newfile.txt") and reported the wrong
    # status. ---
    if command -v git >/dev/null 2>&1; then
        local f09g_dir=$(create_temp_dir)
        mkdir -p "$f09g_dir/subdir"
        # These two git calls run in a `set -euo pipefail` context, so a
        # non-zero status from a bare subshell would kill the whole
        # test_ls run instead of just this case (e.g. a sandboxed/noexec
        # temp mount, or a "dubious ownership" refusal on a shared
        # runner). Guard each with `|| true` and then verify the expected
        # state directly, degrading to a single SKIP rather than aborting
        # every later test in this file.
        (cd "$f09g_dir" && git init -q >/dev/null 2>&1) || true
        if [[ ! -d "$f09g_dir/.git" ]]; then
            print_test_result "ls --git status resolves against the full relative operand path" "SKIP" \
                "git init failed in test environment"
        else
        # `git status --porcelain` defaults to -unormal, which collapses a
        # WHOLLY untracked directory into a single "?? subdir/" entry --
        # status_map would then never have the key "subdir/newfile.txt",
        # so the test could never pass regardless of the fix. Add and
        # stage a second file in the same subdir first (no commit needed,
        # so no user.name/user.email config required); porcelain then
        # reports the two files individually.
        printf 'tracked' >"$f09g_dir/subdir/tracked.txt"
        (cd "$f09g_dir" && git add subdir/tracked.txt >/dev/null 2>&1) || true
        printf 'untracked' >"$f09g_dir/subdir/newfile.txt"

        local f09g_staged
        f09g_staged=$(cd "$f09g_dir" && git diff --cached --name-only 2>/dev/null || true)
        if [[ "$f09g_staged" != *"subdir/tracked.txt"* ]]; then
            print_test_result "ls --git status resolves against the full relative operand path" "SKIP" \
                "git add failed in test environment"
        else
            local f09g_output
            f09g_output=$(cd "$f09g_dir" && NO_COLOR=1 "$binary" --git=always "subdir/newfile.txt" 2>/dev/null | strip_ansi)
            if [[ "$f09g_output" == "?? subdir/newfile.txt" ]]; then
                print_test_result "ls --git status resolves against the full relative operand path" "PASS"
            else
                print_test_result "ls --git status resolves against the full relative operand path" "FAIL" \
                    "Expected '?? subdir/newfile.txt', got: '$f09g_output'"
            fi
        fi
        fi
    else
        print_test_result "ls --git status resolves against the full relative operand path" "SKIP" \
            "git not found on PATH"
    fi

    # --- Mixed operand case: at least one file operand AND at least one
    # directory operand together. Pins that the Bug B restructure keeps
    # file operands (a) sorted, (b) preceding directory operands, (c)
    # still headerless, and that the blank-line separator between the
    # file section and the directory section is derived correctly from
    # the new file-group size rather than a stale/miscounted signal --
    # e.g. a fix that derives the separator from `dir_idx > 0` alone (or
    # double-counts) would still pass every OTHER test in this file while
    # dropping or duplicating the blank line here.
    local f09m_dir=$(create_temp_dir)
    mkdir -p "$f09m_dir/a_dir"
    create_temp_file "x" "$f09m_dir/a_dir/x"
    create_temp_file "z" "$f09m_dir/z_file"

    local f09m_output
    f09m_output=$(cd "$f09m_dir" && NO_COLOR=1 "$binary" -1 z_file a_dir 2>/dev/null | strip_ansi)
    local f09m_expected=$'z_file\n\na_dir:\nx'
    if [[ "$f09m_output" == "$f09m_expected" ]]; then
        print_test_result "ls mixed file+directory operands: file listed first, one blank line before directory header" "PASS"
    else
        print_test_result "ls mixed file+directory operands: file listed first, one blank line before directory header" "FAIL" \
            "Expected $(printf '%q' "$f09m_expected"), got: $(printf '%q' "$f09m_output")"
    fi
}
