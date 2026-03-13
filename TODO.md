# vibeutils - GNU Coreutils in Zig

## Progress Summary
- **Completed**: 47/47 utilities - ALL IMPLEMENTED
- **Utilities**: basename, cat, chmod, chown, cp, cut, date, dd, df, dirname, du, echo, env, false, find, free, grep, head, id, ln, ls, mkdir, mktemp, mv, nl, printf, pwd, readlink, realpath, rm, rmdir, seq, sleep, sort, stat, tac, tail, tee, test, timeout, touch, tr, true, uniq, wc, whoami, yes
- **Compatibility**: 90-100% GNU feature coverage for completed utilities
- **Infrastructure**: Build system, CI/CD, privileged testing, writer-based I/O, **Zig 0.15.2**
- **Documentation**: Claude Code quality check (/qc), man page style guide, testing strategy

## Project Goals
- **Balance**: 80% of GNU's usefulness with 20% of the complexity
- **High test coverage**: 90%+ with TDD approach
- **Modern enhancements**: Colors, icons, smart formatting, performance
- **OpenBSD-inspired**: Clear options, concise man pages with examples
- **Practical compatibility**: Features people actually use

## POSIX Compliance & Flag Coverage

### Step 1: Build per-utility flag reference
For each of our 47 utilities, create `docs/specs/<util>.md`
with a flags table extracted from the POSIX spec at
`pubs.opengroup.org/onlinepubs/9699919799/utilities/<util>.html`.
Only utilities we implement; markdown format; OPTIONS section
only.

### Step 2: Capture macOS system flags
For each utility, parse the flags section from
`MANPATH=/usr/share/man man <util>` on macOS. Store alongside
the POSIX table in the same `docs/specs/<util>.md` file under
a "macOS" section. Also capture GNU coreutils flags via
`g<util> --help` (Nix coreutils package) under a "GNU"
section and our own flags from `./zig-out/bin/<util> --help`
under a "vibeutils" section.

### Step 3: Coverage decisions (tiered)
Add a coverage column to each flag in the spec files:
- **MUST**: All POSIX-required flags (target 100%)
- **SHOULD**: Top GNU coreutils flags that users expect
- **WONT**: Rare, macOS-only, or legacy flags we choose to
  skip (with documented rationale)

### Step 4: Integration / regression tests
Write bash shell scripts in `tests/posix/`, one per utility.
Each script validates that every MUST and SHOULD flag is
accepted and produces correct behavior. Compare output
against expected results, not against GNU coreutils directly.
Run via `just test-posix`.

## TDD Development Cycle
For each utility:
1. **Red**: Write failing tests for basic functionality
2. **Green**: Implement minimal code to pass tests
3. **Refactor**: Improve code quality while keeping tests green
4. **Repeat**: Add more test cases for edge cases and flags

## Implementation Order

### Phase 1: Essential & Simple Utilities

#### 1. echo ✓
- [x] Test: Basic text output
- [x] Test: No newline flag (-n)
- [x] Test: Escape sequences (-e)
- [x] Test: Multiple arguments
- [x] Test: Empty input
- [x] Test: Combined flags (-en, -ne)
- [x] Test: Octal sequences (\101)
- [x] Test: Hex sequences (\x41)
- [x] Implement: Basic functionality
- [x] Implement: Flag parsing
- [x] Implement: Escape sequence handling
- [x] Implement: --help and --version flags
- [x] Man page: Write concise man page with examples

##### echo - Additional GNU features (TDD): ✓
- [x] Test: -E flag disables escapes even after -e
- [x] Test: -E flag behavior in combined flags
- [x] Implement: -E flag to explicitly disable escape sequences

#### 2. cat ✓
- [x] Test: Single file reading
- [x] Test: Multiple files concatenation
- [x] Test: STDIN reading
- [x] Test: Line numbering (-n)
- [x] Test: Show ends (-E)
- [x] Test: Show tabs (-T)
- [x] Test: Non-existent file error
- [x] Test: Number non-blank lines (-b)
- [x] Test: Squeeze blank lines (-s)
- [x] Test: Show non-printing (-v)
- [x] Implement: Basic file reading
- [x] Implement: STDIN support
- [x] Implement: Line numbering
- [x] Implement: Special character display
- [x] Man page: Write concise man page with examples

##### cat - Additional GNU features (TDD): ✓
- [x] Test: -A flag combines -vET behavior
- [x] Test: -e flag combines -vE behavior
- [x] Test: -t flag combines -vT behavior
- [x] Test: -u flag is silently ignored
- [x] Test: -A with control characters
- [x] Implement: -A (--show-all) combination flag
- [x] Implement: -e combination flag
- [x] Implement: -t combination flag
- [x] Implement: -u flag (no-op for POSIX)
- [x] Implement: Long option support (--show-all already works)

#### 3. ls ✓ (Phases 1-5 complete)
- [x] Test: Basic directory listing
- [x] Test: Hidden files (-a)
- [x] Test: One file per line (-1)
- [x] Test: Alphabetical sorting
- [x] Test: Empty directory handling
- [x] Test: Mixed files and directories
- [x] Implement: Basic listing
- [x] Implement: Directory iteration
- [x] Implement: Hidden file filtering
- [x] Implement: Alphabetical sorting
- [x] Man page: Write concise man page with examples

##### ls - Implementation Plan (Balanced Approach)

###### Phase 1: Essential Features (TDD) ✓
- [x] Test: Long format (-l) with permissions, size, date
- [x] Test: stat() wrapper for file attributes
- [x] Test: Permission string formatting (e.g., -rw-r--r--)
- [x] Test: Human readable sizes (-h) with K/M/G/T
- [x] Test: Kilobyte sizes (-k) always in 1K blocks
- [x] Test: Show all files (-a) including . and ..
- [x] Test: Almost all (-A) excluding . and ..
- [x] Implement: stat() wrapper in common library
- [x] Implement: Permission string formatter
- [x] Implement: Size formatters (bytes, human, kilobytes)
- [x] Implement: Date/time formatter (smart: recent vs old)
- [x] Implement: Long format assembly
- [x] Implement: User/group name lookup via C interop
- [x] Implement: Hard link count display
- [x] Implement: Total blocks calculation

###### Phase 2: Sorting & Display Options (TDD)
- [x] Test: Sort by time (-t) newest first
- [x] Test: Sort by size (-S) largest first
- [x] Test: Reverse sort (-r) for any sorting mode
- [x] Test: File type indicators (-F) /=*@|
- [x] Test: Directory itself (-d) without recursion
- [x] Test: Symlink target display with -l
- [x] Implement: Modular sorting system
- [x] Implement: Time-based comparator
- [x] Implement: Size-based comparator
- [x] Implement: Reverse sort wrapper
- [x] Implement: File type detection and indicators
- [x] Implement: Symlink target reading and display

###### Phase 3: Modern UX & Color (TDD)
- [x] Test: Color capability detection (isatty, TERM)
- [x] Test: --color=auto/always/never modes
- [x] Test: Basic color scheme (dirs, executables, symlinks) ✓
- [x] Test: LS_COLORS environment variable parsing ✓
- [x] Test: --group-directories-first option ✓
- [x] Test: Terminal width detection for columns ✓
- [x] Test: Smart column formatting (-C is default) ✓
- [x] Implement: Color system with graceful degradation ✓
- [x] Implement: LS_COLORS parser (simplified) ✓
- [x] Implement: Directory grouping logic ✓
- [x] Implement: Responsive column layout ✓

###### Phase 4: Recursive & Nice-to-Have (TDD) ✓
- [x] Test: Recursive listing (-R) with proper formatting
- [x] Test: Recursive with cycle detection
- [x] Test: Inode display (-i) before filename
- [x] Test: Numeric user/group IDs (-n) 
- [x] Test: Comma-separated output (-m)
- [x] Test: Single column force (-1) ✓ already done
- [x] Implement: Recursive directory walker
- [x] Implement: Symlink cycle detection
- [x] Implement: Inode display formatting
- [x] Implement: Comma-separated formatter

###### Phase 5: Modern Enhancements ✓
- [x] Test: Nerd font icon detection
- [x] Test: Icon mapping for common file types
- [x] Test: Git status integration (modified/new files)
- [x] Test: Smart date formatting ("2 hours ago")
- [ ] Test: Parallel stat() for performance (deferred - see Future Optimizations)
- [x] Implement: Optional icon system
- [x] Implement: Git repository detection
- [x] Implement: Human-friendly date formatting
- [ ] Implement: Parallel I/O for large directories (deferred - see Future Optimizations)

##### ls - Features We're NOT Implementing
- SELinux context (-Z, --context) - Too Linux-specific
- Author field (--author) - Nobody uses this
- Emacs dired mode (-D, --dired) - Too niche
- Complex quoting styles - Just escape when needed
- Multiple time formats - One smart format is enough
- Block size gymnastics (--block-size) - Just -h and -k
- All the --indicator-style variants - Just -F
- Explicit --si flag - We use binary (1024) for -h

#### 4. cp ✓ (Complete implementation)
- [x] Test: Single file copy
- [x] Test: Copy to existing directory
- [x] Test: Error on directory without recursive flag
- [x] Test: Preserve attributes (-p)
- [x] Test: Directory copy (-r)
- [x] Test: Interactive mode (-i)
- [x] Test: Force overwrite (-f)
- [x] Test: Symbolic link handling (-d)
- [x] Test: Error cases (permission denied, disk full)
- [x] Implement: Basic file copying
- [x] Implement: Attribute preservation (mode, timestamps)
- [x] Implement: Copy to directory detection
- [x] Implement: Directory recursion
- [x] Implement: Symlink handling (-d/--no-dereference)
- [x] Man page: Write concise man page with examples

#### 5. mv ✓
- [x] Test: File rename in same directory
- [x] Test: Move to different directory
- [x] Test: Directory move
- [x] Test: Interactive mode (-i)
- [x] Test: Force mode (-f)
- [x] Test: Cross-filesystem move
- [x] Test: Atomic rename when possible
- [x] Implement: Basic move/rename
- [x] Implement: Cross-filesystem support
- [x] Implement: Directory handling
- [x] Man page: Write concise man page with examples

#### 6. rm ✓
- [x] Test: Single file removal
- [x] Test: Multiple files
- [x] Test: Directory removal (-r)
- [x] Test: Force mode (-f)
- [x] Test: Interactive mode (-i)
- [x] Test: Write-protected file handling
- [x] Test: Non-existent file behavior
- [x] Implement: Basic removal
- [x] Implement: Recursive removal
- [x] Implement: Safety checks
- [x] Man page: Write concise man page with examples

##### rm - Advanced Implementation (TDD) ✓
**Phase 1: Basic File Removal**
- [x] Test: Basic file removal
- [x] Test: Non-existent file with force
- [x] Test: Multiple file removal
- [x] Test: Directory without recursive flag
- [x] Test: Verbose output
- [x] Implement: Core removal logic
- [x] Implement: Force mode handling
- [x] Implement: Error reporting

**Phase 2: Safety and Interaction**
- [x] Test: Interactive mode prompts
- [x] Test: Force mode bypasses prompts
- [x] Test: Root directory protection
- [x] Test: Same-file detection (hard links)
- [x] Test: Empty path handling
- [x] Test: Path traversal attack prevention
- [x] Implement: User interaction system
- [x] Implement: Write-protected file prompts
- [x] Implement: Interactive once mode (-I)
- [x] Implement: Critical system path protection

**Phase 3: Recursive Directory Operations**
- [x] Test: Recursive directory removal
- [x] Test: Deep nested directories
- [x] Test: Symlink handling (don't follow)
- [x] Test: Permission handling with force
- [x] Implement: Depth-first directory traversal
- [x] Implement: Symlink detection
- [x] Implement: Permission modification for force mode
- [x] Implement: Inode tracking for cycles

**Phase 4: Advanced Safety Features**
- [x] Test: Symlink cycle detection
- [x] Test: Cross-filesystem boundary handling
- [x] Test: Race condition protection
- [x] Implement: Complex symlink cycle detection
- [x] Implement: Device ID tracking for filesystem boundaries
- [x] Implement: Atomic operations using *at() syscalls
- [x] Implement: File descriptor-based removal for TOCTOU protection

#### 7. mkdir ✓
- [x] Test: Single directory creation
- [x] Test: Parent creation (-p)
- [x] Test: Mode setting (-m)
- [x] Test: Multiple directories
- [x] Test: Already exists error
- [x] Test: Permission denied
- [x] Implement: Basic mkdir
- [x] Implement: Parent directory creation
- [x] Implement: Permission setting (partial - chmod TODO)
- [x] Man page: Write concise man page with examples

#### 8. rmdir ✓
- [x] Test: Empty directory removal
- [x] Test: Non-empty directory error
- [x] Test: Parent removal (-p)
- [x] Test: Multiple directories
- [x] Test: Non-existent directory
- [x] Test: File instead of directory error
- [x] Test: Verbose output (-v)
- [x] Test: Ignore fail on non-empty (--ignore-fail-on-non-empty)
- [x] Test: Parent removal stops on error
- [x] Test: Path traversal protection
- [x] Test: Symbolic link detection
- [x] Test: Unicode path handling
- [x] Test: Long path support
- [x] Test: Memory management (no leaks)
- [x] Test: Progress indicators
- [x] Implement: Basic removal with atomic operations
- [x] Implement: Parent cleanup with ParentIterator (memory-safe)
- [x] Implement: Verbose output with colors
- [x] Implement: --ignore-fail-on-non-empty flag
- [x] Implement: Path validation (traversal, symlinks, system paths)
- [x] Implement: Atomic removal with unlinkat syscall
- [x] Implement: Progress indicators for bulk operations
- [x] Man page: Write concise man page with examples

#### 9. touch ✓
- [x] Test: Create new file
- [x] Test: Update existing file timestamp
- [x] Test: Specific time (-t)
- [x] Test: Reference file (-r)
- [x] Test: Access time only (-a)
- [x] Test: Modification time only (-m)
- [x] Test: -h/--no-dereference for symlinks
- [x] Test: --time=WORD support
- [x] Test: Multiple files
- [x] Test: -c/--no-create flag
- [x] Test: Timestamp parsing validation
- [x] Test: Error handling
- [x] Test: Pre-1970 date validation
- [x] Implement: File creation
- [x] Implement: Timestamp manipulation
- [x] Implement: Reference file support
- [x] Implement: Atomic operations (no race conditions)
- [x] Implement: Dynamic path allocation
- [x] Implement: Comprehensive error handling
- [x] Man page: Write concise man page with examples

#### 10. pwd ✓
- [x] Test: Basic working directory
- [x] Test: Logical path (-L)
- [x] Test: Physical path (-P)
- [x] Test: Symlink resolution
- [x] Test: PWD environment variable validation
- [x] Test: Flag precedence (last flag wins)
- [x] Test: Security validation with inode comparison
- [x] Test: Output format validation
- [x] Implement: Basic pwd
- [x] Implement: Path resolution options
- [x] Implement: Secure PWD validation using inode comparison
- [x] Implement: Proper error handling with common library
- [x] Implement: GNU/POSIX compliant flag handling
- [x] Man page: Write concise man page with examples

#### 11. chmod ✓
- [x] Test: Basic permission changes (numeric: 755, 644)
- [x] Test: Symbolic mode changes (u+x, g-w, o=r)
- [x] Test: Recursive mode (-R)
- [x] Test: Preserve root (-c, --changes)
- [x] Test: Error handling (permission denied)
- [x] Test: Special bits (setuid, setgid, sticky)
- [x] Implement: Numeric mode parser
- [x] Implement: Symbolic mode parser
- [x] Implement: Recursive directory walker
- [x] Man page: Write concise man page with examples

#### 12. chown ✓
- [x] Test: Basic ownership change (user:group)
- [x] Test: User only change
- [x] Test: Group only change (:group)
- [x] Test: Recursive mode (-R)
- [x] Test: Dereference/no-dereference (-h, -H, -L, -P)
- [x] Test: From reference file (--reference)
- [x] Implement: User/group parsing
- [x] Implement: Ownership change syscalls
- [x] Implement: Recursive walker with symlink handling
- [x] Man page: Write concise man page with examples

#### 13. ln ✓
- [x] Test: Create hard link
- [x] Test: Create symbolic link (-s)
- [x] Test: Force overwrite (-f)
- [x] Test: Interactive mode (-i)
- [x] Test: Create links in directory (-t)
- [x] Test: Relative symlinks (--relative)
- [x] Test: Error cases (cross-device hard link)
- [x] Implement: Hard link creation
- [x] Implement: Symbolic link creation
- [x] Implement: Path resolution for relative links
- [x] Implement: Path security validation
- [x] Man page: Write concise man page with examples

#### 14. basename ✓
- [x] Test: Strip directory from path
- [x] Test: Strip suffix (-s, --suffix)
- [x] Test: Multiple paths (-a, --multiple)
- [x] Test: Zero delimiter (-z, --zero)
- [x] Test: Edge cases (/, //, no slash)
- [x] Implement: Path parsing logic
- [x] Implement: Suffix stripping
- [x] Implement: Multiple file handling
- [x] Man page: Write concise man page with examples

#### 15. dirname ✓
- [x] Test: Extract directory from path
- [x] Test: Multiple paths
- [x] Test: Zero delimiter (-z, --zero)
- [x] Test: Edge cases (/, //, no slash, .)
- [x] Implement: Path parsing logic
- [x] Implement: Multiple path handling
- [x] Man page: Write concise man page with examples

#### 16. sleep ✓
- [x] Test: Sleep for seconds
- [x] Test: Sleep for decimal seconds (0.5)
- [x] Test: Sleep for minutes/hours/days suffix (5m, 2h, 1d)
- [x] Test: Multiple time arguments (sleep 1m 30s)
- [x] Test: Signal handling (interruptible)
- [x] Implement: Time parsing with units
- [x] Implement: High-precision sleep
- [x] Implement: Signal-safe sleep
- [x] Man page: Write concise man page with examples

#### 17. true ✓
- [x] Test: Always returns 0 exit code
- [x] Test: Ignores all arguments
- [x] Implement: Minimal implementation
- [x] Man page: Write concise man page

#### 18. false ✓
- [x] Test: Always returns 1 exit code
- [x] Test: Ignores all arguments
- [x] Test: Produces no output
- [x] Test: Handles empty arguments array
- [x] Test: Handles many arguments
- [x] Implement: Minimal implementation
- [x] Man page: Write concise man page

#### 19. test ✓
- [x] Test: File existence checks (-e, -f, -d, -r, -w, -x)
- [x] Test: String comparisons (=, !=, -z, -n)
- [x] Test: Numeric comparisons (-eq, -ne, -lt, -le, -gt, -ge)
- [x] Test: Logical operators (-a, -o, !)
- [x] Test: Complex expressions with parentheses
- [x] Test: Exit codes (0 for true, 1 for false, 2 for error)
- [x] Test: Both test and [ ] forms
- [x] Test: Terminal tests (-t)
- [x] Test: Special file tests (-p, -S, -b, -c, -L/-h)
- [x] Test: File size test (-s)
- [x] Test: Permission bit tests (-g for setgid)
- [x] Test: Operator precedence and negation
- [x] Test: Error handling for invalid expressions
- [x] Implement: Expression parser with proper precedence
- [x] Implement: File test operations (all POSIX types)
- [x] Implement: String and numeric comparison operations
- [x] Implement: Logical operators with POSIX precedence
- [x] Implement: Parentheses grouping support
- [x] Implement: Both test and [ executable forms
- [x] Man page: Write concise man page with examples

#### 20. date ✓
- [x] Test: Display current date/time
- [x] Test: Custom format string (+FORMAT)
- [x] Test: Set date/time (-s, --set)
- [x] Test: Display file's date (-r, --reference)
- [x] Test: UTC mode (-u, --utc)
- [x] Test: RFC formats (--rfc-3339, --rfc-email)
- [x] Test: Relative dates (-d "2 days ago")
- [x] Implement: Format string parser (strftime-like)
- [x] Implement: Date parsing for various formats
- [x] Implement: Relative date calculations
- [x] Man page: Write concise man page with examples

#### 21. env ✓
- [x] Test: Print current environment
- [x] Test: Run command with modified env (env VAR=value cmd)
- [x] Test: Clear environment (-i, --ignore-environment)
- [x] Test: Unset variables (-u, --unset)
- [x] Test: Change directory (-C, --chdir)
- [x] Test: Split string arguments (-S)
- [x] Implement: Environment manipulation
- [x] Implement: Command execution with env
- [x] Implement: Argument splitting parser
- [x] Man page: Write concise man page with examples

#### 22. seq ✓
- [x] Test: Generate sequence (seq 10)
- [x] Test: Start and end (seq 5 10)
- [x] Test: Start, increment, end (seq 1 2 10)
- [x] Test: Floating point sequences (seq 0.1 0.1 1.0)
- [x] Test: Format string (-f "%03g")
- [x] Test: Separator (-s ", ")
- [x] Test: Equal width (-w)
- [x] Implement: Number sequence generation
- [x] Implement: Format string support
- [x] Implement: Width calculation
- [x] Man page: Write concise man page with examples

#### 23. tee ✓
- [x] Test: Write to stdout and file
- [x] Test: Write to multiple files
- [x] Test: Append mode (-a, --append)
- [x] Test: Ignore interrupts (-i)
- [x] Test: Diagnose write errors (-p)
- [x] Test: Binary data handling
- [x] Implement: Multi-writer system
- [x] Implement: Signal handling
- [x] Implement: Error diagnosis
- [x] Man page: Write concise man page with examples

#### 24. yes ✓
- [x] Test: Repeat "y" infinitely
- [x] Test: Repeat custom string
- [x] Test: Multiple arguments joined with space
- [x] Test: Performance (must be fast)
- [x] Test: SIGPIPE handling
- [x] Implement: Efficient output loop
- [x] Implement: Buffer optimization
- [x] Implement: Signal handling
- [x] Man page: Write concise man page with examples

#### 25. whoami ✓
- [x] Test: Print effective username
- [x] Test: No options accepted
- [x] Test: Error when can't determine user
- [x] Implement: Get effective user ID
- [x] Implement: User lookup
- [x] Man page: Write concise man page with examples

#### 26. id ✓
- [x] Test: Print all IDs (default)
- [x] Test: User ID only (-u, --user)
- [x] Test: Group ID only (-g, --group)
- [x] Test: All group IDs (-G, --groups)
- [x] Test: Names instead of numbers (-n, --name)
- [x] Test: Real instead of effective (-r, --real)
- [x] Test: Different user (id username)
- [x] Implement: ID retrieval syscalls
- [x] Implement: User/group lookups
- [x] Implement: Format selection
- [x] Man page: Write concise man page with examples

#### 27. printf ✓
- [x] Test: Basic format strings (%s, %d, %f)
- [x] Test: Escape sequences (\n, \t, \x41)
- [x] Test: Width and precision (%.2f, %10s)
- [x] Test: Multiple arguments with reuse
- [x] Test: Octal/hex formats (%o, %x, %X)
- [x] Test: Error handling (type mismatches)
- [x] Implement: Format string parser
- [x] Implement: Type conversions
- [x] Implement: Escape sequence handling
- [x] Man page: Write concise man page with examples

#### 28. free ✓
- [x] Test: Basic memory information display (total, used, free, available)
- [x] Test: Human readable format (-h) with K/M/G/T units
- [x] Test: Show swap information (default)
- [x] Test: Hide swap information (-s, --no-swap)
- [x] Test: Continuous monitoring (-c, --count with interval)
- [x] Test: Wide format (-w) for better readability
- [ ] Test: Color-coded memory usage levels (green/yellow/red)
- [x] Test: Cross-platform support (Linux /proc/meminfo, macOS vm_stat)
- [ ] Test: Memory pressure indicators and warnings
- [ ] Test: Unicode glyphs and progress bars for visual appeal
- [x] Implement: Linux memory parsing (/proc/meminfo)
- [x] Implement: macOS memory info via syscalls (host_statistics64)
- [x] Implement: Human-readable size formatting
- [ ] Implement: Color-coded output with terminal detection
- [ ] Implement: Progress bar visualization for memory usage
- [ ] Implement: Modern glyphs and icons for memory types
- [x] Implement: Continuous monitoring with refresh
- [x] Man page: Write concise man page with examples

### Phase 2: Text Processing Utilities

#### 29. dd ✓
- [x] Test: Basic copy (if=input of=output)
- [x] Test: Block size (bs=1M, ibs=512, obs=4096)
- [x] Test: Count limit (count=100)
- [x] Test: Seek/skip (seek=10, skip=5)
- [x] Test: Conversion (conv=ucase,lcase,notrunc,sync)
- [x] Test: Status output (status=progress)
- [x] Test: Direct I/O (iflag=direct, oflag=direct)
- [x] Implement: Block-based I/O
- [x] Implement: Conversion operations
- [x] Implement: Progress reporting
- [x] Man page: Write concise man page with examples

#### 30. realpath ✓
- [x] Test: Resolve to absolute path
- [x] Test: Canonicalize existing (-e, --canonicalize-existing)
- [x] Test: Canonicalize missing (-m, --canonicalize-missing)
- [x] Test: No symlinks (-s, --strip, --no-symlinks)
- [x] Test: Relative to directory (--relative-to)
- [x] Test: Relative base (--relative-base)
- [x] Implement: Path resolution
- [x] Implement: Symlink following
- [x] Implement: Relative path computation
- [x] Man page: Write concise man page with examples

#### 31. readlink ✓
- [x] Test: Print symlink target
- [x] Test: Canonicalize (-f, --canonicalize)
- [x] Test: Canonicalize existing (-e)
- [x] Test: Canonicalize missing (-m)
- [x] Test: No newline (-n, --no-newline)
- [x] Test: Error on non-symlink
- [x] Implement: Symlink reading
- [x] Implement: Path canonicalization
- [x] Man page: Write concise man page with examples

#### 32. mktemp ✓
- [x] Test: Create temporary file
- [x] Test: Create temporary directory (-d, --directory)
- [x] Test: Custom template (mktemp /tmp/test.XXX)
- [x] Test: Dry run (-u, --dry-run)
- [x] Test: Custom tmpdir (--tmpdir)
- [x] Test: Suffix (--suffix=.txt)
- [x] Implement: Secure random name generation
- [x] Implement: Atomic file creation
- [x] Implement: Template parsing
- [x] Man page: Write concise man page with examples

#### 33. timeout ✓
- [x] Test: Basic timeout with seconds (timeout 5 sleep 10)
- [x] Test: Command succeeds before timeout (exit status 0)
- [x] Test: Command killed on timeout (exit status 124)
- [x] Test: Floating point durations (timeout 2.5 sleep 3)
- [x] Test: Time units (5s, 2m, 1h, 0.5d)
- [x] Test: Zero timeout disables (timeout 0 sleep 1)
- [x] Test: Exit status preservation (--preserve-status)
- [x] Test: Kill after timeout (-k 2s kills if TERM ignored)
- [x] Test: Custom signals (-s INT, -s KILL, -s 15)
- [x] Test: Foreground mode (-f) for interactive commands
- [x] Test: Verbose mode (-v) diagnostic output
- [x] Test: Command not found (exit 127)
- [x] Test: Command not executable (exit 126)
- [x] Test: Signal handling (SIGTERM, SIGKILL propagation)
- [x] Test: Child process handling
- [x] Test: Error cases (invalid duration, invalid signal)
- [x] Implement: Duration parser (float + units)
- [x] Implement: Process spawning with exec
- [x] Implement: Timer using setitimer or timerfd
- [x] Implement: Signal management and propagation
- [x] Implement: Foreground TTY handling
- [x] Implement: Exit status handling
- [x] Implement: Verbose diagnostic messages
- [x] Man page: Write concise man page with examples

##### timeout - Implementation Notes
**Why Priority**: macOS lacks timeout, causing issues in scripts/CI
**Key Features**: Must support both simple (timeout 5 cmd) and complex (timeout -k 2s -s INT 10s cmd) usage
**Platform Considerations**: 
- Linux: Use timerfd_create for precise timing
- macOS/BSD: Use setitimer or kqueue timers
- Signal handling must be robust across platforms

#### 34. tac ✓
- [x] Test: Reverse file lines
- [x] Test: Multiple files
- [x] Test: Custom separator (-s, --separator)
- [x] Test: Separator before line (-b, --before)
- [x] Test: Regex separator (-r, --regex)
- [x] Test: Large file handling
- [x] Implement: Reverse line reading
- [x] Implement: Memory-efficient algorithm
- [x] Implement: Separator handling
- [x] Man page: Write concise man page with examples

#### 35. nl ✓
- [x] Test: Number all lines (default)
- [x] Test: Number non-empty lines (-b a, -b t)
- [x] Test: Number format (-n ln, -n rn, -n rz)
- [x] Test: Starting number (-v 100)
- [x] Test: Increment (-i 2)
- [x] Test: Width (-w 4)
- [x] Test: Separator (-s ": ")
- [x] Implement: Line numbering logic
- [x] Implement: Format options
- [x] Implement: Section handling
- [x] Man page: Write concise man page with examples

#### 36. head ✓
- [x] Test: Default 10 lines
- [x] Test: Custom line count (-n)
- [x] Test: Byte count (-c)
- [x] Test: Multiple files
- [x] Test: STDIN input
- [x] Test: File headers with multiple files
- [x] Implement: Line-based reading
- [x] Implement: Byte-based reading
- [x] Implement: Multi-file handling
- [x] Man page: Write concise man page with examples

#### 37. tail ✓
- [x] Test: Default 10 lines
- [x] Test: Custom line count (-n)
- [ ] Test: Follow mode (-f) (deferred - complex feature)
- [x] Test: Byte count (-c)
- [x] Test: Multiple files
- [x] Test: Reverse line reading
- [x] Test: Zero-terminated lines (-z)
- [x] Test: Files without final newline
- [x] Implement: Efficient line reading from end
- [ ] Implement: Follow mode with inotify (deferred - complex feature)
- [x] Implement: CircularLineBuffer for performance
- [x] Implement: Zero-terminated line support
- [x] Implement: Zig 0.15.1 Reader API migration
- [x] Man page: Write concise man page with examples

#### 38. wc ✓
- [x] Test: Line count (-l)
- [x] Test: Word count (-w)
- [x] Test: Byte count (-c)
- [x] Test: Character count (-m)
- [x] Test: Maximum line length (-L)
- [x] Test: Multiple files
- [x] Test: STDIN input
- [x] Test: Unicode handling
- [x] Test: Default behavior (lines, words, bytes)
- [x] Test: File error handling
- [x] Implement: Efficient counting with streaming
- [x] Implement: Unicode support with proper character counting
- [x] Implement: Performance-optimized byte counting
- [x] Man page: Write concise man page with examples

#### 39. sort ✓
- [x] Test: Basic alphabetical sort
- [x] Test: Numeric sort (-n)
- [x] Test: Reverse sort (-r)
- [x] Test: Key-based sort (-k)
- [x] Test: Unique sort (-u)
- [x] Test: Case-insensitive (-f)
- [x] Test: Memory limit handling
- [x] Implement: In-memory sorting
- [x] Implement: External merge sort
- [x] Implement: Key extraction
- [x] Man page: Write concise man page with examples

#### 40. uniq ✓
- [x] Test: Remove adjacent duplicates
- [x] Test: Count occurrences (-c)
- [x] Test: Only duplicates (-d)
- [x] Test: Only unique (-u)
- [x] Test: Skip fields (-f)
- [x] Test: Case-insensitive (-i)
- [x] Implement: Line comparison
- [x] Implement: Counting logic
- [x] Implement: Field skipping
- [x] Man page: Write concise man page with examples

#### 41. cut ✓
- [x] Test: Byte selection (-b)
- [x] Test: Character selection (-c)
- [x] Test: Field selection (-f)
- [x] Test: Delimiter (-d)
- [x] Test: Complement (-c)
- [x] Test: Multiple files
- [x] Implement: Range parsing
- [x] Implement: UTF-8 character handling
- [x] Implement: Field extraction
- [x] Man page: Write concise man page with examples

#### 42. tr ✓
- [x] Test: Character translation
- [x] Test: Character deletion (-d)
- [x] Test: Squeeze repeats (-s)
- [x] Test: Complement set (-c)
- [x] Test: Character classes [:alpha:]
- [x] Test: Range expansion [a-z]
- [x] Implement: Translation tables
- [x] Implement: Unicode support
- [x] Implement: Character class parsing
- [x] Man page: Write concise man page with examples

### Phase 3: File Information Utilities

#### 43. stat ✓
- [x] Test: File information display
- [x] Test: Custom format (-c)
- [x] Test: Filesystem info (-f)
- [x] Test: Dereference (-L)
- [x] Test: Terse output (-t)
- [x] Implement: System call wrapper
- [x] Implement: Format string parser
- [x] Implement: Human-readable output
- [x] Man page: Write concise man page with examples

#### 44. du ✓
- [x] Test: Directory size calculation
- [x] Test: Human readable (-h)
- [x] Test: Summary only (-s)
- [x] Test: Max depth (-d)
- [x] Test: Exclude patterns
- [x] Test: Hard link handling
- [x] Implement: Directory traversal
- [x] Implement: Size calculation
- [x] Implement: Caching for performance
- [x] Man page: Write concise man page with examples

#### 45. df ✓
- [x] Test: Filesystem listing
- [x] Test: Human readable (-h)
- [x] Test: Filesystem type (-t)
- [x] Test: Inode information (-i)
- [x] Test: Mount point resolution
- [x] Implement: Mount point parsing
- [x] Implement: Space calculation
- [x] Implement: Filesystem filtering
- [x] Man page: Write concise man page with examples

### Phase 4: Advanced Utilities

#### 46. find ✓
- [x] Test: Name matching (-name)
- [x] Test: Type filtering (-type)
- [x] Test: Size filtering (-size)
- [x] Test: Time filtering (-mtime)
- [x] Test: Execution (-exec)
- [x] Test: Logical operators
- [x] Test: Depth control
- [x] Implement: Expression parser
- [x] Implement: Directory walker
- [x] Implement: Action execution
- [x] Man page: Write concise man page with examples

#### 47. grep ✓
- [x] Test: Basic pattern matching
- [x] Test: Regular expressions (-E)
- [x] Test: Case insensitive (-i)
- [x] Test: Invert match (-v)
- [x] Test: Line numbers (-n)
- [x] Test: Recursive (-r)
- [x] Test: Binary file handling
- [x] Implement: Pattern compilation
- [x] Implement: Line matching
- [x] Implement: Performance optimizations
- [x] Man page: Write concise man page with examples

## Testing Strategy
- **Coverage Goals**: 90%+ line, 85%+ branch, 100% error paths
- **Unit Tests**: Individual flags, combinations, edge cases
- **Integration Tests**: Pipes, signals, GNU compatibility, benchmarks

### Custom Argument Parser Implementation ✓

#### Replace zig-clap Dependency (COMPLETED)
**Goal**: Replace zig-clap's 3,000 lines with focused ~400-line library supporting 95% of real usage patterns

**Design Philosophy**:
- API-first design with type-safe interfaces
- Zero allocations for flag parsing (positionals may allocate)
- Compile-time validation where possible
- Self-documenting through struct field names
- OpenBSD-inspired simplicity with GNU compatibility

##### Phase 1: Core Parsing Engine (COMPLETED) ✓
- [x] Test: Boolean flag parsing (-h, --help, -v, --verbose)
- [x] Test: Combined short flags (-abc = -a -b -c)
- [x] Test: Unknown flag error handling
- [x] Test: Flag mapping generation from struct reflection
- [x] Test: Memory management (no leaks)
- [x] Implement: Core `ArgParser.parse()` function with generic struct support
- [x] Implement: Comptime flag mapping using `@typeInfo()`
- [x] Implement: Boolean flag state management
- [x] Implement: ParseResult with proper cleanup
- [x] Implement: Error types (InvalidArgument, UnknownFlag, MissingValue)

##### Phase 2: String Options and Positionals (COMPLETED) ✓
- [x] Test: String option parsing (--color=auto, --output file)
- [x] Test: Both `--option=value` and `--option value` syntax
- [x] Test: Missing value error for string options
- [x] Test: Positional argument collection
- [x] Test: GNU `--` separator handling
- [x] Test: Single `-` as positional (stdin convention)
- [x] Implement: String option value extraction
- [x] Implement: Two-pass parsing (flags first, then values)
- [x] Implement: Positional argument allocation and management
- [x] Implement: State machine for parsing stages

##### Phase 3: Help Generation System (COMPLETED) ✓
- [x] Test: Help text parsing from struct `meta` field
- [x] Test: Automatic help formatting matching GNU style
- [x] Test: Usage line generation with positional indicators
- [x] Test: Option description alignment and formatting
- [x] Test: Integration with existing --help flag patterns
- [x] Implement: `printHelp()` function
- [x] Implement: Help text parser for embedded descriptions
- [x] Implement: GNU-style help formatting
- [x] Implement: Usage line generation based on struct analysis

##### Phase 4: GNU Compatibility and Edge Cases (COMPLETED) ✓
- [x] Test: POSIX compliance for argument ordering
- [x] Test: Error message format matching GNU conventions
- [x] Test: Complex combined flags with string options
- [x] Test: Edge cases (empty args, only positionals, only flags)
- [x] Test: Integration with all existing utility patterns
- [x] Implement: Full GNU argument parsing compatibility
- [x] Implement: Comprehensive error reporting
- [x] Implement: Performance optimization (comptime where possible)

##### Migration Plan (COMPLETED) ✓
- [x] **echo**: Migrated simplest case (boolean flags only)
- [x] **cat**: Multiple boolean flags, combination flags (-A, -e, -t)
- [x] **ls**: Complex case with string options (--color, --time-style)
- [x] **cp/mv/rm**: Interactive flags and mixed option types
- [x] **mkdir/rmdir/touch**: Mode settings and timestamp options
- [x] **All utilities**: Complete migration for all 22 implemented utilities

##### Integration and Cleanup (COMPLETED) ✓
- [x] Test: Drop-in compatibility with existing utility code
- [x] Test: Performance benchmarks vs zig-clap
- [x] Test: Binary size comparison
- [x] Test: Compile time comparison
- [x] Update: build.zig to remove zig-clap dependency
- [x] Update: build.zig.zon to remove clap entry
- [x] Verify: All existing tests pass with new parser
- [x] Document: API documentation in argparse.zig

**Success Criteria**:
- Library under 500 lines total (vs 3,000 for zig-clap)
- 95%+ test coverage with embedded tests
- All existing utilities work unchanged
- Argument parsing <1ms for complex cases
- Zero regressions in functionality
- Binary size comparable or smaller than zig-clap

**API Design Pattern**:
```zig
const EchoArgs = struct {
    help: bool = false,        // -h, --help
    version: bool = false,     // -V, --version
    suppress_newline: bool = false, // -n
    positionals: []const []const u8,
    
    pub const help_text = 
        \\-h, --help     Display this help and exit.
        \\-V, --version  Output version information and exit.
        \\-n             Do not output the trailing newline.
        \\<str>...       Text to echo.
    ;
};

const args = Args.parse(EchoArgs, allocator) catch |err| switch (err) {
    error.InvalidArgument => return usage_error(),
    else => return err,
};
defer args.deinit(allocator);
```

## Stdout Testing Infrastructure ✓

### Overview
Implemented idiomatic Zig writer pattern to enable comprehensive testing of stdout/stderr output without hangs or skipped tests.

### Design Principles
- Pass writers as parameters (idiomatic Zig pattern) ✓
- Enable full output testing without process-level complexity ✓
- Maintain production behavior while improving testability ✓
- Zero allocation overhead for production code ✓

### Implementation Completed

#### Phase 1: Core Infrastructure ✓
- [x] Writer parameter pattern implemented across all utilities
- [x] Test infrastructure using buffer writers (std.ArrayList(u8).writer())
- [x] Stdout/stderr isolation in all utilities
- [x] Memory management with proper cleanup patterns

#### Phase 2: All Utilities Updated ✓
- [x] **cat** - printVersion, printHelp with writer parameters
- [x] **ls** - lsMain function accepting writer parameter
- [x] **mkdir** - runMkdir with stdout/stderr writers
- [x] **rmdir** - handleError returning !void for proper error propagation
- [x] **touch** - mainWithWriter accepting both writers
- [x] **mv** - Complete parameter threading for progress functions
- [x] **ln** - createSingleLink with writer parameters, test_mode support
- [x] **cp** - runCp and all sub-modules updated (errors.zig, user_interaction.zig, etc.)
- [x] **chmod** - printHelp and printVersion updated
- [x] **chown** - printHelp and printVersion updated
- [x] **common/lib.zig** - printErrorTo function added
- [x] **echo** - Already had writer support, updated for consistency
- [x] **rm** - Already had writer support, maintained
- [x] **pwd** - Already had writer support, maintained

#### Phase 3: Test Infrastructure ✓
- [x] Implemented anytype writer compatibility across all utilities
- [x] Verified stdout/stderr isolation in tests  
- [x] Removed dead code buffering tests (746 lines of stdlib testing)
- [x] Fixed writer parameter patterns to prevent test stderr pollution

#### Phase 4: Pattern Documentation ✓
- [x] Consistent runXxx() pattern returning ExitCode
- [x] main() as thin wrapper calling runXxx()
- [x] All output functions accept writer parameters
- [x] Tests use buffer writers for output verification

### Success Achieved
- [x] Zero test hangs due to stdout buffering
- [x] All utilities use consistent writer pattern
- [x] Full test coverage for output functionality
- [x] No performance regression (verified with timing tests)
- [x] Clear pattern established for future utilities

## Architecture Decisions

### Design Philosophy
- Balance OpenBSD clarity with GNU usefulness
- Modern UX improvements (colors, icons, responsive layouts)
- Smart defaults (auto-color, readable dates, parallel I/O)

### Shared Components
- [x] Create common library for:
  - [x] Error handling (fatal, printError, printWarning, ExitCode)
  - [x] Color output (Style with terminal detection)
  - [x] Progress indicators (Progress with ETA)
  - [x] Version/help support (CommonOpts)
  - [x] Advanced argument parsing (using zig-clap)
  - [x] File operations helpers (stat wrappers, permission formatting)
  - [x] **Unified file permissions** (file_ops.zig - prevents macOS SIGABRT)
  - [x] Size formatters (bytes, -k kilobytes, -h human readable)
  - [x] Date/time formatting helpers (smart recent vs old)
  - [x] User/group name lookup (getpwuid/getgrgid via C interop)
  - [x] CI environment detection (isRunningInCI, shouldSkipMacOSCITest)
  - [ ] Terminal width detection for responsive layouts
  - [ ] Parallel I/O utilities for performance

### Build System
- [x] Set up build.zig
- [x] Configure test runner
- [x] Common library module system
- [x] Integrate zig-clap dependency
- [x] Basic Makefile for common tasks
- [x] **Security fixes**: Replace fragile version parsing with safe ZON parser
- [x] **Modular architecture**: Metadata-driven utility configuration in build/utils.zig
- [x] **Memory management**: Fix memory leaks and add proper cleanup
- [x] **Error handling**: Replace @panic() calls with graceful error returns
- [x] **Test coverage**: Comprehensive unit tests for build system functions
- [x] **Code quality**: Pre-commit hook for automatic formatting and testing
- [x] **Coverage system**: Removed non-functional coverage system (Zig 0.15.1 lacks native coverage)
- [x] **CI/CD pipeline**: GitHub Actions workflows for cross-platform testing
- [x] **Multi-platform releases**: GitHub Actions matrix build (linux arm64/amd64, darwin arm64/amd64)
- [ ] Add install targets for man pages
- [ ] Add benchmarking infrastructure (see Benchmarking System section)

### Documentation
- [x] Man page style guide (OpenBSD-inspired):
  - [x] Concise DESCRIPTION
  - [x] Clear OPTIONS section
  - [x] 2-3 practical EXAMPLES
  - [x] Brief SEE ALSO
  - [x] No verbose explanations
- [x] Help text standardization (via --help flag)
- [x] Help text consistency test (automated checks across all utilities)
- [x] Man page standardization (mdoc format, consistent sections across 48 pages)
- [x] Design philosophy document
- [x] Zig patterns reference (ZIG_PATTERNS.md)
- [x] Standard library summary (STD_LIBRARY_SUMMARY.md)
- [ ] Man page generation/installation system
- [ ] Example usage for each utility
- [ ] Performance comparison with GNU coreutils

## Modern Enhancements

### Color Support
- [x] Terminal capability detection (basic, 256, truecolor)
- [x] NO_COLOR environment variable support
- [x] VIBEUTILS_STYLE environment variable (plain/color/full)
- [x] Graceful fallback for limited terminals
- [x] Colored help output with syntax highlighting
- [x] Nerd Font glyphs in help and ls
- [ ] LS_COLORS parsing and theming
- [ ] Accessibility modes
- [ ] User-configurable color themes

### Performance
- [ ] Parallel processing where applicable
- [ ] Memory-mapped I/O
- [ ] SIMD optimizations
- [ ] Async I/O for large operations

### Output Formats
- [ ] JSON output mode
- [ ] CSV output mode
- [ ] Null-separated output
- [ ] Progress bars for long operations

## Future Optimizations (Post-Implementation)

### Parallel Filesystem Operations Framework
- [ ] **Research Phase**: Study io_uring, kqueue, and thread pool alternatives
- [ ] **Architecture Design**: Cross-platform abstraction for parallel filesystem operations  
- [ ] **Core Interface**: Generic `ParallelFs.batchOperation()` supporting multiple operation types
- [ ] **Linux Implementation**: io_uring-based parallel operations (statx, openat, read, etc.)
- [ ] **BSD/macOS Implementation**: kqueue-based async or thread pool fallback
- [ ] **High-Level Operations**: 
  - `statMany()` - Parallel file stat operations
  - `openMany()` - Parallel file opening  
  - `readDirMany()` - Parallel directory reading
  - `readMany()` - Parallel file reading
- [ ] **Utility Integration**: Roll out to du, find, grep, cp, wc, and other I/O-heavy utilities
- [ ] **Performance Benchmarking**: Measure improvements on large filesystems
- [ ] **Error Handling**: Robust cross-platform error recovery and resource cleanup

**Complexity**: High (🔥🔥🔥) - Cross-platform async I/O, resource management, testing
**Impact**: Massive performance gains for `du`, `find`, `grep` on large directories
**Timeline**: 2-3 weeks implementation, significant maintenance overhead
**Decision**: Implement after core utilities are complete to avoid scope creep

## Privileged Testing Strategy

### Overview
Comprehensive cross-platform testing for commands that require elevated privileges (chmod, chown, etc.) across Linux, macOS, OpenBSD, FreeBSD, and NetBSD in GitHub Actions.

### Platform-Specific Approaches

#### Linux (Best Support)
- **Tools**: fakeroot, unshare (user namespaces), podman (rootless containers)
- **Strategy**: Full privilege simulation without actual root
- **Coverage**: 100% of privilege-related tests

#### macOS (Limited Options)
- **Tools**: Real sudo (GitHub Actions allows), limited fakeroot
- **Strategy**: Focus on error paths, use sudo for critical tests
- **Coverage**: ~70% through error simulation + real sudo tests

#### BSD Systems (VM-Based)
- **FreeBSD**: fakeroot available in ports
- **OpenBSD**: Use doas for privilege testing
- **NetBSD**: Basic permission testing
- **Strategy**: Run in VMs via vmactions/* GitHub Actions

### Commands Requiring Privileged Testing

#### Currently Implemented
- **rm**: chmod operations on write-protected files
- **mkdir**: Setting custom permissions with -m flag
- **cp**: Preserving permissions/ownership with -p
- **ls**: Displaying special permission bits
- **chmod**: Permission modification (setuid/setgid/sticky) - tests migrated to privilege framework ✓
- **chown**: Ownership changes

#### Planned Commands
- **ln**: Hard link permission requirements
- **stat**: Ownership/permission display
- **find**: Permission-denied scenarios
- **du/df**: Restricted directory access

### Implementation Plan

#### 1. Test Infrastructure ✓
- [x] Create src/common/privilege_test.zig module
- [x] Add platform detection (fakeroot, unshare, etc.)
- [x] Implement test skip annotations for unprivileged environments
- [x] Add mock system calls for unit testing

#### 2. GitHub Actions Workflow ✓
- [x] Linux: Test with fakeroot (automated privilege simulation)
- [x] macOS: Native testing with privilege simulation support
- [x] BSD: Set up VM-based testing with vmactions
- [x] Add privileged test matrix to CI pipeline
- [x] Cross-platform CI/CD with Ubuntu and macOS runners
- [x] Coverage reporting with Codecov integration
- [x] Security scanning with Dependabot and CodeQL
- [x] Automated release workflow with multi-platform binaries

#### 3. Test Categories
- [x] **Permission Simulation**: Test actual permission changes (infrastructure ready)
- [x] **Error Paths**: Test permission-denied handling
- [ ] **Integration Tests**: Real operations in permitted locations
- [x] **Mock Tests**: Unit tests with injected syscalls (via requiresPrivilege)

#### 4. Makefile Targets ✓
- [x] test-privileged: Cross-platform privileged test runner
- [x] test-privileged-linux: Linux-specific with fakeroot (make test-privileged)
- [x] test-privileged-macos: macOS with Docker fallback (make test-privileged-local)
- [x] test-privileged-bsd: BSD VMs with available tools

### Fallback Strategies
1. Test error paths (permission denied scenarios)
2. Use dependency injection for mockable syscalls
3. Focus on logic testing without privilege operations
4. Document privilege requirements

### Success Metrics
- [x] All privilege-related tests pass on Linux with fakeroot (infrastructure ready)
- [x] Core functionality works without privileges
- [x] Clear test output indicating skipped privileged tests
- [ ] CI passes on all 5 target platforms

## Benchmarking System

### Overview
Comprehensive performance tracking system to monitor improvements and regressions across all utilities.

### Infrastructure Components

#### 1. Benchmark Framework
- [ ] Add zBench dependency for Zig-native benchmarking
- [ ] Create benchmark directory structure (micro/utilities/comparative/scenarios)
- [ ] Implement BenchmarkResult and BenchmarkContext structs
- [ ] Add memory tracking allocator for detailed analysis
- [ ] Create benchmark runner with statistical analysis

#### 2. Benchmark Types

##### Micro-benchmarks (Function Level)
- [ ] Terminal style detection and color output
- [ ] Argument parsing performance
- [ ] File stat operations
- [ ] Directory traversal algorithms
- [ ] String formatting and allocation patterns

##### Utility Benchmarks (Command Level)
- [ ] Standard scenarios for each utility:
  - Empty inputs (baseline overhead)
  - Small inputs (typical usage)
  - Large inputs (stress testing)
  - Edge cases (pathological inputs)
- [ ] Memory usage profiling
- [ ] Syscall counting and analysis

##### Comparative Benchmarks
- [ ] Hyperfine integration for vibeutils vs GNU coreutils
- [ ] Automated comparison scripts
- [ ] Performance ratio tracking

##### Real-world Scenarios
- [ ] Large file processing (1GB, 10GB files)
- [ ] Many files handling (10k, 100k files)
- [ ] Deep directory trees (1000+ levels)
- [ ] Parallel operation benefits

#### 3. Metrics Collection
- [ ] Execution time (wall clock, CPU time)
- [ ] Memory usage (allocated, peak, leaked)
- [ ] System metrics (syscalls, cache misses, I/O operations)
- [ ] CPU metrics (instructions, cycles, branch predictions)

#### 4. CI/CD Integration
- [ ] GitHub Actions workflow for automated benchmarking
- [ ] Benchmark on: PRs, main commits, weekly schedule
- [ ] Performance regression detection (>10% threshold)
- [ ] Benchmark result storage in git branch
- [ ] GitHub Pages dashboard for visualization

#### 5. Build System Integration
- [ ] Add `zig build bench` target
- [ ] Makefile targets:
  - `make benchmark` - Run all benchmarks
  - `make bench-micro` - Micro-benchmarks only  
  - `make bench-utilities` - Utility benchmarks only
  - `make bench-compare` - GNU comparison
  - `make bench-report` - Generate HTML report

#### 6. Reporting and Visualization
- [ ] JSON output format for automation
- [ ] Historical trend graphs
- [ ] Regression alerts on PRs
- [ ] Performance comparison matrix
- [ ] Memory usage evolution charts

### Implementation Timeline
- **Week 1-2**: Infrastructure setup, zBench integration
- **Week 3-4**: Micro-benchmarks for common library
- **Week 5-6**: Utility benchmarks (echo, cat, ls)
- **Week 7-8**: Remaining utilities and comparative benchmarks
- **Week 9-10**: CI/CD integration and dashboard
- **Week 11-12**: Documentation and optimization based on findings

### Success Metrics
- [ ] All utilities benchmarked with 3+ scenarios each
- [ ] Performance within 10% of GNU coreutils
- [ ] Memory usage equal or better than GNU
- [ ] <5% false positive rate for regression detection
- [ ] 6+ months of historical data tracked

## CI/CD Infrastructure (Implemented) ✓

### GitHub Actions Workflows
- [x] **CI Workflow** (.github/workflows/ci.yml)
  - [x] Cross-platform testing (Ubuntu, macOS)
  - [x] Privileged test support with fakeroot
  - [x] Code formatting validation
  - [x] Build artifacts generation
  - [x] Performance benchmarking (basic)
  - [x] Code quality checks
  - [x] Integration test suite
  - [x] Windows build (experimental)

- [x] **Documentation Workflow** (.github/workflows/docs.yml)
  - [x] Automatic documentation generation
  - [x] GitHub Pages deployment
  - [x] API documentation from source
  - [x] Man page conversion to HTML

- [x] **Security Workflow** (.github/workflows/security.yml)
  - [x] Dependabot dependency scanning
  - [x] CodeQL static analysis
  - [x] Security policy enforcement
  - [x] Vulnerability reporting

- [x] **Release Workflow** (.github/workflows/release.yml)
  - [x] Automated release on tag push
  - [x] Multi-platform binary generation
  - [x] Checksum generation
  - [x] GitHub Release creation
  - [x] Asset upload automation

### Supporting Infrastructure
- [x] **Coverage Reporting**: Integrated with Codecov for test coverage tracking
- [x] **Privileged Testing**: Smart detection and fallback for privilege simulation
- [x] **File Permission Fixes**: Unified file operations to prevent macOS SIGABRT
- [x] **Error Reporting**: Consistent warning/error functions across utilities
- [x] **CI Environment Detection**: Helper functions for CI-specific behavior

### Key Improvements from CI/CD Implementation
1. **Cross-platform Compatibility**: Fixed file permission operations for macOS
2. **Test Reliability**: Privileged tests now skip gracefully when simulation unavailable
3. **Code Quality**: Automated formatting and quality checks on every push
4. **Security**: Continuous vulnerability scanning and static analysis
5. **Release Process**: Fully automated multi-platform releases

## Modern Features Roadmap

See `docs/plans/2026-03-01-modern-features-design.md` for
full design.

### 1. Colored `--help` Output ✓
- [x] Modify argparse to render colored help on TTY
- [x] Bold utility name and section headers
- [x] Cyan flag names, yellow arguments
- [x] Respect NO_COLOR, plain text when piped
- [x] Nerd-font glyphs for section headers
- [x] Yellow UPPERCASE metavariable highlighting in descriptions
- [x] Handle trailing punctuation and (s) suffixes

### 2. `grep --color=auto` ✓
- [x] Highlight matched text in bold red
- [x] Filename in magenta, line numbers in green
- [x] `--color=auto/always/never` flags
- [x] Match GNU grep color conventions

### 3. `VIBEUTILS_STYLE` Environment Variable ✓
- [x] `VIBEUTILS_STYLE=full`: color, icons, git status (TTY only)
- [x] `VIBEUTILS_STYLE=color`: color only, no icons (TTY only)
- [x] `VIBEUTILS_STYLE=plain`: no color, no icons, no glyphs
- [x] `VIBEUTILS_STYLE=always`: force all features through pipes
- [x] Presets respect TTY detection (no ANSI leaking into pipes)
- [x] NO_COLOR still respected
- [x] Integrated in ls, grep, du, and help output
- [x] `--color=auto` checks isatty(stdout) in ls
- [ ] `df`, `du`, `ls -l`: human-readable by default
- [ ] Explicit flags always override

### 3a. Command Linter Warnings ✓
- [x] chown: warn when argument looks like octal mode
- [x] chmod: warn when numeric mode contains 8 or 9
- [x] rm: refuse to remove '/' without --no-preserve-root
- [x] cp/mv: hint about -i for interactive overwrite prompts
- [x] ln: warn when creating dangling symlinks

### 3b. ls Git Status Auto-Detection ✓
- [x] Auto-enable git status when inside a git repo
- [x] `--git=WHEN` flag (always/auto/never)
- [x] Respects VIBEUTILS_STYLE (plain/color disable git)
- [x] Fix: suppress git status and icons in `-1` mode
- [x] Fix: alphabetize `--help` flags
- [x] Fix: flush stderr in `fatalWithWriter` before exit

### 4. Color-Coded Numeric Output
- [x] `df`: green/yellow/red by usage percentage
- [x] `df`: optional inline usage bar
- [ ] `du`: color size relative to largest entry
- [x] `du`: file-type icons before paths (`--icons=WHEN`)
- [x] `wc`: semantic column colors (`--color=WHEN`)
- [x] Icon coverage: 59 extensions, brand colors, dark-bg
  visibility

### 5. `tree` Utility
- [ ] Recursive directory listing with box-drawing lines
- [ ] File-type icons via common/icons
- [ ] Truecolor/256/basic icon coloring (reuse ls pattern)
- [ ] `-L` depth limit, `-d` directories only
- [ ] `-I` pattern exclusion
- [ ] Summary line (N directories, M files)
- [ ] `--color=auto/always/never`, respect NO_COLOR
- [ ] Man page

### 6. Progress Feedback for `cp`/`mv`/`dd`
- [ ] Progress module in `src/common/`
- [ ] Show status line on stderr after 2s delay
- [ ] Update in place, clear when done
- [ ] Only when stderr is a TTY

### 7. Smarter Error Messages
- [ ] File not found with fuzzy "did you mean?" suggestion
- [ ] Permission denied with hint
- [ ] Directory not empty with `rm -r` suggestion
- [ ] Start with `rm`, `cp`, `cat`

### 8. `diff` Utility
- [ ] Myers diff algorithm implementation
- [ ] Unified diff as default format
- [ ] Colored output (red/green/cyan)
- [ ] Flags: `-u`, `-c`, `-y`, `-r`, `-q`
- [ ] `--color=auto/always/never`
- [ ] Man page

## Testing Improvements (Post-Issue #5 Analysis)

The O_APPEND bug (issue #5) exposed gaps in our testing
strategy. These items address the categories of testing
that would have caught it — and similar bugs — earlier.

### 1. File Descriptor Mode Tests
- [ ] Generic test harness that runs each binary under
      different fd configurations
- [ ] Test `>> file` append mode for every utility
- [ ] Test pipe mode (`| cat`) for every utility
- [ ] Test truncate mode (`> file`) for every utility
- [ ] Test dup'd descriptors (`2>&1 >> file`)

### 2. POSIX Behavioral Conformance Suite
- [ ] `>>` must append, not overwrite
- [ ] Stdout to a closed pipe must produce SIGPIPE/EPIPE
- [ ] Stderr must be unbuffered
- [ ] Exit codes conform to POSIX spec
- [ ] Utility-agnostic: same I/O contract tests run
      against every binary

### 3. Cross-Platform Behavioral Comparison Tests
- [ ] Run identical operations on macOS and Linux
- [ ] Diff results between platforms
- [ ] Flag divergences as test failures (the divergence
      itself is the signal)

### 4. Real-World Pipeline Tests
- [ ] Log accumulation: repeated `>> logfile` appends
- [ ] Pipeline composition: `cat | sort | uniq >> output`
- [ ] Interleaved stdout/stderr with redirects
- [ ] Simulate actual usage patterns that exercise
      binaries in realistic scenarios

### 5. Adopt Shared TestDir Across All Utilities
- [ ] Replace ad-hoc `testing.tmpDir(.{})` usage with
      shared `common.test_dir.TestDir` in all utility tests
- [ ] Ensure all tests use absolute paths (no fchdir)
- [ ] Utilities to migrate: cat, chmod, chown, cut, dd,
      du, find, grep, head, ln, ls, mkdir, mktemp, nl,
      pwd, readlink, realpath, rm, rmdir, stat, tac,
      tail, tee, test, touch, tr, uniq, wc
- [ ] Consolidate mv.zig's local TestDir into the shared
      one

### 6. Fix LLVM Backend Test Failures
- [ ] cp overwrite hint test fails under `.use_llvm = true`
      but passes with self-hosted backend
- [ ] mv overwrite hint test has the same issue
- [ ] Root cause: likely Style/writer generic instantiation
      differs between backends
- [ ] Blocking accurate coverage numbers (2 of 49 binaries
      fail)

### 7. main() Function Coverage
- [ ] Test the writer setup code path in main(), not just
      runUtil() with test-provided writers
- [ ] Integration tests that exercise the compiled binary's
      actual I/O initialization

## Success Criteria
- [ ] All utilities pass GNU coreutils test suite
- [ ] Performance within 10% of GNU implementation
- [ ] 90%+ test coverage
- [ ] Clean static analysis reports
- [ ] Comprehensive benchmarking system
- [x] Privileged operations tested (Linux, macOS)
- [x] CI/CD pipeline operational
