#!/usr/bin/env bash
# Integration tests for date utility
# Tests default output, flags, format strings, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_date() {
    local util="date"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should be non-empty
    local output
    output=$("$binary" 2>/dev/null)
    if [[ -n "$output" ]]; then
        print_test_result "date default output is non-empty" "PASS"
    else
        print_test_result "date default output is non-empty" "FAIL" \
            "Expected non-empty output"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage text and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "date --help shows usage" "PASS"
    else
        print_test_result "date --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ date ]]; then
        print_test_result "date --version shows version" "PASS"
    else
        print_test_result "date --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "date invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    echo -e "${CYAN}Testing format strings...${NC}"

    # +%Y outputs 4-digit year
    local year_output
    year_output=$("$binary" "+%Y" 2>/dev/null)
    if [[ "$year_output" =~ ^[0-9]{4}$ ]]; then
        print_test_result "date +%Y outputs 4-digit year" "PASS"
    else
        print_test_result "date +%Y outputs 4-digit year" "FAIL" \
            "Expected 4-digit year, got '$year_output'"
    fi

    echo -e "${CYAN}Testing UTC mode...${NC}"

    # -u (UTC) exits 0
    test_command_exit_code "date -u exits 0" 0 "$binary" -u

    # Regression test: date -v exits non-zero (not yet implemented)
    # Should fail cleanly with no misleading date output on stdout
    echo -e "${CYAN}Testing unimplemented -v flag...${NC}"

    local dv_cmd dv_out dv_err dv_exit
    run_command dv_cmd dv_out dv_err dv_exit "$binary" -v +1d
    if [[ $dv_exit -ne 0 ]]; then
        print_test_result "date -v exits non-zero" "PASS"
    else
        print_test_result "date -v exits non-zero" "FAIL" \
            "Expected non-zero exit for unimplemented -v flag, got 0"
    fi
    if [[ -z "$dv_out" ]]; then
        print_test_result "date -v produces no stdout" "PASS"
    else
        print_test_result "date -v produces no stdout" "FAIL" \
            "Expected empty stdout, got: '$dv_out'"
    fi

    # ================================================================
    # F62: date -r with numeric timestamp should parse as epoch seconds
    # ================================================================
    # macOS/BSD -r accepts both filenames and numeric epoch seconds.
    # Our implementation always calls statFile(), so -r 0 fails.
    echo -e "${CYAN}Testing -r with numeric epoch timestamp (F62)...${NC}"

    local r0_cmd r0_out r0_err r0_exit
    run_command r0_cmd r0_out r0_err r0_exit "$binary" -r 0 -u "+%Y-%m-%d"
    if [[ $r0_exit -eq 0 && "$r0_out" == "1970-01-01" ]]; then
        print_test_result "date -r 0 -u displays epoch" "PASS"
    else
        print_test_result "date -r 0 -u displays epoch" "FAIL" \
            "Expected '1970-01-01' exit 0, got '$r0_out' exit $r0_exit stderr='$r0_err'"
    fi

    local r86_cmd r86_out r86_err r86_exit
    run_command r86_cmd r86_out r86_err r86_exit "$binary" -r 86400 -u "+%Y-%m-%d"
    if [[ $r86_exit -eq 0 && "$r86_out" == "1970-01-02" ]]; then
        print_test_result "date -r 86400 -u displays next day" "PASS"
    else
        print_test_result "date -r 86400 -u displays next day" "FAIL" \
            "Expected '1970-01-02' exit 0, got '$r86_out' exit $r86_exit stderr='$r86_err'"
    fi

    # Edge case: negative epoch (pre-1970)
    local rneg_cmd rneg_out rneg_err rneg_exit
    run_command rneg_cmd rneg_out rneg_err rneg_exit "$binary" -r -86400 -u "+%Y-%m-%d"
    if [[ $rneg_exit -eq 0 && "$rneg_out" == "1969-12-31" ]]; then
        print_test_result "date -r -86400 -u displays pre-epoch" "PASS"
    else
        print_test_result "date -r -86400 -u displays pre-epoch" "FAIL" \
            "Expected '1969-12-31' exit 0, got '$rneg_out' exit $rneg_exit stderr='$rneg_err'"
    fi

    # -r with numeric should round-trip via %s
    local rs_cmd rs_out rs_err rs_exit
    run_command rs_cmd rs_out rs_err rs_exit "$binary" -r 1000000 -u "+%s"
    if [[ $rs_exit -eq 0 && "$rs_out" == "1000000" ]]; then
        print_test_result "date -r 1000000 -u +%s round-trips" "PASS"
    else
        print_test_result "date -r 1000000 -u +%s round-trips" "FAIL" \
            "Expected '1000000' exit 0, got '$rs_out' exit $rs_exit stderr='$rs_err'"
    fi

    # ================================================================
    # F63: date -d should respect timezone offset in ISO 8601
    # ================================================================
    # parseIso8601 discards the Z suffix and +HH:MM offset, then uses
    # mktime which treats the time as local. Run in a non-UTC timezone
    # to expose the bug.
    echo -e "${CYAN}Testing -d with ISO 8601 timezone offsets (F63)...${NC}"

    # Z suffix should mean UTC; epoch for 2024-01-15T00:00:00Z = 1705276800
    local dz_cmd dz_out dz_err dz_exit
    run_command dz_cmd dz_out dz_err dz_exit \
        env TZ=America/New_York "$binary" -d "2024-01-15T00:00:00Z" -u "+%s"
    if [[ $dz_exit -eq 0 && "$dz_out" == "1705276800" ]]; then
        print_test_result "date -d ISO8601 Z suffix gives UTC epoch" "PASS"
    else
        print_test_result "date -d ISO8601 Z suffix gives UTC epoch" "FAIL" \
            "Expected '1705276800' exit 0, got '$dz_out' exit $dz_exit stderr='$dz_err'"
    fi

    # +05:30 offset: 2024-01-15T00:00:00+05:30 = UTC 2024-01-14T18:30:00 = 1705257000
    local d530_cmd d530_out d530_err d530_exit
    run_command d530_cmd d530_out d530_err d530_exit \
        env TZ=America/New_York "$binary" -d "2024-01-15T00:00:00+05:30" -u "+%s"
    if [[ $d530_exit -eq 0 && "$d530_out" == "1705257000" ]]; then
        print_test_result "date -d ISO8601 +05:30 offset" "PASS"
    else
        print_test_result "date -d ISO8601 +05:30 offset" "FAIL" \
            "Expected '1705257000' exit 0, got '$d530_out' exit $d530_exit stderr='$d530_err'"
    fi

    # -05:00 offset: 2024-01-15T00:00:00-05:00 = UTC 2024-01-15T05:00:00 = 1705294800
    # Use Asia/Kolkata (UTC+5:30) so that ignoring the offset gives the WRONG answer,
    # ensuring we test that the -05:00 offset is actually being parsed and applied.
    local dm5_cmd dm5_out dm5_err dm5_exit
    run_command dm5_cmd dm5_out dm5_err dm5_exit \
        env TZ=Asia/Kolkata "$binary" -d "2024-01-15T00:00:00-05:00" -u "+%s"
    if [[ $dm5_exit -eq 0 && "$dm5_out" == "1705294800" ]]; then
        print_test_result "date -d ISO8601 -05:00 offset" "PASS"
    else
        print_test_result "date -d ISO8601 -05:00 offset" "FAIL" \
            "Expected '1705294800' exit 0, got '$dm5_out' exit $dm5_exit stderr='$dm5_err'"
    fi

    # +00:00 should be equivalent to Z
    local d00_cmd d00_out d00_err d00_exit
    run_command d00_cmd d00_out d00_err d00_exit \
        env TZ=America/New_York "$binary" -d "2024-01-15T00:00:00+00:00" -u "+%s"
    if [[ $d00_exit -eq 0 && "$d00_out" == "1705276800" ]]; then
        print_test_result "date -d ISO8601 +00:00 same as Z" "PASS"
    else
        print_test_result "date -d ISO8601 +00:00 same as Z" "FAIL" \
            "Expected '1705276800' exit 0, got '$d00_out' exit $d00_exit stderr='$d00_err'"
    fi
}
