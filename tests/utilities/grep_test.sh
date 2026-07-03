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

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}grep tests completed${NC}"
}

# Export the test function
export -f test_grep
