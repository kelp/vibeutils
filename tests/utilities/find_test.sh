#!/usr/bin/env bash
# Tests for find utility
# Tests core predicates, operators, actions, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_find() {
    local util="find"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default behavior...${NC}"

    # Default: search current directory
    local test_dir=$(create_temp_dir)
    create_temp_file "content" "$test_dir/file1.txt"
    create_temp_file "content" "$test_dir/file2.md"
    mkdir "$test_dir/subdir"

    local out="" err="" exit_code=""
    run_command cmd out err exit_code "$binary" "$test_dir"
    if [[ "$out" =~ file1.txt && "$out" =~ file2.md && "$out" =~ subdir ]]; then
        print_test_result "find default lists all entries" "PASS"
    else
        print_test_result "find default lists all entries" "FAIL" "Got: $out"
    fi
    rm -rf "$test_dir"

    echo -e "${CYAN}Testing -name predicate...${NC}"

    local name_dir=$(create_temp_dir)
    create_temp_file "content" "$name_dir/hello.txt"
    create_temp_file "content" "$name_dir/world.md"
    create_temp_file "content" "$name_dir/data.txt"
    create_temp_file "content" "$name_dir/a.md"

    run_command cmd out err exit_code "$binary" "$name_dir" "-name" "*.txt"
    if [[ "$out" =~ hello.txt && "$out" =~ data.txt && ! "$out" =~ world.md ]]; then
        print_test_result "find -name *.txt" "PASS"
    else
        print_test_result "find -name *.txt" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$name_dir" "-name" "hello*"
    if [[ "$out" =~ hello.txt && ! "$out" =~ world.md ]]; then
        print_test_result "find -name hello*" "PASS"
    else
        print_test_result "find -name hello*" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$name_dir" "-name" "?.md"
    if [[ "$out" =~ a.md && ! "$out" =~ world.md ]]; then
        print_test_result "find -name ? single char" "PASS"
    else
        print_test_result "find -name ? single char" "FAIL" "Got: $out"
    fi
    rm -rf "$name_dir"

    echo -e "${CYAN}Testing -iname predicate...${NC}"

    local iname_dir=$(create_temp_dir)
    create_temp_file "content" "$iname_dir/Hello.TXT"
    create_temp_file "content" "$iname_dir/world.txt"
    create_temp_file "content" "$iname_dir/DATA.md"

    run_command cmd out err exit_code "$binary" "$iname_dir" "-iname" "*.txt"
    if [[ "$out" =~ Hello.TXT && "$out" =~ world.txt && ! "$out" =~ DATA.md ]]; then
        print_test_result "find -iname case insensitive" "PASS"
    else
        print_test_result "find -iname case insensitive" "FAIL" "Got: $out"
    fi
    rm -rf "$iname_dir"

    echo -e "${CYAN}Testing -type predicate...${NC}"

    local type_dir=$(create_temp_dir)
    create_temp_file "content" "$type_dir/regular.txt"
    mkdir "$type_dir/directory"

    run_command cmd out err exit_code "$binary" "$type_dir" "-type" "f"
    if [[ "$out" =~ regular.txt && ! "$out" =~ directory ]]; then
        print_test_result "find -type f" "PASS"
    else
        print_test_result "find -type f" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$type_dir" "-type" "d"
    if [[ "$out" =~ directory && ! "$out" =~ regular.txt ]]; then
        print_test_result "find -type d" "PASS"
    else
        print_test_result "find -type d" "FAIL" "Got: $out"
    fi

    # Symlink type test
    ln -s "$type_dir/regular.txt" "$type_dir/link.txt"
    run_command cmd out err exit_code "$binary" "$type_dir" "-type" "l"
    if [[ "$out" =~ link.txt ]]; then
        print_test_result "find -type l" "PASS"
    else
        print_test_result "find -type l" "FAIL" "Got: $out"
    fi
    rm -rf "$type_dir"

    echo -e "${CYAN}Testing -empty predicate...${NC}"

    local empty_dir=$(create_temp_dir)
    create_temp_file "" "$empty_dir/empty.txt"
    create_temp_file "not empty" "$empty_dir/notempty.txt"
    mkdir "$empty_dir/emptydir"
    mkdir "$empty_dir/fulldir"
    create_temp_file "content" "$empty_dir/fulldir/file.txt"

    run_command cmd out err exit_code "$binary" "$empty_dir" "-empty"
    if [[ "$out" =~ empty.txt && "$out" =~ emptydir && ! "$out" =~ notempty.txt ]]; then
        print_test_result "find -empty" "PASS"
    else
        print_test_result "find -empty" "FAIL" "Got: $out"
    fi
    rm -rf "$empty_dir"

    echo -e "${CYAN}Testing -size predicate...${NC}"

    local size_dir=$(create_temp_dir)
    create_temp_file "" "$size_dir/zero.txt"
    printf '%2048s' ' ' > "$size_dir/medium.txt"

    run_command cmd out err exit_code "$binary" "$size_dir" "-type" "f" "-size" "+1000c"
    if [[ "$out" =~ medium.txt && ! "$out" =~ zero.txt ]]; then
        print_test_result "find -size +1000c" "PASS"
    else
        print_test_result "find -size +1000c" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$size_dir" "-type" "f" "-size" "0c"
    if [[ "$out" =~ zero.txt && ! "$out" =~ medium.txt ]]; then
        print_test_result "find -size 0c" "PASS"
    else
        print_test_result "find -size 0c" "FAIL" "Got: $out"
    fi
    rm -rf "$size_dir"

    # F56: -size block rounding tests
    # GNU find -size N (default unit = 512-byte blocks) uses ceiling division:
    # file_blocks = ceil(file_bytes / 512)
    echo -e "${CYAN}Testing -size block rounding (F56)...${NC}"

    local blk_dir=$(create_temp_dir)
    # 100-byte file: ceil(100/512) = 1 block
    python3 -c "open('$blk_dir/small.txt','wb').write(b'x'*100)"
    # 513-byte file: ceil(513/512) = 2 blocks
    python3 -c "open('$blk_dir/medium.txt','wb').write(b'x'*513)"
    # 512-byte file: ceil(512/512) = 1 block
    python3 -c "open('$blk_dir/exact512.txt','wb').write(b'x'*512)"
    touch "$blk_dir/zero_len.txt"

    # -size 1 should match files occupying 1 block (1-512 bytes)
    run_command cmd out err exit_code "$binary" "$blk_dir" "-type" "f" "-size" "1"
    if [[ "$out" =~ small.txt && "$out" =~ exact512.txt && ! "$out" =~ medium.txt && ! "$out" =~ zero_len.txt ]]; then
        print_test_result "find -size 1 matches 1-block files" "PASS"
    else
        print_test_result "find -size 1 matches 1-block files" "FAIL" "Got: $out"
    fi

    # -size 2 should match files occupying 2 blocks (513-1024 bytes)
    run_command cmd out err exit_code "$binary" "$blk_dir" "-type" "f" "-size" "2"
    if [[ "$out" =~ medium.txt && ! "$out" =~ small.txt && ! "$out" =~ exact512.txt ]]; then
        print_test_result "find -size 2 matches 2-block files" "PASS"
    else
        print_test_result "find -size 2 matches 2-block files" "FAIL" "Got: $out"
    fi

    # -size -2 should match files with fewer than 2 blocks (0 or 1 block)
    # 513-byte file = 2 blocks, should NOT match -size -2
    # 100-byte file = 1 block, should match -size -2
    run_command cmd out err exit_code "$binary" "$blk_dir" "-type" "f" "-size" "-2"
    if [[ "$out" =~ small.txt && "$out" =~ exact512.txt && ! "$out" =~ medium.txt ]]; then
        print_test_result "find -size -2 excludes 2-block files" "PASS"
    else
        print_test_result "find -size -2 excludes 2-block files" "FAIL" "Got: $out"
    fi

    rm -rf "$blk_dir"

    echo -e "${CYAN}Testing -maxdepth...${NC}"

    local depth_dir=$(create_temp_dir)
    create_temp_file "content" "$depth_dir/top.txt"
    mkdir -p "$depth_dir/sub"
    create_temp_file "content" "$depth_dir/sub/deep.txt"
    mkdir -p "$depth_dir/sub/sub2"
    create_temp_file "content" "$depth_dir/sub/sub2/deeper.txt"

    run_command cmd out err exit_code "$binary" "$depth_dir" "-maxdepth" "1"
    if [[ "$out" =~ top.txt && "$out" =~ sub && ! "$out" =~ deep.txt ]]; then
        print_test_result "find -maxdepth 1" "PASS"
    else
        print_test_result "find -maxdepth 1" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$depth_dir" "-maxdepth" "0"
    if [[ ! "$out" =~ top.txt && ! "$out" =~ sub ]]; then
        print_test_result "find -maxdepth 0" "PASS"
    else
        print_test_result "find -maxdepth 0" "FAIL" "Got: $out"
    fi
    rm -rf "$depth_dir"

    echo -e "${CYAN}Testing -mindepth...${NC}"

    local mind_dir=$(create_temp_dir)
    create_temp_file "content" "$mind_dir/top.txt"
    mkdir -p "$mind_dir/sub"
    create_temp_file "content" "$mind_dir/sub/deep.txt"

    run_command cmd out err exit_code "$binary" "$mind_dir" "-mindepth" "2"
    if [[ "$out" =~ deep.txt && ! "$out" =~ top.txt ]]; then
        print_test_result "find -mindepth 2" "PASS"
    else
        print_test_result "find -mindepth 2" "FAIL" "Got: $out"
    fi
    rm -rf "$mind_dir"

    echo -e "${CYAN}Testing -perm predicate...${NC}"

    local perm_dir=$(create_temp_dir)
    touch "$perm_dir/rw.txt"
    chmod 644 "$perm_dir/rw.txt"
    touch "$perm_dir/rwx.txt"
    chmod 755 "$perm_dir/rwx.txt"

    run_command cmd out err exit_code "$binary" "$perm_dir" "-type" "f" "-perm" "755"
    if [[ "$out" =~ rwx.txt && ! "$out" =~ rw.txt ]]; then
        print_test_result "find -perm 755" "PASS"
    else
        print_test_result "find -perm 755" "FAIL" "Got: $out"
    fi
    rm -rf "$perm_dir"

    echo -e "${CYAN}Testing -newer predicate...${NC}"

    local newer_dir=$(create_temp_dir)
    create_temp_file "old content" "$newer_dir/old.txt"
    sleep 1
    create_temp_file "new content" "$newer_dir/new.txt"

    run_command cmd out err exit_code "$binary" "$newer_dir" "-newer" "$newer_dir/old.txt" "-type" "f"
    if [[ "$out" =~ new.txt && ! "$out" =~ old.txt ]]; then
        print_test_result "find -newer" "PASS"
    else
        print_test_result "find -newer" "FAIL" "Got: $out"
    fi
    rm -rf "$newer_dir"

    echo -e "${CYAN}Testing operators...${NC}"

    local op_dir=$(create_temp_dir)
    create_temp_file "content" "$op_dir/a.txt"
    create_temp_file "content" "$op_dir/b.md"
    create_temp_file "content" "$op_dir/c.log"

    # -or operator
    run_command cmd out err exit_code "$binary" "$op_dir" "-name" "*.txt" "-o" "-name" "*.md"
    if [[ "$out" =~ a.txt && "$out" =~ b.md ]]; then
        print_test_result "find -or operator" "PASS"
    else
        print_test_result "find -or operator" "FAIL" "Got: $out"
    fi

    # -not operator
    run_command cmd out err exit_code "$binary" "$op_dir" "-type" "f" "-not" "-name" "*.log"
    if [[ "$out" =~ a.txt && "$out" =~ b.md && ! "$out" =~ c.log ]]; then
        print_test_result "find -not operator" "PASS"
    else
        print_test_result "find -not operator" "FAIL" "Got: $out"
    fi

    # ! operator (same as -not)
    run_command cmd out err exit_code "$binary" "$op_dir" "-type" "f" "!" "-name" "*.log"
    if [[ "$out" =~ a.txt && "$out" =~ b.md && ! "$out" =~ c.log ]]; then
        print_test_result "find ! operator" "PASS"
    else
        print_test_result "find ! operator" "FAIL" "Got: $out"
    fi

    # Parentheses grouping
    run_command cmd out err exit_code "$binary" "$op_dir" "(" "-name" "*.txt" "-o" "-name" "*.md" ")"
    if [[ "$out" =~ a.txt && "$out" =~ b.md ]]; then
        print_test_result "find parentheses grouping" "PASS"
    else
        print_test_result "find parentheses grouping" "FAIL" "Got: $out"
    fi
    rm -rf "$op_dir"

    echo -e "${CYAN}Testing actions...${NC}"

    # -print0 (use raw output to preserve NUL bytes)
    local print0_dir=$(create_temp_dir)
    create_temp_file "content" "$print0_dir/file.txt"

    local print0_out="$TEMP_DIR/print0_output"
    "$binary" "$print0_dir" "-name" "file.txt" "-print0" > "$print0_out" 2>/dev/null
    local print0_exit=$?
    # Check output contains NUL byte and no newline
    if [[ $print0_exit -eq 0 ]] && od -A n -t x1 "$print0_out" | grep -q '00'; then
        print_test_result "find -print0 produces NUL bytes" "PASS"
    else
        print_test_result "find -print0 produces NUL bytes" "FAIL" "Expected NUL-terminated output"
    fi
    rm -f "$print0_out"
    rm -rf "$print0_dir"

    # -delete
    local del_dir=$(create_temp_dir)
    create_temp_file "content" "$del_dir/deleteme.txt"
    create_temp_file "content" "$del_dir/keepme.md"

    run_command cmd out err exit_code "$binary" "$del_dir" "-name" "deleteme.txt" "-delete"
    if [[ ! -e "$del_dir/deleteme.txt" && -e "$del_dir/keepme.md" ]]; then
        print_test_result "find -delete" "PASS"
    else
        print_test_result "find -delete" "FAIL" "Expected deleteme.txt removed, keepme.md kept"
    fi
    rm -rf "$del_dir"

    echo -e "${CYAN}Testing -depth option...${NC}"

    local depth_opt_dir=$(create_temp_dir)
    create_temp_file "content" "$depth_opt_dir/file.txt"
    mkdir "$depth_opt_dir/sub"
    create_temp_file "content" "$depth_opt_dir/sub/file2.txt"

    run_command cmd out err exit_code "$binary" "$depth_opt_dir" "-depth"
    # With -depth, directory contents appear before the directory
    local sub_pos=$(echo "$out" | grep -n "sub/file2.txt" | head -1 | cut -d: -f1)
    local dir_pos=$(echo "$out" | grep -n "${depth_opt_dir##*/}/sub$" | head -1 | cut -d: -f1)
    if [[ -n "$sub_pos" && -n "$dir_pos" ]] && [[ "$sub_pos" -lt "$dir_pos" ]]; then
        print_test_result "find -depth order" "PASS"
    else
        print_test_result "find -depth order" "FAIL" "depth ordering not verified"
    fi
    rm -rf "$depth_opt_dir"

    echo -e "${CYAN}Testing -L (follow symlinks)...${NC}"

    local link_dir=$(create_temp_dir)
    mkdir "$link_dir/target"
    create_temp_file "content" "$link_dir/target/real.txt"
    ln -s "$link_dir/target" "$link_dir/link"

    run_command cmd out err exit_code "$binary" "-L" "$link_dir" "-name" "real.txt"
    if [[ "$out" =~ real.txt ]]; then
        print_test_result "find -L follows symlinks" "PASS"
    else
        print_test_result "find -L follows symlinks" "FAIL" "Got: $out"
    fi
    rm -rf "$link_dir"

    echo -e "${CYAN}Testing -prune predicate...${NC}"

    local prune_dir=$(create_temp_dir)
    create_temp_file "content" "$prune_dir/top.txt"
    mkdir -p "$prune_dir/skip_me"
    create_temp_file "content" "$prune_dir/skip_me/hidden.txt"
    mkdir -p "$prune_dir/keep_me"
    create_temp_file "content" "$prune_dir/keep_me/visible.txt"

    run_command cmd out err exit_code "$binary" "$prune_dir" "-name" "skip_me" "-prune" "-o" "-type" "f" "-print"
    if [[ "$out" =~ top.txt && "$out" =~ visible.txt && ! "$out" =~ hidden.txt ]]; then
        print_test_result "find -prune skips directory contents" "PASS"
    else
        print_test_result "find -prune skips directory contents" "FAIL" "Got: $out"
    fi
    rm -rf "$prune_dir"

    echo -e "${CYAN}Testing -atime/-ctime predicates...${NC}"

    local time_dir=$(create_temp_dir)
    create_temp_file "recent content" "$time_dir/recent.txt"

    # -atime 0 should match files accessed today
    run_command cmd out err exit_code "$binary" "$time_dir" "-type" "f" "-atime" "0"
    if [[ $exit_code -eq 0 && "$out" =~ recent.txt ]]; then
        print_test_result "find -atime 0 matches recent file" "PASS"
    else
        print_test_result "find -atime 0 matches recent file" "FAIL" "Got: $out"
    fi

    # -ctime 0 should match files changed today
    run_command cmd out err exit_code "$binary" "$time_dir" "-type" "f" "-ctime" "0"
    if [[ $exit_code -eq 0 && "$out" =~ recent.txt ]]; then
        print_test_result "find -ctime 0 matches recent file" "PASS"
    else
        print_test_result "find -ctime 0 matches recent file" "FAIL" "Got: $out"
    fi

    # -atime +1000 should not match recent files
    run_command cmd out err exit_code "$binary" "$time_dir" "-type" "f" "-atime" "+1000"
    if [[ $exit_code -eq 0 && ! "$out" =~ recent.txt ]]; then
        print_test_result "find -atime +1000 excludes recent file" "PASS"
    else
        print_test_result "find -atime +1000 excludes recent file" "FAIL" "Exit: $exit_code, got: $out"
    fi
    rm -rf "$time_dir"

    echo -e "${CYAN}Testing -links predicate...${NC}"

    local links_dir=$(create_temp_dir)
    create_temp_file "link test" "$links_dir/original.txt"
    ln "$links_dir/original.txt" "$links_dir/hardlink.txt"
    # Create a single-link file before the -links 2 test so we can assert it's excluded
    create_temp_file "single" "$links_dir/single.txt"

    # original.txt now has 2 hard links
    run_command cmd out err exit_code "$binary" "$links_dir" "-type" "f" "-links" "2"
    if [[ "$out" =~ original.txt && "$out" =~ hardlink.txt && ! "$out" =~ single.txt ]]; then
        print_test_result "find -links 2 matches hard-linked files" "PASS"
    else
        print_test_result "find -links 2 matches hard-linked files" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" "$links_dir" "-type" "f" "-links" "1"
    if [[ "$out" =~ single.txt && ! "$out" =~ original.txt ]]; then
        print_test_result "find -links 1 matches single-link files" "PASS"
    else
        print_test_result "find -links 1 matches single-link files" "FAIL" "Got: $out"
    fi
    rm -rf "$links_dir"

    echo -e "${CYAN}Testing -nouser/-nogroup predicates...${NC}"

    # Acceptance test: flag is parsed without error
    local nouser_dir=$(create_temp_dir)
    create_temp_file "content" "$nouser_dir/file.txt"

    # Acceptance test: -nouser should not match files owned by current user
    # Note: positive-match testing requires root to create orphaned-owner files
    run_command cmd out err exit_code "$binary" "$nouser_dir" "-nouser"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -nouser flag accepted" "PASS"
    else
        print_test_result "find -nouser flag accepted" "FAIL" "Exit: $exit_code, out: $out, err: $err"
    fi

    run_command cmd out err exit_code "$binary" "$nouser_dir" "-nogroup"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -nogroup flag accepted" "PASS"
    else
        print_test_result "find -nogroup flag accepted" "FAIL" "Exit: $exit_code, out: $out, err: $err"
    fi
    rm -rf "$nouser_dir"

    echo -e "${CYAN}Testing -xdev/-mount predicates...${NC}"

    # Acceptance test: flags are parsed and produce valid output
    local xdev_dir=$(create_temp_dir)
    create_temp_file "content" "$xdev_dir/file.txt"

    run_command cmd out err exit_code "$binary" "$xdev_dir" "-xdev"
    if [[ $exit_code -eq 0 && "$out" =~ file.txt ]]; then
        print_test_result "find -xdev flag accepted" "PASS"
    else
        print_test_result "find -xdev flag accepted" "FAIL" "Exit code: $exit_code, err: $err"
    fi

    run_command cmd out err exit_code "$binary" "$xdev_dir" "-mount"
    if [[ $exit_code -eq 0 && "$out" =~ file.txt ]]; then
        print_test_result "find -mount flag accepted" "PASS"
    else
        print_test_result "find -mount flag accepted" "FAIL" "Exit code: $exit_code, err: $err"
    fi
    rm -rf "$xdev_dir"

    echo -e "${CYAN}Testing -ok action...${NC}"

    # Acceptance test: -ok is parsed without error (feed /dev/null as stdin for no confirmation)
    local ok_dir=$(create_temp_dir)
    create_temp_file "content" "$ok_dir/okfile.txt"

    local ok_out="" ok_err=""
    ok_out=$("$binary" "$ok_dir" "-type" "f" "-ok" "echo" "{}" ";" </dev/null 2>"$TEMP_DIR/ok_stderr")
    local ok_exit=$?
    if [[ $ok_exit -eq 0 ]]; then
        print_test_result "find -ok flag accepted" "PASS"
    else
        ok_err=$(cat "$TEMP_DIR/ok_stderr" 2>/dev/null)
        print_test_result "find -ok flag accepted" "FAIL" "Exit code: $ok_exit, err: $ok_err"
    fi
    rm -f "$TEMP_DIR/ok_stderr"
    rm -rf "$ok_dir"

    echo -e "${CYAN}Testing error handling...${NC}"

    # Nonexistent path
    run_command cmd out err exit_code "$binary" "/tmp/nonexistent_vibeutils_find_test_99999"
    if [[ $exit_code -ne 0 && -n "$err" ]]; then
        print_test_result "find nonexistent path" "PASS"
    else
        print_test_result "find nonexistent path" "FAIL" "Expected error for missing path"
    fi

    # Unknown predicate
    run_command cmd out err exit_code "$binary" "." "-bogus"
    if [[ $exit_code -ne 0 && "$err" =~ "unknown predicate" ]]; then
        print_test_result "find unknown predicate" "PASS"
    else
        print_test_result "find unknown predicate" "FAIL" "Expected error for unknown predicate"
    fi

    # Missing argument to -name
    run_command cmd out err exit_code "$binary" "." "-name"
    if [[ $exit_code -ne 0 ]]; then
        print_test_result "find missing argument to -name" "PASS"
    else
        print_test_result "find missing argument to -name" "FAIL" "Expected error"
    fi

    # Invalid -type argument
    run_command cmd out err exit_code "$binary" "." "-type" "x"
    if [[ $exit_code -ne 0 ]]; then
        print_test_result "find invalid -type argument" "PASS"
    else
        print_test_result "find invalid -type argument" "FAIL" "Expected error"
    fi

    echo -e "${CYAN}Testing combined predicates...${NC}"

    local combo_dir=$(create_temp_dir)
    create_temp_file "" "$combo_dir/empty.txt"
    create_temp_file "not empty" "$combo_dir/notempty.txt"
    create_temp_file "" "$combo_dir/empty.md"
    mkdir "$combo_dir/subdir"

    # -type f -name *.txt -empty
    run_command cmd out err exit_code "$binary" "$combo_dir" "-type" "f" "-name" "*.txt" "-empty"
    if [[ "$out" =~ empty.txt && ! "$out" =~ notempty.txt && ! "$out" =~ empty.md ]]; then
        print_test_result "find combined -type -name -empty" "PASS"
    else
        print_test_result "find combined -type -name -empty" "FAIL" "Got: $out"
    fi
    rm -rf "$combo_dir"

    echo -e "${CYAN}Testing -user predicate...${NC}"

    local user_dir=$(create_temp_dir)
    create_temp_file "content" "$user_dir/myfile.txt"

    run_command cmd out err exit_code "$binary" "$user_dir" "-user" "$(whoami)" "-type" "f"
    if [[ "$out" =~ myfile.txt ]]; then
        print_test_result "find -user $(whoami)" "PASS"
    else
        print_test_result "find -user $(whoami)" "FAIL" "Got: $out"
    fi
    rm -rf "$user_dir"

    echo -e "${CYAN}Testing -path predicate...${NC}"

    local path_dir=$(create_temp_dir)
    create_temp_file "content" "$path_dir/file.txt"
    mkdir -p "$path_dir/sub"
    create_temp_file "content" "$path_dir/sub/file.txt"

    run_command cmd out err exit_code "$binary" "$path_dir" "-path" "*/sub/*"
    if [[ "$out" =~ sub/file.txt ]]; then
        print_test_result "find -path */sub/*" "PASS"
    else
        print_test_result "find -path */sub/*" "FAIL" "Got: $out"
    fi
    rm -rf "$path_dir"

    # Regression test: -regex rejects non-matching patterns
    echo -e "${CYAN}Testing -regex non-matching pattern...${NC}"
    local regex_dir=$(create_temp_dir)
    touch "$regex_dir/a" "$regex_dir/b"
    run_command cmd out err exit_code "$binary" "$regex_dir" "-regex" "impossible_pattern"
    rm -rf "$regex_dir"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -regex rejects non-matching pattern" "PASS"
    else
        print_test_result "find -regex rejects non-matching pattern" "FAIL" \
            "Expected empty output, got: '$out' (exit: $exit_code)"
    fi

    # ================================================================
    # F1: find -regex/-iregex with C POSIX regex
    # GNU find: -regex '.*' should match every path (it matches the
    # full path against the regex).
    # ================================================================
    echo -e "${CYAN}Testing -regex matching (F1)...${NC}"

    local regex_match_dir=$(create_temp_dir)
    touch "$regex_match_dir/hello.txt" "$regex_match_dir/world.txt"

    # -regex '.*' should match all entries (directory + both files)
    run_command cmd out err exit_code "$binary" "$regex_match_dir" "-regex" ".*"
    if [[ $exit_code -eq 0 && -n "$out" ]]; then
        # Should contain at least the two files
        if echo "$out" | grep -q "hello.txt" && echo "$out" | grep -q "world.txt"; then
            print_test_result "find -regex '.*' matches all entries" "PASS"
        else
            print_test_result "find -regex '.*' matches all entries" "FAIL" \
                "Expected hello.txt and world.txt in output, got: '$out'"
        fi
    else
        print_test_result "find -regex '.*' matches all entries" "FAIL" \
            "Expected non-empty output, got: '$out' (exit: $exit_code)"
    fi

    # -regex filtering: match only .txt files
    run_command cmd out err exit_code "$binary" "$regex_match_dir" "-regex" ".*\.txt"
    if [[ $exit_code -eq 0 && -n "$out" ]]; then
        if echo "$out" | grep -q "hello.txt" && echo "$out" | grep -q "world.txt"; then
            print_test_result "find -regex filters specific pattern" "PASS"
        else
            print_test_result "find -regex filters specific pattern" "FAIL" \
                "Expected hello.txt and world.txt, got: '$out'"
        fi
    else
        print_test_result "find -regex filters specific pattern" "FAIL" \
            "Expected non-empty output, got: '$out' (exit: $exit_code)"
    fi

    # -iregex: case-insensitive match
    touch "$regex_match_dir/Upper.TXT"
    run_command cmd out err exit_code "$binary" "$regex_match_dir" "-iregex" ".*\.txt"
    if [[ $exit_code -eq 0 && -n "$out" ]]; then
        if echo "$out" | grep -q "Upper.TXT"; then
            print_test_result "find -iregex case-insensitive match" "PASS"
        else
            print_test_result "find -iregex case-insensitive match" "FAIL" \
                "Expected Upper.TXT in output, got: '$out'"
        fi
    else
        print_test_result "find -iregex case-insensitive match" "FAIL" \
            "Expected non-empty output, got: '$out' (exit: $exit_code)"
    fi
    rm -rf "$regex_match_dir"

    # ================================================================
    # F2: find -Bmin/-Bnewer/-Btime/-newerXY always returns true
    # These birth-time predicates are stubs that match everything.
    # A file just created should NOT match -Btime +9999 (born more
    # than 9999 days ago).
    # ================================================================
    echo -e "${CYAN}Testing birth-time predicates not always-true (F2)...${NC}"

    local btime_dir=$(create_temp_dir)
    touch "$btime_dir/recent.txt"

    # -Btime +9999 means "birth time more than 9999 days ago"
    # A just-created file should NOT match
    run_command cmd out err exit_code "$binary" "$btime_dir" "-type" "f" "-Btime" "+9999"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -Btime +9999 excludes recent file" "PASS"
    else
        print_test_result "find -Btime +9999 excludes recent file" "FAIL" \
            "Recent file should not match -Btime +9999, got: '$out'"
    fi

    # -Bmin +999999 means "born more than 999999 minutes ago"
    run_command cmd out err exit_code "$binary" "$btime_dir" "-type" "f" "-Bmin" "+999999"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -Bmin +999999 excludes recent file" "PASS"
    else
        print_test_result "find -Bmin +999999 excludes recent file" "FAIL" \
            "Recent file should not match -Bmin +999999, got: '$out'"
    fi

    # -Bnewer REF: file born after REF. A file is not newer than
    # itself, so -Bnewer <self> with -type f should return nothing
    run_command cmd out err exit_code "$binary" "$btime_dir" "-type" "f" "-Bnewer" "$btime_dir/recent.txt"
    if [[ $exit_code -eq 0 && -z "$out" ]]; then
        print_test_result "find -Bnewer self excludes file" "PASS"
    else
        print_test_result "find -Bnewer self excludes file" "FAIL" \
            "File should not be newer than itself, got: '$out'"
    fi

    # -newerBm REF with negative case: create old-timestamped ref,
    # then check that -newermB (mtime newer than birth) fails for
    # the old file
    touch -t 197001010000 "$btime_dir/epoch.txt" 2>/dev/null || true
    if [[ -f "$btime_dir/epoch.txt" ]]; then
        run_command cmd out err exit_code "$binary" "$btime_dir" \
            "-type" "f" "-name" "epoch.txt" "-newermB" "$btime_dir/recent.txt"
        if [[ $exit_code -eq 0 && -z "$out" ]]; then
            print_test_result "find -newermB excludes older file" "PASS"
        else
            print_test_result "find -newermB excludes older file" "FAIL" \
                "epoch.txt mtime not newer than recent.txt birth, got: '$out'"
        fi
    fi
    rm -rf "$btime_dir"

    # ================================================================
    # F3: find -printf ignores format string, prints full path
    # GNU find: -printf '%f\n' prints the filename (basename).
    # Our stub ignores the format and prints the full path.
    # ================================================================
    echo -e "${CYAN}Testing -printf respects format string (F3)...${NC}"

    local printf_dir=$(create_temp_dir)
    touch "$printf_dir/testfile.txt"

    # %f = filename only (basename)
    run_command cmd out err exit_code "$binary" "$printf_dir" \
        "-maxdepth" "0" "-printf" "%f\n"
    local printf_base
    printf_base=$(basename "$printf_dir")
    if [[ $exit_code -eq 0 && "$out" == "$printf_base" ]]; then
        print_test_result "find -printf '%f' prints basename" "PASS"
    else
        print_test_result "find -printf '%f' prints basename" "FAIL" \
            "Expected '$printf_base', got: '$out'"
    fi

    # %f for a file inside the directory
    run_command cmd out err exit_code "$binary" "$printf_dir" \
        "-name" "testfile.txt" "-printf" "%f\n"
    if [[ $exit_code -eq 0 && "$out" == "testfile.txt" ]]; then
        print_test_result "find -printf '%f' file basename" "PASS"
    else
        print_test_result "find -printf '%f' file basename" "FAIL" \
            "Expected 'testfile.txt', got: '$out'"
    fi

    # %h = directory component
    run_command cmd out err exit_code "$binary" "$printf_dir" \
        "-name" "testfile.txt" "-printf" "%h\n"
    if [[ $exit_code -eq 0 && "$out" == "$printf_dir" ]]; then
        print_test_result "find -printf '%h' prints dirname" "PASS"
    else
        print_test_result "find -printf '%h' prints dirname" "FAIL" \
            "Expected '$printf_dir', got: '$out'"
    fi

    # %s = file size in bytes (empty file = 0)
    run_command cmd out err exit_code "$binary" "$printf_dir" \
        "-name" "testfile.txt" "-printf" "%s\n"
    if [[ $exit_code -eq 0 && "$out" == "0" ]]; then
        print_test_result "find -printf '%s' prints file size" "PASS"
    else
        print_test_result "find -printf '%s' prints file size" "FAIL" \
            "Expected '0', got: '$out'"
    fi
    rm -rf "$printf_dir"

    # ================================================================
    # F4: find -s (stable/sorted order) is a no-op
    # BSD find -s outputs entries in sorted (lexicographic) order
    # within each directory.
    # ================================================================
    echo -e "${CYAN}Testing -s produces sorted output (F4)...${NC}"

    local sort_dir=$(create_temp_dir)
    # Create files in non-alphabetical order
    touch "$sort_dir/cherry.txt"
    touch "$sort_dir/apple.txt"
    touch "$sort_dir/banana.txt"

    run_command cmd out err exit_code "$binary" "-s" "$sort_dir" "-type" "f"
    if [[ $exit_code -eq 0 ]]; then
        # Extract just filenames, check sorted order
        local sorted_files
        sorted_files=$(echo "$out" | while read -r line; do
            basename "$line"
        done)
        local expected_sorted
        expected_sorted=$(printf "apple.txt\nbanana.txt\ncherry.txt")
        if [[ "$sorted_files" == "$expected_sorted" ]]; then
            print_test_result "find -s outputs in sorted order" "PASS"
        else
            print_test_result "find -s outputs in sorted order" "FAIL" \
                "Expected sorted: '$expected_sorted', got: '$sorted_files'"
        fi
    else
        print_test_result "find -s outputs in sorted order" "FAIL" \
            "Exit code: $exit_code, err: $err"
    fi

    # Also test sorted order within subdirectories
    mkdir "$sort_dir/subdir"
    touch "$sort_dir/subdir/zebra.txt"
    touch "$sort_dir/subdir/aardvark.txt"

    run_command cmd out err exit_code "$binary" "-s" "$sort_dir" "-type" "f"
    if [[ $exit_code -eq 0 ]]; then
        local aardvark_pos zebra_pos
        aardvark_pos=$(echo "$out" | grep -n "aardvark" | head -1 | cut -d: -f1)
        zebra_pos=$(echo "$out" | grep -n "zebra" | head -1 | cut -d: -f1)
        if [[ -n "$aardvark_pos" && -n "$zebra_pos" \
              && "$aardvark_pos" -lt "$zebra_pos" ]]; then
            print_test_result "find -s sorts within subdirectories" "PASS"
        else
            print_test_result "find -s sorts within subdirectories" "FAIL" \
                "aardvark before zebra, got output: '$out'"
        fi
    else
        print_test_result "find -s sorts within subdirectories" "FAIL" \
            "Exit code: $exit_code, err: $err"
    fi
    rm -rf "$sort_dir"

    # ================================================================
    # F5: find -perm -mode and /mode prefix forms rejected
    # GNU find: -perm -644 means "at least these bits set"
    # GNU find: -perm /111 means "any of these bits set"
    # Our parsePerm only accepts raw octal, so these are rejected.
    # ================================================================
    echo -e "${CYAN}Testing -perm prefix forms (F5)...${NC}"

    local perm_prefix_dir=$(create_temp_dir)
    touch "$perm_prefix_dir/rw.txt"
    chmod 644 "$perm_prefix_dir/rw.txt"
    touch "$perm_prefix_dir/rwx.txt"
    chmod 755 "$perm_prefix_dir/rwx.txt"

    # -perm -644: "at least rw-r--r--" -- both files match
    run_command cmd out err exit_code "$binary" "$perm_prefix_dir" \
        "-type" "f" "-perm" "-644"
    if [[ $exit_code -eq 0 && "$out" =~ rw.txt && "$out" =~ rwx.txt ]]; then
        print_test_result "find -perm -644 matches both files" "PASS"
    else
        print_test_result "find -perm -644 matches both files" "FAIL" \
            "Expected both files, exit: $exit_code, out: '$out', err: '$err'"
    fi

    # -perm -755: "at least rwxr-xr-x" -- only rwx.txt matches
    run_command cmd out err exit_code "$binary" "$perm_prefix_dir" \
        "-type" "f" "-perm" "-755"
    if [[ $exit_code -eq 0 && "$out" =~ rwx.txt && ! "$out" =~ rw.txt ]]; then
        print_test_result "find -perm -755 matches only rwx file" "PASS"
    else
        print_test_result "find -perm -755 matches only rwx file" "FAIL" \
            "Expected only rwx.txt, exit: $exit_code, out: '$out', err: '$err'"
    fi

    # -perm /111: "any execute bit set" -- only rwx.txt matches
    run_command cmd out err exit_code "$binary" "$perm_prefix_dir" \
        "-type" "f" "-perm" "/111"
    if [[ $exit_code -eq 0 && "$out" =~ rwx.txt && ! "$out" =~ rw.txt ]]; then
        print_test_result "find -perm /111 matches executable files" "PASS"
    else
        print_test_result "find -perm /111 matches executable files" "FAIL" \
            "Expected only rwx.txt, exit: $exit_code, out: '$out', err: '$err'"
    fi
    rm -rf "$perm_prefix_dir"

    # ================================================================
    # U4: -exec {} ; basic functionality
    # Verify that -exec actually runs the command and the exit
    # code gates the expression (true => subsequent -print fires,
    # false => it does not).
    # ================================================================
    echo -e "${CYAN}Testing -exec {} ; basic (U4)...${NC}"

    local exec_basic_dir=$(create_temp_dir)
    touch "$exec_basic_dir/found.txt"

    # -exec true {} ; -print => file should be printed
    run_command cmd out err exit_code "$binary" "$exec_basic_dir" \
        "-type" "f" "-exec" "true" "{}" ";" "-print"
    if [[ $exit_code -eq 0 && "$out" =~ found.txt ]]; then
        print_test_result "find -exec true {} ; -print shows file" "PASS"
    else
        print_test_result "find -exec true {} ; -print shows file" "FAIL" \
            "Expected found.txt, exit: $exit_code, out: '$out', err: '$err'"
    fi

    # -exec false {} ; -print => file should NOT be printed
    run_command cmd out err exit_code "$binary" "$exec_basic_dir" \
        "-type" "f" "-exec" "false" "{}" ";" "-print"
    if [[ $exit_code -eq 0 && ! "$out" =~ found.txt ]]; then
        print_test_result "find -exec false {} ; -print suppresses file" "PASS"
    else
        print_test_result "find -exec false {} ; -print suppresses file" "FAIL" \
            "Expected no output, exit: $exit_code, out: '$out', err: '$err'"
    fi
    rm -rf "$exec_basic_dir"

    # ================================================================
    # U9: -group predicate has no test
    # ================================================================
    echo -e "${CYAN}Testing -group predicate (U9)...${NC}"

    local group_dir=$(create_temp_dir)
    create_temp_file "content" "$group_dir/grpfile.txt"

    # Get the group name of the file
    local grp_name
    grp_name=$(stat -c '%G' "$group_dir/grpfile.txt" 2>/dev/null \
        || stat -f '%Sg' "$group_dir/grpfile.txt")
    run_command cmd out err exit_code "$binary" "$group_dir" \
        "-type" "f" "-group" "$grp_name"
    if [[ $exit_code -eq 0 && "$out" =~ grpfile.txt ]]; then
        print_test_result "find -group $grp_name" "PASS"
    else
        print_test_result "find -group $grp_name" "FAIL" \
            "Expected grpfile.txt, got: '$out', err: '$err'"
    fi
    rm -rf "$group_dir"

    # ================================================================
    # U10: -nogroup predicate has no test
    # ================================================================
    echo -e "${CYAN}Testing -nogroup predicate (U10)...${NC}"

    local nogroup_dir=$(create_temp_dir)
    create_temp_file "content" "$nogroup_dir/normal.txt"

    # Files owned by real groups should not match -nogroup
    run_command cmd out err exit_code "$binary" "$nogroup_dir" \
        "-type" "f" "-nogroup"
    if [[ $exit_code -eq 0 && ! "$out" =~ normal.txt ]]; then
        print_test_result "find -nogroup excludes normal files" "PASS"
    else
        print_test_result "find -nogroup excludes normal files" "FAIL" \
            "Expected empty, got: '$out', err: '$err'"
    fi
    rm -rf "$nogroup_dir"

    # ================================================================
    # U13: -H follows only command-line symlinks
    # ================================================================
    echo -e "${CYAN}Testing -H option (U13)...${NC}"

    local h_dir=$(create_temp_dir)
    mkdir "$h_dir/target"
    create_temp_file "content" "$h_dir/target/inner.txt"
    ln -s "$h_dir/target" "$h_dir/toplink"

    # -H with symlink as starting path should follow it
    run_command cmd out err exit_code "$binary" "-H" "$h_dir/toplink" \
        "-name" "inner.txt"
    if [[ $exit_code -eq 0 && "$out" =~ inner.txt ]]; then
        print_test_result "find -H follows cmdline symlinks" "PASS"
    else
        print_test_result "find -H follows cmdline symlinks" "FAIL" \
            "Expected inner.txt, got: '$out', err: '$err'"
    fi
    rm -rf "$h_dir"

    # ================================================================
    # H7: -follow in expression position
    # macOS/GNU find accept -follow as a deprecated expression primary.
    # Our implementation only recognizes it before paths, so
    #   find <path> -maxdepth 1 -follow
    # gives "unknown predicate '-follow'".
    # ================================================================
    echo -e "${CYAN}Testing -follow in expression position (H7)...${NC}"

    local follow_dir=$(create_temp_dir)
    create_temp_file "content" "$follow_dir/file.txt"

    run_command cmd out err exit_code "$binary" "$follow_dir" \
        "-maxdepth" "1" "-follow"
    if [[ $exit_code -eq 0 && -z "$err" ]]; then
        print_test_result "find -follow in expression position" "PASS"
    else
        print_test_result "find -follow in expression position" "FAIL" \
            "Expected exit 0, got $exit_code, err: '$err'"
    fi
    rm -rf "$follow_dir"

    # ================================================================
    # U14: -a / -and operator has no test
    # ================================================================
    echo -e "${CYAN}Testing -a / -and operator (U14)...${NC}"

    local and_dir=$(create_temp_dir)
    create_temp_file "content" "$and_dir/hello.txt"
    create_temp_file "content" "$and_dir/hello.md"
    create_temp_file "content" "$and_dir/world.txt"

    # -name "hello*" -a -name "*.txt" should match only hello.txt
    run_command cmd out err exit_code "$binary" "$and_dir" \
        "-name" "hello*" "-a" "-name" "*.txt"
    if [[ $exit_code -eq 0 && "$out" =~ hello.txt \
          && ! "$out" =~ hello.md && ! "$out" =~ world.txt ]]; then
        print_test_result "find -a operator" "PASS"
    else
        print_test_result "find -a operator" "FAIL" \
            "Expected only hello.txt, got: '$out', err: '$err'"
    fi

    # Same test with -and (long form)
    run_command cmd out err exit_code "$binary" "$and_dir" \
        "-name" "hello*" "-and" "-name" "*.txt"
    if [[ $exit_code -eq 0 && "$out" =~ hello.txt \
          && ! "$out" =~ hello.md && ! "$out" =~ world.txt ]]; then
        print_test_result "find -and operator" "PASS"
    else
        print_test_result "find -and operator" "FAIL" \
            "Expected only hello.txt, got: '$out', err: '$err'"
    fi
    rm -rf "$and_dir"

    # ================================================================
    # F6: find -exec {} + (batch form) broken
    # GNU find: -exec CMD {} + collects args and executes CMD once
    # with all matched files as arguments.
    # Our parser only looks for ';' terminator, not '+'.
    # ================================================================
    echo -e "${CYAN}Testing -exec {} + batch form (F6)...${NC}"

    local exec_batch_dir=$(create_temp_dir)
    touch "$exec_batch_dir/file1.txt" \
          "$exec_batch_dir/file2.txt" \
          "$exec_batch_dir/file3.txt"

    # -exec echo {} + should batch all files into one echo call
    run_command cmd out err exit_code "$binary" "$exec_batch_dir" \
        "-type" "f" "-exec" "echo" "{}" "+"
    if [[ $exit_code -eq 0 ]]; then
        local line_count
        line_count=$(echo "$out" | wc -l | tr -d ' ')
        if [[ "$out" =~ file1.txt && "$out" =~ file2.txt \
              && "$out" =~ file3.txt ]]; then
            # Batch mode: echo produces one line with all files
            if [[ "$line_count" -le 1 ]]; then
                print_test_result "find -exec {} + batches args" "PASS"
            else
                print_test_result "find -exec {} + batches args" "FAIL" \
                    "Expected 1 line (batched), got $line_count: '$out'"
            fi
        else
            print_test_result "find -exec {} + batches args" "FAIL" \
                "Expected all 3 files in output, got: '$out'"
        fi
    else
        print_test_result "find -exec {} + batches args" "FAIL" \
            "Expected exit 0, got $exit_code, err: '$err'"
    fi
    rm -rf "$exec_batch_dir"

    # ================================================================
    # F7: find -execdir {} + also broken
    # Same issue as F6 but for -execdir.
    # ================================================================
    echo -e "${CYAN}Testing -execdir {} + batch form (F7)...${NC}"

    local execdir_batch_dir=$(create_temp_dir)
    touch "$execdir_batch_dir/alpha.txt" "$execdir_batch_dir/beta.txt"

    # -execdir echo {} + should batch files per-directory
    run_command cmd out err exit_code "$binary" "$execdir_batch_dir" \
        "-type" "f" "-execdir" "echo" "{}" "+"
    if [[ $exit_code -eq 0 ]]; then
        local edir_line_count
        edir_line_count=$(echo "$out" | wc -l | tr -d ' ')
        if [[ "$out" =~ alpha.txt && "$out" =~ beta.txt ]]; then
            if [[ "$edir_line_count" -le 1 ]]; then
                print_test_result "find -execdir {} + batches args" "PASS"
            else
                print_test_result "find -execdir {} + batches args" "FAIL" \
                    "Expected 1 line, got $edir_line_count: '$out'"
            fi
        else
            print_test_result "find -execdir {} + batches args" "FAIL" \
                "Expected both files, got: '$out'"
        fi
    else
        print_test_result "find -execdir {} + batches args" "FAIL" \
            "Expected exit 0, got $exit_code, err: '$err'"
    fi
    rm -rf "$execdir_batch_dir"
}
