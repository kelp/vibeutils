#!/usr/bin/env bash
# Integration tests for free utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_free() {
    local util="free"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output...${NC}"

    # Default output should contain Mem: and Swap: lines
    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" =~ Mem: && "$output" =~ Swap: ]]; then
        print_test_result "free default output contains Mem: and Swap:" "PASS"
    else
        print_test_result "free default output contains Mem: and Swap:" "FAIL" \
            "Output: '$output'"
    fi

    # Header should contain expected columns
    if [[ "$output" =~ total && "$output" =~ used && "$output" =~ free ]]; then
        print_test_result "free header contains total/used/free" "PASS"
    else
        print_test_result "free header contains total/used/free" "FAIL" \
            "Output: '$output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "free --help shows usage" "PASS"
    else
        print_test_result "free --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ free ]]; then
        print_test_result "free --version shows version" "PASS"
    else
        print_test_result "free --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing unit flags...${NC}"

    # -b (bytes) exits 0
    test_command_exit_code "free -b exits 0" 0 "$binary" -b

    # -k (kibi) exits 0
    test_command_exit_code "free -k exits 0" 0 "$binary" -k

    # -m (mebi) exits 0
    test_command_exit_code "free -m exits 0" 0 "$binary" -m

    # -g (gibi) exits 0
    test_command_exit_code "free -g exits 0" 0 "$binary" -g

    # -h (human) exits 0
    test_command_exit_code "free -h exits 0" 0 "$binary" -h

    echo -e "${CYAN}Testing human readable output...${NC}"

    # -h should contain unit suffixes
    local human_output
    human_output=$("$binary" -h 2>/dev/null)
    if [[ "$human_output" =~ [KMGT]i || "$human_output" =~ [0-9]B ]]; then
        print_test_result "free -h shows unit suffixes" "PASS"
    else
        print_test_result "free -h shows unit suffixes" "FAIL" \
            "Output: '$human_output'"
    fi

    echo -e "${CYAN}Testing total flag...${NC}"

    # -t should add a Total: line
    local total_output
    total_output=$("$binary" -t 2>/dev/null)
    if [[ "$total_output" =~ Total: ]]; then
        print_test_result "free -t shows Total line" "PASS"
    else
        print_test_result "free -t shows Total line" "FAIL" \
            "Output: '$total_output'"
    fi

    echo -e "${CYAN}Testing wide flag...${NC}"

    # -w should show buffers and cache separately
    local wide_output
    wide_output=$("$binary" -w 2>/dev/null)
    if [[ "$wide_output" =~ buffers && "$wide_output" =~ cache ]]; then
        print_test_result "free -w shows buffers and cache" "PASS"
    else
        print_test_result "free -w shows buffers and cache" "FAIL" \
            "Output: '$wide_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 1
    test_command_exit_code "free invalid flag exits 1" 1 \
        "$binary" --invalid-flag

    echo -e "${CYAN}Testing audit findings (wave 4)...${NC}"

    # AUDIT: -w wide mode buffers column should show nonzero on Linux
    if [[ "$(uname)" == "Linux" ]]; then
        local wide_out
        wide_out=$("$binary" -w -b 2>/dev/null)
        # Extract the Mem: line
        local mem_line
        mem_line=$(echo "$wide_out" | grep "^Mem:")
        # Parse the 5th numeric column (buffers)
        local buffers_val
        buffers_val=$(echo "$mem_line" | awk '{print $6}')
        if [[ -n "$buffers_val" && "$buffers_val" -gt 0 ]] 2>/dev/null; then
            print_test_result "free -w shows nonzero buffers" "PASS"
        else
            print_test_result "free -w shows nonzero buffers" "FAIL" \
                "Buffers column is '$buffers_val', expected > 0. Line: '$mem_line'"
        fi
    fi

    # AUDIT: -c N works WITHOUT -s, with an implied 1-second interval.
    # procps-ng 4.0.4: `free -c 3` prints 3 reports, blank line between,
    # exit 0. `free -c 1` returns immediately; the interval is only paid
    # between reports. -c 2 costs ~1s, which is why it is not -c 3.
    local count_out
    count_out=$(run_with_limit 10 "$binary" -c 2 2>/dev/null)
    exit_code=$?
    local mem_lines
    mem_lines=$(echo "$count_out" | grep -c "^Mem:")
    if [[ $exit_code -eq 0 && $mem_lines -eq 2 ]]; then
        print_test_result "free -c 2 without -s prints 2 reports" "PASS"
    else
        print_test_result "free -c 2 without -s prints 2 reports" "FAIL" \
            "Expected exit 0 and 2 Mem: lines, got exit $exit_code and $mem_lines"
    fi

    # -c 1 must not sleep: one report, immediate exit.
    count_out=$(run_with_limit 10 "$binary" -c 1 2>/dev/null)
    exit_code=$?
    mem_lines=$(echo "$count_out" | grep -c "^Mem:")
    if [[ $exit_code -eq 0 && $mem_lines -eq 1 ]]; then
        print_test_result "free -c 1 prints exactly 1 report" "PASS"
    else
        print_test_result "free -c 1 prints exactly 1 report" "FAIL" \
            "Expected exit 0 and 1 Mem: line, got exit $exit_code and $mem_lines"
    fi

    # A count of zero is an error, never an unbounded loop. procps:
    # "free: failed to parse count argument: '0': Numerical result out of
    # range", exit 1. run_with_limit bounds the run so a regression that
    # loops forever fails instead of hanging the suite.
    local zero_out
    zero_out=$(run_with_limit 5 "$binary" -c 0 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 1 && -z "$zero_out" ]]; then
        print_test_result "free -c 0 exits 1 without printing" "PASS"
    else
        print_test_result "free -c 0 exits 1 without printing" "FAIL" \
            "Expected exit 1 and empty stdout, got exit $exit_code, stdout '$zero_out'"
    fi

    # Same for an explicit interval: -s 1 -c 0 must not loop forever.
    zero_out=$(run_with_limit 5 "$binary" -s 1 -c 0 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        print_test_result "free -s 1 -c 0 exits 1 instead of looping" "PASS"
    else
        print_test_result "free -s 1 -c 0 exits 1 instead of looping" "FAIL" \
            "Expected exit 1, got: $exit_code"
    fi

    # A non-numeric or negative count is rejected, exit 1, nothing on stdout.
    local bad_out
    for bad in abc -1; do
        bad_out=$(run_with_limit 5 "$binary" -c "$bad" 2>/dev/null)
        exit_code=$?
        if [[ $exit_code -eq 1 && -z "$bad_out" ]]; then
            print_test_result "free -c $bad exits 1 without printing" "PASS"
        else
            print_test_result "free -c $bad exits 1 without printing" "FAIL" \
                "Expected exit 1 and empty stdout, got exit $exit_code, stdout '$bad_out'"
        fi
    done

    # --help must not repeat the retired "-c requires -s" constraint.
    local count_help
    count_help=$("$binary" --help 2>/dev/null)
    if [[ "$count_help" != *"used with -s"* && "$count_help" != *"requires -s"* ]]; then
        print_test_result "free --help does not tie -c to -s" "PASS"
    else
        print_test_result "free --help does not tie -c to -s" "FAIL" \
            "Help still documents -c as requiring -s: '$count_help'"
    fi

    # AUDIT: -s should set seconds interval, not SI mode
    # free -s 1 -c 1 should succeed (continuous mode, 1 iteration).
    # Wrap in run_with_limit because macOS CI has no GNU timeout(1).
    run_with_limit 5 "$binary" -s 1 -c 1 >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_test_result "free -s 1 -c 1 sets seconds interval" "PASS"
    else
        print_test_result "free -s 1 -c 1 sets seconds interval" "FAIL" \
            "Expected exit 0, got: $exit_code"
    fi

    echo -e "${CYAN}Testing --color and --bar flags...${NC}"

    local color_help
    color_help=$("$binary" --help 2>/dev/null)
    if [[ "$color_help" == *"--color=WHEN"* && "$color_help" == *"--bar=WHEN"* ]]; then
        print_test_result "free --help lists --color=WHEN and --bar=WHEN" "PASS"
    else
        print_test_result "free --help lists --color=WHEN and --bar=WHEN" "FAIL" \
            "Help missing --color=WHEN/--bar=WHEN"
    fi

    # --color=always emits CSI; a default pipe does not. Scrub ambient
    # NO_COLOR and pin a capable TERM: this VM exports TERM=dumb, which
    # must still kill color even with --color=always (unit test 5b).
    local always_out default_out
    always_out=$(env -u NO_COLOR TERM=xterm-256color "$binary" --color=always 2>/dev/null)
    default_out=$("$binary" 2>/dev/null)
    if [[ "$always_out" == *$'\033'* && "$default_out" != *$'\033'* ]]; then
        print_test_result "free --color=always emits CSI; default pipe does not" "PASS"
    else
        print_test_result "free --color=always emits CSI; default pipe does not" "FAIL" \
            "always missing ESC or default pipe leaked ESC"
    fi

    # NO_COLOR wins over --color=always even with a capable TERM (ls guard).
    local nocolor_out
    nocolor_out=$(NO_COLOR=1 TERM=xterm-256color "$binary" --color=always 2>/dev/null)
    if [[ "$nocolor_out" != *$'\033'* ]]; then
        print_test_result "free NO_COLOR overrides --color=always" "PASS"
    else
        print_test_result "free NO_COLOR overrides --color=always" "FAIL" \
            "Found ESC despite NO_COLOR=1"
    fi

    # --bar=always emits U+2588/U+2591 through a pipe; default pipe does not.
    local bar_out
    bar_out=$("$binary" --bar=always 2>/dev/null)
    if [[ "$bar_out" == *$'\xe2\x96\x88'* || "$bar_out" == *$'\xe2\x96\x91'* ]]; then
        if [[ "$default_out" != *$'\xe2\x96\x88'* && "$default_out" != *$'\xe2\x96\x91'* ]]; then
            print_test_result "free --bar=always emits bar bytes through a pipe" "PASS"
        else
            print_test_result "free --bar=always emits bar bytes through a pipe" "FAIL" \
                "Default pipe also contained bar glyphs"
        fi
    else
        print_test_result "free --bar=always emits bar bytes through a pipe" "FAIL" \
            "No U+2588/U+2591 in --bar=always output"
    fi

    # Empty --color= / --bar= is valid argparse and still an invalid WHEN.
    # Must exit 1 (not panic / SIGABRT).
    local empty_color_rc empty_bar_rc
    "$binary" --color= >/dev/null 2>&1
    empty_color_rc=$?
    "$binary" --bar= >/dev/null 2>&1
    empty_bar_rc=$?
    if [[ $empty_color_rc -eq 1 && $empty_bar_rc -eq 1 ]]; then
        print_test_result "free --color= and --bar= empty WHEN exit 1" "PASS"
    else
        print_test_result "free --color= and --bar= empty WHEN exit 1" "FAIL" \
            "Expected exit 1 (no panic), got --color=$empty_color_rc --bar=$empty_bar_rc"
    fi
}
