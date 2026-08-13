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

    # --- Issue #ls-git-column: the 3-column git-status prefix must be
    # reserved PER DIRECTORY SECTION, based on whether any entry in that
    # section is actually dirty/untracked -- not per entry. A repo where
    # every tracked file is clean must render identically to --git=never,
    # with no reserved column at all. ---
    if command -v git >/dev/null 2>&1; then
        local g09_dir=$(create_temp_dir)
        (cd "$g09_dir" && git init -q >/dev/null 2>&1) || true
        if [[ ! -d "$g09_dir/.git" ]]; then
            print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-C)" "SKIP" \
                "git init failed in test environment"
            print_test_result "ls #ls-git-column: all-clean repo matches --git=never (implicit one-per-line)" "SKIP" \
                "git init failed in test environment"
            print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-l)" "SKIP" \
                "git init failed in test environment"
            print_test_result "ls #119: clean tracked file operand lists flush left" "SKIP" \
                "git init failed in test environment"
            print_test_result "ls #119: modified file operand keeps the git indicator" "SKIP" \
                "git init failed in test environment"
        else
            (cd "$g09_dir" && git config commit.gpgsign false) || true
            (cd "$g09_dir" && git config user.email "test@example.com") || true
            (cd "$g09_dir" && git config user.name "Test User") || true
            create_temp_file "one" "$g09_dir/clean1.txt"
            create_temp_file "two" "$g09_dir/clean2.txt"
            (cd "$g09_dir" && git add -A >/dev/null 2>&1) || true
            local g09_committed=1
            # -c core.hooksPath=/dev/null and --no-verify: a host or CI
            # runner with a global core.hooksPath (this repo's own
            # `just install-hooks` sets a repo-local one, but a user could
            # set a global one too) must not be able to fail this commit
            # and silently SKIP all of the coverage below.
            (cd "$g09_dir" && git -c core.hooksPath=/dev/null commit --no-verify -q -m init >/dev/null 2>&1) || g09_committed=0

            if [[ "$g09_committed" -ne 1 ]]; then
                print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-C)" "SKIP" \
                    "git commit failed in test environment"
                print_test_result "ls #ls-git-column: all-clean repo matches --git=never (implicit one-per-line)" "SKIP" \
                    "git commit failed in test environment"
                print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-l)" "SKIP" \
                    "git commit failed in test environment"
                print_test_result "ls #119: clean tracked file operand lists flush left" "SKIP" \
                    "git commit failed in test environment"
                print_test_result "ls #119: modified file operand keeps the git indicator" "SKIP" \
                    "git commit failed in test environment"
            else
                # -C: explicit multi-column, fixed width so the arithmetic
                # is deterministic regardless of the host's real terminal.
                # Pin the exact literal (not just equality with --git=never)
                # so a host where git status silently comes back empty
                # can't make this pass vacuously: -w 40, two 10-char names,
                # colwidth = (10+8)&~7 = 16, both fit on one row.
                local g09_c_always g09_c_never
                g09_c_always=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always -C -w 40 2>/dev/null | strip_ansi)
                g09_c_never=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=never -C -w 40 2>/dev/null | strip_ansi)
                local g09_c_expected=$'clean1.txt\tclean2.txt'
                if [[ "$g09_c_always" == "$g09_c_never" && "$g09_c_always" == "$g09_c_expected" ]]; then
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-C)" "PASS"
                else
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-C)" "FAIL" \
                        "Expected $(printf '%q' "$g09_c_expected"), got: $(printf '%q' "$g09_c_always")"
                fi

                # No -C: implicit non-tty single-column default (issue
                # #113's piped case), still with --git=always in effect.
                local g09_1_always g09_1_never
                g09_1_always=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always 2>/dev/null | strip_ansi)
                g09_1_never=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=never 2>/dev/null | strip_ansi)
                local g09_1_expected=$'clean1.txt\nclean2.txt'
                if [[ "$g09_1_always" == "$g09_1_never" && "$g09_1_always" == "$g09_1_expected" ]]; then
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (implicit one-per-line)" "PASS"
                else
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (implicit one-per-line)" "FAIL" \
                        "Expected $(printf '%q' "$g09_1_expected"), got: $(printf '%q' "$g09_1_always")"
                fi

                # -l: long format dispatches through printEntries_longFormat
                # -> printLongFormatEntryAligned -> display.printEntryName
                # (formatter.zig:489), a separate call site from -C/-1 that
                # forwards options independently. A fix scoped only to the
                # columnar/one-per-line paths would leave this one buggy.
                # Rather than pin the whole line (owner/group/perm bits are
                # environment-dependent), require byte-identical output
                # between --git=always and --git=never AND a discriminating
                # negative check: the fixed name field is preceded by
                # exactly one space (the date column's own trailing space),
                # so two or more spaces immediately before the filename at
                # end of line can only happen if the 3-column reservation
                # leaked in. This "exactly one space" invariant depends on
                # clean1.txt and clean2.txt formatting to equal-length
                # timestamps (writeDateColored in formatter.zig pads to
                # max_time_width before its own trailing space) -- true here
                # because both files are created back-to-back with the
                # default time style, but a future edit that changes the
                # fixture's mtimes or time style could desync the two
                # timestamps' widths and produce a confusing false FAIL.
                local g09_l_always g09_l_never
                g09_l_always=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always -l 2>/dev/null | strip_ansi)
                g09_l_never=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=never -l 2>/dev/null | strip_ansi)
                if [[ "$g09_l_always" == "$g09_l_never" ]] \
                    && printf '%s\n' "$g09_l_always" | grep -qE '(^|[^ ]) clean1\.txt$' \
                    && ! printf '%s\n' "$g09_l_always" | grep -qE '  clean1\.txt$'; then
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-l)" "PASS"
                else
                    print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-l)" "FAIL" \
                        "Expected byte-identical -l output with exactly one space before the name, got --git=always: $(printf '%q' "$g09_l_always")"
                fi

                # --- Issue #119: a non-directory OPERAND must make the
                # same per-section git-column decision a directory
                # section makes. Operands were printed one at a time by
                # listSingleFileEntry, which never reaches the
                # printEntries seam that owns the decision, so a clean
                # tracked file reserved the column and came out indented
                # by three spaces while the very same file listed flush
                # left as a section entry. Compare against the section
                # rendering AND pin the literal, so a host where git
                # status silently comes back empty cannot pass this
                # vacuously.
                local g119_operand
                g119_operand=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always clean1.txt 2>/dev/null | strip_ansi)
                if [[ "$g119_operand" == "clean1.txt" ]]; then
                    print_test_result "ls #119: clean tracked file operand lists flush left" "PASS"
                else
                    print_test_result "ls #119: clean tracked file operand lists flush left" "FAIL" \
                        "Expected 'clean1.txt', got: $(printf '%q' "$g119_operand")"
                fi

                # Positive control: prove git status is actually live in
                # this environment, so the two PASSes above cannot be
                # explained by git status silently coming back empty
                # (GitContext.init / refreshStatus in git.zig swallow
                # failures and fall back to .not_in_repo for every entry,
                # which would make --git=always and --git=never collapse
                # to the same bytes even on unfixed code). Deliberately NOT
                # using explicit -1 here: that flag unconditionally zeroes
                # show_git_status itself (formatter.zig's one_per_line
                # branch), which is unrelated pre-existing behavior that
                # would mask the control -- use the same implicit
                # non-tty-default invocation as the "(implicit
                # one-per-line)" test above.
                printf 'modified' >"$g09_dir/clean1.txt"
                local g09_dirty_output
                g09_dirty_output=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always 2>/dev/null | strip_ansi)
                if [[ "$g09_dirty_output" == M\ \ clean1.txt* ]]; then
                    print_test_result "ls #ls-git-column: git status positive control (modified file shows M  prefix)" "PASS"
                else
                    print_test_result "ls #ls-git-column: git status positive control (modified file shows M  prefix)" "FAIL" \
                        "Expected output to start with 'M  clean1.txt', got: $(printf '%q' "$g09_dirty_output")"
                fi

                # Negative space for the #119 test above: dropping the
                # column is owed to the section being clean, not to the
                # operand path skipping git status altogether. clean1.txt
                # is modified by the positive control just above, so the
                # same operand must now carry its indicator.
                local g119_dirty_operand
                g119_dirty_operand=$(cd "$g09_dir" && NO_COLOR=1 "$binary" --git=always clean1.txt 2>/dev/null | strip_ansi)
                if [[ "$g119_dirty_operand" == "M  clean1.txt" ]]; then
                    print_test_result "ls #119: modified file operand keeps the git indicator" "PASS"
                else
                    print_test_result "ls #119: modified file operand keeps the git indicator" "FAIL" \
                        "Expected 'M  clean1.txt', got: $(printf '%q' "$g119_dirty_operand")"
                fi
            fi
        fi

        # --- -R: each directory section decides independently. A dirty
        # root (an untracked file) must keep the reserved column for
        # every root entry, while a clean subdirectory nested inside the
        # same run lists flush left. ---
        local g09r_dir=$(create_temp_dir)
        mkdir -p "$g09r_dir/subdir"
        (cd "$g09r_dir" && git init -q >/dev/null 2>&1) || true
        if [[ ! -d "$g09r_dir/.git" ]]; then
            print_test_result "ls #ls-git-column: -R decides each directory section independently" "SKIP" \
                "git init failed in test environment"
        else
            (cd "$g09r_dir" && git config commit.gpgsign false) || true
            (cd "$g09r_dir" && git config user.email "test@example.com") || true
            (cd "$g09r_dir" && git config user.name "Test User") || true
            create_temp_file "a" "$g09r_dir/subdir/clean_a.txt"
            create_temp_file "b" "$g09r_dir/subdir/clean_b.txt"
            (cd "$g09r_dir" && git add -A >/dev/null 2>&1) || true
            local g09r_committed=1
            # -c core.hooksPath=/dev/null and --no-verify: see the g09
            # block above for why this must not be able to SKIP silently
            # on a host with a global core.hooksPath.
            (cd "$g09r_dir" && git -c core.hooksPath=/dev/null commit --no-verify -q -m init >/dev/null 2>&1) || g09r_committed=0

            if [[ "$g09r_committed" -ne 1 ]]; then
                print_test_result "ls #ls-git-column: -R decides each directory section independently" "SKIP" \
                    "git commit failed in test environment"
            else
                create_temp_file "new" "$g09r_dir/untracked.txt"
                # Run from inside the repo (matching the operand-resolution
                # test above): GitContext is anchored to the process cwd,
                # so invoking against an absolute path from a different cwd
                # would resolve git status against the wrong repository --
                # a separate, pre-existing limitation this test must not
                # trip over.
                local g09r_expected
                g09r_expected=$'.:\n   subdir\n?? untracked.txt\n\n./subdir:\nclean_a.txt\nclean_b.txt'
                local g09r_output
                g09r_output=$(cd "$g09r_dir" && NO_COLOR=1 "$binary" --git=always -R . 2>/dev/null | strip_ansi)
                if [[ "$g09r_output" == "$g09r_expected" ]]; then
                    print_test_result "ls #ls-git-column: -R decides each directory section independently" "PASS"
                else
                    print_test_result "ls #ls-git-column: -R decides each directory section independently" "FAIL" \
                        "Expected $(printf '%q' "$g09r_expected"), got: $(printf '%q' "$g09r_output")"
                fi
            fi
        fi

        # NOTE: a mirror-image "-R clean parent / dirty child" shell test was
        # considered here but is not reachable at the CLI: recursive git
        # status lookups resolve subdirectory entries by bare basename
        # (src/ls/entry_collector.zig:208-209 -> GitRepo.getFileStatus ->
        # makeRelativePath in src/common/git.zig, which does not prepend the
        # subdirectory prefix), while the status map is keyed by
        # repo-root-relative paths from `git status --porcelain`. So any
        # subdirectory entry looks up its bare name against the map and
        # misses, resolving to .clean regardless of its real status -- a
        # pre-existing bug outside this issue's scope (entry_collector.zig /
        # git.zig are not in the implementer's allowed file list). Only the
        # top-level section (operand ".", cwd == repo root) gets correct
        # statuses, which is exactly what the dirty-root/clean-child test
        # above exercises. The reverse (parent-then-child, clean-after-dirty)
        # ordering is covered at unit level instead, where git_status can be
        # set directly on synthetic types.Entry values without going through
        # basename resolution: see "printEntries: per-call git column
        # decision does not depend on other calls" and "printEntries:
        # sequential calls into the same writer do not leak the reserve
        # decision" in src/ls/integration_test.zig.
    else
        print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-C)" "SKIP" \
            "git not found on PATH"
        print_test_result "ls #ls-git-column: all-clean repo matches --git=never (implicit one-per-line)" "SKIP" \
            "git not found on PATH"
        print_test_result "ls #ls-git-column: all-clean repo matches --git=never (-l)" "SKIP" \
            "git not found on PATH"
        print_test_result "ls #ls-git-column: -R decides each directory section independently" "SKIP" \
            "git not found on PATH"
        print_test_result "ls #119: clean tracked file operand lists flush left" "SKIP" \
            "git not found on PATH"
        print_test_result "ls #119: modified file operand keeps the git indicator" "SKIP" \
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

    # --- Operand that cannot be stat'd: stderr only, never a stdout section.
    # Such an operand used to be classified into the directory group, which
    # printed a bogus "missing:" header on stdout before the diagnostic. GNU
    # 9.5 prints only the diagnostic and exits 2:
    #     $ ls -1 z_file missing a_dir
    #     ls: cannot access 'missing': ...      [stderr]
    #     z_file                                [stdout]
    #                                           [stdout blank line]
    #     a_dir:                                [stdout]
    #     x                                     [stdout]
    # Our wording is "ls: 'missing': No such file or directory", so the stderr
    # assertion pins the operand name and the "No such file" substring rather
    # than GNU's exact "cannot access" phrasing. Both halves are asserted: a
    # stdout-only check would still pass if the diagnostic vanished entirely.
    local f10_dir=$(create_temp_dir)
    mkdir -p "$f10_dir/a_dir"
    create_temp_file "x" "$f10_dir/a_dir/x"
    create_temp_file "z" "$f10_dir/z_file"

    local f10_out="$TEMP_DIR/ls_f10_stdout"
    local f10_err="$TEMP_DIR/ls_f10_stderr"
    local f10_status=0
    (cd "$f10_dir" && NO_COLOR=1 "$binary" -1 z_file missing a_dir) \
        >"$f10_out" 2>"$f10_err" || f10_status=$?

    local f10_stdout
    f10_stdout=$(strip_ansi <"$f10_out")
    local f10_stderr
    f10_stderr=$(strip_ansi <"$f10_err")

    if echo "$f10_stdout" | grep -qFx "missing:"; then
        print_test_result "ls unstattable operand produces no stdout header" "FAIL" \
            "Expected no 'missing:' header on stdout, got: $(printf '%q' "$f10_stdout")"
    else
        print_test_result "ls unstattable operand produces no stdout header" "PASS"
    fi

    local f10_expected=$'z_file\n\na_dir:\nx'
    if [[ "$f10_stdout" == "$f10_expected" ]]; then
        print_test_result "ls unstattable operand is dropped from every stdout section" "PASS"
    else
        print_test_result "ls unstattable operand is dropped from every stdout section" "FAIL" \
            "Expected $(printf '%q' "$f10_expected"), got: $(printf '%q' "$f10_stdout")"
    fi

    if [[ "$f10_stderr" == *"missing"* && "$f10_stderr" == *"No such file"* ]]; then
        print_test_result "ls unstattable operand still names the operand on stderr" "PASS"
    else
        print_test_result "ls unstattable operand still names the operand on stderr" "FAIL" \
            "Expected stderr naming 'missing' and 'No such file', got: $(printf '%q' "$f10_stderr")"
    fi

    if [[ "$f10_status" -eq 2 ]]; then
        print_test_result "ls exits 2 when an operand cannot be stat'd" "PASS"
    else
        print_test_result "ls exits 2 when an operand cannot be stat'd" "FAIL" \
            "Expected exit 2, got $f10_status"
    fi

    # --- -d with multiple operands: a directory operand is an ordinary entry.
    # It sorts together with the file operands and never gets a "dir:" header.
    # GNU 9.5:
    #     $ ls -1d z_file a_dir
    #     a_dir
    #     z_file
    # Argv order is z_file first, so this also proves the sort is applied.
    local f11_dir=$(create_temp_dir)
    mkdir -p "$f11_dir/a_dir"
    create_temp_file "x" "$f11_dir/a_dir/x"
    create_temp_file "z" "$f11_dir/z_file"

    local f11_output
    f11_output=$(cd "$f11_dir" && NO_COLOR=1 "$binary" -1d z_file a_dir 2>/dev/null | strip_ansi)
    local f11_expected=$'a_dir\nz_file'
    if [[ "$f11_output" == "$f11_expected" ]]; then
        print_test_result "ls -d sorts a directory operand together with file operands" "PASS"
    else
        print_test_result "ls -d sorts a directory operand together with file operands" "FAIL" \
            "Expected $(printf '%q' "$f11_expected"), got: $(printf '%q' "$f11_output")"
    fi

    if echo "$f11_output" | grep -qFx "a_dir:"; then
        print_test_result "ls -d gives a directory operand no header and no contents" "FAIL" \
            "Expected no 'a_dir:' header, got: $(printf '%q' "$f11_output")"
    elif echo "$f11_output" | grep -qFx "x"; then
        print_test_result "ls -d gives a directory operand no header and no contents" "FAIL" \
            "Expected no directory contents, got: $(printf '%q' "$f11_output")"
    else
        print_test_result "ls -d gives a directory operand no header and no contents" "PASS"
    fi

    local f11_status=0
    (cd "$f11_dir" && NO_COLOR=1 "$binary" -1d z_file a_dir >/dev/null 2>&1) || f11_status=$?
    if [[ "$f11_status" -eq 0 ]]; then
        print_test_result "ls -d with multiple operands exits 0" "PASS"
    else
        print_test_result "ls -d with multiple operands exits 0" "FAIL" \
            "Expected exit 0, got $f11_status"
    fi

    # ================================================================
    # Issue #113: default format must be one-per-line when stdout is
    # not a terminal (POSIX/GNU/BSD parity). File names and pinned
    # bytes below are taken verbatim from the GNU coreutils 9.5
    # reference capture in the issue.
    # ================================================================
    echo -e "${CYAN}Testing ls #113: default format is not-a-terminal aware...${NC}"

    local i113_dir=$(create_temp_dir)
    create_temp_file "" "$i113_dir/aaa"
    create_temp_file "" "$i113_dir/bbbbbbbbbbbb"
    create_temp_file "" "$i113_dir/ccc"

    local i113_expected=$'aaa\nbbbbbbbbbbbb\nccc'

    # Default output through a pipe (command substitution is inherently
    # non-tty stdout) must be exactly one entry per line, no padding.
    local i113_piped
    i113_piped=$(NO_COLOR=1 "$binary" "$i113_dir" 2>/dev/null | strip_ansi)
    if [[ "$i113_piped" == "$i113_expected" ]]; then
        print_test_result "ls #113: default output piped is one entry per line" "PASS"
    else
        print_test_result "ls #113: default output piped is one entry per line" "FAIL" \
            "Expected $(printf '%q' "$i113_expected"), got: $(printf '%q' "$i113_piped")"
    fi

    # Default output redirected to a regular file must behave identically
    # to the piped case (both are simply "not a terminal").
    local i113_outfile
    i113_outfile=$(mktemp "$TEMP_DIR/ls113_redirect_XXXXXX")
    NO_COLOR=1 "$binary" "$i113_dir" >"$i113_outfile" 2>/dev/null
    local i113_redirected
    i113_redirected=$(strip_ansi <"$i113_outfile")
    if [[ "$i113_redirected" == "$i113_expected" ]]; then
        print_test_result "ls #113: default output redirected to a file is one entry per line" "PASS"
    else
        print_test_result "ls #113: default output redirected to a file is one entry per line" "FAIL" \
            "Expected $(printf '%q' "$i113_expected"), got: $(printf '%q' "$i113_redirected")"
    fi

    # No line of the non-terminal default output may carry trailing or
    # internal column-padding whitespace: padded entries silently break
    # anchored patterns like `grep -v '\.lock$'` in downstream pipelines
    # (the original symptom). A single trailing-space check ($) is not
    # enough here: with these 3 names at the default 80-column fallback
    # the buggy multi-column grid happens to fit on one row ending
    # exactly at "ccc" with no trailing pad, so also reject any run of
    # two or more spaces (the column separator the buggy grid inserts
    # between "aaa" and "bbbbbbbbbbbb"), mirroring the Zig companion
    # check at integration_test.zig ("...has no trailing whitespace on
    # any line").
    if printf '%s' "$i113_piped" | grep -qE ' $|  '; then
        print_test_result "ls #113: default piped output has no trailing whitespace" "FAIL" \
            "Found a line with trailing or internal padding whitespace: $(printf '%q' "$i113_piped")"
    else
        print_test_result "ls #113: default piped output has no trailing whitespace" "PASS"
    fi

    # An explicit format flag must always win over the non-tty default.
    # -C: multi-column sorted down columns stays multi-column even piped.
    local i113_C_output
    i113_C_output=$(NO_COLOR=1 "$binary" -C -w 80 "$i113_dir" 2>/dev/null | strip_ansi)
    local i113_C_lines
    i113_C_lines=$(printf '%s\n' "$i113_C_output" | wc -l | tr -d ' ')
    if [[ "$i113_C_lines" -eq 1 && "$i113_C_output" == *"aaa"* && \
          "$i113_C_output" == *"bbbbbbbbbbbb"* && "$i113_C_output" == *"ccc"* ]]; then
        print_test_result "ls #113: explicit -C keeps multi-column layout when piped" "PASS"
    else
        print_test_result "ls #113: explicit -C keeps multi-column layout when piped" "FAIL" \
            "Expected all 3 names on a single multi-column line, got: $(printf '%q' "$i113_C_output")"
    fi

    # -x: multi-column sorted across rows stays multi-column even piped.
    # With only 3 short names and -w 80 the grid fits in a single row,
    # which is byte-identical to -C's output and cannot distinguish
    # across-row from down-column ordering. Use a separate, dedicated
    # directory and a narrow width to force >=2 rows, then assert the
    # first row holds the first entries in reading order ("aaa", "bbb")
    # rather than the down-column order ("aaa", "ccc") -- same intent as
    # the Zig companion test "columns_across: -x first row contains
    # first entries" (same 4 names and the same -w 20). On the BSD grid
    # these 3-char names give a column width of (3+8)&~7 = 8, so 20/8 = 2
    # columns fit and the four names take a 2x2 grid. A narrower width
    # such as -w 12 would fit only ONE column and print one name per line,
    # which cannot show traversal order at all.
    local i113_x_dir=$(create_temp_dir)
    create_temp_file "" "$i113_x_dir/aaa"
    create_temp_file "" "$i113_x_dir/bbb"
    create_temp_file "" "$i113_x_dir/ccc"
    create_temp_file "" "$i113_x_dir/ddd"

    local i113_x_output
    i113_x_output=$(NO_COLOR=1 "$binary" -x -w 20 "$i113_x_dir" 2>/dev/null | strip_ansi)
    local i113_x_lines
    i113_x_lines=$(printf '%s\n' "$i113_x_output" | wc -l | tr -d ' ')
    local i113_x_first_line
    i113_x_first_line=$(printf '%s\n' "$i113_x_output" | head -n 1)
    if [[ "$i113_x_lines" -ge 2 && "$i113_x_first_line" == *"aaa"* && \
          "$i113_x_first_line" == *"bbb"* ]]; then
        print_test_result "ls #113: explicit -x keeps across-row multi-column layout when piped" "PASS"
    else
        print_test_result "ls #113: explicit -x keeps across-row multi-column layout when piped" "FAIL" \
            "Expected first row to contain 'aaa' and 'bbb' across >=2 lines, got: $(printf '%q' "$i113_x_output")"
    fi

    # -m: comma-separated format is unaffected by the non-tty default.
    local i113_m_expected='aaa, bbbbbbbbbbbb, ccc'
    local i113_m_output
    i113_m_output=$(NO_COLOR=1 "$binary" -m "$i113_dir" 2>/dev/null | strip_ansi)
    if [[ "$i113_m_output" == "$i113_m_expected" ]]; then
        print_test_result "ls #113: explicit -m keeps comma-separated format when piped" "PASS"
    else
        print_test_result "ls #113: explicit -m keeps comma-separated format when piped" "FAIL" \
            "Expected $(printf '%q' "$i113_m_expected"), got: $(printf '%q' "$i113_m_output")"
    fi

    # -1 is already the not-a-terminal default and must stay unchanged.
    local i113_1_output
    i113_1_output=$(NO_COLOR=1 "$binary" -1 "$i113_dir" 2>/dev/null | strip_ansi)
    if [[ "$i113_1_output" == "$i113_expected" ]]; then
        print_test_result "ls #113: explicit -1 is unchanged when piped" "PASS"
    else
        print_test_result "ls #113: explicit -1 is unchanged when piped" "FAIL" \
            "Expected $(printf '%q' "$i113_expected"), got: $(printf '%q' "$i113_1_output")"
    fi

    # -l is already one entry per line and must not gain or lose lines.
    local i113_l_output
    i113_l_output=$(NO_COLOR=1 "$binary" -l "$i113_dir" 2>/dev/null | strip_ansi)
    local i113_l_lines
    i113_l_lines=$(printf '%s\n' "$i113_l_output" | wc -l | tr -d ' ')
    # 3 file lines plus one "total N" line.
    if [[ "$i113_l_lines" -eq 4 ]]; then
        print_test_result "ls #113: -l is unaffected when piped" "PASS"
    else
        print_test_result "ls #113: -l is unaffected when piped" "FAIL" \
            "Expected 4 lines (total + 3 files), got $i113_l_lines: $(printf '%q' "$i113_l_output")"
    fi

    # -R: every directory section (including the top-level one) must be
    # one entry per line when piped, with headers/blank-line separation
    # unchanged.
    mkdir -p "$i113_dir/sub"
    create_temp_file "" "$i113_dir/sub/zzz"
    local i113_R_expected
    i113_R_expected=$(printf '%s:\naaa\nbbbbbbbbbbbb\nccc\nsub\n\n%s/sub:\nzzz' \
        "$i113_dir" "$i113_dir")
    local i113_R_output
    i113_R_output=$(NO_COLOR=1 "$binary" -R "$i113_dir" 2>/dev/null | strip_ansi)
    if [[ "$i113_R_output" == "$i113_R_expected" ]]; then
        print_test_result "ls #113: -R prints one entry per line in every section when piped" "PASS"
    else
        print_test_result "ls #113: -R prints one entry per line in every section when piped" "FAIL" \
            "Expected $(printf '%q' "$i113_R_expected"), got: $(printf '%q' "$i113_R_output")"
    fi

    # ================================================================
    # Issue #ls-column-tabs: -C padding must use tabs (matching macOS
    # /bin/ls's tab-stop columnizer), never leave trailing whitespace
    # on a row, and match colwidth = (maxlen + 8) & ~7 exactly. GNU is
    # explicitly NOT the reference for this fix -- the fixtures below
    # are pinned against the real /bin/ls on the maintainer's macOS
    # host (see the Zig companion tests in integration_test.zig, same
    # fixtures, prefixed "columnar: -C").
    # ================================================================
    echo -e "${CYAN}Testing ls #ls-column-tabs: -C uses BSD tab-stop padding...${NC}"

    local tabs_partial_dir=$(create_temp_dir)
    create_temp_file "" "$tabs_partial_dir/a"
    create_temp_file "" "$tabs_partial_dir/bb"
    create_temp_file "" "$tabs_partial_dir/ccc"
    create_temp_file "" "$tabs_partial_dir/dddd"
    create_temp_file "" "$tabs_partial_dir/eeeee"
    create_temp_file "" "$tabs_partial_dir/ffffff"
    create_temp_file "" "$tabs_partial_dir/ggggggg"

    # colwidth = (7+8)&~7 = 8, num_cols = 24/8 = 3, num_rows =
    # ceil(7/3) = 3 -- the third column only has one entry, so rows 2
    # and 3 are partially filled and must not end in a tab.
    local tabs_partial_expected
    tabs_partial_expected=$'a\tdddd\tggggggg\nbb\teeeee\nccc\tffffff'
    local tabs_partial_output
    tabs_partial_output=$(NO_COLOR=1 "$binary" -C -w 24 "$tabs_partial_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_partial_output" == "$tabs_partial_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -C partially filled last row has no trailing tab" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -C partially filled last row has no trailing tab" "FAIL" \
            "Expected $(printf '%q' "$tabs_partial_expected"), got: $(printf '%q' "$tabs_partial_output")"
    fi

    local tabs_len8_dir=$(create_temp_dir)
    local i
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        create_temp_file "" "$tabs_len8_dir/aaaaaa$i"
    done

    # colwidth = (8+8)&~7 = 16, num_cols = 80/16 = 5, num_rows =
    # ceil(12/5) = 3; column-major fill-down only produces 4 visible
    # columns since the 5th column's first index (12) is out of range.
    local tabs_len8_expected
    tabs_len8_expected=$'aaaaaa01\taaaaaa04\taaaaaa07\taaaaaa10\naaaaaa02\taaaaaa05\taaaaaa08\taaaaaa11\naaaaaa03\taaaaaa06\taaaaaa09\taaaaaa12'
    local tabs_len8_output
    tabs_len8_output=$(NO_COLOR=1 "$binary" -C -w 80 "$tabs_len8_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_len8_output" == "$tabs_len8_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -C matches /bin/ls at the maxlen=8 tab-stop boundary" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -C matches /bin/ls at the maxlen=8 tab-stop boundary" "FAIL" \
            "Expected $(printf '%q' "$tabs_len8_expected"), got: $(printf '%q' "$tabs_len8_output")"
    fi

    local tabs_len16_dir=$(create_temp_dir)
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        create_temp_file "" "$tabs_len16_dir/aaaaaaaaaaaaaa$i"
    done

    # colwidth = (16+8)&~7 = 24, num_cols = 80/24 = 3, num_rows =
    # ceil(12/3) = 4 -- an exact fill, unlike the maxlen=8 case above.
    local tabs_len16_expected
    tabs_len16_expected=$'aaaaaaaaaaaaaa01\taaaaaaaaaaaaaa05\taaaaaaaaaaaaaa09\naaaaaaaaaaaaaa02\taaaaaaaaaaaaaa06\taaaaaaaaaaaaaa10\naaaaaaaaaaaaaa03\taaaaaaaaaaaaaa07\taaaaaaaaaaaaaa11\naaaaaaaaaaaaaa04\taaaaaaaaaaaaaa08\taaaaaaaaaaaaaa12'
    local tabs_len16_output
    tabs_len16_output=$(NO_COLOR=1 "$binary" -C -w 80 "$tabs_len16_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_len16_output" == "$tabs_len16_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -C matches /bin/ls at the maxlen=16 tab-stop boundary" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -C matches /bin/ls at the maxlen=16 tab-stop boundary" "FAIL" \
            "Expected $(printf '%q' "$tabs_len16_expected"), got: $(printf '%q' "$tabs_len16_output")"
    fi

    # Mixed widths (1, 9, 5, 8, 2 chars): longest name is 9, so
    # colwidth = (9+8)&~7 = 16 and all 5 entries fit on one row at
    # COLUMNS=80. Pinned against real /bin/ls: this is the one fixture
    # where a single '\t' per entry is NOT enough -- "a" (width 1)
    # needs two tabs to reach column 16 (1 -> 8 -> 16), and "ccccc"
    # (width 5, column-relative start 32) needs two tabs to reach 48
    # (37 -> 40 -> 48). An implementation that always emits exactly one
    # '\t' per padded entry passes every other fixture above but fails
    # this one.
    local tabs_mixed_dir=$(create_temp_dir)
    create_temp_file "" "$tabs_mixed_dir/a"
    create_temp_file "" "$tabs_mixed_dir/bbbbbbbbb"
    create_temp_file "" "$tabs_mixed_dir/ccccc"
    create_temp_file "" "$tabs_mixed_dir/dddddddd"
    create_temp_file "" "$tabs_mixed_dir/ee"

    local tabs_mixed_expected
    tabs_mixed_expected=$'a\t\tbbbbbbbbb\tccccc\t\tdddddddd\tee'
    local tabs_mixed_output
    tabs_mixed_output=$(NO_COLOR=1 "$binary" -C -w 80 "$tabs_mixed_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_mixed_output" == "$tabs_mixed_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -C pads a short entry across multiple tab stops, not a single tab" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -C pads a short entry across multiple tab stops, not a single tab" "FAIL" \
            "Expected $(printf '%q' "$tabs_mixed_expected"), got: $(printf '%q' "$tabs_mixed_output")"
    fi

    # No row of any fixture above may end in a space or a tab.
    local tabs_trailing_ws_found=0
    local tabs_ws_output
    for tabs_ws_output in "$tabs_partial_output" "$tabs_len8_output" \
        "$tabs_len16_output" "$tabs_mixed_output"; do
        if printf '%s' "$tabs_ws_output" | grep -qE $'[ \t]$'; then
            tabs_trailing_ws_found=1
        fi
    done
    if [[ "$tabs_trailing_ws_found" -eq 0 ]]; then
        print_test_result "ls #ls-column-tabs: -C rows never end in space or tab" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -C rows never end in space or tab" "FAIL" \
            "Found a row ending in space or tab in one of the -C fixture outputs above"
    fi

    # -x (printColumnarAcross) lays out on the SAME grid as -C and differs
    # only in traversal order: BSD fills across rows for -x and down columns
    # for -C, but both round the widest cell up to the next 8-column tab
    # stop and separate cells with literal tabs. -x used a flat two-space
    # pad at (max_width + 2) instead, which both mis-sized the column and
    # emitted the wrong separator byte. With max_width = 3 the column is
    # (3+8)&~7 = 8 wide and only 20/8 = 2 columns fit, so these four names
    # take two rows with a single tab hop in each gap. Pinned against macOS
    # /bin/ls -x at COLUMNS=20, which prints "aaa\tbbb\nccc\tddd"; the old
    # two-space pad put all four names on one row.
    local tabs_x_dir=$(create_temp_dir)
    create_temp_file "" "$tabs_x_dir/aaa"
    create_temp_file "" "$tabs_x_dir/bbb"
    create_temp_file "" "$tabs_x_dir/ccc"
    create_temp_file "" "$tabs_x_dir/ddd"

    local tabs_x_expected
    tabs_x_expected=$'aaa\tbbb\nccc\tddd'
    local tabs_x_output
    tabs_x_output=$(NO_COLOR=1 "$binary" -x -w 20 "$tabs_x_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_x_output" == "$tabs_x_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -x pads with tabs on the -C tab-stop grid" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -x pads with tabs on the -C tab-stop grid" "FAIL" \
            "Expected $(printf '%q' "$tabs_x_expected"), got: $(printf '%q' "$tabs_x_output")"
    fi

    # The four-name fixture above only ever needs one tab hop per gap. This
    # one has nine names of increasing width (max 9), so colwidth =
    # (9+8)&~7 = 16 and num_cols = 40/16 = 2, and every gap needs TWO hops
    # to reach column 16 (1 -> 8 -> 16 for "a", 3 -> 8 -> 16 for "ccc", and
    # so on). An implementation that emits exactly one tab per gap passes
    # the fixture above and fails here. Pinned against macOS /bin/ls -x at
    # COLUMNS=40, which also proves the column COUNT: the two-space pad fit
    # three columns where BSD fits two.
    local tabs_x_wide_dir=$(create_temp_dir)
    local tabs_x_name
    for tabs_x_name in a bb ccc dddd eeeee ffffff ggggggg hhhhhhhh iiiiiiiii; do
        create_temp_file "" "$tabs_x_wide_dir/$tabs_x_name"
    done

    local tabs_x_wide_expected
    tabs_x_wide_expected=$'a\t\tbb\nccc\t\tdddd\neeeee\t\tffffff\nggggggg\t\thhhhhhhh\niiiiiiiii'
    local tabs_x_wide_output
    tabs_x_wide_output=$(NO_COLOR=1 "$binary" -x -w 40 "$tabs_x_wide_dir" 2>/dev/null | strip_ansi)
    if [[ "$tabs_x_wide_output" == "$tabs_x_wide_expected" ]]; then
        print_test_result "ls #ls-column-tabs: -x pads across intervening tab stops" "PASS"
    else
        print_test_result "ls #ls-column-tabs: -x pads across intervening tab stops" "FAIL" \
            "Expected $(printf '%q' "$tabs_x_wide_expected"), got: $(printf '%q' "$tabs_x_wide_output")"
    fi

    # The -s block-count field must be sized to the WIDEST count in the
    # section and right-aligned inside it, not padded to a fixed four
    # columns. An empty file occupies 0 blocks and an 8 KiB file occupies
    # 16 (512-byte units) on APFS and on ext4 alike, so the field is two
    # columns wide here. Pinned against macOS /bin/ls -1s, which prints
    # " 0 a" / "16 b"; the hardcoded width printed "   0 a" / "  16 b".
    # GNU `gls -1s` sizes the field the same way.
    local sfield_dir=$(create_temp_dir)
    create_temp_file "" "$sfield_dir/a"
    dd if=/dev/zero of="$sfield_dir/b" bs=1024 count=8 2>/dev/null

    local sfield_expected
    sfield_expected=$'total 16\n 0 a\n16 b'
    local sfield_output
    sfield_output=$(NO_COLOR=1 "$binary" -1s "$sfield_dir" 2>/dev/null | strip_ansi)
    if [[ "$sfield_output" == "$sfield_expected" ]]; then
        print_test_result "ls #ls-s-field-width: -s sizes the block field to the widest count" "PASS"
    else
        print_test_result "ls #ls-s-field-width: -s sizes the block field to the widest count" "FAIL" \
            "Expected $(printf '%q' "$sfield_expected"), got: $(printf '%q' "$sfield_output")"
    fi

    # Negative space for the test above: a section whose counts are all a
    # single digit gets a one-column field, which is where a hardcoded four
    # is most visibly wrong. Two empty files occupy no blocks on either
    # filesystem. Pinned against macOS /bin/ls -1s ("0 a" / "0 b").
    local snarrow_dir=$(create_temp_dir)
    create_temp_file "" "$snarrow_dir/a"
    create_temp_file "" "$snarrow_dir/b"

    local snarrow_expected
    snarrow_expected=$'total 0\n0 a\n0 b'
    local snarrow_output
    snarrow_output=$(NO_COLOR=1 "$binary" -1s "$snarrow_dir" 2>/dev/null | strip_ansi)
    if [[ "$snarrow_output" == "$snarrow_expected" ]]; then
        print_test_result "ls #ls-s-field-width: -s uses a one-column field for single-digit counts" "PASS"
    else
        print_test_result "ls #ls-s-field-width: -s uses a one-column field for single-digit counts" "FAIL" \
            "Expected $(printf '%q' "$snarrow_expected"), got: $(printf '%q' "$snarrow_output")"
    fi

    # Long format prints the -s prefix from its own call site, a separate
    # width computation from the block-only tests above. Only the prefix is
    # asserted: our nlink/owner/group/size columns follow GNU's dynamic,
    # section-scoped sizing (see issue #124 below), which is not the same
    # layout BSD's ls produces, so a whole-line comparison against a BSD
    # reference would fail for reasons unrelated to this assertion. Pinned
    # against macOS /bin/ls -ls on this fixture, whose lines begin " 0 -"
    # and "16 -".
    local slong_output
    slong_output=$(NO_COLOR=1 "$binary" -ls "$sfield_dir" 2>/dev/null | strip_ansi)
    local slong_a slong_b
    slong_a=$(printf '%s\n' "$slong_output" | sed -n '2p')
    slong_b=$(printf '%s\n' "$slong_output" | sed -n '3p')
    if [[ "${slong_a:0:4}" == " 0 -" && "${slong_b:0:4}" == "16 -" ]]; then
        print_test_result "ls #ls-s-field-width: -l -s sizes the block field to the widest count" "PASS"
    else
        print_test_result "ls #ls-s-field-width: -l -s sizes the block field to the widest count" "FAIL" \
            "Expected lines starting ' 0 -' and '16 -', got: $(printf '%q' "$slong_a") and $(printf '%q' "$slong_b")"
    fi

    echo -e "${CYAN}Testing issue #124: -l nlink/owner/group/size column widths...${NC}"

    # Real system fixture: /run/systemd/netif, /etc/hostname and /usr give
    # owner/group names of two different widths in one section --
    # "root" (4 chars) and "systemd-network" (15 chars, a real system
    # account) -- which the Zig-level unit tests can only approximate with
    # numeric-uid fallback strings for host portability. Rather than
    # hardcoding the exact byte values this host happens to produce today
    # (a different /usr link count, hostname length, or systemd-network
    # uid on another Linux host would false-FAIL a fixed snapshot even
    # against a correct fix), the expected prefix is derived live from a
    # real GNU ls on the SAME fixture in the SAME run, so only genuine
    # divergence between our output and GNU's is a failure. Only the
    # prefix through the size column is compared; the date field depends
    # on each file's real mtime and the test's timezone, unrelated to
    # this bug, so it (and everything after it, including the path) is
    # stripped from both sides before comparing.
    # Integration tests pin PATH to zig-out/bin (see tests/integration.sh)
    # so that resolving system binaries under test can't mask the wrong
    # implementation -- but that means a bare `ls` here would silently
    # resolve to OUR ls, not a real one. Probe fixed absolute paths
    # instead, unaffected by that pinning.
    local gnu_ls=""
    local candidate
    for candidate in /usr/bin/ls /bin/ls; do
        if [[ -x "$candidate" ]] && LC_ALL=C "$candidate" --version 2>/dev/null | head -1 | grep -q "GNU coreutils"; then
            gnu_ls="$candidate"
            break
        fi
    done

    # The fixtures below are real system paths, so what they prove depends
    # on accounts this host may not have: /run/systemd/netif is only owned
    # by the 15-char systemd-network where systemd-networkd is installed,
    # and a runner without it (ubuntu-24.04-arm, macOS) would otherwise run
    # a test whose name promises a >8-char name against a fixture that has
    # none. Rather than guard on the account names, guard on the PROPERTY
    # each assertion needs, measured from GNU's own output on the exact
    # paths the assertion reads: two owner names of different widths, the
    # widest over 8 columns. Anything less SKIPs with the observed names in
    # the message, so a skip on CI is diagnosable instead of mysterious.
    #
    # Echoes "min_owner max_owner min_group max_group min_uid max_uid" over
    # the given paths, or nothing when any path cannot be listed.
    name_width_range() {
        local p line owner group uid
        local omin=99 omax=0 gmin=99 gmax=0 umin=99 umax=0
        for p in "$@"; do
            line=$(LC_ALL=C TZ=UTC "$gnu_ls" -ld "$p" 2>/dev/null) || return 1
            [[ -n "$line" ]] || return 1
            owner=$(printf '%s\n' "$line" | awk 'NR==1 {print $3}')
            group=$(printf '%s\n' "$line" | awk 'NR==1 {print $4}')
            uid=$(LC_ALL=C TZ=UTC "$gnu_ls" -ldn "$p" 2>/dev/null | awk 'NR==1 {print $3}')
            [[ -n "$owner" && -n "$group" && -n "$uid" ]] || return 1
            (( ${#owner} < omin )) && omin=${#owner}
            (( ${#owner} > omax )) && omax=${#owner}
            (( ${#group} < gmin )) && gmin=${#group}
            (( ${#group} > gmax )) && gmax=${#group}
            (( ${#uid} < umin )) && umin=${#uid}
            (( ${#uid} > umax )) && umax=${#uid}
        done
        printf '%s %s %s %s %s %s\n' "$omin" "$omax" "$gmin" "$gmax" "$umin" "$umax"
    }

    local w124_range=""
    local w124_omin=0 w124_omax=0 w124_umin=0 w124_umax=0
    if [[ -n "$gnu_ls" ]]; then
        w124_range=$(name_width_range /run/systemd/netif /etc/hostname /usr) || w124_range=""
    fi
    if [[ -n "$w124_range" ]]; then
        read -r w124_omin w124_omax _ _ w124_umin w124_umax <<<"$w124_range"
    fi

    # Needs owner names of two different widths with the widest over the 8
    # columns the old code hardcoded (the name case), and uids of two
    # different digit widths (the -n case).
    if [[ -n "$w124_range" ]] && (( w124_omax > 8 )) && (( w124_omax != w124_omin )) \
        && (( w124_umax != w124_umin )); then
        # Strips " Mon DD HH:MM ...path" (or " Mon DD  YYYY ...path") from
        # the end of a `ls -ld`-style line, leaving only the permission/
        # nlink/owner/group/size prefix (with its trailing separator
        # space) common to both our output and GNU's.
        strip_date_and_path() {
            sed -E 's/ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) .*$//'
        }

        # Drops the leading 10-char permission field, plus GNU's optional
        # 11th-position marker ('.' for an SELinux context, '+' for an ACL)
        # that occupies what would otherwise be the separator space on a
        # runner where any listed file carries one. That marker is unrelated
        # to issue #124 and vibeutils never emits it, so leaving it in the
        # comparison would FAIL forever on an SELinux-enabled host (e.g.
        # Fedora/RHEL) against an otherwise-correct fix. Comparing only from
        # character 11 onward scopes the assertion to the nlink/owner/group/
        # size region this issue is actually about; the permission string
        # itself is covered separately by the Zig-level regression guard.
        strip_perm_field() {
            sed -E 's/^.{10}//; s/^[.+]//'
        }

        local w124_ours w124_gnu
        w124_ours=$(NO_COLOR=1 "$binary" -ld /run/systemd/netif /etc/hostname /usr 2>/dev/null | strip_ansi)
        w124_gnu=$(LC_ALL=C TZ=UTC "$gnu_ls" -ld /run/systemd/netif /etc/hostname /usr 2>/dev/null)

        local w124_ours_hostname w124_ours_netif w124_ours_usr
        local w124_gnu_hostname w124_gnu_netif w124_gnu_usr
        w124_ours_hostname=$(printf '%s\n' "$w124_ours" | grep '/etc/hostname$' | strip_date_and_path)
        w124_ours_netif=$(printf '%s\n' "$w124_ours" | grep '/run/systemd/netif$' | strip_date_and_path)
        w124_ours_usr=$(printf '%s\n' "$w124_ours" | grep '/usr$' | strip_date_and_path)
        w124_gnu_hostname=$(printf '%s\n' "$w124_gnu" | grep '/etc/hostname$' | strip_date_and_path)
        w124_gnu_netif=$(printf '%s\n' "$w124_gnu" | grep '/run/systemd/netif$' | strip_date_and_path)
        w124_gnu_usr=$(printf '%s\n' "$w124_gnu" | grep '/usr$' | strip_date_and_path)

        # An empty capture on either side (e.g. because a future change
        # alters how operands are echoed, or the grep pattern stops
        # matching) must FAIL, not silently compare "" == "" as a PASS. A
        # real ls -ld line always starts with a 10-char permission string,
        # so requiring that shape on the GNU side is a cheap, precise guard.
        if [[ -z "$w124_gnu_hostname" || -z "$w124_gnu_netif" || -z "$w124_gnu_usr" || \
              ! "$w124_gnu_hostname" =~ ^[-dlbcpsD][-rwxXsSt]{9} || \
              ! "$w124_gnu_netif" =~ ^[-dlbcpsD][-rwxXsSt]{9} || \
              ! "$w124_gnu_usr" =~ ^[-dlbcpsD][-rwxXsSt]{9} ]]; then
            print_test_result "ls #124: -l sizes owner/group to the widest name (15-char systemd-network) and nlink to the widest count" "FAIL" \
                "GNU ls capture was empty or missing a permission string -- fixture or grep pattern broke: hostname=$(printf '%q' "$w124_gnu_hostname") netif=$(printf '%q' "$w124_gnu_netif") usr=$(printf '%q' "$w124_gnu_usr")"
        elif [[ "$(printf '%s' "$w124_ours_hostname" | strip_perm_field)" == "$(printf '%s' "$w124_gnu_hostname" | strip_perm_field)" && \
              "$(printf '%s' "$w124_ours_netif" | strip_perm_field)" == "$(printf '%s' "$w124_gnu_netif" | strip_perm_field)" && \
              "$(printf '%s' "$w124_ours_usr" | strip_perm_field)" == "$(printf '%s' "$w124_gnu_usr" | strip_perm_field)" ]]; then
            print_test_result "ls #124: -l sizes owner/group to the widest name (15-char systemd-network) and nlink to the widest count" "PASS"
        else
            print_test_result "ls #124: -l sizes owner/group to the widest name (15-char systemd-network) and nlink to the widest count" "FAIL" \
                "GNU ls prefix hostname=$(printf '%q' "$w124_gnu_hostname") netif=$(printf '%q' "$w124_gnu_netif") usr=$(printf '%q' "$w124_gnu_usr"); ours hostname=$(printf '%q' "$w124_ours_hostname") netif=$(printf '%q' "$w124_ours_netif") usr=$(printf '%q' "$w124_ours_usr")"
        fi

        # Same fixture under -n: uid/gid RIGHT-align to the widest value,
        # the opposite of the name case's left-align above -- a real
        # behavioral flip, not a cosmetic difference, and easy to miss if
        # only names are tested. Again compared against a live GNU
        # reference rather than a hardcoded uid/gid snapshot.
        local w124n_ours w124n_gnu
        w124n_ours=$(NO_COLOR=1 "$binary" -ldn /run/systemd/netif /etc/hostname /usr 2>/dev/null | strip_ansi)
        w124n_gnu=$(LC_ALL=C TZ=UTC "$gnu_ls" -ldn /run/systemd/netif /etc/hostname /usr 2>/dev/null)

        local w124n_ours_hostname w124n_ours_netif w124n_ours_usr
        local w124n_gnu_hostname w124n_gnu_netif w124n_gnu_usr
        w124n_ours_hostname=$(printf '%s\n' "$w124n_ours" | grep '/etc/hostname$' | strip_date_and_path)
        w124n_ours_netif=$(printf '%s\n' "$w124n_ours" | grep '/run/systemd/netif$' | strip_date_and_path)
        w124n_ours_usr=$(printf '%s\n' "$w124n_ours" | grep '/usr$' | strip_date_and_path)
        w124n_gnu_hostname=$(printf '%s\n' "$w124n_gnu" | grep '/etc/hostname$' | strip_date_and_path)
        w124n_gnu_netif=$(printf '%s\n' "$w124n_gnu" | grep '/run/systemd/netif$' | strip_date_and_path)
        w124n_gnu_usr=$(printf '%s\n' "$w124n_gnu" | grep '/usr$' | strip_date_and_path)

        if [[ -z "$w124n_gnu_hostname" || -z "$w124n_gnu_netif" || -z "$w124n_gnu_usr" || \
              ! "$w124n_gnu_hostname" =~ ^[-dlbcpsD][-rwxXsSt]{9} || \
              ! "$w124n_gnu_netif" =~ ^[-dlbcpsD][-rwxXsSt]{9} || \
              ! "$w124n_gnu_usr" =~ ^[-dlbcpsD][-rwxXsSt]{9} ]]; then
            print_test_result "ls #124: -ln right-aligns numeric uid/gid, flipping alignment vs the name case" "FAIL" \
                "GNU ls capture was empty or missing a permission string -- fixture or grep pattern broke: hostname=$(printf '%q' "$w124n_gnu_hostname") netif=$(printf '%q' "$w124n_gnu_netif") usr=$(printf '%q' "$w124n_gnu_usr")"
        elif [[ "$(printf '%s' "$w124n_ours_hostname" | strip_perm_field)" == "$(printf '%s' "$w124n_gnu_hostname" | strip_perm_field)" && \
              "$(printf '%s' "$w124n_ours_netif" | strip_perm_field)" == "$(printf '%s' "$w124n_gnu_netif" | strip_perm_field)" && \
              "$(printf '%s' "$w124n_ours_usr" | strip_perm_field)" == "$(printf '%s' "$w124n_gnu_usr" | strip_perm_field)" ]]; then
            print_test_result "ls #124: -ln right-aligns numeric uid/gid, flipping alignment vs the name case" "PASS"
        else
            print_test_result "ls #124: -ln right-aligns numeric uid/gid, flipping alignment vs the name case" "FAIL" \
                "GNU ls prefix hostname=$(printf '%q' "$w124n_gnu_hostname") netif=$(printf '%q' "$w124n_gnu_netif") usr=$(printf '%q' "$w124n_gnu_usr"); ours hostname=$(printf '%q' "$w124n_ours_hostname") netif=$(printf '%q' "$w124n_ours_netif") usr=$(printf '%q' "$w124n_ours_usr")"
        fi

        unset -f strip_date_and_path strip_perm_field
    else
        local w124_why="Requires a real GNU ls plus /run/systemd/netif, /etc/hostname and /usr owned by accounts of two different name widths, the widest over 8 chars (needs systemd-network); observed owner widths ${w124_omin}-${w124_omax}, uid widths ${w124_umin}-${w124_umax}"
        print_test_result "ls #124: -l sizes owner/group to the widest name (15-char systemd-network) and nlink to the widest count" "SKIP" \
            "$w124_why"
        print_test_result "ls #124: -ln right-aligns numeric uid/gid, flipping alignment vs the name case" "SKIP" \
            "$w124_why"
    fi

    # Every fixture above has owner name == group name on both files
    # ("root"/"root" and "systemd-network"/"systemd-network"), so a
    # column-width implementation that computes ONE shared width =
    # max(widest owner, widest group) and reuses it for BOTH columns
    # passes every test above while still diverging from GNU. /var/log/
    # journal (root:systemd-journal, a standard systemd path present on
    # any systemd-based Linux host) alongside /etc/hostname (root:root)
    # gives owner name "root" (4 chars) on both files but group names of
    # two different widths ("root" 4 chars vs "systemd-journal" 15
    # chars) -- so the owner column's correct width (4) and the group
    # column's correct width (15) differ, and a shared-width bug would
    # widen the owner column to 15 as well. Verified live against GNU ls
    # on this host rather than a hardcoded snapshot, for the same
    # portability reason as the fixture above.
    #
    # The systemd-journal group is exactly as host-dependent as
    # systemd-network above, and /var/log/journal existing does NOT imply
    # it (a runner with volatile journal storage, or a group-less image,
    # gives root:root and the two columns then have the SAME correct
    # width, making a shared-width bug invisible). So the guard measures
    # the property the assertion needs -- widest owner width != widest
    # group width -- on the very paths it lists.
    local w124ind_range=""
    local w124ind_omax=0 w124ind_gmax=0
    if [[ -n "$gnu_ls" ]]; then
        w124ind_range=$(name_width_range /var/log/journal /etc/hostname) || w124ind_range=""
    fi
    if [[ -n "$w124ind_range" ]]; then
        read -r _ w124ind_omax _ w124ind_gmax _ _ <<<"$w124ind_range"
    fi

    if [[ -n "$w124ind_range" ]] && (( w124ind_omax != w124ind_gmax )); then
        strip_date_and_path() {
            sed -E 's/ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) .*$//'
        }
        strip_perm_field() {
            sed -E 's/^.{10}//; s/^[.+]//'
        }

        local w124ind_ours w124ind_gnu
        w124ind_ours=$(NO_COLOR=1 "$binary" -ld /var/log/journal /etc/hostname 2>/dev/null | strip_ansi)
        w124ind_gnu=$(LC_ALL=C TZ=UTC "$gnu_ls" -ld /var/log/journal /etc/hostname 2>/dev/null)

        local w124ind_ours_hostname w124ind_ours_journal
        local w124ind_gnu_hostname w124ind_gnu_journal
        w124ind_ours_hostname=$(printf '%s\n' "$w124ind_ours" | grep '/etc/hostname$' | strip_date_and_path)
        w124ind_ours_journal=$(printf '%s\n' "$w124ind_ours" | grep '/var/log/journal$' | strip_date_and_path)
        w124ind_gnu_hostname=$(printf '%s\n' "$w124ind_gnu" | grep '/etc/hostname$' | strip_date_and_path)
        w124ind_gnu_journal=$(printf '%s\n' "$w124ind_gnu" | grep '/var/log/journal$' | strip_date_and_path)

        if [[ -z "$w124ind_gnu_hostname" || -z "$w124ind_gnu_journal" || \
              ! "$w124ind_gnu_hostname" =~ ^[-dlbcpsD][-rwxXsSt]{9} || \
              ! "$w124ind_gnu_journal" =~ ^[-dlbcpsD][-rwxXsSt]{9} ]]; then
            print_test_result "ls #124: owner and group columns size independently, not to a shared max" "FAIL" \
                "GNU ls capture was empty or missing a permission string -- fixture or grep pattern broke: hostname=$(printf '%q' "$w124ind_gnu_hostname") journal=$(printf '%q' "$w124ind_gnu_journal")"
        elif [[ "$(printf '%s' "$w124ind_ours_hostname" | strip_perm_field)" == "$(printf '%s' "$w124ind_gnu_hostname" | strip_perm_field)" && \
              "$(printf '%s' "$w124ind_ours_journal" | strip_perm_field)" == "$(printf '%s' "$w124ind_gnu_journal" | strip_perm_field)" ]]; then
            print_test_result "ls #124: owner and group columns size independently, not to a shared max" "PASS"
        else
            print_test_result "ls #124: owner and group columns size independently, not to a shared max" "FAIL" \
                "GNU ls prefix hostname=$(printf '%q' "$w124ind_gnu_hostname") journal=$(printf '%q' "$w124ind_gnu_journal"); ours hostname=$(printf '%q' "$w124ind_ours_hostname") journal=$(printf '%q' "$w124ind_ours_journal")"
        fi

        unset -f strip_date_and_path strip_perm_field
    else
        print_test_result "ls #124: owner and group columns size independently, not to a shared max" "SKIP" \
            "Requires a real GNU ls plus /var/log/journal and /etc/hostname whose widest owner name and widest group name differ in width (needs the systemd-journal group); observed owner ${w124ind_omax}, group ${w124ind_gmax}"
    fi

    unset -f name_width_range

    # Every #124 test above lists ONE section, so an implementation that
    # computes the widths once and reuses them for every later section
    # passes all of them. `ls -l dirA dirB` is exactly two sections in one
    # process, and putting the WIDE one first is what makes a leak visible:
    # a max-accumulating leak is invisible in the narrow-then-wide order,
    # because the wide section's own values already dominate.
    #
    # The fixture needs no system accounts at all -- nlink comes from hard
    # links and size from file contents, both of which any unprivileged
    # user can create -- so unlike the fixtures above this runs everywhere.
    # -go omits both the owner and the group column, which are the only
    # fields whose width depends on who the test user happens to be; what
    # is left (nlink and size) is fully controlled by the fixture. The
    # "total" lines are dropped because vibeutils reports 512-byte blocks
    # where GNU reports 1 KiB, a difference that predates this issue.
    # ls sorts its directory operands, so the two section directories are
    # named to sort wide-first rather than relying on the order they are
    # passed in (create_temp_dir hands out random names, which would make
    # the order -- and with it what a leak would look like -- a coin toss).
    local sect_parent sect_wide_dir sect_narrow_dir sect_link_dir
    sect_parent=$(create_temp_dir)
    sect_wide_dir="$sect_parent/a_wide"
    sect_narrow_dir="$sect_parent/b_narrow"
    sect_link_dir="$sect_parent/links"
    mkdir -p "$sect_wide_dir" "$sect_narrow_dir" "$sect_link_dir"
    dd if=/dev/zero of="$sect_wide_dir/big" bs=1024 count=100 2>/dev/null
    local sect_i
    for sect_i in 1 2 3 4 5 6 7 8 9 10; do
        ln "$sect_wide_dir/big" "$sect_link_dir/l$sect_i" 2>/dev/null
    done
    create_temp_file "" "$sect_narrow_dir/small"

    # Strips the variable " Mon DD HH:MM name" tail and the total lines,
    # leaving the permission/nlink/size prefix plus the section headers.
    # sed rather than `grep -v`: the suite runs under `set -o pipefail`, and
    # grep exits 1 when it filters everything away, which would abort the
    # run instead of failing this one test.
    strip_section_noise() {
        sed -E 's/ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) .*$//; /^total /d'
    }

    local sect_nlink
    sect_nlink=$(LC_ALL=C "$binary" -lgo "$sect_wide_dir/big" 2>/dev/null | strip_ansi | awk '{print $2}')
    if [[ "$sect_nlink" != "11" ]]; then
        print_test_result "ls #124: a second -l section sizes its columns to its own content" "SKIP" \
            "Fixture needs 11 hard links on this filesystem; got nlink=$(printf '%q' "$sect_nlink")"
        print_test_result "ls #124: -R sizes each directory section to its own content" "SKIP" \
            "Fixture needs 11 hard links on this filesystem; got nlink=$(printf '%q' "$sect_nlink")"
    else
        # Section one is nlink 11 (2 columns) and size 102400 (6 columns);
        # section two must fall back to 1 and 1, not inherit 2 and 6.
        local sect_expected sect_output
        sect_expected="$sect_wide_dir:
-rw-r--r-- 11 102400

$sect_narrow_dir:
-rw-r--r-- 1 0"
        sect_output=$(NO_COLOR=1 LC_ALL=C "$binary" -lgo "$sect_wide_dir" "$sect_narrow_dir" 2>/dev/null |
            strip_ansi | strip_section_noise)
        if [[ "$sect_output" == "$sect_expected" ]]; then
            print_test_result "ls #124: a second -l section sizes its columns to its own content" "PASS"
        else
            print_test_result "ls #124: a second -l section sizes its columns to its own content" "FAIL" \
                "Expected $(printf '%q' "$sect_expected"), got: $(printf '%q' "$sect_output")"
        fi

        # -R reaches the same code path through a different driver: the
        # subdirectory section is emitted by the recursive walk rather than
        # by a second operand, and must size its own columns too.
        local sect_r_dir
        sect_r_dir=$(create_temp_dir)
        dd if=/dev/zero of="$sect_r_dir/big" bs=1024 count=100 2>/dev/null
        mkdir -p "$sect_r_dir/sub"
        create_temp_file "" "$sect_r_dir/sub/small"

        # The "sub" directory entry itself is dropped from the comparison:
        # a directory's reported size is 4096 on ext4 but something else
        # on APFS, and pinning it would make this test a filesystem test.
        # It still participates in the parent section's widths, where it
        # cannot change the outcome -- a directory size is narrower than
        # 102400 and its link count is a single digit.
        local sect_r_expected sect_r_output
        sect_r_expected="$sect_r_dir:
-rw-r--r-- 1 102400

$sect_r_dir/sub:
-rw-r--r-- 1 0"
        sect_r_output=$(NO_COLOR=1 LC_ALL=C "$binary" -lRgo "$sect_r_dir" 2>/dev/null |
            strip_ansi | strip_section_noise | sed '/^d/d')
        if [[ "$sect_r_output" == "$sect_r_expected" ]]; then
            print_test_result "ls #124: -R sizes each directory section to its own content" "PASS"
        else
            print_test_result "ls #124: -R sizes each directory section to its own content" "FAIL" \
                "Expected $(printf '%q' "$sect_r_expected"), got: $(printf '%q' "$sect_r_output")"
        fi
    fi

    unset -f strip_section_noise
}
