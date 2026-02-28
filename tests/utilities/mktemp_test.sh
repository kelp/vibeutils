#!/usr/bin/env bash
# Comprehensive tests for mktemp utility
# Tests all flags, error conditions, and edge cases

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_mktemp() {
    local util="mktemp"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing basic functionality...${NC}"

    # Default template creates a file
    local output
    output=$("$binary")
    local exit_code=$?
    if [[ $exit_code -eq 0 && -f "$output" ]]; then
        print_test_result "mktemp creates file with default template" "PASS"
        rm -f "$output"
    else
        print_test_result "mktemp creates file with default template" "FAIL" "exit=$exit_code, file=$output"
    fi

    # File should start with tmp. prefix
    output=$("$binary")
    local basename_out
    basename_out=$(basename "$output")
    if [[ "$basename_out" == tmp.* ]]; then
        print_test_result "mktemp default template starts with tmp." "PASS"
    else
        print_test_result "mktemp default template starts with tmp." "FAIL" "got: $basename_out"
    fi
    rm -f "$output"

    # Custom template
    output=$("$binary" "mytest.XXXXXX")
    basename_out=$(basename "$output")
    if [[ "$basename_out" == mytest.* && -f "$output" ]]; then
        print_test_result "mktemp with custom template" "PASS"
    else
        print_test_result "mktemp with custom template" "FAIL" "got: $basename_out"
    fi
    rm -f "$output"

    echo -e "${CYAN}Testing directory creation (-d)...${NC}"

    # Create directory
    output=$("$binary" -d)
    if [[ $? -eq 0 && -d "$output" ]]; then
        print_test_result "mktemp -d creates directory" "PASS"
        rmdir "$output"
    else
        print_test_result "mktemp -d creates directory" "FAIL" "output=$output"
    fi

    # Long form
    output=$("$binary" --directory)
    if [[ $? -eq 0 && -d "$output" ]]; then
        print_test_result "mktemp --directory creates directory" "PASS"
        rmdir "$output"
    else
        print_test_result "mktemp --directory creates directory" "FAIL"
    fi

    echo -e "${CYAN}Testing dry-run mode (-u)...${NC}"

    # Dry run should not create file
    output=$("$binary" -u)
    if [[ $? -eq 0 && ! -e "$output" ]]; then
        print_test_result "mktemp -u does not create file" "PASS"
    else
        print_test_result "mktemp -u does not create file" "FAIL"
        rm -f "$output"
    fi

    # Dry run with directory flag
    output=$("$binary" -u -d)
    if [[ $? -eq 0 && ! -e "$output" ]]; then
        print_test_result "mktemp -u -d does not create directory" "PASS"
    else
        print_test_result "mktemp -u -d does not create directory" "FAIL"
        rmdir "$output" 2>/dev/null
    fi

    echo -e "${CYAN}Testing tmpdir flag (-p)...${NC}"

    # Use specific directory
    local tmpdir="$TEMP_DIR/mktemp_test_dir"
    mkdir -p "$tmpdir"

    output=$("$binary" -p "$tmpdir")
    if [[ $? -eq 0 && "$output" == "$tmpdir"/* && -f "$output" ]]; then
        print_test_result "mktemp -p DIR uses specified directory" "PASS"
        rm -f "$output"
    else
        print_test_result "mktemp -p DIR uses specified directory" "FAIL" "output=$output"
    fi

    # Long form
    output=$("$binary" --tmpdir="$tmpdir")
    if [[ $? -eq 0 && "$output" == "$tmpdir"/* && -f "$output" ]]; then
        print_test_result "mktemp --tmpdir=DIR uses specified directory" "PASS"
        rm -f "$output"
    else
        print_test_result "mktemp --tmpdir=DIR uses specified directory" "FAIL" "output=$output"
    fi

    rmdir "$tmpdir" 2>/dev/null

    echo -e "${CYAN}Testing quiet mode (-q)...${NC}"

    # Quiet mode should suppress errors but still fail
    local stderr_output
    stderr_output=$("$binary" -q "noX" 2>&1)
    local q_exit=$?
    if [[ $q_exit -ne 0 && -z "$stderr_output" ]]; then
        print_test_result "mktemp -q suppresses error messages" "PASS"
    else
        print_test_result "mktemp -q suppresses error messages" "FAIL" "exit=$q_exit, stderr='$stderr_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Too few X's
    test_command_fails "error: too few X's" "$binary" "tmp.XX"
    test_command_fails "error: no X's" "$binary" "template"

    # Too many templates
    test_command_fails "error: too many templates" "$binary" "tmp.XXX" "tmp2.XXX"

    # Invalid flags
    test_command_fails "error: invalid flag" "$binary" --invalid
    test_command_fails "error: invalid short flag" "$binary" -x

    # Suffix with directory separator
    test_command_fails "error: suffix with slash" "$binary" --suffix=/bad "tmpXXXXXX"

    echo -e "${CYAN}Testing uniqueness...${NC}"

    # Two consecutive mktemp calls should produce different names
    local out1 out2
    out1=$("$binary")
    out2=$("$binary")
    if [[ "$out1" != "$out2" ]]; then
        print_test_result "mktemp produces unique names" "PASS"
    else
        print_test_result "mktemp produces unique names" "FAIL" "both produced: $out1"
    fi
    rm -f "$out1" "$out2"

    echo -e "${CYAN}Testing help and version output...${NC}"

    # Help contains expected content
    local help_output
    help_output=$("$binary" --help)
    if [[ "$help_output" =~ "Usage:" && "$help_output" =~ "--directory" && "$help_output" =~ "--dry-run" ]]; then
        print_test_result "help output contains expected content" "PASS"
    else
        print_test_result "help output contains expected content" "FAIL" "Missing expected help content"
    fi

    # Version output
    local version_output
    version_output=$("$binary" --version)
    if [[ "$version_output" =~ "mktemp" ]]; then
        print_test_result "version output contains utility name" "PASS"
    else
        print_test_result "version output contains utility name" "FAIL" "Version output: '$version_output'"
    fi

    echo -e "${CYAN}Testing file permissions...${NC}"

    # Created file should have mode 0600
    output=$("$binary")
    if [[ -f "$output" ]]; then
        local perms
        perms=$(get_file_permissions "$output")
        if [[ "$perms" == "600" ]]; then
            print_test_result "mktemp file has mode 0600" "PASS"
        else
            print_test_result "mktemp file has mode 0600" "FAIL" "got mode $perms"
        fi
        rm -f "$output"
    fi

    # Created directory should have mode 0700
    output=$("$binary" -d)
    if [[ -d "$output" ]]; then
        local perms
        perms=$(get_file_permissions "$output")
        if [[ "$perms" == "700" ]]; then
            print_test_result "mktemp directory has mode 0700" "PASS"
        else
            print_test_result "mktemp directory has mode 0700" "FAIL" "got mode $perms"
        fi
        rmdir "$output"
    fi
}
