#!/usr/bin/env bash
# Comprehensive tests for tr (translate) utility
# Tests translation, deletion, squeezing, character classes, and POSIX compliance

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_tr() {
    local util="tr"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic infrastructure...${NC}"

    # Missing operands
    test_command_exit_code "tr no arguments" 2 "$binary" 2>/dev/null
    test_command_exit_code "tr single arg (no SET2)" 2 bash -c "echo '' | '$binary' abc 2>/dev/null"

    echo -e "${CYAN}Testing basic translation...${NC}"

    # Simple character translation
    test_command_output "tr translate a->x" "xbcxbc" bash -c "echo -n 'abcabc' | '$binary' a x"
    test_command_output "tr translate abc->xyz" "xyzxyz" bash -c "echo -n 'abcabc' | '$binary' abc xyz"
    test_command_output "tr translate vowels" "hEllO wOrld" bash -c "echo -n 'hello world' | '$binary' aeiou AEIOU"

    # Uppercase to lowercase
    test_command_output "tr upper to lower" "hello world" bash -c "echo -n 'HELLO WORLD' | '$binary' A-Z a-z"

    # Lowercase to uppercase
    test_command_output "tr lower to upper" "HELLO WORLD" bash -c "echo -n 'hello world' | '$binary' a-z A-Z"

    # Translation preserves unmapped characters
    test_command_output "tr preserves unmapped" "x23" bash -c "echo -n 'a23' | '$binary' a x"

    # SET2 shorter than SET1 extends last char
    test_command_output "tr SET2 shorter extends" "xxxx" bash -c "echo -n 'abcd' | '$binary' abcd x"

    echo -e "${CYAN}Testing character ranges...${NC}"

    # Numeric range (use -- to prevent SET2 from being treated as flags)
    test_command_output "tr digit range" "----------" bash -c "echo -n '0123456789' | '$binary' -- 0-9 '----------'"

    # Alphabetic range
    test_command_output "tr alpha range" "ABCDE" bash -c "echo -n 'abcde' | '$binary' a-e A-E"

    echo -e "${CYAN}Testing character classes...${NC}"

    # [:upper:] to [:lower:]
    test_command_output "tr class upper->lower" "hello world" bash -c "echo -n 'HELLO WORLD' | '$binary' '[:upper:]' '[:lower:]'"

    # [:lower:] to [:upper:]
    test_command_output "tr class lower->upper" "HELLO WORLD" bash -c "echo -n 'hello world' | '$binary' '[:lower:]' '[:upper:]'"

    echo -e "${CYAN}Testing delete mode (-d)...${NC}"

    # Delete specific characters
    test_command_output "tr -d delete chars" "hll wrld" bash -c "echo -n 'hello world' | '$binary' -d aeiou"

    # Delete digits
    test_command_output "tr -d delete digits" "hello" bash -c "echo -n 'h1e2l3l4o5' | '$binary' -d 0-9"

    # Delete with character class
    test_command_output "tr -d delete class digits" "abc" bash -c "echo -n 'a1b2c3' | '$binary' -d '[:digit:]'"

    # Delete newlines
    test_command_output "tr -d delete newlines" "abc" bash -c "printf 'a\nb\nc' | '$binary' -d '\\n'"

    # -d needs only SET1
    test_command_exit_code "tr -d with SET1 only succeeds" 0 bash -c "echo '' | '$binary' -d a"

    echo -e "${CYAN}Testing squeeze mode (-s)...${NC}"

    # Squeeze repeated characters
    test_command_output "tr -s squeeze spaces" "hello world" bash -c "echo -n 'hello   world' | '$binary' -s ' '"

    # Squeeze with translation
    test_command_output "tr -s translate and squeeze" "xyz" bash -c "echo -n 'aabbbcc' | '$binary' -s abc xyz"

    # Squeeze multiple character types
    test_command_output "tr -s squeeze multiple" "abcabc" bash -c "echo -n 'aabbccaaabbbccc' | '$binary' -s abc"

    echo -e "${CYAN}Testing delete and squeeze combined (-ds)...${NC}"

    # Delete SET1 then squeeze SET2
    test_command_output "tr -ds delete and squeeze" "XY" bash -c "echo -n 'aabbbXXYcc' | '$binary' -ds abc XY"

    echo -e "${CYAN}Testing complement mode (-c)...${NC}"

    # Complement delete: keep only digits
    test_command_output "tr -cd keep digits" "123" bash -c "echo -n 'hello123world' | '$binary' -cd '0-9'"

    # Complement translate (replace everything not a digit with .)
    test_command_output "tr -c complement translate" ".....123....." bash -c "echo -n 'hello123world' | '$binary' -c '0-9' '.'"

    echo -e "${CYAN}Testing truncate mode (-t)...${NC}"

    # Truncate SET1 to length of SET2 (c is not mapped, stays as c)
    test_command_output "tr -t truncate set1" "xycxyc" bash -c "echo -n 'abcabc' | '$binary' -t abc xy"

    echo -e "${CYAN}Testing escape sequences...${NC}"

    # Tab translation
    test_command_output "tr translate tab to space" "hello world" bash -c "printf 'hello\tworld' | '$binary' '\\t' ' '"

    # Newline handling
    test_command_output "tr delete newlines" "helloworld" bash -c "printf 'hello\nworld' | '$binary' -d '\\n'"

    echo -e "${CYAN}Testing edge cases...${NC}"

    # Empty input
    test_command_output "tr empty input" "" bash -c "echo -n '' | '$binary' abc xyz"

    # Single character input
    test_command_output "tr single char" "x" bash -c "echo -n 'a' | '$binary' a x"

    # Identity translation (same SET1 and SET2)
    test_command_output "tr identity translation" "hello" bash -c "echo -n 'hello' | '$binary' abc abc"

    # Large input
    test_command_exit_code "tr large input" 0 bash -c "dd if=/dev/zero bs=1024 count=100 2>/dev/null | '$binary' '\\0' x >/dev/null"

    echo -e "${CYAN}Testing POSIX compliance...${NC}"

    # Exit codes
    test_command_exit_code "tr success exit code" 0 bash -c "echo 'test' | '$binary' a b"
    test_command_exit_code "tr help exit code" 0 "$binary" --help >/dev/null
    test_command_exit_code "tr version exit code" 0 "$binary" --version >/dev/null
    test_command_exit_code "tr invalid flag exit code" 2 "$binary" --invalid 2>/dev/null

    # Stdin processing
    test_command_output "tr processes stdin" "HELLO" bash -c "echo -n 'hello' | '$binary' a-z A-Z"

    # Binary data preservation (non-matched bytes pass through)
    test_command_exit_code "tr binary data" 0 bash -c "printf '\\x00\\x01\\x02\\xFF' | '$binary' a b >/dev/null"

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flags
    test_command_exit_code "tr invalid flag -x" 2 "$binary" -x 2>/dev/null
    test_command_exit_code "tr invalid long flag" 2 "$binary" --invalid 2>/dev/null

    # -ds requires two operands
    test_command_exit_code "tr -ds needs two sets" 2 bash -c "echo '' | '$binary' -ds abc 2>/dev/null"

    # Extra operands should be rejected (GNU: exit 1 with "extra operand")
    test_command_exit_code "tr extra operand rejected" 1 bash -c "echo test | '$binary' a b c 2>/dev/null"
    # Verify stderr contains "extra operand" message
    test_command_output "tr extra operand stderr msg" "extra operand" bash -c "'$binary' a b c 2>&1 >/dev/null </dev/null | head -1 | grep -o 'extra operand'"

    echo -e "${CYAN}Testing [c*] repeat fill...${NC}"

    # [c*] should fill SET2 to match SET1 length
    test_command_output "tr [c*] fill basic" "xxx" bash -c "printf 'abc' | '$binary' 'abc' '[x*]'"

    # [c*0] is the POSIX synonym for [c*]
    test_command_output "tr [c*0] fill POSIX synonym" "xxx" bash -c "printf 'abc' | '$binary' 'abc' '[x*0]'"

    # [c*] with character class in SET1
    test_command_output "tr [c*] fill with class" "xxxxx" bash -c "printf 'HELLO' | '$binary' '[:upper:]' '[x*]'"

    # [c*] with other chars before repeat
    test_command_output "tr [c*] fill after literal" "yxxx" bash -c "printf 'abcd' | '$binary' 'abcd' 'y[x*]'"

    echo -e "${CYAN}Testing [x*N] explicit repeat (regression)...${NC}"

    # [x*3] explicit repeat count: first 3 chars map to x, rest to yz
    test_command_output "tr [x*3] explicit repeat" "xxxyz" \
        bash -c "printf 'abcde' | '$binary' 'abcde' '[x*3]yz'"

    # [x*1] single repeat
    test_command_output "tr [x*1] single repeat" "xbc" \
        bash -c "printf 'abc' | '$binary' 'abc' '[x*1]bc'"

    echo -e "${CYAN}Testing -C complement flag behavioral (audit gap)...${NC}"

    # -C should be functionally identical to -c for single-byte locales
    # Test -C delete: keep only specified chars
    test_command_output "tr -Cd keep digits" "123" \
        bash -c "echo -n 'hello123world' | '$binary' -Cd '0-9'"

    # -C translate: replace non-digits with dots
    test_command_output "tr -C complement translate" ".....123....." \
        bash -c "echo -n 'hello123world' | '$binary' -C '0-9' '.'"

    # -C with character class
    test_command_output "tr -Cd keep alpha" "helloworld" \
        bash -c "echo -n 'hello 123 world!' | '$binary' -Cd '[:alpha:]'"

    # Cleanup
    cleanup_test_session
    echo -e "${GREEN}tr tests completed${NC}"
}

# Export the test function
export -f test_tr
