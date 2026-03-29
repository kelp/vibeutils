# Integration Test Audit: ln

**Date**: 2026-03-28
**Test file**: tests/utilities/ln_test.sh
**Run result**: 57 tests, 57 passed, 0 failed, 0 skipped
(1 conditional SKIP on Linux for `-P` when unprivileged)

## Executive Summary

NEEDS_FIXES

All 57 tests pass and the core coverage is solid: hard links,
symbolic links, `-f`, `-v`, `-n`, `-L`, `-P`, `-b`, inode
verification, dangling symlinks, multi-target, and error
conditions are all exercised with behavioral checks.

However, six SHOULD-tier flags from the flag table have zero
integration tests: `-i`, `-w`, `-F`, `-r`, `-t`, and `-T`.
Two of the `-v` verbose tests accept any `=>` or `->` match
without checking which stream the output appeared on, so a
binary that wrote verbose text to stderr would pass. The `-n`
behavioral test only verifies that a link was created, not
that `-n` actually suppressed dereference.

---

## Test Inventory

| Test Name (abbreviated) | Verification Type | Verdict |
|-------------------------|-------------------|---------|
| ln binary exists | binary check | STRONG |
| ln --help / --version | exit-code | STRONG |
| ln hard link | exit-code | WEAK |
| ln hard link content | file content read | STRONG |
| ln hard link inode match | inode comparison | STRONG |
| ln -s symbolic link | exit-code | WEAK |
| ln -s creates symlink | `-L` test | STRONG |
| ln -s symlink content | file content read | STRONG |
| ln --symbolic | exit-code | WEAK |
| ln --symbolic creates symlink | `-L` test | STRONG |
| ln -s dangling symlink | exit-code | WEAK |
| ln -s dangling symlink created | `-L` test | STRONG |
| ln -f force hard link | exit-code | WEAK |
| ln -f overwrites existing | file content read | STRONG |
| ln -sf force symbolic link | exit-code | WEAK |
| ln -sf creates symlink | `-L` test | STRONG |
| ln --force | exit-code | WEAK |
| ln --force overwrites existing | file content read | STRONG |
| ln without force to existing | exit-code 1 | MODERATE |
| ln without force preserves existing | file content read | STRONG |
| ln -v hard link output | exit-code + stdout pattern | MODERATE |
| ln -sv symbolic link output | exit-code + stdout pattern | MODERATE |
| ln --verbose output | exit-code + stdout pattern | MODERATE |
| ln multiple targets to directory | exit-code | WEAK |
| ln multi target 1/2/3 created | `-f` existence check | MODERATE |
| ln multi target 1 content | file content read | STRONG |
| ln -s multiple targets to dir | exit-code | WEAK |
| ln -s multi target 1/2 is symlink | `-L` test | STRONG |
| ln nonexistent target | exit-code 1 | WEAK |
| ln nonexistent target no link created | `! -e` check | STRONG |
| ln no arguments | exit-code 2 | WEAK |
| ln invalid flag | exit-code 2 | WEAK |
| ln multiple targets to non-dir | exit-code 1 | WEAK |
| ln error message format | stderr pattern | STRONG |
| ln file exists error message | stderr pattern | STRONG |
| ln -sfn replaces symlink | exit-code | WEAK |
| ln -sfn result is symlink | `-L` test | STRONG |
| ln -n flag accepted | exit-code | WEAK |
| ln -n creates symlink | `-L` test | MODERATE |
| ln --no-dereference accepted | exit-code | WEAK |
| ln --no-dereference creates symlink | `-L` test | MODERATE |
| ln -L follows symlink | exit-code | WEAK |
| ln -L hard link matches target inode | inode comparison | STRONG |
| ln -L creates hard link not symlink | `! -L` test | STRONG |
| ln -P links to symlink itself (macOS) | exit-code + inode | STRONG |
| ln -P hard link matches symlink inode | inode comparison | STRONG |
| ln -P result is symlink | `-L` test | STRONG |
| ln -P on Linux (requires privileges) | SKIP | — |
| ln -sfv combination | exit-code + stdout + `-L` | STRONG |
| ln POSIX success exit code | exit-code | WEAK |
| ln POSIX failure exit code | exit-code | WEAK |
| ln -sb creates backup and new link | exit-code | WEAK |
| ln -sb backup file created | `-e/-L` existence | MODERATE |
| ln -sb new symlink created | `-L` test | STRONG |
| ln readable error message (regression) | stderr pattern | STRONG |

---

## Weak Tests

### [IMPORTANT] `-v` output tests do not verify stream — lines 222, 237, 252

All three verbose tests use `run_command` and check
`$verb_out =~ "=>"` or `$verb_sym_out =~ "->"`. This
captures only stdout. If the implementation writes verbose
output to stderr instead of stdout, all three tests pass.
GNU `ln -v` writes to stdout.

**Fix**: Assert the stream explicitly and confirm stderr is
empty:

```bash
if [[ $verb_exit -eq 0 && "$verb_out" =~ "=>" \
      && -z "$verb_err" ]]; then
    print_test_result "ln -v hard link output on stdout" "PASS"
else
    print_test_result "ln -v hard link output on stdout" "FAIL" \
        "stdout: $verb_out  stderr: $verb_err"
fi
```

### [IMPORTANT] `-n` / `--no-dereference` tests do not verify dereference
suppression — lines 399-434

The three `-n` tests verify only that a symlink was created.
They do not confirm the defining behavior of `-n`: when the
destination is itself a symlink to a directory, `-n` prevents
following that symlink (treating the symlink itself as the
destination rather than the directory it points to).

The `-sfn` test (lines 396-421) exercises one scenario — it
replaces a symlink pointing to a file — which is good but
only partial. Neither test covers the case where the
destination symlink points to a directory.

**Fix**: Add a test that sets the destination to a symlink
pointing to a directory and confirms that `-sfn` replaces
the symlink rather than creating a new link inside the
directory:

```bash
local n_dir=$(create_temp_dir)
local n_dest="$TEMP_DIR/n_dest_sym"
ln -s "$n_dir" "$n_dest"
local n_src=$(create_temp_file "n flag content")

test_command_exit_code "ln -sfn dest is symlink to dir" 0 \
    "$binary" -sfn "$n_src" "$n_dest"

# n_dest should now point to n_src, not be inside n_dir
if [[ -L "$n_dest" ]]; then
    local n_target
    n_target=$(readlink "$n_dest")
    if [[ "$n_target" == "$n_src" ]]; then
        print_test_result \
            "ln -sfn replaces symlink-to-dir not dir entry" "PASS"
    else
        print_test_result \
            "ln -sfn replaces symlink-to-dir not dir entry" "FAIL" \
            "Symlink points to: $n_target"
    fi
else
    print_test_result \
        "ln -sfn dest is still a symlink" "FAIL" \
        "Expected symlink, got non-symlink"
fi
# Verify nothing was created inside n_dir
if [[ -z "$(ls -A "$n_dir")" ]]; then
    print_test_result "ln -sfn did not enter target dir" "PASS"
else
    print_test_result "ln -sfn did not enter target dir" "FAIL"
fi
```

### [IMPORTANT] `-b` backup test does not verify backup content — lines 571-590

The `-sb` test only checks that `${backup_link}~` exists and
that `$backup_link` is still a symlink. It does not read the
backup file's content or verify that the new symlink points
to the expected target. A backup file created with wrong
content or an empty file would pass.

**Fix**: Add content verification for both the backup and
the new link:

```bash
# Verify backup preserves the original symlink target
local backup_orig_target
backup_orig_target=$(readlink "${backup_link}~")
if [[ "$backup_orig_target" == "/some/original/target" ]]; then
    print_test_result "ln -sb backup has original target" "PASS"
else
    print_test_result "ln -sb backup has original target" "FAIL" \
        "backup target: $backup_orig_target"
fi

# Verify new link points to backup_target
local new_link_target
new_link_target=$(readlink "$backup_link")
if [[ "$new_link_target" == "$backup_target" ]]; then
    print_test_result "ln -sb new link points to source" "PASS"
else
    print_test_result "ln -sb new link points to source" "FAIL" \
        "new link target: $new_link_target"
fi
```

### [SUGGESTION] Exit-code-only tests for errors — lines 331-357

Five tests use `test_command_exit_code` for error conditions
(`ln nonexistent target`, `ln no arguments`, `ln invalid
flag`, `ln multiple targets to non-dir`) without checking
that a useful error message appeared on stderr. A silent
non-zero exit would pass all of them.

The "ln error message format" and "ln file exists error
message" tests (lines 358-387) are already strong — these
specific coverage gaps apply only to the `test_command_exit_code`-only
error tests listed above.

---

## Missing Coverage

| Flag | Tier | Has Integration Test? | Strength |
|------|------|-----------------------|---------|
| -f | MUST | Yes (content read) | STRONG |
| -L | MUST | Yes (inode match) | STRONG |
| -P | MUST | Yes (inode match, platform-gated) | STRONG |
| -s | MUST | Yes (content + `-L` + inode) | STRONG |
| -h | MUST | Yes (via -sfn test, partial) | MODERATE |
| -n | MUST | Yes but symlink-to-dir case missing | MODERATE |
| -i | SHOULD | **No** | — |
| -v | SHOULD | Yes but stream not verified | MODERATE |
| -F | SHOULD | **No** | — |
| -w | SHOULD | **No** | — |
| -b | SHOULD | Yes but content not verified | WEAK |
| -r | SHOULD | **No** | — |
| -t | SHOULD | **No** | — |
| -T | SHOULD | **No** | — |
| --backup | SHOULD | Covered by -b test | WEAK |

### `-i` interactive flag (SHOULD)

No test exercises `-i`. The defining behavior is that when
the destination exists, `ln -i` writes a prompt to stderr
and reads a response from stdin. If the response begins with
`y` or `Y`, the destination is unlinked and the link is
created; otherwise the link is skipped.

**Missing tests**:

```bash
echo -e "${CYAN}Testing interactive flag (-i)...${NC}"

# -i with empty stdin: link should not be created
local i_target=$(create_temp_file "interactive target")
local i_existing=$(create_temp_file "interactive existing")
"$binary" -i "$i_target" "$i_existing" </dev/null >/dev/null 2>&1 || true
local i_content
i_content=$(cat "$i_existing")
if [[ "$i_content" == "interactive existing" ]]; then
    print_test_result "ln -i empty stdin preserves existing" "PASS"
else
    print_test_result "ln -i empty stdin preserves existing" "FAIL" \
        "Existing file was modified"
fi

# -i with 'y' on stdin: link should be created
local iy_target=$(create_temp_file "interactive y target")
local iy_existing=$(create_temp_file "interactive y existing")
echo "y" | "$binary" -i "$iy_target" "$iy_existing" >/dev/null 2>&1
local iy_content
iy_content=$(cat "$iy_existing")
if [[ "$iy_content" == "interactive y target" ]]; then
    print_test_result "ln -i y response creates link" "PASS"
else
    print_test_result "ln -i y response creates link" "FAIL" \
        "Expected 'interactive y target', got '$iy_content'"
fi

# -i emits prompt to stderr
local i_prompt_err=""
local i_prompt_out=""
local i_prompt_exit=""
run_command i_prompt_cmd i_prompt_out i_prompt_err i_prompt_exit \
    "$binary" -i "$i_target" "$iy_existing" </dev/null
if [[ "$i_prompt_err" =~ "overwrite" \
      || "$i_prompt_err" =~ "replace" \
      || "$i_prompt_err" =~ "?" ]]; then
    print_test_result "ln -i prompt on stderr" "PASS"
else
    print_test_result "ln -i prompt on stderr" "FAIL" \
        "stderr: $i_prompt_err"
fi
```

### `-w` warn on nonexistent symlink source (SHOULD)

`-w` should write a warning to stderr when creating a
symbolic link whose source does not currently exist (a
dangling symlink). The link should still be created.

**Missing test**:

```bash
echo -e "${CYAN}Testing warn flag (-w)...${NC}"

local w_link="$TEMP_DIR/w_warn_link"
local w_out="" w_err="" w_exit=""
run_command w_cmd w_out w_err w_exit \
    "$binary" -sw "/nonexistent/warn/target" "$w_link"

# Link should be created despite the warning
if [[ -L "$w_link" ]]; then
    print_test_result "ln -w creates dangling symlink" "PASS"
else
    print_test_result "ln -w creates dangling symlink" "FAIL" \
        "Dangling symlink not created"
fi

# A warning should appear on stderr
if [[ -n "$w_err" ]]; then
    print_test_result "ln -w warning on stderr" "PASS"
else
    print_test_result "ln -w warning on stderr" "FAIL" \
        "Expected a warning on stderr, got none"
fi
```

### `-F` remove target directory (SHOULD)

`-F` removes an existing target directory so the link can
replace it. It is a no-op without `-s`. No test verifies
this end-to-end.

**Missing test**:

```bash
echo -e "${CYAN}Testing -F remove directory target...${NC}"

local F_dir=$(create_temp_dir)
local F_src=$(create_temp_file "F flag source")
local F_link="$TEMP_DIR/F_link"
cp -r "$F_dir" "$F_link"  # F_link is now a directory

test_command_exit_code "ln -sF replaces directory" 0 \
    "$binary" -sF "$F_src" "$F_link"

if [[ -L "$F_link" ]]; then
    print_test_result "ln -sF creates symlink over directory" "PASS"
else
    print_test_result "ln -sF creates symlink over directory" "FAIL" \
        "Expected symlink, got: $(ls -ld "$F_link" 2>&1)"
fi
```

### `-r` / `--relative` make symlinks relative (SHOULD)

`-r` creates a symlink using a relative path from the link's
location to the target, rather than an absolute path. No
test exercises this.

**Missing test**:

```bash
echo -e "${CYAN}Testing -r relative symlink...${NC}"

local r_target=$(create_temp_file "relative target")
local r_dir=$(create_temp_dir)
local r_link="$r_dir/r_link"

test_command_exit_code "ln -sr creates relative symlink" 0 \
    "$binary" -sr "$r_target" "$r_link"

if [[ -L "$r_link" ]]; then
    local r_dest
    r_dest=$(readlink "$r_link")
    # The stored path must be relative (must not start with /)
    if [[ "$r_dest" != /* ]]; then
        print_test_result "ln -sr stores relative path" "PASS"
    else
        print_test_result "ln -sr stores relative path" "FAIL" \
            "readlink returned absolute path: $r_dest"
    fi
else
    print_test_result "ln -sr creates symlink" "FAIL" \
        "No symlink created"
fi
```

### `-t` / `--target-directory` (SHOULD)

`-t DIR` treats the last argument as the target directory
rather than the destination, matching the `cp`/`mv` pattern.
No test exercises this.

**Missing test**:

```bash
echo -e "${CYAN}Testing -t target directory...${NC}"

local t_target=$(create_temp_file "t flag content")
local t_dir=$(create_temp_dir)

test_command_exit_code "ln -t target directory" 0 \
    "$binary" -t "$t_dir" "$t_target"

local t_base
t_base=$(basename "$t_target")
if [[ -f "$t_dir/$t_base" ]]; then
    print_test_result "ln -t link created in directory" "PASS"
else
    print_test_result "ln -t link created in directory" "FAIL" \
        "Expected link at $t_dir/$t_base"
fi
```

### `-T` / `--no-target-directory` treat dest as normal file (SHOULD)

`-T` prevents treating the last argument as a target
directory even when it is a directory. With `-T`, passing an
existing directory as destination should fail. No test
exercises this.

**Missing test**:

```bash
echo -e "${CYAN}Testing -T no-target-directory...${NC}"

local T_target=$(create_temp_file "T flag content")
local T_dir=$(create_temp_dir)

# When dest is a directory and -T is set, ln should fail
test_command_exit_code "ln -T rejects directory dest" 1 \
    "$binary" -T "$T_target" "$T_dir"

# Verify nothing was created inside the directory
if [[ -z "$(ls -A "$T_dir")" ]]; then
    print_test_result "ln -T did not create link in dir" "PASS"
else
    print_test_result "ln -T did not create link in dir" "FAIL"
fi
```

---

## System Comparison

The macOS man page describes `-h` as treating a symlink
target as the link itself rather than following it. The
`-sfn` test partially covers this for symlinks-to-files but
not for symlinks-to-directories. The important directory
case is described in the macOS EXAMPLES section (`ln -shf
baz foo`) and is not tested.

The flag table lists `-i`, `-w`, `-F`, `-r`, `-t`, and `-T`
as SHOULD-tier and all implemented. None have integration
tests. These are the main coverage gap.

---

## Findings

| ID | Severity | Description |
|----|----------|-------------|
| F1 | IMPORTANT | `-v` tests do not verify output is on stdout; stderr output would pass |
| F2 | IMPORTANT | `-n` tests do not cover symlink-to-dir case; dereference suppression unverified end-to-end |
| F3 | IMPORTANT | `-b` backup test does not verify backup content or new link target |
| F4 | IMPORTANT | `-i` (SHOULD) has zero integration tests; prompt and response paths untested |
| F5 | IMPORTANT | `-w` (SHOULD) has zero integration tests; warning-on-dangling unverified |
| F6 | IMPORTANT | `-F` (SHOULD) has zero integration tests; replace-directory behavior unverified |
| F7 | IMPORTANT | `-r`/`--relative` (SHOULD) has zero integration tests; relative path stored unverified |
| F8 | IMPORTANT | `-t`/`--target-directory` (SHOULD) has zero integration tests |
| F9 | IMPORTANT | `-T`/`--no-target-directory` (SHOULD) has zero integration tests |
| F10 | SUGGESTION | Five error-condition tests are exit-code-only; stderr message not verified |

---

## Fix Order

```
Fix Order:
1. [IMPORTANT] -v tests: add stderr-empty assertion to verify
   verbose output goes to stdout — lines 222, 237, 252
2. [IMPORTANT] -n test: add symlink-to-dir case verifying
   dereference suppression — missing
3. [IMPORTANT] -b/-sb test: add readlink checks on backup
   file and new link — lines 571-590
4. [IMPORTANT] Add integration tests for -i (prompt,
   empty-stdin skip, y-response overwrite) — missing
5. [IMPORTANT] Add integration test for -w (warning on
   dangling symlink) — missing
6. [IMPORTANT] Add integration test for -F (remove directory
   target) — missing
7. [IMPORTANT] Add integration test for -r/--relative
   (verify stored path is relative) — missing
8. [IMPORTANT] Add integration test for -t/--target-directory
   — missing
9. [IMPORTANT] Add integration test for -T/--no-target-directory
   — missing
10. [SUGGESTION] Add stderr checks to error-condition tests
    — lines 331-357
```

REVIEW COMPLETE - NEEDS_FIXES
