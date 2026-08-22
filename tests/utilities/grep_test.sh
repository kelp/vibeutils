#!/usr/bin/env bash
# Comprehensive tests for grep utility
# Tests pattern matching, flags, regex modes, context, recursion, and error handling

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_grep() {
    local util="grep"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic matching...${NC}"

    # Basic string match
    test_command_output "grep basic match" "hello world" bash -c "printf 'hello world\nfoo bar\n' | '$binary' --color=never hello"

    # Multiple matches
    test_command_output "grep multiple matches" $'hello world\nhello again' bash -c "printf 'hello world\nfoo bar\nhello again\n' | '$binary' --color=never hello"

    # No match
    test_command_exit_code "grep no match exit 1" 1 bash -c "printf 'hello world\n' | '$binary' --color=never zzzzz"

    # Empty input
    test_command_exit_code "grep empty input exit 1" 1 bash -c "printf '' | '$binary' --color=never pattern"

    echo -e "${CYAN}Testing case insensitive (-i)...${NC}"

    test_command_output "grep -i case insensitive" $'Hello World\nhello again' bash -c "printf 'Hello World\nfoo bar\nhello again\n' | '$binary' --color=never -i hello"

    test_command_output "grep --ignore-case" "HELLO" bash -c "printf 'HELLO\nworld\n' | '$binary' --color=never --ignore-case hello"

    echo -e "${CYAN}Testing invert match (-v)...${NC}"

    test_command_output "grep -v invert" "foo bar" bash -c "printf 'hello world\nfoo bar\nhello again\n' | '$binary' --color=never -v hello"

    echo -e "${CYAN}Testing count (-c)...${NC}"

    test_command_output "grep -c count" "2" bash -c "printf 'hello world\nfoo bar\nhello again\n' | '$binary' --color=never -c hello"

    test_command_output "grep -c no match" "0" bash -c "printf 'foo bar\n' | '$binary' --color=never -c hello"

    echo -e "${CYAN}Testing line number (-n)...${NC}"

    test_command_output "grep -n line number" $'1:hello world\n3:hello again' bash -c "printf 'hello world\nfoo bar\nhello again\n' | '$binary' --color=never -n hello"

    echo -e "${CYAN}Testing files-with-matches (-l)...${NC}"

    local test_file1="$TEMP_DIR/grep_file1.txt"
    local test_file2="$TEMP_DIR/grep_file2.txt"
    local test_file3="$TEMP_DIR/grep_file3.txt"
    printf 'hello world\n' > "$test_file1"
    printf 'foo bar\n' > "$test_file2"
    printf 'hello again\n' > "$test_file3"

    local out="" err="" exit_code=""
    run_command cmd out err exit_code "$binary" --color=never -l hello "$test_file1" "$test_file2" "$test_file3"
    if [[ "$out" =~ "$test_file1" && ! "$out" =~ "$test_file2" && "$out" =~ "$test_file3" ]]; then
        print_test_result "grep -l files with matches" "PASS"
    else
        print_test_result "grep -l files with matches" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing files-without-match (-L)...${NC}"

    run_command cmd out err exit_code "$binary" --color=never -L hello "$test_file1" "$test_file2" "$test_file3"
    if [[ ! "$out" =~ "$test_file1" && "$out" =~ "$test_file2" && ! "$out" =~ "$test_file3" ]]; then
        print_test_result "grep -L files without match" "PASS"
    else
        print_test_result "grep -L files without match" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing extended regexp (-E)...${NC}"

    test_command_output "grep -E alternation" $'hello\nworld' bash -c "printf 'hello\nfoo\nworld\n' | '$binary' --color=never -E 'hello|world'"

    test_command_output "grep -E plus" "helllo" bash -c "printf 'helllo\nheo\n' | '$binary' --color=never -E 'hel+o'"

    echo -e "${CYAN}Testing fixed strings (-F)...${NC}"

    # Dot should be literal, not regex any-char
    test_command_output "grep -F literal dot" "hello.world" bash -c "printf 'hello.world\nhelloXworld\n' | '$binary' --color=never -F 'hello.world'"

    # Regex special chars treated literally
    test_command_output "grep -F literal brackets" "[test]" bash -c "printf '[test]\ntest\n' | '$binary' --color=never -F '[test]'"

    echo -e "${CYAN}Testing only-matching (-o)...${NC}"

    test_command_output "grep -o only matching" "hello" bash -c "printf 'say hello world\n' | '$binary' --color=never -Eo 'hello'"

    echo -e "${CYAN}Testing quiet mode (-q)...${NC}"

    test_command_exit_code "grep -q match exits 0" 0 bash -c "printf 'hello\n' | '$binary' --color=never -q hello"
    test_command_exit_code "grep -q no match exits 1" 1 bash -c "printf 'hello\n' | '$binary' --color=never -q zzzzz"

    echo -e "${CYAN}Testing line regexp (-x)...${NC}"

    test_command_output "grep -x whole line" "hello" bash -c "printf 'hello\nhello world\n' | '$binary' --color=never -Ex 'hello'"

    echo -e "${CYAN}Testing max-count (-m)...${NC}"

    test_command_output "grep -m 1" "hello one" bash -c "printf 'hello one\nhello two\nhello three\n' | '$binary' --color=never -m 1 hello"

    echo -e "${CYAN}Testing multiple patterns (-e)...${NC}"

    test_command_output "grep -e multiple patterns" $'hello\nworld' bash -c "printf 'hello\nfoo\nworld\n' | '$binary' --color=never -e hello -e world"

    echo -e "${CYAN}Testing pattern from file (-f)...${NC}"

    local pattern_file="$TEMP_DIR/grep_patterns.txt"
    printf 'hello\nworld\n' > "$pattern_file"
    test_command_output "grep -f pattern file" $'hello\nworld' bash -c "printf 'hello\nfoo\nworld\n' | '$binary' --color=never -f '$pattern_file'"

    echo -e "${CYAN}Testing context (-A, -B, -C)...${NC}"

    test_command_output "grep -A1 after context" $'match\nafter' bash -c "printf 'before\nmatch\nafter\nend\n' | '$binary' --color=never -A1 match"

    test_command_output "grep -B1 before context" $'before\nmatch' bash -c "printf 'start\nbefore\nmatch\nafter\n' | '$binary' --color=never -B1 match"

    test_command_output "grep -C1 context" $'before\nmatch\nafter' bash -c "printf 'start\nbefore\nmatch\nafter\nend\n' | '$binary' --color=never -C1 match"

    echo -e "${CYAN}Testing filename display (-H, -h)...${NC}"

    local fn_file="$TEMP_DIR/grep_fntest.txt"
    printf 'hello world\n' > "$fn_file"

    # -H forces filename display
    run_command cmd out err exit_code "$binary" --color=never -H hello "$fn_file"
    if [[ "$out" =~ "$fn_file" ]]; then
        print_test_result "grep -H with filename" "PASS"
    else
        print_test_result "grep -H with filename" "FAIL" "Got: $out"
    fi

    # -h suppresses filename
    run_command cmd out err exit_code "$binary" --color=never -h hello "$fn_file" "$test_file1"
    if [[ ! "$out" =~ "$fn_file" ]]; then
        print_test_result "grep -h no filename" "PASS"
    else
        print_test_result "grep -h no filename" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing recursive search (-r)...${NC}"

    local recurse_dir="$TEMP_DIR/grep_recurse"
    mkdir -p "$recurse_dir/sub"
    printf 'hello in root\n' > "$recurse_dir/file1.txt"
    printf 'hello in sub\n' > "$recurse_dir/sub/file2.txt"
    printf 'no match here\n' > "$recurse_dir/sub/file3.txt"

    run_command cmd out err exit_code "$binary" --color=never -r hello "$recurse_dir"
    if [[ "$out" =~ "hello in root" && "$out" =~ "hello in sub" && ! "$out" =~ "no match" ]]; then
        print_test_result "grep -r recursive" "PASS"
    else
        print_test_result "grep -r recursive" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing --include and --exclude...${NC}"

    local filter_dir="$TEMP_DIR/grep_filter"
    mkdir -p "$filter_dir"
    printf 'hello c\n' > "$filter_dir/test.c"
    printf 'hello h\n' > "$filter_dir/test.h"
    printf 'hello o\n' > "$filter_dir/test.o"

    run_command cmd out err exit_code "$binary" --color=never -r --include='*.c' hello "$filter_dir"
    if [[ "$out" =~ "hello c" && ! "$out" =~ "hello h" ]]; then
        print_test_result "grep --include=*.c" "PASS"
    else
        print_test_result "grep --include=*.c" "FAIL" "Got: $out"
    fi

    run_command cmd out err exit_code "$binary" --color=never -r --exclude='*.o' hello "$filter_dir"
    if [[ "$out" =~ "hello c" && ! "$out" =~ "hello o" ]]; then
        print_test_result "grep --exclude=*.o" "PASS"
    else
        print_test_result "grep --exclude=*.o" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing --exclude-dir...${NC}"

    local exdir_dir="$TEMP_DIR/grep_exdir"
    mkdir -p "$exdir_dir/include" "$exdir_dir/.git"
    printf 'hello include\n' > "$exdir_dir/include/file.txt"
    printf 'hello git\n' > "$exdir_dir/.git/file.txt"

    run_command cmd out err exit_code "$binary" --color=never -r --exclude-dir='.git' hello "$exdir_dir"
    if [[ "$out" =~ "hello include" && ! "$out" =~ "hello git" ]]; then
        print_test_result "grep --exclude-dir=.git" "PASS"
    else
        print_test_result "grep --exclude-dir=.git" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing color output...${NC}"

    # --color=always should produce ANSI codes
    run_command cmd out err exit_code "$binary" --color=always hello "$test_file1"
    if [[ "$out" =~ $'\x1b[' ]]; then
        print_test_result "grep --color=always produces ANSI" "PASS"
    else
        print_test_result "grep --color=always produces ANSI" "FAIL" "No ANSI codes found"
    fi

    # --color=never should not produce ANSI codes
    run_command cmd out err exit_code "$binary" --color=never hello "$test_file1"
    if [[ ! "$out" =~ $'\x1b[' ]]; then
        print_test_result "grep --color=never no ANSI" "PASS"
    else
        print_test_result "grep --color=never no ANSI" "FAIL" "ANSI codes found"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No pattern
    test_command_exit_code "grep no pattern exit 2" 2 "$binary" 2>/dev/null

    # Issue #162: GNU 3.x prints a Usage line, not "grep: no pattern specified".
    # Host GNU is /usr/bin/grep or /bin/grep (never PATH). LC_ALL=C. Keep the
    # exit-code test above; these only add wording and a full-stderr compare.
    echo -e "${CYAN}Testing issue #162: no-pattern Usage stderr...${NC}"
    local usage_line="Usage: grep [OPTION]... PATTERNS [FILE]..."
    local try_line="Try 'grep --help' for more information."
    local gnu_grep=""
    local gnu_ver=""
    if [[ -x /usr/bin/grep ]]; then
        gnu_ver=$(LC_ALL=C /usr/bin/grep --version 2>/dev/null | head -n1 || true)
        if [[ "$gnu_ver" == *"GNU grep"* ]]; then
            gnu_grep=/usr/bin/grep
        fi
    fi
    if [[ -z "$gnu_grep" && -x /bin/grep ]]; then
        gnu_ver=$(LC_ALL=C /bin/grep --version 2>/dev/null | head -n1 || true)
        if [[ "$gnu_ver" == *"GNU grep"* ]]; then
            gnu_grep=/bin/grep
        fi
    fi

    local nopattern_out="" nopattern_err="" nopattern_exit="" nopattern_cmd=""
    local nopattern_first="" nopattern_hint=""
    run_command nopattern_cmd nopattern_out nopattern_err nopattern_exit \
        bash -c "LC_ALL=C '$binary' </dev/null"
    nopattern_first=$(printf '%s\n' "$nopattern_err" | sed -n '1p')
    nopattern_hint=$(printf '%s\n' "$nopattern_err" | sed -n '2p')
    if [[ "$nopattern_first" == "$usage_line" ]]; then
        print_test_result "grep no pattern stderr Usage line (#162)" "PASS"
    else
        print_test_result "grep no pattern stderr Usage line (#162)" "FAIL" \
            "expected '$usage_line', got '$nopattern_first'"
    fi
    if [[ "$nopattern_hint" == "$try_line" ]]; then
        print_test_result "grep no pattern stderr Try-help line (#162)" "PASS"
    else
        print_test_result "grep no pattern stderr Try-help line (#162)" "FAIL" \
            "expected '$try_line', got '$nopattern_hint'"
    fi
    if [[ "$nopattern_err" != *"no pattern specified"* ]]; then
        print_test_result "grep no pattern omits 'no pattern specified' (#162)" "PASS"
    else
        print_test_result "grep no pattern omits 'no pattern specified' (#162)" "FAIL" \
            "stderr: '$nopattern_err'"
    fi
    if [[ -z "$nopattern_out" ]]; then
        print_test_result "grep no pattern stdout empty (#162)" "PASS"
    else
        print_test_result "grep no pattern stdout empty (#162)" "FAIL" \
            "got '$nopattern_out'"
    fi

    local ddash_out="" ddash_err="" ddash_exit="" ddash_cmd=""
    local ddash_first="" ddash_hint=""
    run_command ddash_cmd ddash_out ddash_err ddash_exit \
        bash -c "LC_ALL=C '$binary' -- </dev/null"
    ddash_first=$(printf '%s\n' "$ddash_err" | sed -n '1p')
    ddash_hint=$(printf '%s\n' "$ddash_err" | sed -n '2p')
    if [[ "$ddash_first" == "$usage_line" ]]; then
        print_test_result "grep -- stderr Usage line (#162)" "PASS"
    else
        print_test_result "grep -- stderr Usage line (#162)" "FAIL" \
            "expected '$usage_line', got '$ddash_first'"
    fi
    if [[ "$ddash_hint" == "$try_line" ]]; then
        print_test_result "grep -- stderr Try-help line (#162)" "PASS"
    else
        print_test_result "grep -- stderr Try-help line (#162)" "FAIL" \
            "expected '$try_line', got '$ddash_hint'"
    fi
    if [[ "$ddash_err" != *"no pattern specified"* ]]; then
        print_test_result "grep -- omits 'no pattern specified' (#162)" "PASS"
    else
        print_test_result "grep -- omits 'no pattern specified' (#162)" "FAIL" \
            "stderr: '$ddash_err'"
    fi
    if [[ -z "$ddash_out" ]]; then
        print_test_result "grep -- stdout empty (#162)" "PASS"
    else
        print_test_result "grep -- stdout empty (#162)" "FAIL" \
            "got '$ddash_out'"
    fi

    if [[ -n "$gnu_grep" ]]; then
        local gnu_err_file="$TEMP_DIR/gnu_nopattern.err"
        local ours_err_file="$TEMP_DIR/ours_nopattern.err"
        local gnu_exit=0
        local ours_exit=0
        set +e
        LC_ALL=C "$gnu_grep" </dev/null >/dev/null 2>"$gnu_err_file"
        gnu_exit=$?
        LC_ALL=C "$binary" </dev/null >/dev/null 2>"$ours_err_file"
        ours_exit=$?
        set -e
        if cmp -s "$gnu_err_file" "$ours_err_file" && [[ "$gnu_exit" -eq 2 && "$ours_exit" -eq 2 ]]; then
            print_test_result "grep no pattern stderr matches host GNU (#162)" "PASS"
        else
            print_test_result "grep no pattern stderr matches host GNU (#162)" "FAIL" \
                "gnu_exit=$gnu_exit ours_exit=$ours_exit gnu='$(cat "$gnu_err_file")' ours='$(cat "$ours_err_file")'"
        fi
        set +e
        LC_ALL=C "$gnu_grep" -- </dev/null >/dev/null 2>"$gnu_err_file"
        gnu_exit=$?
        LC_ALL=C "$binary" -- </dev/null >/dev/null 2>"$ours_err_file"
        ours_exit=$?
        set -e
        if cmp -s "$gnu_err_file" "$ours_err_file" && [[ "$gnu_exit" -eq 2 && "$ours_exit" -eq 2 ]]; then
            print_test_result "grep -- stderr matches host GNU (#162)" "PASS"
        else
            print_test_result "grep -- stderr matches host GNU (#162)" "FAIL" \
                "gnu_exit=$gnu_exit ours_exit=$ours_exit gnu='$(cat "$gnu_err_file")' ours='$(cat "$ours_err_file")'"
        fi
    else
        print_test_result "grep no pattern stderr matches host GNU (#162)" "SKIP" \
            "needs GNU /usr/bin/grep or /bin/grep (not present on $(uname))"
    fi

    # Invalid option
    test_command_exit_code "grep invalid option exit 2" 2 "$binary" -Q pattern 2>/dev/null

    # Nonexistent file
    test_command_exit_code "grep nonexistent file exit 2" 2 "$binary" --color=never pattern /nonexistent/file 2>/dev/null

    # Invalid regex
    test_command_exit_code "grep invalid regex exit 2" 2 "$binary" --color=never '[invalid' /dev/null 2>/dev/null

    echo -e "${CYAN}Testing -- separator...${NC}"

    local dash_file="$TEMP_DIR/-dashfile.txt"
    printf 'hello\n' > "$dash_file"
    test_command_output "grep -- handles dash files" "hello" "$binary" --color=never -e hello -- "$dash_file"

    echo -e "${CYAN}Testing stdin with - argument...${NC}"

    test_command_output "grep - means stdin" "hello" bash -c "printf 'hello\nworld\n' | '$binary' --color=never hello -"

    echo -e "${CYAN}Testing combined flags...${NC}"

    test_command_output "grep -ivn combined" $'2:foo bar' bash -c "printf 'hello world\nfoo bar\nhello again\n' | '$binary' --color=never -ivn hello"

    echo -e "${CYAN}Testing multi-file with filename...${NC}"

    run_command cmd out err exit_code "$binary" --color=never hello "$test_file1" "$test_file3"
    if [[ "$out" =~ "$test_file1" && "$out" =~ "$test_file3" ]]; then
        print_test_result "grep multi-file shows filenames" "PASS"
    else
        print_test_result "grep multi-file shows filenames" "FAIL" "Got: $out"
    fi

    echo -e "${CYAN}Testing -s suppress errors...${NC}"

    # -s should suppress error about nonexistent file
    run_command cmd out err exit_code "$binary" --color=never -s pattern /nonexistent/file
    if [[ -z "$err" ]]; then
        print_test_result "grep -s suppresses errors" "PASS"
    else
        print_test_result "grep -s suppresses errors" "FAIL" "Got stderr: $err"
    fi

    echo -e "${CYAN}Testing F27: grep -x in BRE mode...${NC}"

    # F27: -x should work in BRE mode (default). The bug wraps pattern as
    # ^(foo)$ but ( ) are literal in BRE, so it matches "(foo)" not "foo".
    test_command_output "grep -x BRE matches whole line" "foo" bash -c "printf 'foo\nfoo bar\n' | '$binary' --color=never -x 'foo'"

    test_command_exit_code "grep -x BRE no match returns 1" 1 bash -c "printf 'foo bar\nbaz\n' | '$binary' --color=never -x 'foo'"

    # -x with regex metacharacter in BRE mode
    test_command_output "grep -x BRE with dot metachar" $'foo\nfXo' bash -c "printf 'foo\nfXo\nf.o bar\n' | '$binary' --color=never -x 'f.o'"

    # -Ex (ERE mode) should still work (control test)
    test_command_output "grep -Ex ERE whole line" "foo" bash -c "printf 'foo\nfoo bar\n' | '$binary' --color=never -Ex 'foo'"

    echo -e "${CYAN}Testing F28: grep -o multiple matches per line...${NC}"

    # F28: -o should print every non-overlapping match, not just the first.
    test_command_output "grep -o all matches per line" $'foo\nfoo' bash -c "printf 'foobarfoo\n' | '$binary' --color=never -o 'foo'"

    test_command_output "grep -Eo all matches per line" $'foo\nfoo' bash -c "printf 'foobarfoo\n' | '$binary' --color=never -Eo 'foo'"

    # Multiple matches across multiple lines
    test_command_output "grep -o multi-line multi-match" $'abc\nabc\nabc' bash -c "printf 'abcabc\nxyzabc\n' | '$binary' --color=never -o 'abc'"

    # Single-char pattern with many matches
    test_command_output "grep -o single char many matches" $'a\na\na\na\na' bash -c "printf 'aababaa\n' | '$binary' --color=never -o 'a'"

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression test: grep -f pattern_file data_file should work correctly
    # Verifies -f flag doesn't leak file descriptors or misread patterns
    local reg_pattern_file="$TEMP_DIR/grep_reg_patterns.txt"
    local reg_data_file="$TEMP_DIR/grep_reg_data.txt"
    printf 'hello\n' > "$reg_pattern_file"
    printf 'hello world\nfoo bar\nhello again\n' > "$reg_data_file"
    test_command_output "grep -f with data file (regression)" $'hello world\nhello again' "$binary" --color=never -f "$reg_pattern_file" "$reg_data_file"

    echo -e "${CYAN}Testing G-03: grep -wo boundary char exclusion...${NC}"

    # G-03: -w with -o should print only the matched word, not boundary chars.
    # BUG: pmatch[0] includes the boundary characters from the word-boundary
    # groups, so "hello foo bar" with -wo "foo" prints " foo " with spaces.
    local wo_file="$TEMP_DIR/grep_wo.txt"
    printf 'hello foo bar\n' > "$wo_file"
    test_command_output "grep -wo prints only the word (mid-line)" "foo" "$binary" --color=never -wo "foo" "$wo_file"

    # Word at start of line
    printf 'foo bar baz\n' > "$wo_file"
    test_command_output "grep -wo word at start of line" "foo" "$binary" --color=never -wo "foo" "$wo_file"

    # Word at end of line
    printf 'baz bar foo\n' > "$wo_file"
    test_command_output "grep -wo word at end of line" "foo" "$binary" --color=never -wo "foo" "$wo_file"

    # Multiple word matches on one line with -wo
    printf 'foo bar foo\n' > "$wo_file"
    test_command_output "grep -wo multiple words on line" $'foo\nfoo' "$binary" --color=never -wo "foo" "$wo_file"

    echo -e "${CYAN}Testing issue #58: recursive walk errors set exit 2...${NC}"

    # GNU 3.11 pinned: grep -r exits 2 when a read error occurs during the walk
    # (unreadable subdir), except -q returns 0 when a line was selected.
    local walk_root
    walk_root=$(create_temp_dir)
    mkdir -p "$walk_root/ok" "$walk_root/locked"
    printf 'hay\n' > "$walk_root/ok/f.txt"
    printf 'secret\n' > "$walk_root/locked/s.txt"
    chmod 000 "$walk_root/locked"

    # No match + unreadable subdir => exit 2 (not 1), with a stderr diagnostic.
    run_command cmd out err exit_code "$binary" --color=never -r zzz "$walk_root"
    if [[ "$exit_code" -eq 2 && -n "$err" ]]; then
        print_test_result "grep -r no-match unreadable subdir exits 2" "PASS"
    else
        print_test_result "grep -r no-match unreadable subdir exits 2" "FAIL" "exit=$exit_code err=$err"
    fi

    # Match found + unreadable subdir, no -q => exit 2 (error dominates match).
    run_command cmd out err exit_code "$binary" --color=never -r hay "$walk_root"
    if [[ "$exit_code" -eq 2 && "$out" =~ hay ]]; then
        print_test_result "grep -r match unreadable subdir exits 2" "PASS"
    else
        print_test_result "grep -r match unreadable subdir exits 2" "FAIL" "exit=$exit_code out=$out"
    fi

    # -q + match => exit 0 (quiet match wins over the error).
    run_command cmd out err exit_code "$binary" --color=never -q -r hay "$walk_root"
    if [[ "$exit_code" -eq 0 ]]; then
        print_test_result "grep -q -r match unreadable subdir exits 0" "PASS"
    else
        print_test_result "grep -q -r match unreadable subdir exits 0" "FAIL" "exit=$exit_code"
    fi

    # -q + no match => exit 2 (quiet overrides to 0 only when a match was found;
    # here the walk error dominates, not mere no-match 1).
    run_command cmd out err exit_code "$binary" --color=never -q -r zzz "$walk_root"
    if [[ "$exit_code" -eq 2 ]]; then
        print_test_result "grep -q -r no-match unreadable subdir exits 2" "PASS"
    else
        print_test_result "grep -q -r no-match unreadable subdir exits 2" "FAIL" "exit=$exit_code"
    fi

    chmod 755 "$walk_root/locked"
    rm -rf "$walk_root"

    # Fully readable tree: the error channel must not leak into clean walks.
    local clean_root
    clean_root=$(create_temp_dir)
    mkdir -p "$clean_root/ok"
    printf 'hay\n' > "$clean_root/ok/f.txt"
    test_command_exit_code "grep -r clean tree match exits 0" 0 "$binary" --color=never -r hay "$clean_root"
    test_command_exit_code "grep -r clean tree no-match exits 1" 1 "$binary" --color=never -r zzz "$clean_root"
    rm -rf "$clean_root"

    echo -e "${CYAN}Testing issue #63: operand errors stay unquoted (GNU grep parity)...${NC}"

    # GNU grep 3.11 (LC_ALL=C) prints all four of these bare, with no quotes
    # around the operand: "grep: PATH: MESSAGE". Unlike coreutils, GNU grep
    # never wraps the failing operand in quotes.

    # Missing operand file.
    run_command cmd out err exit_code "$binary" --color=never pattern "$TEMP_DIR/grep_63_nosuch.txt"
    if [[ "$err" == "grep: $TEMP_DIR/grep_63_nosuch.txt: No such file or directory" ]]; then
        print_test_result "grep missing operand file stays unquoted" "PASS"
    else
        print_test_result "grep missing operand file stays unquoted" "FAIL" "Got: $err"
    fi

    # Missing -f pattern file.
    local pf_data_file="$TEMP_DIR/grep_63_data.txt"
    printf 'hello\n' > "$pf_data_file"
    run_command cmd out err exit_code "$binary" --color=never -f "$TEMP_DIR/grep_63_nopatterns.txt" "$pf_data_file"
    if [[ "$err" == "grep: $TEMP_DIR/grep_63_nopatterns.txt: No such file or directory" ]]; then
        print_test_result "grep missing -f pattern file stays unquoted" "PASS"
    else
        print_test_result "grep missing -f pattern file stays unquoted" "FAIL" "Got: $err"
    fi

    # Unreadable operand file (non-recursive).
    local locked_file="$TEMP_DIR/grep_63_locked.txt"
    printf 'secret\n' > "$locked_file"
    chmod 000 "$locked_file"
    run_command cmd out err exit_code "$binary" --color=never pattern "$locked_file"
    if [[ "$err" == "grep: $locked_file: Permission denied" ]]; then
        print_test_result "grep unreadable operand file stays unquoted" "PASS"
    else
        print_test_result "grep unreadable operand file stays unquoted" "FAIL" "Got: $err"
    fi
    chmod 644 "$locked_file"
    rm -f "$locked_file"

    # Unreadable file found during a recursive walk.
    local walk_file_root
    walk_file_root=$(create_temp_dir)
    printf 'hay\n' > "$walk_file_root/f.txt"
    local locked_walk_file="$walk_file_root/secret.txt"
    printf 'secret\n' > "$locked_walk_file"
    chmod 000 "$locked_walk_file"
    run_command cmd out err exit_code "$binary" --color=never -r hay "$walk_file_root"
    if [[ "$err" == "grep: $locked_walk_file: Permission denied" ]]; then
        print_test_result "grep unreadable file during -r walk stays unquoted" "PASS"
    else
        print_test_result "grep unreadable file during -r walk stays unquoted" "FAIL" "Got: $err"
    fi
    chmod 644 "$locked_walk_file"
    rm -rf "$walk_file_root"

    # Unreadable subdirectory found during a recursive walk.
    local walk_dir_root
    walk_dir_root=$(create_temp_dir)
    mkdir -p "$walk_dir_root/ok" "$walk_dir_root/locked"
    printf 'hay\n' > "$walk_dir_root/ok/f.txt"
    printf 'secret\n' > "$walk_dir_root/locked/s.txt"
    chmod 000 "$walk_dir_root/locked"
    run_command cmd out err exit_code "$binary" --color=never -r hay "$walk_dir_root"
    if [[ "$err" == "grep: $walk_dir_root/locked: Permission denied" ]]; then
        print_test_result "grep unreadable dir during -r walk stays unquoted" "PASS"
    else
        print_test_result "grep unreadable dir during -r walk stays unquoted" "FAIL" "Got: $err"
    fi
    chmod 755 "$walk_dir_root/locked"
    rm -rf "$walk_dir_root"

    echo -e "${CYAN}Testing GNU regex escape extensions (\\s \\S \\w \\W \\| \\< \\> \\\\b \\\\B)...${NC}"

    # GNU extension: \s == [[:space:]] in ERE (exact issue #78 repro).
    test_command_output "grep -E backslash-s whitespace (GNU ext)" "  plan: x" bash -c "printf '  plan: x\n' | '$binary' --color=never -E '^\s+plan\s*:'"

    # GNU extension: \s in BRE (default mode).
    test_command_output "grep BRE backslash-s whitespace (GNU ext)" "a b" bash -c "printf 'a b\n' | '$binary' --color=never 'a\sb'"

    # GNU extension: \S == [^[:space:]].
    test_command_output "grep -E backslash-S non-whitespace (GNU ext)" "acb" bash -c "printf 'a b\nacb\n' | '$binary' --color=never -E 'a\Sb'"

    # GNU extension: \w == [[:alnum:]_].
    test_command_exit_code "grep BRE backslash-w word chars (GNU ext)" 0 bash -c "printf 'foo_1\n' | '$binary' --color=never '\w\w\w_\w'"

    # GNU extension: \W == [^[:alnum:]_].
    test_command_output "grep BRE backslash-W non-word chars (GNU ext)" "a-b" bash -c "printf 'a-b\naxb\n' | '$binary' --color=never 'a\Wb'"

    # GNU extension: \| is alternation in BRE without -x.
    test_command_output "grep BRE backslash-pipe alternation without -x (GNU ext)" $'foo\nbar' bash -c "printf 'foo\nbar\nbaz\n' | '$binary' --color=never 'foo\|bar'"

    # -i composes with the \s GNU extension.
    test_command_output "grep -i composes with backslash-s (GNU ext)" "A B" bash -c "printf 'A B\n' | '$binary' --color=never -i 'a\sb'"

    # \| inside a bracket expression remains a literal member.
    test_command_output "grep -x bracket [a\\|] keeps backslash literal" '\' bash -c "printf '%s\n' '\' | '$binary' --color=never -x '[a\|]'"

    # Negative pin: inside brackets backslash stays literal, never [[:space:]].
    test_command_output "grep bracket [\s] stays literal (stays green everywhere)" $'s\n\\' bash -c "printf '%s\n' 's' '\' ' ' | '$binary' --color=never '[\s]'"

    # Negative pin: an escaped backslash (\\) followed by s must not be
    # re-interpreted as the GNU \s extension.
    test_command_output "grep escaped backslash a\\\\sb stays literal (stays green everywhere)" 'a\sb' bash -c "printf '%s\n' 'a\sb' 'a b' | '$binary' --color=never 'a\\\\sb'"

    # Negative pin: \| in ERE stays an escaped literal pipe, not alternation.
    test_command_output "grep -E foo\\|bar literal pipe not alternation (stays green everywhere)" 'foo|bar' bash -c "printf '%s\n' 'foo|bar' 'foo' | '$binary' --color=never -E 'foo\|bar'"

    # GNU/BSD directional word-boundary escapes. Darwin translates these to
    # [[:<:]]/[[:>:]]; Linux leaves them for glibc.
    test_command_output "grep BRE \\<foo\\> whole word" $'foo\nfoo-' bash -c "printf 'foo\nfoobar\nxfoo\nfoo_\nfoo-\n' | '$binary' --color=never '\<foo\>'"
    test_command_output "grep -E \\< start-of-word" $'foo\nfoobar' bash -c "printf 'foo\nfoobar\nxfoo\n' | '$binary' --color=never -E '\<foo'"
    test_command_output "grep -E \\> end-of-word" $'foo\nxfoo' bash -c "printf 'foo\nxfoo\nfoobar\n' | '$binary' --color=never -E 'foo\>'"
    test_command_output "grep -io directional boundaries" "FOO" bash -c "printf 'say FOO! foobar\n' | '$binary' --color=never -io '\<foo\>'"
    test_command_output "grep boundaries preserve BRE backrefs" "foo foo" bash -c "printf 'foo foo\nfoo food\n' | '$binary' --color=never '\<\(foo\) \1\>'"

    if [[ "$(uname)" == "Darwin" ]]; then
        local expected_boundary_error='grep: invalid regular expression: \b and \B word-boundary escapes are unsupported on this platform'
        run_command cmd out err exit_code "$binary" --color=never '\bfoo\b' /dev/null
        if [[ "$exit_code" == "2" && "$err" == "$expected_boundary_error" ]]; then
            print_test_result "grep Darwin rejects \\\\b clearly" "PASS"
        else
            print_test_result "grep Darwin rejects \\\\b clearly" "FAIL" "Exit: $exit_code; stderr: $err"
        fi
        run_command cmd out err exit_code "$binary" --color=never 'f\Bo' /dev/null
        if [[ "$exit_code" == "2" && "$err" == "$expected_boundary_error" ]]; then
            print_test_result "grep Darwin rejects \\\\B clearly" "PASS"
        else
            print_test_result "grep Darwin rejects \\\\B clearly" "FAIL" "Exit: $exit_code; stderr: $err"
        fi
    else
        test_command_output "grep Linux native \\\\b boundaries" "foo" bash -c "printf 'foo\nfoobar\n' | '$binary' --color=never '\bfoo\b'"
        test_command_output "grep Linux native \\\\B non-boundary" "foo" bash -c "printf 'foo\nf-o\n' | '$binary' --color=never 'f\Bo'"
    fi

    echo -e "${CYAN}Testing issue #151: -- must not consume PATTERNS...${NC}"

    # Pinned against GNU grep 3.11 (LC_ALL=C, stdin </dev/null). GNU's rule:
    # `--` is plain end-of-options, and the first *remaining* operand becomes
    # PATTERNS iff neither -e nor -f supplied a pattern source -- decided after
    # the whole argument scan, not left-to-right during it.
    local ddash_dir
    ddash_dir=$(create_temp_dir)
    printf 'a\nb\n-v\n--\nfoo\n' > "$ddash_dir/g.txt"
    printf 'a\n' > "$ddash_dir/pat.txt"
    : > "$ddash_dir/empty.txt"
    printf 'a\nzz\n' > "$ddash_dir/-dash.txt"
    local dgrep="cd '$ddash_dir' && LC_ALL=C '$binary' --color=never"

    # Core: `--` ends option parsing but leaves the pattern slot open.
    test_command_output "grep -- pattern file" "a" bash -c "$dgrep -- a g.txt </dev/null"
    test_command_output "grep -- -v file (flag-shaped pattern)" "-v" bash -c "$dgrep -- -v g.txt </dev/null"
    test_command_output "grep -- -- file (separator-shaped pattern)" "--" bash -c "$dgrep -- -- g.txt </dev/null"
    test_command_output "grep -n -- pattern file" "1:a" bash -c "$dgrep -n -- a g.txt </dev/null"
    test_command_output "grep -v -- pattern file" $'b\n-v\n--\nfoo' bash -c "$dgrep -v -- a g.txt </dev/null"
    test_command_output "grep -c -- pattern file" "1" bash -c "$dgrep -c -- a g.txt </dev/null"
    test_command_output "grep -i -- pattern file" "a" bash -c "$dgrep -i -- A g.txt </dev/null"
    test_command_exit_code "grep -- nomatch file exits 1" 1 bash -c "$dgrep -- zzzzz g.txt </dev/null"

    # `--` with no file operand at all: grep reads stdin. No `cd` here -- the
    # pipe must feed grep itself, not a leading `cd` in the pipeline.
    local sgrep="LC_ALL=C '$binary' --color=never"
    test_command_output "grep -- pattern reads stdin" "a" bash -c "printf 'a\nb\n' | $sgrep -- a"
    test_command_exit_code "grep -- pattern stdin no match exits 1" 1 bash -c "printf 'b\n' | $sgrep -- a"

    # Two file operands after `--`: filename prefixes appear.
    test_command_output "grep -- pattern two files prefixes names" $'g.txt:a\ng.txt:a' bash -c "$dgrep -- a g.txt g.txt </dev/null"

    # A genuinely dash-named file, the operand `--` exists to protect.
    test_command_output "grep -- pattern -dash.txt" "a" bash -c "$dgrep -- a -dash.txt </dev/null"

    # Bare `grep --` has no pattern source and no operand: exit 2.
    test_command_exit_code "grep -- alone exits 2" 2 bash -c "$dgrep -- </dev/null 2>/dev/null"

    # Recursive walk after `--`. Order is filesystem-dependent, so assert the
    # set of hits rather than a fixed sequence.
    local rdir="$ddash_dir/rwalk"
    mkdir -p "$rdir"
    printf 'a\n' > "$rdir/one.txt"
    printf 'a\n' > "$rdir/two.txt"
    run_command cmd out err exit_code bash -c "cd '$rdir' && LC_ALL=C '$binary' --color=never -r -- a . </dev/null"
    if [[ "$exit_code" -eq 0 && "$out" =~ "./one.txt:a" && "$out" =~ "./two.txt:a" ]]; then
        print_test_result "grep -r -- pattern dir" "PASS"
    else
        print_test_result "grep -r -- pattern dir" "FAIL" "exit=$exit_code out=$out"
    fi

    # After `--` every remaining operand is ordinary: the second -v is a file.
    # stdout and stderr must be compared separately -- GNU flushes stderr
    # eagerly while vibeutils buffers stdout to exit, so a merged 2>&1 capture
    # interleaves differently for identical content.
    run_command cmd out err exit_code bash -c "$dgrep -- -v -v g.txt </dev/null"
    if [[ "$exit_code" -eq 2 && "$out" == "g.txt:-v" && "$err" == "grep: -v: No such file or directory" ]]; then
        print_test_result "grep -- -v -v file: second -v is a file operand" "PASS"
    else
        print_test_result "grep -- -v -v file: second -v is a file operand" "FAIL" "exit=$exit_code out=$out err=$err"
    fi

    echo -e "${CYAN}Testing issue #151: the pattern slot is decided after the scan...${NC}"

    # -e/-f supply the pattern source, so a *leading* operand stays a file.
    test_command_output "grep file -e pattern (operand before -e is a file)" "a" bash -c "$dgrep g.txt -e a </dev/null"

    run_command cmd out err exit_code bash -c "$dgrep foo -e a g.txt </dev/null"
    if [[ "$exit_code" -eq 2 && "$out" == "g.txt:a" && "$err" == "grep: foo: No such file or directory" ]]; then
        print_test_result "grep missingfile -e pattern file reports the missing operand" "PASS"
    else
        print_test_result "grep missingfile -e pattern file reports the missing operand" "FAIL" "exit=$exit_code out=$out err=$err"
    fi

    # An empty -f file is a legal, empty pattern set: the operand stays a file.
    # GNU exits 1 without opening any operand unless -v or -L is in play.
    run_command cmd out err exit_code bash -c "$dgrep -f empty.txt g.txt </dev/null"
    if [[ "$exit_code" -eq 1 && -z "$out" ]]; then
        print_test_result "grep -f empty file: empty pattern set exits 1" "PASS"
    else
        print_test_result "grep -f empty file: empty pattern set exits 1" "FAIL" "exit=$exit_code out=$out"
    fi

    run_command cmd out err exit_code bash -c "$dgrep -f empty.txt -- g.txt </dev/null"
    if [[ "$exit_code" -eq 1 && -z "$out" ]]; then
        print_test_result "grep -f empty -- file: empty pattern set exits 1" "PASS"
    else
        print_test_result "grep -f empty -- file: empty pattern set exits 1" "FAIL" "exit=$exit_code out=$out"
    fi

    run_command cmd out err exit_code bash -c "$dgrep -c -f empty.txt g.txt </dev/null"
    if [[ "$exit_code" -eq 1 && -z "$out" ]]; then
        print_test_result "grep -c -f empty file prints nothing, not 0" "PASS"
    else
        print_test_result "grep -c -f empty file prints nothing, not 0" "FAIL" "exit=$exit_code out=$out"
    fi

    run_command cmd out err exit_code bash -c "$dgrep -f empty.txt nosuchfile </dev/null"
    if [[ "$exit_code" -eq 1 && -z "$out" && -z "$err" ]]; then
        print_test_result "grep -f empty nosuchfile is silent and exits 1" "PASS"
    else
        print_test_result "grep -f empty nosuchfile is silent and exits 1" "FAIL" "exit=$exit_code out=$out err=$err"
    fi

    # -v and -L take the normal path and do open the operands.
    test_command_output "grep -v -f empty file prints every line" $'a\nb\n-v\n--\nfoo' bash -c "$dgrep -v -f empty.txt g.txt </dev/null"
    test_command_output "grep -cv -f empty file counts every line" "5" bash -c "$dgrep -cv -f empty.txt g.txt </dev/null"

    run_command cmd out err exit_code bash -c "$dgrep -L -f empty.txt g.txt </dev/null"
    if [[ "$exit_code" -eq 1 && "$out" == "g.txt" ]]; then
        print_test_result "grep -L -f empty file names the file and exits 1" "PASS"
    else
        print_test_result "grep -L -f empty file names the file and exits 1" "FAIL" "exit=$exit_code out=$out"
    fi

    echo -e "${CYAN}Testing issue #151: empty operand and -- regression guards...${NC}"

    # An empty file-path operand is legal. A naive assert(path.len > 0) panics.
    run_command cmd out err exit_code bash -c "$dgrep a '' </dev/null"
    if [[ "$exit_code" -eq 2 && "$err" == "grep: : No such file or directory" ]]; then
        print_test_result "grep pattern '' reports ENOENT on the empty path" "PASS"
    else
        print_test_result "grep pattern '' reports ENOENT on the empty path" "FAIL" "exit=$exit_code err=$err"
    fi

    run_command cmd out err exit_code bash -c "$dgrep -- a '' </dev/null"
    if [[ "$exit_code" -eq 2 && "$err" == "grep: : No such file or directory" ]]; then
        print_test_result "grep -- pattern '' reports ENOENT on the empty path" "PASS"
    else
        print_test_result "grep -- pattern '' reports ENOENT on the empty path" "FAIL" "exit=$exit_code err=$err"
    fi

    # Guards: shapes that already work must keep working after the fix.
    test_command_output "grep guard -e pattern -- file" "a" bash -c "$dgrep -e a -- g.txt </dev/null"
    test_command_output "grep guard -f patfile -- file" "a" bash -c "$dgrep -f pat.txt -- g.txt </dev/null"
    test_command_output "grep guard pattern -- file" "a" bash -c "$dgrep a -- g.txt </dev/null"
    test_command_output "grep guard pattern file --" "a" bash -c "$dgrep a g.txt -- </dev/null"
    test_command_output "grep guard pattern file" "a" bash -c "$dgrep a g.txt </dev/null"
    test_command_output "grep guard -e pattern file" "a" bash -c "$dgrep -e a g.txt </dev/null"

    run_command cmd out err exit_code bash -c "$dgrep a -- g.txt -n </dev/null"
    if [[ "$exit_code" -eq 2 && "$out" == "g.txt:a" && "$err" == "grep: -n: No such file or directory" ]]; then
        print_test_result "grep guard pattern -- file -n treats -n as a file" "PASS"
    else
        print_test_result "grep guard pattern -- file -n treats -n as a file" "FAIL" "exit=$exit_code out=$out err=$err"
    fi

    rm -rf "$ddash_dir"

    echo -e "${CYAN}Testing an unopenable -f argument is fatal (exit 2)...${NC}"

    # Pinned against GNU grep 3.11 (LC_ALL=C, stdin </dev/null, pristine fixture
    # dir). GNU's rule is uniform: if a -f/--file argument cannot be read, grep
    # dies with exit 2 and never opens a single operand. It must never
    # "fail open" -- an unreadable blocklist under -v previously printed nothing
    # and must not start printing the whole input instead.
    #
    # Note: the exact stderr text for a directory argument is deliberately not
    # pinned here (GNU says "Is a directory", we say "No such file or
    # directory"); that message divergence is pre-existing and out of scope.
    # Only "exit 2, empty stdout, one error line naming the operand" is pinned.
    #
    # Note: an existing-but-unreadable regular file cannot be exercised in this
    # suite -- integration tests may run as root, where mode 000 is still
    # readable and GNU itself succeeds. A missing path and a directory cover the
    # same code path portably.
    local fdir
    fdir=$(create_temp_dir)
    printf 'a\nb\n-v\n--\nfoo\n' > "$fdir/g.txt"
    printf 'a\n' > "$fdir/pat.txt"
    : > "$fdir/empty.txt"
    mkdir -p "$fdir/sub"
    local fgrep_cmd="cd '$fdir' && LC_ALL=C '$binary' --color=never"

    # Assert exit code, stdout and stderr separately: the regression produced
    # output with a *zero* exit, so an exit-code-only check would miss it.
    check_f_fatal() {
        local name="$1" expected_err="$2"
        shift 2
        local cmd out err exit_code
        run_command cmd out err exit_code bash -c "$fgrep_cmd $* </dev/null"
        if [[ "$exit_code" -eq 2 && -z "$out" && "$err" == "$expected_err" ]]; then
            print_test_result "$name" "PASS"
        else
            print_test_result "$name" "FAIL" "exit=$exit_code out=$out err=$err"
        fi
    }

    local enoent="grep: nosuch.txt: No such file or directory"

    # The table of shapes the review pinned, GNU-first.
    check_f_fatal "grep -f missing file exits 2" "$enoent" -f nosuch.txt g.txt
    check_f_fatal "grep -v -f missing file exits 2 with no stdout" "$enoent" \
        -v -f nosuch.txt g.txt
    check_f_fatal "grep -L -f missing file exits 2 with no stdout" "$enoent" \
        -L -f nosuch.txt g.txt
    check_f_fatal "grep -f -- consumes -- as the pattern file and exits 2" \
        "grep: --: No such file or directory" -f -- nosuch.txt -v g.txt
    check_f_fatal "grep -L -f -- empty.txt a exits 2 with no stdout" \
        "grep: --: No such file or directory" -L -f -- empty.txt a

    # A directory as the -f argument is unopenable too. Message text is not
    # pinned (see note above), only the fatal shape.
    local cmd out err exit_code
    run_command cmd out err exit_code bash -c "$fgrep_cmd -f sub g.txt </dev/null"
    if [[ "$exit_code" -eq 2 && -z "$out" && "$err" == "grep: sub: "* ]]; then
        print_test_result "grep -f directory exits 2" "PASS"
    else
        print_test_result "grep -f directory exits 2" "FAIL" "exit=$exit_code out=$out err=$err"
    fi

    run_command cmd out err exit_code bash -c "$fgrep_cmd -v -f sub g.txt </dev/null"
    if [[ "$exit_code" -eq 2 && -z "$out" && "$err" == "grep: sub: "* ]]; then
        print_test_result "grep -v -f directory exits 2 with no stdout" "PASS"
    else
        print_test_result "grep -v -f directory exits 2 with no stdout" "FAIL" \
            "exit=$exit_code out=$out err=$err"
    fi

    # One bad -f poisons the whole run: neither a second valid -f nor an -e
    # rescues it. Verified against GNU grep 3.11 in both orders.
    check_f_fatal "grep -f missing -f valid still exits 2" "$enoent" \
        -f nosuch.txt -f pat.txt g.txt
    check_f_fatal "grep -f valid -f missing still exits 2" "$enoent" \
        -f pat.txt -f nosuch.txt g.txt
    check_f_fatal "grep -f missing -e valid is not rescued by -e" "$enoent" \
        -f nosuch.txt -e a g.txt
    check_f_fatal "grep -e valid -f missing is not rescued by -e" "$enoent" \
        -e a -f nosuch.txt g.txt

    # No operands at all: grep must die before it ever reads stdin.
    check_f_fatal "grep -f missing with no operands exits 2" "$enoent" -f nosuch.txt
    check_f_fatal "grep -v -f missing with no operands exits 2" "$enoent" -v -f nosuch.txt

    # Output-suppressing modes must not launder the failure into a 0 or 1.
    check_f_fatal "grep -c -f missing exits 2" "$enoent" -c -f nosuch.txt g.txt
    check_f_fatal "grep -q -f missing exits 2" "$enoent" -q -f nosuch.txt g.txt
    check_f_fatal "grep -l -f missing exits 2" "$enoent" -l -f nosuch.txt g.txt

    # The long spelling shares the same loader and the same regression.
    check_f_fatal "grep --file=missing exits 2" "$enoent" --file=nosuch.txt g.txt
    check_f_fatal "grep -v --file=missing exits 2 with no stdout" "$enoent" \
        -v --file=nosuch.txt g.txt

    # Guards: a *readable* but empty -f file is still a legal empty pattern set
    # and must keep its pre-regression behavior, so the fix cannot simply make
    # every zero-pattern run fatal.
    run_command cmd out err exit_code bash -c "$fgrep_cmd -f empty.txt g.txt </dev/null"
    if [[ "$exit_code" -eq 1 && -z "$out" && -z "$err" ]]; then
        print_test_result "grep guard -f empty file exits 1 silently" "PASS"
    else
        print_test_result "grep guard -f empty file exits 1 silently" "FAIL" \
            "exit=$exit_code out=$out err=$err"
    fi

    test_command_output "grep guard -v -f empty file prints every line" \
        $'a\nb\n-v\n--\nfoo' bash -c "$fgrep_cmd -v -f empty.txt g.txt </dev/null"

    rm -rf "$fdir"

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}grep tests completed${NC}"
}

# Export the test function
export -f test_grep
