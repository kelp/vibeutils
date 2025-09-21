#!/usr/bin/env bash
# Comprehensive tests for basename utility
# Tests all flags, POSIX compliance, GNU extensions, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_basename() {
    local util="basename"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Basic functionality tests - core POSIX behavior
    test_command_output "basename basic path stripping" "sort" "$binary" "/usr/bin/sort"
    test_command_output "basename no directory" "filename" "$binary" "filename"
    test_command_output "basename with suffix" "file" "$binary" "file.txt" ".txt"
    test_command_output "basename relative path" "document.pdf" "$binary" "dir/document.pdf"

    echo -e "${CYAN}Testing POSIX core functionality...${NC}"

    # POSIX standard behavior tests
    test_command_output "POSIX: simple filename" "test" "$binary" "test"
    test_command_output "POSIX: absolute path" "file" "$binary" "/path/to/file"
    test_command_output "POSIX: suffix removal" "document" "$binary" "document.txt" ".txt"
    test_command_output "POSIX: complex path" "final.ext" "$binary" "/very/long/path/to/final.ext"

    # Special root directory cases
    test_command_output "POSIX: root directory" "/" "$binary" "/"
    test_command_output "POSIX: double slash" "/" "$binary" "//"
    test_command_output "POSIX: trailing slashes" "bin" "$binary" "/usr/bin/"
    test_command_output "POSIX: multiple trailing slashes" "usr" "$binary" "/usr///"

    # Empty and edge cases
    test_command_output "POSIX: empty string becomes dot" "." "$binary" ""
    test_command_output "POSIX: single dot" "." "$binary" "."
    test_command_output "POSIX: double dot" ".." "$binary" ".."
    test_command_output "POSIX: relative with dots" ".." "$binary" "path/../.."

    echo -e "${CYAN}Testing suffix handling...${NC}"

    # Suffix removal edge cases
    test_command_output "suffix: normal removal" "hello" "$binary" "hello.txt" ".txt"
    test_command_output "suffix: no match" "hello.pdf" "$binary" "hello.pdf" ".txt"
    test_command_output "suffix: empty suffix" "hello.txt" "$binary" "hello.txt" ""
    test_command_output "suffix: suffix equals basename" ".txt" "$binary" ".txt" ".txt"
    test_command_output "suffix: partial match not removed" "hello.txtx" "$binary" "hello.txtx" ".txt"
    test_command_output "suffix: multi-dot file" "file.name" "$binary" "file.name.ext" ".ext"
    test_command_output "suffix: path with suffix" "document" "$binary" "/path/to/document.pdf" ".pdf"

    echo -e "${CYAN}Testing GNU extensions (-a flag)...${NC}"

    # Multiple files processing with -a flag
    test_command_output "GNU: -a with two files" $'file1.txt\nfile2.txt' "$binary" -a "path/file1.txt" "dir/file2.txt"
    test_command_output "GNU: -a with three files" $'sort\ngrep\nawk' "$binary" -a "/usr/bin/sort" "/bin/grep" "awk"
    test_command_output "GNU: -a with mixed paths" $'file\nscript\ntest' "$binary" -a "file" "/path/script" "./test"
    test_command_output "GNU: --multiple long form" $'one\ntwo' "$binary" --multiple "one" "two"

    # Single file with -a (should work same as without)
    test_command_output "GNU: -a with single file" "single" "$binary" -a "path/single"

    echo -e "${CYAN}Testing GNU extensions (-s flag)...${NC}"

    # Suffix flag (implies -a according to GNU behavior)
    test_command_output "GNU: -s removes suffix from multiple files" $'hello\nworld\ntest.h' "$binary" -s ".c" "hello.c" "world.c" "test.h"
    test_command_output "GNU: --suffix long form" $'file1\nfile2' "$binary" --suffix=".txt" "file1.txt" "file2.txt"
    test_command_output "GNU: -s with single file" "document" "$binary" -s ".pdf" "path/document.pdf"
    test_command_output "GNU: -s with no matching suffix" $'file.h\ntest.c' "$binary" -s ".txt" "file.h" "test.c"

    echo -e "${CYAN}Testing GNU extensions (-z flag)...${NC}"

    # Zero delimiter tests - use temporary files to avoid bash null byte issues
    local temp_out1="$TEMP_DIR/zero_test1"
    local temp_out2="$TEMP_DIR/zero_test2"
    local temp_out3="$TEMP_DIR/zero_test3"

    # Single file with zero delimiter
    "$binary" -z "test/file" > "$temp_out1"
    if printf "file\0" | cmp -s - "$temp_out1"; then
        print_test_result "GNU: -z single file with null terminator" "PASS"
    else
        print_test_result "GNU: -z single file with null terminator" "FAIL" "Output doesn't match expected 'file\\0'"
    fi

    # Multiple files with zero delimiter
    "$binary" -az "file1" "file2" > "$temp_out2"
    if printf "file1\0file2\0" | cmp -s - "$temp_out2"; then
        print_test_result "GNU: -az multiple files with null terminators" "PASS"
    else
        print_test_result "GNU: -az multiple files with null terminators" "FAIL" "Output doesn't match expected 'file1\\0file2\\0'"
    fi

    # Long form
    test_command_exit_code "GNU: --zero flag exists" 0 "$binary" --zero "test"

    # Clean up temp files
    rm -f "$temp_out1" "$temp_out2" "$temp_out3"

    echo -e "${CYAN}Testing flag combinations...${NC}"

    # Combining flags
    test_command_output "flags: -a -s combination" $'hello\nworld' "$binary" -a -s ".txt" "hello.txt" "world.txt"
    test_command_output "flags: -s -a combination" $'doc1\ndoc2' "$binary" -s ".pdf" -a "doc1.pdf" "doc2.pdf"

    # Test that -s implies -a
    test_command_output "flags: -s implies -a" $'file1\nfile2' "$binary" -s ".c" "file1.c" "file2.c"

    # Zero with multiple and suffix (separate flags - combined short flags not supported yet)
    local temp_out_sz="$TEMP_DIR/sz_test"
    "$binary" -s ".txt" -z "hello.txt" "world.txt" > "$temp_out_sz"
    if printf "hello\0world\0" | cmp -s - "$temp_out_sz"; then
        print_test_result "flags: -s -z combination" "PASS"
    else
        print_test_result "flags: -s -z combination" "FAIL" "Output doesn't match expected 'hello\\0world\\0'"
    fi
    rm -f "$temp_out_sz"

    # Note: Combined short flags like -sz are not currently supported by argparse
    # Test that combined flags produce an error (expected behavior for now)
    test_command_fails "flags: -sz combined not supported" "$binary" -sz ".txt" "hello.txt"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments provided
    test_command_fails "error: no arguments" "$binary"

    # Too many arguments in POSIX mode (no -a flag)
    test_command_fails "error: too many args in POSIX mode" "$binary" "file1" "suffix" "extra"

    # Invalid flags
    test_command_fails "error: invalid flag" "$binary" --invalid-flag
    test_command_fails "error: invalid short flag" "$binary" -x

    # Invalid long flag values
    test_command_fails "error: invalid suffix syntax" "$binary" --suffix

    echo -e "${CYAN}Testing POSIX compliance verification...${NC}"

    # POSIX required behaviors
    test_command_output "POSIX: basename with leading dirs" "file" "$binary" "/usr/local/bin/file"
    test_command_output "POSIX: basename no dirs" "file" "$binary" "file"
    test_command_output "POSIX: suffix removal standard" "file" "$binary" "file.txt" ".txt"

    # POSIX exit codes
    test_command_exit_code "POSIX: success exit code" 0 "$binary" "testfile"
    test_command_exit_code "POSIX: error exit code" 1 "$binary" 2>/dev/null || true

    # POSIX specified edge cases
    test_command_output "POSIX: slash only" "/" "$binary" "/"
    test_command_output "POSIX: double slash" "/" "$binary" "//"
    test_command_output "POSIX: slash-slash-slash" "/" "$binary" "///"

    echo -e "${CYAN}Testing complex path cases...${NC}"

    # Complex directory structures
    test_command_output "complex: deep nesting" "final" "$binary" "/very/deep/nested/directory/structure/final"
    test_command_output "complex: with dots in path" "file.final" "$binary" "/path/with.dots/in.dirs/file.final"
    test_command_output "complex: multiple extensions" "file.tar" "$binary" "dir/file.tar.gz" ".gz"
    test_command_output "complex: hidden files" ".hidden" "$binary" "/path/.hidden"
    test_command_output "complex: hidden with extension" ".config" "$binary" ".config.bak" ".bak"

    # Special characters in filenames (safe ones)
    test_command_output "complex: underscores" "my_file" "$binary" "/path/my_file"
    test_command_output "complex: hyphens" "my-file" "$binary" "dir/my-file"
    test_command_output "complex: numbers" "file123" "$binary" "path/file123"

    echo -e "${CYAN}Testing edge cases and boundaries...${NC}"

    # Boundary conditions
    test_command_output "edge: single character name" "a" "$binary" "/path/a"
    test_command_output "edge: single character with suffix" "a" "$binary" "a.x" ".x"
    test_command_output "edge: very long path component" "verylongfilenamethatexceedsusualsizelimits" "$binary" "/short/verylongfilenamethatexceedsusualsizelimits"

    # Multiple consecutive slashes in middle of path
    test_command_output "edge: multiple slashes in path" "file" "$binary" "/path//to///file"

    # Suffix edge cases
    test_command_output "edge: longer suffix than name" "ab" "$binary" "ab" ".toolong"
    test_command_output "edge: suffix at start" "file.txt" "$binary" "file.txt" "file"

    # Mixed path separators and edge cases
    test_command_output "edge: path ending with multiple slashes" "dir" "$binary" "/path/to/dir////"

    echo -e "${CYAN}Testing platform compatibility...${NC}"

    # These should work consistently across platforms
    test_command_output "platform: standard unix path" "file" "$binary" "/usr/bin/file"
    test_command_output "platform: relative path" "file" "$binary" "subdir/file"
    test_command_output "platform: current dir file" "file" "$binary" "./file"

    echo -e "${CYAN}Testing performance with edge cases...${NC}"

    # Test with realistic but complex scenarios
    test_command_output "performance: many path components" "file.txt" "$binary" "/usr/local/share/doc/package/examples/demo/file.txt"
    test_command_output "performance: with multiple args" $'file1\nfile2\nfile3' "$binary" -a "/long/path/file1" "/another/long/path/file2" "/third/path/file3"

    # Large suffix removal scenario
    test_command_output "performance: many files with suffix" $'a\nb\nc\nd\ne' "$binary" -s ".txt" "a.txt" "b.txt" "c.txt" "d.txt" "e.txt"

    echo -e "${CYAN}Testing help and version output content...${NC}"

    # Test that help contains expected information
    local help_output
    help_output=$("$binary" --help)
    if [[ "$help_output" =~ "Usage:" && "$help_output" =~ "--multiple" && "$help_output" =~ "--suffix" ]]; then
        print_test_result "help output contains expected content" "PASS"
    else
        print_test_result "help output contains expected content" "FAIL" "Missing expected help content"
    fi

    # Test version output
    local version_output
    version_output=$("$binary" --version)
    if [[ "$version_output" =~ "basename" ]]; then
        print_test_result "version output contains utility name" "PASS"
    else
        print_test_result "version output contains utility name" "FAIL" "Version output: '$version_output'"
    fi
}