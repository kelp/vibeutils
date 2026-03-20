#!/usr/bin/env bash
# Help text consistency validation for all utilities
#
# Checks that --help output follows project conventions:
# - Starts with "Usage:"
# - No bare "Options:" header (semantic headers are fine)
# - Contains standard --help and --version descriptions
# - Flag descriptions start lowercase
# - No contractions
# - No footer lines

test_help_consistency() {
    local util binary help_output

    for binary in "$BIN_DIR"/*; do
        [[ -f "$binary" && -x "$binary" ]] || continue
        util=$(basename "$binary")

        # Skip utilities without standard --help
        case "$util" in
            true|false|test|\[) continue ;;
        esac

        # Capture help output
        help_output=$("$binary" --help 2>&1) || true

        # Check 1: starts with Usage:
        local first_line
        first_line=$(echo "$help_output" | head -n 1)
        if [[ "$first_line" == Usage:* ]]; then
            print_test_result "$util --help starts with Usage:" "PASS"
        else
            print_test_result "$util --help starts with Usage:" "FAIL" \
                "First line: '$first_line'"
        fi

        # Check 2: no bare "Options:" header
        if echo "$help_output" | grep -qx 'Options:'; then
            print_test_result "$util --help no bare Options: header" "FAIL" \
                "Found bare 'Options:' line; use a semantic header instead"
        else
            print_test_result "$util --help no bare Options: header" "PASS"
        fi

        # Check 3: standard --help line
        if echo "$help_output" | grep -qi 'display this help and exit'; then
            print_test_result "$util --help has standard help description" "PASS"
        else
            print_test_result "$util --help has standard help description" "FAIL" \
                "Missing 'display this help and exit'"
        fi

        # Check 4: standard --version line
        if echo "$help_output" | grep -qi 'output version information and exit'; then
            print_test_result "$util --help has standard version description" "PASS"
        else
            print_test_result "$util --help has standard version description" "FAIL" \
                "Missing 'output version information and exit'"
        fi

        # Check 5: lowercase descriptions on flag lines
        # Flag lines look like: "  -f, --force              force the op"
        # We match lines starting with 2+ spaces then a dash.
        local uppercase_flags=""
        while IFS= read -r line; do
            # Extract the description: text after 2+ consecutive spaces
            # following the flag/value portion. The flag portion is the
            # first token group; the description starts after a gap of
            # 2+ spaces.
            local desc
            desc=$(echo "$line" | sed -n 's/^  \+-[^ ]*\(  *[^ ]\+\)*  \{2,\}\(.\)/\2/p')
            if [[ -n "$desc" ]]; then
                # Check if first character is uppercase A-Z
                if [[ "$desc" =~ ^[A-Z] ]]; then
                    uppercase_flags="${uppercase_flags}${line}"$'\n'
                fi
            fi
        done < <(echo "$help_output" | grep -E '^  +-.')

        if [[ -z "$uppercase_flags" ]]; then
            print_test_result "$util --help flag descriptions lowercase" "PASS"
        else
            # Show just the first offending line
            local first_bad
            first_bad=$(echo "$uppercase_flags" | head -n 1)
            print_test_result "$util --help flag descriptions lowercase" "FAIL" \
                "Uppercase description: '$(echo "$first_bad" | sed 's/^ *//')'"
        fi

        # Check 6: no contractions
        local contractions="don't|won't|can't|isn't|doesn't|shouldn't|wouldn't|couldn't|aren't|hasn't|haven't"
        if echo "$help_output" | grep -qiE "$contractions"; then
            local found
            found=$(echo "$help_output" | grep -oiE "$contractions" | head -n 1)
            print_test_result "$util --help no contractions" "FAIL" \
                "Found contraction: '$found'"
        else
            print_test_result "$util --help no contractions" "PASS"
        fi

        # Check 7: no footer lines
        local has_footer=""
        if echo "$help_output" | grep -q '^Report bugs to'; then
            has_footer="Found 'Report bugs to' line"
        fi
        if echo "$help_output" | grep -q '^Home page:'; then
            has_footer="${has_footer:+$has_footer; }Found 'Home page:' line"
        fi

        if [[ -z "$has_footer" ]]; then
            print_test_result "$util --help no footer lines" "PASS"
        else
            print_test_result "$util --help no footer lines" "FAIL" \
                "$has_footer"
        fi
    done
}
