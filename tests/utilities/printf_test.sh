#!/usr/bin/env bash
# Integration tests for printf utility
# Tests format specifiers, escape sequences, width, precision, and reuse

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_printf() {
    local util="printf"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic string formatting...${NC}"

    # Basic %s
    local output
    output=$("$binary" "%s" "hello")
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf %s basic" "PASS"
    else
        print_test_result "printf %s basic" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    # Format with newline
    output=$("$binary" "%s\n" "hello")
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf %s with newline" "PASS"
    else
        print_test_result "printf %s with newline" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    echo -e "${CYAN}Testing integer formatting...${NC}"

    # %d decimal
    output=$("$binary" "%d" "42")
    if [[ "$output" == "42" ]]; then
        print_test_result "printf %d decimal" "PASS"
    else
        print_test_result "printf %d decimal" "FAIL" \
            "Expected '42', got '$output'"
    fi

    # %o octal
    output=$("$binary" "%o" "255")
    if [[ "$output" == "377" ]]; then
        print_test_result "printf %o octal" "PASS"
    else
        print_test_result "printf %o octal" "FAIL" \
            "Expected '377', got '$output'"
    fi

    # %x hex
    output=$("$binary" "%x" "255")
    if [[ "$output" == "ff" ]]; then
        print_test_result "printf %x hex" "PASS"
    else
        print_test_result "printf %x hex" "FAIL" \
            "Expected 'ff', got '$output'"
    fi

    # %X hex uppercase
    output=$("$binary" "%X" "255")
    if [[ "$output" == "FF" ]]; then
        print_test_result "printf %X hex uppercase" "PASS"
    else
        print_test_result "printf %X hex uppercase" "FAIL" \
            "Expected 'FF', got '$output'"
    fi

    echo -e "${CYAN}Testing width and padding...${NC}"

    # Right-aligned string
    output=$("$binary" "%10s" "hello")
    if [[ "$output" == "     hello" ]]; then
        print_test_result "printf %10s right-aligned" "PASS"
    else
        print_test_result "printf %10s right-aligned" "FAIL" \
            "Expected '     hello', got '$output'"
    fi

    # Left-aligned string
    output=$("$binary" "%-10s" "hello")
    if [[ "$output" == "hello     " ]]; then
        print_test_result "printf %-10s left-aligned" "PASS"
    else
        print_test_result "printf %-10s left-aligned" "FAIL" \
            "Expected 'hello     ', got '$output'"
    fi

    # Zero-padded integer
    output=$("$binary" "%05d" "42")
    if [[ "$output" == "00042" ]]; then
        print_test_result "printf %05d zero-padded" "PASS"
    else
        print_test_result "printf %05d zero-padded" "FAIL" \
            "Expected '00042', got '$output'"
    fi

    echo -e "${CYAN}Testing precision...${NC}"

    # String precision
    output=$("$binary" "%.3s" "hello")
    if [[ "$output" == "hel" ]]; then
        print_test_result "printf %.3s precision" "PASS"
    else
        print_test_result "printf %.3s precision" "FAIL" \
            "Expected 'hel', got '$output'"
    fi

    echo -e "${CYAN}Testing escape sequences...${NC}"

    # Tab
    output=$("$binary" "a\tb")
    local expected=$'a\tb'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf tab escape" "PASS"
    else
        print_test_result "printf tab escape" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    # Literal percent
    output=$("$binary" "100%%")
    if [[ "$output" == "100%" ]]; then
        print_test_result "printf literal percent" "PASS"
    else
        print_test_result "printf literal percent" "FAIL" \
            "Expected '100%', got '$output'"
    fi

    echo -e "${CYAN}Testing format string reuse...${NC}"

    # Reuse format with multiple args
    output=$("$binary" "%s\n" "a" "b" "c")
    expected=$'a\nb\nc'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf format reuse" "PASS"
    else
        print_test_result "printf format reuse" "FAIL" \
            "Expected '$expected', got '$output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "printf --help shows usage" "PASS"
    else
        print_test_result "printf --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ printf ]]; then
        print_test_result "printf --version shows version" "PASS"
    else
        print_test_result "printf --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # No arguments exits with code 1
    test_command_exit_code "printf no args exits 1" 1 \
        "$binary"

    # GNU coreutils diagnostic for no operands, verified on Ubuntu with
    # `LC_ALL=C /usr/bin/printf`:
    #   printf: missing operand
    #   Try 'printf --help' for more information.
    # GNU echoes argv[0]; we print the plain utility name, as uniq and
    # whoami do.
    local missing_err
    missing_err=$("$binary" 2>&1 >/dev/null)
    local expected_err
    expected_err=$'printf: missing operand\nTry \'printf --help\' for more information.'
    if [[ "$missing_err" == "$expected_err" ]]; then
        print_test_result "printf no args prints GNU missing-operand text" "PASS"
    else
        print_test_result "printf no args prints GNU missing-operand text" "FAIL" \
            "Expected '$expected_err', got '$missing_err'"
    fi

    # The diagnostic goes to stderr, leaving stdout empty.
    local missing_out
    missing_out=$("$binary" 2>/dev/null)
    if [[ -z "$missing_out" ]]; then
        print_test_result "printf no args writes nothing to stdout" "PASS"
    else
        print_test_result "printf no args writes nothing to stdout" "FAIL" \
            "Expected empty stdout, got '$missing_out'"
    fi

    # Regression test: write errors propagated (smoke test)
    # The actual write-error path is hard to exercise in shell, so verify
    # that escape sequences produce correct output end-to-end (the fix
    # ensures flush/write errors are not silently swallowed).
    echo -e "${CYAN}Testing escape sequence output end-to-end...${NC}"

    local nl_output
    nl_output=$("$binary" 'line1\nline2')
    local nl_expected=$'line1\nline2'
    if [[ "$nl_output" == "$nl_expected" ]]; then
        print_test_result "printf backslash-n produces newline" "PASS"
    else
        print_test_result "printf backslash-n produces newline" "FAIL" \
            "Expected 'line1<NL>line2', got '$nl_output'"
    fi

    # Regression test: carry propagation in float formatting
    echo -e "${CYAN}Testing float rounding carry propagation...${NC}"

    output=$("$binary" '%.2f' 9.995)
    if [[ "$output" == "10.00" ]]; then
        print_test_result "printf %.2f 9.995 rounds to 10.00" "PASS"
    else
        print_test_result "printf %.2f 9.995 rounds to 10.00" "FAIL" \
            "Expected '10.00', got '$output'"
    fi

    output=$("$binary" '%.0f' 9.5)
    if [[ "$output" == "10" ]]; then
        print_test_result "printf %.0f 9.5 rounds to 10" "PASS"
    else
        print_test_result "printf %.0f 9.5 rounds to 10" "FAIL" \
            "Expected '10', got '$output'"
    fi

    output=$("$binary" '%.2f' 99.999)
    if [[ "$output" == "100.00" ]]; then
        print_test_result "printf %.2f 99.999 rounds to 100.00" "PASS"
    else
        print_test_result "printf %.2f 99.999 rounds to 100.00" "FAIL" \
            "Expected '100.00', got '$output'"
    fi

    # ========== AUDIT FINDING TESTS ==========

    echo -e "${CYAN}Testing F31: octal escapes without leading zero...${NC}"

    # F31: \NNN octal escape without leading zero
    # GNU printf '\101\n' outputs 'A' (octal 101 = 65)
    output=$("$binary" '\101')
    if [[ "$output" == "A" ]]; then
        print_test_result "printf F31: \\101 octal = A" "PASS"
    else
        print_test_result "printf F31: \\101 octal = A" "FAIL" \
            "Expected 'A', got '$output'"
    fi

    # F31: single octal digit
    output=$("$binary" '\7')
    local expected_bel=$'\x07'
    if [[ "$output" == "$expected_bel" ]]; then
        print_test_result "printf F31: \\7 octal = BEL" "PASS"
    else
        print_test_result "printf F31: \\7 octal = BEL" "FAIL" \
            "Expected BEL (0x07), got '$output'"
    fi

    # F31: 3-digit octal
    output=$("$binary" '\110')
    if [[ "$output" == "H" ]]; then
        print_test_result "printf F31: \\110 octal = H" "PASS"
    else
        print_test_result "printf F31: \\110 octal = H" "FAIL" \
            "Expected 'H', got '$output'"
    fi

    echo -e "${CYAN}Testing F32: %b octal \\0NNN off-by-one...${NC}"

    # F32: %b \0NNN should skip the leading 0 prefix
    output=$("$binary" '%b' '\0101')
    if [[ "$output" == "A" ]]; then
        print_test_result "printf F32: %b \\0101 = A" "PASS"
    else
        print_test_result "printf F32: %b \\0101 = A" "FAIL" \
            "Expected 'A', got '$(echo -n "$output" | od -A x -t x1z)'"
    fi

    # F32: %b \0110 = 'H'
    output=$("$binary" '%b' '\0110')
    if [[ "$output" == "H" ]]; then
        print_test_result "printf F32: %b \\0110 = H" "PASS"
    else
        print_test_result "printf F32: %b \\0110 = H" "FAIL" \
            "Expected 'H', got '$(echo -n "$output" | od -A x -t x1z)'"
    fi

    echo -e "${CYAN}Testing F33: \\c in format string stops output...${NC}"

    # F33: \c halts output in format string
    output=$("$binary" 'before\cafter')
    if [[ "$output" == "before" ]]; then
        print_test_result "printf F33: \\c stops output" "PASS"
    else
        print_test_result "printf F33: \\c stops output" "FAIL" \
            "Expected 'before', got '$output'"
    fi

    # F33: \c at start
    output=$("$binary" '\chello')
    if [[ "$output" == "" ]]; then
        print_test_result "printf F33: \\c at start = empty" "PASS"
    else
        print_test_result "printf F33: \\c at start = empty" "FAIL" \
            "Expected empty, got '$output'"
    fi

    echo -e "${CYAN}Testing F34: %b \\c halts format-string reuse...${NC}"

    # F34: %b \c should stop reusing format for remaining args
    output=$("$binary" '%b\n' 'hello\c' 'world')
    if [[ "$output" == "hello" ]]; then
        print_test_result "printf F34: %b \\c halts reuse" "PASS"
    else
        print_test_result "printf F34: %b \\c halts reuse" "FAIL" \
            "Expected 'hello', got '$output'"
    fi

    echo -e "${CYAN}Testing F35: %F, %a, %A format specifiers...${NC}"

    # F35: %F is uppercase %f
    output=$("$binary" '%F' 3.14)
    if [[ "$output" == "3.140000" ]]; then
        print_test_result "printf F35: %F 3.14 = 3.140000" "PASS"
    else
        print_test_result "printf F35: %F 3.14 = 3.140000" "FAIL" \
            "Expected '3.140000', got '$output'"
    fi

    # F35: %a hex float (just check it starts with 0x and has p)
    output=$("$binary" '%a' 1.5)
    if [[ "$output" == 0x*p* ]]; then
        print_test_result "printf F35: %a hex float format" "PASS"
    else
        print_test_result "printf F35: %a hex float format" "FAIL" \
            "Expected '0x...p...', got '$output'"
    fi

    # F35: %A hex float uppercase
    output=$("$binary" '%A' 1.5)
    if [[ "$output" == 0X*P* ]]; then
        print_test_result "printf F35: %A hex float uppercase" "PASS"
    else
        print_test_result "printf F35: %A hex float uppercase" "FAIL" \
            "Expected '0X...P...', got '$output'"
    fi

    # ========== AUDIT WAVE 4: printf IMPORTANT findings ==========

    echo -e "${CYAN}Testing audit: %d with non-numeric input...${NC}"

    # IMPORTANT: Invalid numeric argument does not emit warning or set exit 1
    # GNU printf '%d\n' abc prints "0" AND emits warning to stderr AND exits 1
    local aud_out="" aud_err="" aud_exit=""
    run_command aud_cmd aud_out aud_err aud_exit "$binary" '%d' abc
    if [[ $aud_exit -eq 1 ]]; then
        print_test_result "printf audit: %d abc exits 1" "PASS"
    else
        print_test_result "printf audit: %d abc exits 1" "FAIL" \
            "Expected exit 1, got $aud_exit"
    fi
    if [[ -n "$aud_err" ]]; then
        print_test_result "printf audit: %d abc emits warning" "PASS"
    else
        print_test_result "printf audit: %d abc emits warning" "FAIL" \
            "Expected non-empty stderr"
    fi

    echo -e "${CYAN}Testing audit: %i format specifier...${NC}"

    # Test gap: %i is synonym for %d
    output=$("$binary" '%i' 42)
    if [[ "$output" == "42" ]]; then
        print_test_result "printf audit: %i format specifier" "PASS"
    else
        print_test_result "printf audit: %i format specifier" "FAIL" \
            "Expected '42', got '$output'"
    fi

    echo -e "${CYAN}Testing audit: %E and %G format specifiers...${NC}"

    # Test gap: %E uppercase scientific notation
    output=$("$binary" '%E' 1234.5)
    if [[ "$output" == *"E+"* ]]; then
        print_test_result "printf audit: %E uppercase scientific" "PASS"
    else
        print_test_result "printf audit: %E uppercase scientific" "FAIL" \
            "Expected output with 'E+', got '$output'"
    fi

    # Test gap: %G uppercase general float
    output=$("$binary" '%G' 0.00001)
    if [[ "$output" == *"E"* ]]; then
        print_test_result "printf audit: %G uppercase general" "PASS"
    else
        print_test_result "printf audit: %G uppercase general" "FAIL" \
            "Expected output with 'E', got '$output'"
    fi

    echo -e "${CYAN}Testing audit: dynamic width with *...${NC}"

    # Test gap: * dynamic width
    output=$("$binary" '%*d' 10 42)
    if [[ "$output" == "        42" ]]; then
        print_test_result "printf audit: dynamic width *" "PASS"
    else
        print_test_result "printf audit: dynamic width *" "FAIL" \
            "Expected '        42', got '$output'"
    fi

    # IMPORTANT: negative * width implies left-justify
    output=$("$binary" '%*d' -5 42)
    if [[ "$output" == "42   " ]]; then
        print_test_result "printf audit: negative * width left-justify" "PASS"
    else
        print_test_result "printf audit: negative * width left-justify" "FAIL" \
            "Expected '42   ', got '$output'"
    fi

    echo -e "${CYAN}Testing audit: space-sign flag...${NC}"

    # Test gap: space flag on %d
    output=$("$binary" '% d' 42)
    if [[ "$output" == " 42" ]]; then
        print_test_result "printf audit: space-sign flag positive" "PASS"
    else
        print_test_result "printf audit: space-sign flag positive" "FAIL" \
            "Expected ' 42', got '$output'"
    fi

    output=$("$binary" '% d' -42)
    if [[ "$output" == "-42" ]]; then
        print_test_result "printf audit: space-sign flag negative" "PASS"
    else
        print_test_result "printf audit: space-sign flag negative" "FAIL" \
            "Expected '-42', got '$output'"
    fi

    # ========== FORMAT SPECIFIER BEHAVIORAL TESTS ==========

    echo -e "${CYAN}Testing %f fixed float...${NC}"

    test_command_output "printf %f 3.14" "3.140000" \
        "$binary" '%f' 3.14

    test_command_output "printf %f 0" "0.000000" \
        "$binary" '%f' 0

    test_command_output "printf %.2f 3.14159" "3.14" \
        "$binary" '%.2f' 3.14159

    echo -e "${CYAN}Testing %e scientific notation...${NC}"

    test_command_output "printf %e 100000" "1.000000e+05" \
        "$binary" '%e' 100000

    test_command_output "printf %e 0.0025" "2.500000e-03" \
        "$binary" '%e' 0.0025

    echo -e "${CYAN}Testing %g general float...${NC}"

    test_command_output "printf %g 3.14" "3.14" \
        "$binary" '%g' 3.14

    test_command_output "printf %g 100000" "100000" \
        "$binary" '%g' 100000

    test_command_output "printf %g 0.00001" "1e-05" \
        "$binary" '%g' 0.00001

    echo -e "${CYAN}Testing %c character...${NC}"

    test_command_output "printf %c A" "A" \
        "$binary" '%c' A

    test_command_output "printf %c hello" "h" \
        "$binary" '%c' hello

    echo -e "${CYAN}Testing %u unsigned integer...${NC}"

    test_command_output "printf %u 42" "42" \
        "$binary" '%u' 42

    test_command_output "printf %u 0" "0" \
        "$binary" '%u' 0

    echo -e "${CYAN}Testing %d with float argument (GNU truncation)...${NC}"

    # GNU printf '%d' 3.9 outputs "3" (truncates float to integer)
    output=$("$binary" '%d' 3.9)
    if [[ "$output" == "3" ]]; then
        print_test_result "printf %d with float 3.9 truncates to 3" "PASS"
    else
        print_test_result "printf %d with float 3.9 truncates to 3" "FAIL" \
            "Expected '3', got '$output'"
    fi

    # GNU printf '%d' 1e2 outputs "100" (parse as float, truncate)
    output=$("$binary" '%d' 1e2)
    if [[ "$output" == "100" ]]; then
        print_test_result "printf %d with float 1e2 = 100" "PASS"
    else
        print_test_result "printf %d with float 1e2 = 100" "FAIL" \
            "Expected '100', got '$output'"
    fi

    # %d with float should exit 1 (not completely converted)
    local float_exit
    "$binary" '%d' 3.9 >/dev/null 2>/dev/null
    float_exit=$?
    if [[ $float_exit -eq 1 ]]; then
        print_test_result "printf %d with float exits 1" "PASS"
    else
        print_test_result "printf %d with float exits 1" "FAIL" \
            "Expected exit 1, got $float_exit"
    fi

    echo -e "${CYAN}Testing %b escape sequences...${NC}"

    # %b with \n
    output=$("$binary" '%b' 'a\nb')
    expected=$'a\nb'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf %b with newline escape" "PASS"
    else
        print_test_result "printf %b with newline escape" "FAIL" \
            "Expected 'a<NL>b', got '$output'"
    fi

    # %b with \t
    output=$("$binary" '%b' 'a\tb')
    expected=$'a\tb'
    if [[ "$output" == "$expected" ]]; then
        print_test_result "printf %b with tab escape" "PASS"
    else
        print_test_result "printf %b with tab escape" "FAIL" \
            "Expected 'a<TAB>b', got '$output'"
    fi

    echo -e "${CYAN}Testing + sign flag...${NC}"

    test_command_output "printf +sign flag positive" "+42" \
        "$binary" '%+d' 42

    test_command_output "printf +sign flag negative" "-42" \
        "$binary" '%+d' -42

    echo -e "${CYAN}Testing # alternate form...${NC}"

    test_command_output "printf #flag hex" "0xff" \
        "$binary" '%#x' 255

    test_command_output "printf #flag octal" "010" \
        "$binary" '%#o' 8

    echo -e "${CYAN}Testing .* precision from argument...${NC}"

    test_command_output "printf .* precision" "3.142" \
        "$binary" '%.*f' 3 3.14159
}
