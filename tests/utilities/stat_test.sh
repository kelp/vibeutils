#!/usr/bin/env bash
# Integration tests for stat utility
# Tests output correctness, flags, and error conditions
#
# stat implements the BSD interface, on every platform:
#
#   stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]
#
# The authoritative spec is docs/specs/stat-macos.txt (the vendored
# NetBSD/macOS man page, including the full FORMATS grammar);
# docs/specs/stat-openbsd.txt confirms OpenBSD matches.
#
# The GNU long options --format=FMT, --printf=FMT, --file-system, --terse and
# --dereference survive, along with the GNU -c FORMAT, because none of them
# collide with a BSD short flag. In particular -f is NOT an alias for
# --file-system and -t is NOT an alias for --terse: both now take an argument.

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_stat() {
    local util="stat"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    # Create a temp file for testing. mktemp creates mode 0600, so the mode is
    # forced to 0644 to make the %Sp expectations deterministic.
    local tmpfile
    tmpfile=$(mktemp)
    echo "hello" > "$tmpfile"
    chmod 644 "$tmpfile"

    local cmd="" out="" err="" code=""

    echo -e "${CYAN}Testing default output (BSD single line)...${NC}"

    # The default format is documented at stat-macos.txt:218-222 as
    #   %d %i %Sp %l %Su %Sg %r %z "%Sa" "%Sm" "%Sc" "%SB" %k %b %#Xf %N
    # Only its shape is asserted here; the values are volatile.
    run_command cmd out err code "$binary" "$tmpfile"

    local default_lines=""
    default_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    if [[ "$code" -eq 0 && "$default_lines" -eq 1 ]]; then
        print_test_result "stat default output is a single line" "PASS"
    else
        print_test_result "stat default output is a single line" "FAIL" \
            "Exit code: $code, lines: $default_lines"
    fi

    if [[ "$out" == *"-rw-r--r--"* ]]; then
        print_test_result "stat default output contains the %Sp mode string" "PASS"
    else
        print_test_result "stat default output contains the %Sp mode string" "FAIL" \
            "Got: '$out'"
    fi

    if [[ "$out" == *"$tmpfile" ]]; then
        print_test_result "stat default output ends with %N (the file name)" "PASS"
    else
        print_test_result "stat default output ends with %N (the file name)" "FAIL" \
            "Got: '$out'"
    fi

    # %Sa, %Sm, %Sc and %SB are each wrapped in literal double quotes.
    local quote_count=""
    quote_count=$(printf '%s' "$out" | tr -cd '"' | wc -c | tr -d ' ')
    if [[ "$quote_count" -eq 8 ]]; then
        print_test_result "stat default output has four quoted time fields" "PASS"
    else
        print_test_result "stat default output has four quoted time fields" "FAIL" \
            "Expected 8 quote characters, got $quote_count: '$out'"
    fi

    # Regression guard carried over from F15: no signed-format '+' leaks.
    if [[ "$out" != *"+"* ]]; then
        print_test_result "stat default output has no spurious '+'" "PASS"
    else
        print_test_result "stat default output has no spurious '+'" "FAIL" \
            "Found '+' in: '$out'"
    fi

    echo -e "${CYAN}Testing BSD -f format strings...${NC}"

    # %z is st_size (stat-macos.txt:182).
    run_command cmd out err code "$binary" -f '%z' "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == "6" ]]; then
        print_test_result "stat -f '%z' shows file size" "PASS"
    else
        print_test_result "stat -f '%z' shows file size" "FAIL" \
            "Expected '6', got '$out' (exit $code)"
    fi

    # BSD %N is the bare file name, unlike the GNU %N which quotes it.
    run_command cmd out err code "$binary" -f '%N' "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == "$tmpfile" ]]; then
        print_test_result "stat -f '%N' shows the unquoted file name" "PASS"
    else
        print_test_result "stat -f '%N' shows the unquoted file name" "FAIL" \
            "Expected '$tmpfile', got '$out'"
    fi

    # %Sp is "the mode of file as in ls -lTd" (stat-macos.txt:132).
    run_command cmd out err code "$binary" -f '%Sp' "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == "-rw-r--r--" ]]; then
        print_test_result "stat -f '%Sp' shows an ls-style mode string" "PASS"
    else
        print_test_result "stat -f '%Sp' shows an ls-style mode string" "FAIL" \
            "Expected '-rw-r--r--', got '$out'"
    fi

    # Sub-field specifiers, shape taken from stat-macos.txt:273-274.
    run_command cmd out err code "$binary" \
        -f '%Sp -> owner=%SHp group=%SMp other=%SLp' "$tmpfile"
    if [[ "$out" == "-rw-r--r-- -> owner=rw- group=r-- other=r--" ]]; then
        print_test_result "stat -f sub-fields %SHp/%SMp/%SLp split the mode" "PASS"
    else
        print_test_result "stat -f sub-fields %SHp/%SMp/%SLp split the mode" "FAIL" \
            "Got: '$out'"
    fi

    # %t, %n and %% are immediate specials (stat-macos.txt:78-80).
    run_command cmd out err code "$binary" -f 'a%tb%nc' "$tmpfile"
    if [[ "$out" == $'a\tb\nc' ]]; then
        print_test_result "stat -f '%t' and '%n' emit a tab and a newline" "PASS"
    else
        print_test_result "stat -f '%t' and '%n' emit a tab and a newline" "FAIL" \
            "Got: '$out'"
    fi

    run_command cmd out err code "$binary" -f 'x%%y' "$tmpfile"
    if [[ "$out" == "x%y" ]]; then
        print_test_result "stat -f '%%' emits a literal percent" "PASS"
    else
        print_test_result "stat -f '%%' emits a literal percent" "FAIL" "Got: '$out'"
    fi

    # Flags and field widths (stat-macos.txt:83-105).
    run_command cmd out err code "$binary" -f '%-10z|' "$tmpfile"
    if [[ "$out" == "6         |" ]]; then
        print_test_result "stat -f '%-10z|' left-aligns in the field" "PASS"
    else
        print_test_result "stat -f '%-10z|' left-aligns in the field" "FAIL" \
            "Got: '$out'"
    fi

    run_command cmd out err code "$binary" -f '%08z' "$tmpfile"
    if [[ "$out" == "00000006" ]]; then
        print_test_result "stat -f '%08z' zero-pads to the field width" "PASS"
    else
        print_test_result "stat -f '%08z' zero-pads to the field width" "FAIL" \
            "Got: '$out'"
    fi

    # "#" selects the alternate form: non-zero octal gains a leading zero
    # (stat-macos.txt:85-87). st_mode of a 0644 regular file is 0100644.
    run_command cmd out err code "$binary" -f '%#Op' "$tmpfile"
    if [[ "$out" == "0100644" ]]; then
        print_test_result "stat -f '%#Op' uses the alternate octal form" "PASS"
    else
        print_test_result "stat -f '%#Op' uses the alternate octal form" "FAIL" \
            "Expected '0100644', got '$out'"
    fi

    # Default output forms: p defaults to O, everything numeric else to U
    # (stat-macos.txt:209-211). 0100644 octal == 33188 decimal.
    run_command cmd out err code "$binary" -f '%p' "$tmpfile"
    if [[ "$out" == "100644" ]]; then
        print_test_result "stat -f '%p' defaults to octal" "PASS"
    else
        print_test_result "stat -f '%p' defaults to octal" "FAIL" \
            "Expected '100644', got '$out'"
    fi

    run_command cmd out err code "$binary" -f '%Dp' "$tmpfile"
    if [[ "$out" == "33188" ]]; then
        print_test_result "stat -f '%Dp' forces decimal" "PASS"
    else
        print_test_result "stat -f '%Dp' forces decimal" "FAIL" \
            "Expected '33188', got '$out'"
    fi

    # %m is a raw epoch count; %Sm is a strftime rendering
    # (stat-macos.txt:284-292).
    run_command cmd out err code "$binary" -f '%m' "$tmpfile"
    if [[ "$out" =~ ^[0-9]+$ ]]; then
        print_test_result "stat -f '%m' is a raw epoch number" "PASS"
    else
        print_test_result "stat -f '%m' is a raw epoch number" "FAIL" "Got: '$out'"
    fi

    run_command cmd out err code "$binary" -f '%Sm' "$tmpfile"
    if [[ ! "$out" =~ ^[0-9]+$ && "$out" == *":"* ]]; then
        print_test_result "stat -f '%Sm' is a formatted date" "PASS"
    else
        print_test_result "stat -f '%Sm' is a formatted date" "FAIL" "Got: '$out'"
    fi

    # -t sets the strftime format (stat-macos.txt:294-297).
    run_command cmd out err code "$binary" -f '%Sm' -t '%Y%m%d%H%M%S' "$tmpfile"
    if [[ "$out" =~ ^[0-9]{14}$ ]]; then
        print_test_result "stat -f '%Sm' -t '%Y%m%d%H%M%S' yields 14 digits" "PASS"
    else
        print_test_result "stat -f '%Sm' -t '%Y%m%d%H%M%S' yields 14 digits" "FAIL" \
            "Got: '$out'"
    fi

    echo -e "${CYAN}Testing -F, -l, -n, -q, -r, -s and -x...${NC}"

    # -l is "ls -lT format"; -F appends the ls(1) type suffix and implies -l
    # (stat-macos.txt:34-39, :51, example at :227-231).
    local statdir
    statdir=$(create_temp_dir)
    chmod 755 "$statdir"

    run_command cmd out err code "$binary" -l "$statdir"
    if [[ "$code" -eq 0 && "$out" == "drwxr-xr-x "* && "$out" == *"$statdir" ]]; then
        print_test_result "stat -l prints an ls -lT style line" "PASS"
    else
        print_test_result "stat -l prints an ls -lT style line" "FAIL" \
            "Got: '$out' (exit $code)"
    fi

    run_command cmd out err code "$binary" -F "$statdir"
    if [[ "$code" -eq 0 && "$out" == "drwxr-xr-x "* && "$out" == *"$statdir/" ]]; then
        print_test_result "stat -F implies -l and appends the '/' suffix" "PASS"
    else
        print_test_result "stat -F implies -l and appends the '/' suffix" "FAIL" \
            "Got: '$out' (exit $code)"
    fi

    # -n does not force a trailing newline (stat-macos.txt:53-54). run_command
    # strips trailing newlines, so the byte counts are measured directly.
    local with_nl_bytes="" no_nl_bytes=""
    with_nl_bytes=$("$binary" -f '%z' "$tmpfile" 2>/dev/null | wc -c | tr -d ' ') || true
    no_nl_bytes=$("$binary" -n -f '%z' "$tmpfile" 2>/dev/null | wc -c | tr -d ' ') || true
    if [[ "$with_nl_bytes" == "2" && "$no_nl_bytes" == "1" ]]; then
        print_test_result "stat -n suppresses the trailing newline" "PASS"
    else
        print_test_result "stat -n suppresses the trailing newline" "FAIL" \
            "Expected 2 bytes without -n and 1 with, got $with_nl_bytes and $no_nl_bytes"
    fi

    # -q suppresses the stat(2) failure message but not the exit status
    # (stat-macos.txt:56-58, :213-215).
    run_command cmd out err code "$binary" -q /nonexistent/path/file
    if [[ "$code" -ne 0 && -z "$err" ]]; then
        print_test_result "stat -q suppresses the failure message" "PASS"
    else
        print_test_result "stat -q suppresses the failure message" "FAIL" \
            "Exit $code, stderr: '$err'"
    fi

    # -r displays raw numerical values (stat-macos.txt:60-62): a single line
    # ending in the name, with no quoted, formatted times.
    run_command cmd out err code "$binary" -r "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == *"$tmpfile" && "$out" != *'"'* ]]; then
        print_test_result "stat -r prints raw numeric fields" "PASS"
    else
        print_test_result "stat -r prints raw numeric fields" "FAIL" \
            "Got: '$out' (exit $code)"
    fi

    # -s is "shell output" format (stat-macos.txt:64-65, example at :233-243).
    run_command cmd out err code "$binary" -s "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == *"st_size=6"* ]]; then
        print_test_result "stat -s emits shell variable assignments" "PASS"
    else
        print_test_result "stat -s emits shell variable assignments" "FAIL" \
            "Expected 'st_size=6' in output, got '$out'"
    fi

    # The -s line must actually be usable as shell input.
    local st_line="" st_size_probe=""
    st_line=$("$binary" -s "$tmpfile" 2>/dev/null) || true
    if [[ -n "$st_line" ]]; then
        st_size_probe=$(eval "$st_line"'; printf "%s" "${st_size:-}"') || true
    fi
    if [[ "$st_size_probe" == "6" ]]; then
        print_test_result "stat -s output is evaluable by the shell" "PASS"
    else
        print_test_result "stat -s output is evaluable by the shell" "FAIL" \
            "\$st_size was '$st_size_probe'"
    fi

    # -x is the verbose multi-line block (stat-macos.txt:71-72).
    run_command cmd out err code "$binary" -x "$tmpfile"
    local verbose_lines=""
    verbose_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    if [[ "$code" -eq 0 && "$verbose_lines" -ge 5 && "$out" == *"File:"* ]]; then
        print_test_result "stat -x prints a multi-line verbose block" "PASS"
    else
        print_test_result "stat -x prints a multi-line verbose block" "FAIL" \
            "Exit $code, lines $verbose_lines: '$out'"
    fi

    echo -e "${CYAN}Testing symlink handling...${NC}"

    # Create a symlink
    local tmplink="${tmpfile}.link"
    ln -s "$tmpfile" "$tmplink"

    # Without -L: should show symbolic link
    run_command cmd out err code "$binary" -c '%F' "$tmplink"
    if [[ "$out" == "symbolic link" ]]; then
        print_test_result "stat shows symbolic link type" "PASS"
    else
        print_test_result "stat shows symbolic link type" "FAIL" \
            "Expected 'symbolic link', got '$out'"
    fi

    # With -L: should show regular file
    run_command cmd out err code "$binary" -L -c '%F' "$tmplink"
    if [[ "$out" == "regular file" ]]; then
        print_test_result "stat -L follows symlinks" "PASS"
    else
        print_test_result "stat -L follows symlinks" "FAIL" \
            "Expected 'regular file', got '$out'"
    fi

    # -L on a broken link falls back to lstat(2) and reports the link itself
    # (stat-macos.txt:41-45).
    local brokenlink="${tmpfile}.broken"
    ln -s "${tmpfile}.does-not-exist" "$brokenlink"
    run_command cmd out err code "$binary" -L -f '%Sp' "$brokenlink"
    if [[ "$code" -eq 0 && "$out" == l* ]]; then
        print_test_result "stat -L falls back to lstat on a broken link" "PASS"
    else
        print_test_result "stat -L falls back to lstat on a broken link" "FAIL" \
            "Expected a mode string starting with 'l', got '$out' (exit $code)"
    fi
    rm -f "$brokenlink"

    echo -e "${CYAN}Testing surviving GNU long options...${NC}"

    # -c keeps GNU directive semantics.
    run_command cmd out err code "$binary" -c '%s' "$tmpfile"
    if [[ "$out" == "6" ]]; then
        print_test_result "stat -c '%s' shows file size" "PASS"
    else
        print_test_result "stat -c '%s' shows file size" "FAIL" \
            "Expected '6', got '$out'"
    fi

    run_command cmd out err code "$binary" -c '%F' "$tmpfile"
    if [[ "$out" == "regular file" ]]; then
        print_test_result "stat -c '%F' shows file type" "PASS"
    else
        print_test_result "stat -c '%F' shows file type" "FAIL" \
            "Expected 'regular file', got '$out'"
    fi

    run_command cmd out err code "$binary" -c '%n' "$tmpfile"
    if [[ "$out" == "$tmpfile" ]]; then
        print_test_result "stat -c '%n' shows file name" "PASS"
    else
        print_test_result "stat -c '%n' shows file name" "FAIL" \
            "Expected '$tmpfile', got '$out'"
    fi

    run_command cmd out err code "$binary" --format='%s' "$tmpfile"
    if [[ "$out" == "6" ]]; then
        print_test_result "stat --format='%s' syntax works" "PASS"
    else
        print_test_result "stat --format='%s' syntax works" "FAIL" \
            "Expected '6', got '$out'"
    fi

    # --printf keeps GNU escape handling and no mandatory trailing newline.
    local printf_bytes=""
    printf_bytes=$("$binary" --printf='%s' "$tmpfile" 2>/dev/null | wc -c | tr -d ' ') || true
    if [[ "$printf_bytes" == "1" ]]; then
        print_test_result "stat --printf='%s' has no trailing newline" "PASS"
    else
        print_test_result "stat --printf='%s' has no trailing newline" "FAIL" \
            "Expected 1 byte, got $printf_bytes"
    fi

    # --terse still produces GNU's 16-field terse line (ported F18).
    run_command cmd out err code "$binary" --terse "$tmpfile"
    local terse_field_count="" terse_lines=""
    terse_field_count=$(printf '%s' "$out" | wc -w | tr -d ' ')
    terse_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    if [[ "$code" -eq 0 && "$terse_lines" -eq 1 && "$out" == *"$tmpfile"* ]]; then
        print_test_result "stat --terse produces terse output" "PASS"
    else
        print_test_result "stat --terse produces terse output" "FAIL" \
            "Exit $code, lines $terse_lines: '$out'"
    fi
    if [[ "$terse_field_count" -eq 16 ]]; then
        print_test_result "stat --terse has 16 fields like GNU" "PASS"
    else
        print_test_result "stat --terse has 16 fields like GNU" "FAIL" \
            "Expected 16 fields, got $terse_field_count: '$out'"
    fi

    # --file-system still produces filesystem status.
    run_command cmd out err code "$binary" --file-system "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == *"Block"* ]]; then
        print_test_result "stat --file-system shows file system info" "PASS"
    else
        print_test_result "stat --file-system shows file system info" "FAIL" \
            "Exit code: $code, output: '$out'"
    fi

    # Ported F16: the statfs struct must match the platform, so the reported
    # block size stays sane instead of being garbage from wrong field offsets.
    local block_size_val=""
    block_size_val=$(printf '%s\n' "$out" | grep "Block size:" |
        sed 's/.*Block size: *\([0-9]*\).*/\1/') || true
    if [[ -n "$block_size_val" && "$block_size_val" -ge 512 &&
        "$block_size_val" -le 1048576 ]]; then
        print_test_result "stat --file-system block size is sane ($block_size_val)" "PASS"
    else
        print_test_result "stat --file-system block size is sane" "FAIL" \
            "Block size '$block_size_val' is outside the 512-1048576 range"
    fi

    # Ported F17: --file-system with a GNU -c FORMAT honors the format string.
    run_command cmd out err code "$binary" --file-system -c '%n' "$tmpfile"
    if [[ "$out" == "$tmpfile" ]]; then
        print_test_result "stat --file-system -c '%n' outputs the file name" "PASS"
    else
        print_test_result "stat --file-system -c '%n' outputs the file name" "FAIL" \
            "Expected '$tmpfile', got '$out'"
    fi

    echo -e "${CYAN}Testing that -f and -t are not GNU aliases...${NC}"

    # -f consumed '%z' as its format argument, so no filesystem block appears.
    run_command cmd out err code "$binary" -f '%z' "$tmpfile"
    if [[ "$out" == "6" && "$out" != *"Block size:"* ]]; then
        print_test_result "stat -f does not alias --file-system" "PASS"
    else
        print_test_result "stat -f does not alias --file-system" "FAIL" "Got: '$out'"
    fi

    # -t consumed '%Y' as its timefmt argument, so '%Y' is not a path operand
    # and no terse line is emitted.
    run_command cmd out err code "$binary" -t '%Y' -f '%N' "$tmpfile"
    if [[ "$code" -eq 0 && "$out" == "$tmpfile" ]]; then
        print_test_result "stat -t does not alias --terse" "PASS"
    else
        print_test_result "stat -t does not alias --terse" "FAIL" \
            "Expected '$tmpfile', got '$out' (exit $code)"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    run_command cmd out err code "$binary" --invalid-flag
    if [[ "$code" -eq 2 ]]; then
        print_test_result "stat invalid flag exits 2" "PASS"
    else
        print_test_result "stat invalid flag exits 2" "FAIL" "Expected 2, got $code"
    fi

    # No operand means "stat standard input's descriptor"
    # (stat-macos.txt:14-15), not the old GNU missing-operand misuse error.
    run_command cmd out err code "$binary" < /dev/null
    if [[ "$code" -ne 2 && "$err" != *"missing operand"* ]]; then
        print_test_result "stat with no operand is not a missing-operand error" "PASS"
    else
        print_test_result "stat with no operand is not a missing-operand error" "FAIL" \
            "Exit $code, stderr: '$err'"
    fi

    # -f, -l, -r, -s and -x are mutually exclusive (SYNOPSIS, stat-macos.txt:7).
    run_command cmd out err code "$binary" -f '%z' -l "$tmpfile"
    if [[ "$code" -eq 2 && "$err" != *"unrecognized option"* ]]; then
        print_test_result "stat -f with -l is a usage error" "PASS"
    else
        print_test_result "stat -f with -l is a usage error" "FAIL" \
            "Exit $code, stderr: '$err'"
    fi

    run_command cmd out err code "$binary" -r -x "$tmpfile"
    if [[ "$code" -eq 2 && "$err" != *"unrecognized option"* ]]; then
        print_test_result "stat -r with -x is a usage error" "PASS"
    else
        print_test_result "stat -r with -x is a usage error" "FAIL" \
            "Exit $code, stderr: '$err'"
    fi

    # Nonexistent file exits with code 1
    run_command cmd out err code "$binary" /nonexistent/path/file
    if [[ "$code" -eq 1 ]]; then
        print_test_result "stat nonexistent file exits 1" "PASS"
    else
        print_test_result "stat nonexistent file exits 1" "FAIL" "Expected 1, got $code"
    fi

    echo -e "${CYAN}Testing correct error messages...${NC}"

    # Regression test: stat must show correct error for each error type
    run_command cmd out err code "$binary" /nonexistent
    if [[ "$err" == *"No such file"* ]]; then
        print_test_result "stat nonexistent shows 'No such file'" "PASS"
    else
        print_test_result "stat nonexistent shows 'No such file'" "FAIL" \
            "Expected 'No such file' in stderr, got: '$err'"
    fi

    # Regression test: stat permission denied shows correct message
    local stat_perm_dir
    stat_perm_dir=$(create_temp_dir)
    touch "$stat_perm_dir/secret"
    chmod 000 "$stat_perm_dir"
    run_command cmd out err code "$binary" "$stat_perm_dir/secret"
    if [[ "$err" == *"Permission denied"* ]]; then
        print_test_result "stat permission denied shows correct message" "PASS"
    else
        print_test_result "stat permission denied shows correct message" "FAIL" \
            "Expected 'Permission denied' in stderr, got: '$err'"
    fi
    chmod 755 "$stat_perm_dir"
    rm -rf "$stat_perm_dir"

    # Regression test: stat reports "regular file" for a regular file
    run_command cmd out err code "$binary" -c '%F' "$tmpfile"
    if [[ "$out" == "regular file" ]]; then
        print_test_result "stat regular file type string" "PASS"
    else
        print_test_result "stat regular file type string" "FAIL" \
            "Expected 'regular file', got '$out'"
    fi

    # Regression test: stat reports "directory" for a directory
    run_command cmd out err code "$binary" -c '%F' "$statdir"
    if [[ "$out" == "directory" ]]; then
        print_test_result "stat directory type string" "PASS"
    else
        print_test_result "stat directory type string" "FAIL" \
            "Expected 'directory', got '$out'"
    fi

    echo -e "${CYAN}Testing GNU -c directives...${NC}"

    # %N on symlink should show arrow notation (GNU semantics via -c)
    run_command cmd out err code "$binary" -c '%N' "$tmplink"
    if [[ "$out" == *" -> "* ]]; then
        print_test_result "stat -c '%N' symlink shows arrow" "PASS"
    else
        print_test_result "stat -c '%N' symlink shows arrow" "FAIL" \
            "Expected arrow notation, got '$out'"
    fi

    # %N on regular file should be single-quoted (GNU semantics via -c)
    run_command cmd out err code "$binary" -c '%N' "$tmpfile"
    if [[ "$out" == "'$tmpfile'" ]]; then
        print_test_result "stat -c '%N' regular file is quoted" "PASS"
    else
        print_test_result "stat -c '%N' regular file is quoted" "FAIL" \
            "Expected quoted '$tmpfile', got '$out'"
    fi

    # %x %y %z human-readable timestamp format (GNU semantics via -c)
    run_command cmd out err code "$binary" -c '%y' "$tmpfile"
    if [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        print_test_result "stat -c '%y' mtime has YYYY-MM-DD HH:MM:SS format" "PASS"
    else
        print_test_result "stat -c '%y' mtime has YYYY-MM-DD HH:MM:SS format" "FAIL" \
            "Got: '$out'"
    fi

    # %b blocks allocated
    run_command cmd out err code "$binary" -c '%b' "$tmpfile"
    if [[ "$out" =~ ^[0-9]+$ ]]; then
        print_test_result "stat -c '%b' blocks is numeric" "PASS"
    else
        print_test_result "stat -c '%b' blocks is numeric" "FAIL" \
            "Expected integer, got '$out'"
    fi

    # %G group name
    run_command cmd out err code "$binary" -c '%G' "$tmpfile"
    if [[ -n "$out" && ! "$out" =~ ^[0-9]+$ ]]; then
        print_test_result "stat -c '%G' group name is not numeric fallback" "PASS"
    else
        print_test_result "stat -c '%G' group name is not numeric fallback" "FAIL" \
            "Got: '$out'"
    fi

    # --- Differential pinning against the real BSD stat (macOS only) ---
    #
    # /usr/bin/stat on the macOS CI runner is the reference implementation for
    # the whole BSD interface. Comparing our output to it field by field is the
    # only way to get the H/M/L sub-fields and the per-datum default output
    # forms provably right. Only fields that are stable between two successive
    # invocations are compared. PATH is pinned to zig-out/bin by the runner, so
    # the reference is invoked by absolute path.
    if [[ "$(uname)" == "Darwin" && -x /usr/bin/stat ]]; then
        echo -e "${CYAN}Testing BSD parity against /usr/bin/stat...${NC}"

        local diff_fmt="" ours="" theirs=""
        local diff_formats=(
            '%z' '%Sp' '%Su' '%Sg' '%N' '%HT' '%Hr' '%Lr' '%#Xf'
            '%d' '%i' '%l' '%u' '%g' '%r' '%k' '%b' '%f' '%v'
            '%p' '%Dp' '%Op' '%Xp' '%SHp' '%SMp' '%SLp'
            '%Hd' '%Ld' '%T' '%LT' '%R' '%Z'
            '%-10z|' '%08z' '%#Op' '%12Sp|' '%-12Sp|' '%m' '%a' '%c' '%B'
        )
        for diff_fmt in "${diff_formats[@]}"; do
            ours=$("$binary" -f "$diff_fmt" "$tmpfile" 2>&1) || true
            theirs=$(/usr/bin/stat -f "$diff_fmt" "$tmpfile" 2>&1) || true
            if [[ "$ours" == "$theirs" ]]; then
                print_test_result "stat -f '$diff_fmt' matches /usr/bin/stat" "PASS"
            else
                print_test_result "stat -f '$diff_fmt' matches /usr/bin/stat" "FAIL" \
                    "ours='$ours' bsd='$theirs'"
            fi
        done

        # %Sa/%Sm/%Sc/%SB are only comparable with a fixed -t timefmt.
        local time_fmt=""
        for time_fmt in '%Sa' '%Sm' '%Sc' '%SB'; do
            ours=$("$binary" -f "$time_fmt" -t '%Y%m%d%H%M%S' "$tmpfile" 2>&1) || true
            theirs=$(/usr/bin/stat -f "$time_fmt" -t '%Y%m%d%H%M%S' "$tmpfile" 2>&1) || true
            if [[ "$ours" == "$theirs" ]]; then
                print_test_result "stat -f '$time_fmt' -t matches /usr/bin/stat" "PASS"
            else
                print_test_result "stat -f '$time_fmt' -t matches /usr/bin/stat" "FAIL" \
                    "ours='$ours' bsd='$theirs'"
            fi
        done

        # Whole-output parity for the flag-selected formats.
        local diff_flag=""
        for diff_flag in '' '-r' '-s' '-l' '-F' '-x'; do
            if [[ -z "$diff_flag" ]]; then
                ours=$("$binary" "$tmpfile" 2>&1) || true
                theirs=$(/usr/bin/stat "$tmpfile" 2>&1) || true
            else
                ours=$("$binary" "$diff_flag" "$tmpfile" 2>&1) || true
                theirs=$(/usr/bin/stat "$diff_flag" "$tmpfile" 2>&1) || true
            fi
            if [[ "$ours" == "$theirs" ]]; then
                print_test_result "stat ${diff_flag:-<default>} matches /usr/bin/stat" "PASS"
            else
                print_test_result "stat ${diff_flag:-<default>} matches /usr/bin/stat" "FAIL" \
                    "ours='$ours' bsd='$theirs'"
            fi
        done

        # A directory exercises the -F type suffix and the %HT long type name.
        ours=$("$binary" -F "$statdir" 2>&1) || true
        theirs=$(/usr/bin/stat -F "$statdir" 2>&1) || true
        if [[ "$ours" == "$theirs" ]]; then
            print_test_result "stat -F on a directory matches /usr/bin/stat" "PASS"
        else
            print_test_result "stat -F on a directory matches /usr/bin/stat" "FAIL" \
                "ours='$ours' bsd='$theirs'"
        fi

        # A symlink exercises %SY, %Y and the -L fallback.
        ours=$("$binary" -f '%N: %HT%SY' "$tmplink" 2>&1) || true
        theirs=$(/usr/bin/stat -f '%N: %HT%SY' "$tmplink" 2>&1) || true
        if [[ "$ours" == "$theirs" ]]; then
            print_test_result "stat -f '%N: %HT%SY' on a symlink matches /usr/bin/stat" "PASS"
        else
            print_test_result "stat -f '%N: %HT%SY' on a symlink matches /usr/bin/stat" "FAIL" \
                "ours='$ours' bsd='$theirs'"
        fi
    else
        print_test_result "stat BSD parity against /usr/bin/stat (macOS only)" "SKIP"
    fi

    # Cleanup
    rm -f "$tmpfile" "$tmplink"
    rm -rf "$statdir"
}
