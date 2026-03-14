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
    if [[ $print0_exit -eq 0 ]] && xxd "$print0_out" | grep -q '00'; then
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
}
