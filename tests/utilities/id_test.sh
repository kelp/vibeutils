#!/usr/bin/env bash
# Integration tests for id utility
# Tests output correctness, flags, and error conditions

# This file is sourced by test_runner.sh, so common.sh is already loaded

test_id() {
    local util="id"
    local binary="$BIN_DIR/$util"

    # Verify binary exists
    test_binary_exists "$util" || return 1

    # Test basic flags
    test_basic_flags "$util"

    echo -e "${CYAN}Testing default output format...${NC}"

    # Default output should contain uid=, gid=, groups=
    local output
    output=$("$binary" 2>/dev/null)
    if [[ "$output" =~ uid=[0-9]+ && "$output" =~ gid=[0-9]+ && "$output" =~ groups= ]]; then
        print_test_result "id default output format" "PASS"
    else
        print_test_result "id default output format" "FAIL" \
            "Expected uid=N(...) gid=N(...) groups=..., got '$output'"
    fi

    echo -e "${CYAN}Testing -u flag...${NC}"

    # -u should print only the numeric user ID
    local uid_output
    uid_output=$("$binary" -u 2>/dev/null)
    local uid_exit=$?
    if [[ $uid_exit -eq 0 && "$uid_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -u prints numeric user ID" "PASS"
    else
        print_test_result "id -u prints numeric user ID" "FAIL" \
            "Exit code: $uid_exit, output: '$uid_output'"
    fi

    echo -e "${CYAN}Testing -g flag...${NC}"

    # -g should print only the numeric group ID
    local gid_output
    gid_output=$("$binary" -g 2>/dev/null)
    local gid_exit=$?
    if [[ $gid_exit -eq 0 && "$gid_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -g prints numeric group ID" "PASS"
    else
        print_test_result "id -g prints numeric group ID" "FAIL" \
            "Exit code: $gid_exit, output: '$gid_output'"
    fi

    echo -e "${CYAN}Testing -G flag...${NC}"

    # -G should print space-separated group IDs
    local groups_output
    groups_output=$("$binary" -G 2>/dev/null)
    local groups_exit=$?
    if [[ $groups_exit -eq 0 && "$groups_output" =~ ^[0-9] ]]; then
        print_test_result "id -G prints group IDs" "PASS"
    else
        print_test_result "id -G prints group IDs" "FAIL" \
            "Exit code: $groups_exit, output: '$groups_output'"
    fi

    echo -e "${CYAN}Testing -un flag...${NC}"

    # -un should print the effective username
    local un_output
    un_output=$("$binary" -un 2>/dev/null)
    local un_exit=$?
    local expected_user
    expected_user=$(whoami)
    if [[ $un_exit -eq 0 && "$un_output" == "$expected_user" ]]; then
        print_test_result "id -un matches whoami" "PASS"
    else
        print_test_result "id -un matches whoami" "FAIL" \
            "Expected '$expected_user', got '$un_output'"
    fi

    echo -e "${CYAN}Testing --help flag...${NC}"

    # --help shows usage and exits 0
    local help_output
    help_output=$("$binary" --help 2>/dev/null)
    local help_exit=$?
    if [[ $help_exit -eq 0 && "$help_output" =~ [Uu]sage ]]; then
        print_test_result "id --help shows usage" "PASS"
    else
        print_test_result "id --help shows usage" "FAIL" \
            "Exit code: $help_exit, output: '$help_output'"
    fi

    echo -e "${CYAN}Testing --version flag...${NC}"

    # --version shows version and exits 0
    local version_output
    version_output=$("$binary" --version 2>/dev/null)
    local version_exit=$?
    if [[ $version_exit -eq 0 && "$version_output" =~ id ]]; then
        print_test_result "id --version shows version" "PASS"
    else
        print_test_result "id --version shows version" "FAIL" \
            "Exit code: $version_exit, output: '$version_output'"
    fi

    echo -e "${CYAN}Testing error conditions...${NC}"

    # Invalid flag exits with code 2
    test_command_exit_code "id invalid flag exits 2" 2 \
        "$binary" --invalid-flag

    # -n without -u/-g/-G exits with code 2
    test_command_exit_code "id -n alone exits 2" 2 \
        "$binary" -n

    # Nonexistent user exits with code 1
    test_command_exit_code "id nonexistent user exits 1" 1 \
        "$binary" nonexistent_user_12345

    echo -e "${CYAN}Testing -G with named user (F47)...${NC}"

    # F47: `id -G <user>` uses getgrouplist(3) and returns all groups the
    # user belongs to. `id -G` with no argument uses getgroups(2) which
    # returns only the groups currently in the process credential set.
    # On macOS these can differ because the kernel caps getgroups() at
    # NGROUPS_MAX (16 by default), while getgrouplist() is uncapped.
    # On Linux NGROUPS_MAX is typically large enough that the two match.
    # The invariant we can assert cross-platform: every group returned
    # by `id -G` must also appear in `id -G <user>` (the named form is
    # a superset of the credential-set form).
    local groups_no_user groups_named
    groups_no_user=$("$binary" -G 2>/dev/null)
    groups_named=$("$binary" -G "$(whoami)" 2>/dev/null)
    local missing_gids=""
    for g in $groups_no_user; do
        if ! echo " $groups_named " | grep -qF " $g "; then
            missing_gids="$missing_gids $g"
        fi
    done
    if [[ -n "$groups_no_user" && -n "$groups_named" && -z "$missing_gids" ]]; then
        print_test_result "id -G <user> is superset of id -G" "PASS"
    else
        print_test_result "id -G <user> is superset of id -G" "FAIL" \
            "missing gids:$missing_gids; id -G='$groups_no_user'; id -G \$(whoami)='$groups_named'"
    fi

    # F47: same superset property for group names.
    local gn_no_user gn_named
    gn_no_user=$("$binary" -Gn 2>/dev/null)
    gn_named=$("$binary" -Gn "$(whoami)" 2>/dev/null)
    local missing_names=""
    for g in $gn_no_user; do
        if ! echo " $gn_named " | grep -qF " $g "; then
            missing_names="$missing_names $g"
        fi
    done
    if [[ -n "$gn_no_user" && -n "$gn_named" && -z "$missing_names" ]]; then
        print_test_result "id -Gn <user> is superset of id -Gn" "PASS"
    else
        print_test_result "id -Gn <user> is superset of id -Gn" "FAIL" \
            "missing names:$missing_names; id -Gn='$gn_no_user'; id -Gn \$(whoami)='$gn_named'"
    fi

    echo -e "${CYAN}Testing regression fixes...${NC}"

    # Regression: id -g should print numeric GID
    # (Safety net after dead parameter removal)
    local reg_gid_output
    reg_gid_output=$("$binary" -g 2>/dev/null)
    if [[ "$reg_gid_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -g numeric GID (regression)" "PASS"
    else
        print_test_result "id -g numeric GID (regression)" "FAIL" \
            "Expected numeric GID, got '$reg_gid_output'"
    fi

    # Regression: id -gn should print group name (non-numeric string)
    local reg_gn_output
    reg_gn_output=$("$binary" -gn 2>/dev/null)
    local reg_gn_exit=$?
    if [[ $reg_gn_exit -eq 0 && -n "$reg_gn_output" && ! "$reg_gn_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -gn group name (regression)" "PASS"
    else
        print_test_result "id -gn group name (regression)" "FAIL" \
            "Exit code: $reg_gn_exit, output: '$reg_gn_output'"
    fi

    echo -e "${CYAN}Testing audit findings (wave 5)...${NC}"

    # Audit: id -z alone should be rejected (GNU rejects without -u/-g/-G)
    "$binary" -z >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        print_test_result "id -z alone exits 2 (GNU rejects)" "PASS"
    else
        print_test_result "id -z alone exits 2 (GNU rejects)" "FAIL" \
            "Expected exit 2, got $exit_code"
    fi

    # Audit: id -a should be a no-op (GNU ignores it in default format)
    local default_output a_output
    default_output=$("$binary" 2>/dev/null)
    a_output=$("$binary" -a 2>/dev/null)
    if [[ "$a_output" == *"uid="* ]]; then
        print_test_result "id -a produces default format (no-op)" "PASS"
    else
        print_test_result "id -a produces default format (no-op)" "FAIL" \
            "Expected uid=... format, got '$a_output'"
    fi

    echo -e "${CYAN}Testing -r flag (real IDs)...${NC}"

    # -r -u should print the real UID (numeric)
    local ru_output ru_exit
    ru_output=$("$binary" -r -u 2>/dev/null)
    ru_exit=$?
    if [[ $ru_exit -eq 0 && "$ru_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -r -u prints numeric real UID" "PASS"
    else
        print_test_result "id -r -u prints numeric real UID" "FAIL" \
            "Exit code: $ru_exit, output: '$ru_output'"
    fi

    # -r -g should print the real GID (numeric)
    local rg_output rg_exit
    rg_output=$("$binary" -r -g 2>/dev/null)
    rg_exit=$?
    if [[ $rg_exit -eq 0 && "$rg_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -r -g prints numeric real GID" "PASS"
    else
        print_test_result "id -r -g prints numeric real GID" "FAIL" \
            "Exit code: $rg_exit, output: '$rg_output'"
    fi

    # -r -u -n should print the real username (non-numeric)
    local run_output run_exit
    run_output=$("$binary" -r -u -n 2>/dev/null)
    run_exit=$?
    if [[ $run_exit -eq 0 && -n "$run_output" && ! "$run_output" =~ ^[0-9]+$ ]]; then
        print_test_result "id -r -u -n prints real username" "PASS"
    else
        print_test_result "id -r -u -n prints real username" "FAIL" \
            "Exit code: $run_exit, output: '$run_output'"
    fi

    # -r -u should match the system real UID
    local sys_ruid
    sys_ruid=$(id -r -u 2>/dev/null || /usr/bin/id -r -u 2>/dev/null)
    if [[ -n "$sys_ruid" && "$ru_output" == "$sys_ruid" ]]; then
        print_test_result "id -r -u matches system real UID" "PASS"
    else
        print_test_result "id -r -u matches system real UID" "FAIL" \
            "Expected '$sys_ruid', got '$ru_output'"
    fi

    echo -e "${CYAN}Testing -p flag (pretty format)...${NC}"

    # -p should output uid and groups labels on separate lines
    local p_output p_exit
    p_output=$("$binary" -p 2>/dev/null)
    p_exit=$?
    if [[ $p_exit -eq 0 && "$p_output" == *$'uid\t'* && "$p_output" == *$'groups\t'* ]]; then
        print_test_result "id -p shows uid and groups labels" "PASS"
    else
        print_test_result "id -p shows uid and groups labels" "FAIL" \
            "Exit code: $p_exit, output: '$p_output'"
    fi

    # -p should NOT contain uid= (default format leak)
    if [[ $p_exit -eq 0 && "$p_output" != *"uid="* ]]; then
        print_test_result "id -p does not leak default format" "PASS"
    else
        print_test_result "id -p does not leak default format" "FAIL" \
            "Output contains 'uid=': '$p_output'"
    fi

    echo -e "${CYAN}Testing -F flag (full name / GECOS)...${NC}"

    # -F prints the passwd GECOS field for the current user. That field is
    # legitimately EMPTY for many service/CI accounts (e.g. the GitHub
    # Actions `runner` user), so do not assume it is non-empty. Where an
    # authoritative source exists (getent on Linux), assert id -F
    # reproduces it exactly; otherwise (macOS has no getent) fall back to
    # the non-empty expectation, which holds for normal interactive users.
    local f_output f_exit
    f_output=$("$binary" -F 2>/dev/null)
    f_exit=$?
    if command -v getent >/dev/null 2>&1; then
        local expected_gecos
        expected_gecos=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f5)
        if [[ $f_exit -eq 0 && "$f_output" == "$expected_gecos" ]]; then
            print_test_result "id -F prints GECOS field" "PASS"
        else
            print_test_result "id -F prints GECOS field" "FAIL" \
                "Exit: $f_exit, output: '$f_output', expected: '$expected_gecos'"
        fi
    elif [[ $f_exit -eq 0 && -n "$f_output" ]]; then
        print_test_result "id -F prints GECOS field" "PASS"
    else
        print_test_result "id -F prints GECOS field" "FAIL" \
            "Exit code: $f_exit, output: '$f_output'"
    fi

    # -F for root should produce a non-empty string
    local f_root_output f_root_exit
    f_root_output=$("$binary" -F root 2>/dev/null)
    f_root_exit=$?
    if [[ $f_root_exit -eq 0 ]]; then
        print_test_result "id -F root succeeds" "PASS"
    else
        print_test_result "id -F root succeeds" "FAIL" \
            "Exit code: $f_root_exit, output: '$f_root_output'"
    fi

    echo -e "${CYAN}Testing -P flag (passwd entry)...${NC}"

    # -P should output colon-delimited passwd format
    local p_entry_output p_entry_exit
    p_entry_output=$("$binary" -P 2>/dev/null)
    p_entry_exit=$?
    local colon_count
    colon_count=$(echo "$p_entry_output" | tr -cd ':' | wc -c)
    if [[ $p_entry_exit -eq 0 && $colon_count -ge 6 ]]; then
        print_test_result "id -P outputs colon-delimited format" "PASS"
    else
        print_test_result "id -P outputs colon-delimited format" "FAIL" \
            "Exit: $p_entry_exit, colons: $colon_count, output: '$p_entry_output'"
    fi

    # -P output should start with current username
    local cur_user
    cur_user=$(whoami)
    if [[ "$p_entry_output" == "$cur_user:"* ]]; then
        print_test_result "id -P starts with current username" "PASS"
    else
        print_test_result "id -P starts with current username" "FAIL" \
            "Expected to start with '$cur_user:', got '$p_entry_output'"
    fi

    # -P root should contain uid 0
    local p_root_output p_root_exit
    p_root_output=$("$binary" -P root 2>/dev/null)
    p_root_exit=$?
    # Extract third colon-delimited field (UID)
    local p_root_uid
    p_root_uid=$(echo "$p_root_output" | cut -d: -f3)
    if [[ $p_root_exit -eq 0 && "$p_root_uid" == "0" ]]; then
        print_test_result "id -P root shows uid=0" "PASS"
    else
        print_test_result "id -P root shows uid=0" "FAIL" \
            "Exit: $p_root_exit, uid field: '$p_root_uid', output: '$p_root_output'"
    fi

    echo -e "${CYAN}Testing -Gn flag (group names)...${NC}"

    # -Gn should output only group names (no pure-numeric tokens)
    local gn_output gn_exit
    gn_output=$("$binary" -Gn 2>/dev/null)
    gn_exit=$?
    local has_numeric=false
    for token in $gn_output; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            has_numeric=true
            break
        fi
    done
    if [[ $gn_exit -eq 0 && -n "$gn_output" && "$has_numeric" == "false" ]]; then
        print_test_result "id -Gn outputs only group names" "PASS"
    else
        print_test_result "id -Gn outputs only group names" "FAIL" \
            "Exit: $gn_exit, has_numeric: $has_numeric, output: '$gn_output'"
    fi

    # -Gn word count should match -G word count
    local g_output g_count gn_count
    g_output=$("$binary" -G 2>/dev/null)
    g_count=$(echo "$g_output" | wc -w | tr -d ' ')
    gn_count=$(echo "$gn_output" | wc -w | tr -d ' ')
    if [[ "$g_count" == "$gn_count" ]]; then
        print_test_result "id -Gn count matches id -G count" "PASS"
    else
        print_test_result "id -Gn count matches id -G count" "FAIL" \
            "-G has $g_count groups, -Gn has $gn_count names"
    fi
}
