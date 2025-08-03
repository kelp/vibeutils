# vibeutils - GNU Coreutils in Zig

## Progress Summary
- **Completed**: 16/47 utilities (basename, cat, chmod, chown, cp, dirname, echo, false, ln, ls, mkdir, mv, pwd, rm, rmdir, touch)
- **Compatibility**: 90-100% GNU feature coverage for completed utilities
- **Infrastructure**: Build system, CI/CD, privileged testing, writer-based I/O
- **Documentation**: Claude Code quality check (/qc), man page style guide, testing strategy

## Project Goals
- **Balance**: 80% of GNU's usefulness with 20% of the complexity
- **High test coverage**: 90%+ with TDD approach
- **Modern enhancements**: Colors, icons, smart formatting, performance
- **OpenBSD-inspired**: Clear options, concise man pages with examples
- **Practical compatibility**: Features people actually use

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
- [ ] Man page: Write concise man page with examples

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
- [ ] Man page: Write concise man page with examples

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

#### 16. sleep
- [ ] Test: Sleep for seconds
- [ ] Test: Sleep for decimal seconds (0.5)
- [ ] Test: Sleep for minutes/hours/days suffix (5m, 2h, 1d)
- [ ] Test: Multiple time arguments (sleep 1m 30s)
- [ ] Test: Signal handling (interruptible)
- [ ] Implement: Time parsing with units
- [ ] Implement: High-precision sleep
- [ ] Implement: Signal-safe sleep
- [ ] Man page: Write concise man page with examples

#### 17. true
- [ ] Test: Always returns 0 exit code
- [ ] Test: Ignores all arguments
- [ ] Implement: Minimal implementation
- [ ] Man page: Write concise man page

#### 18. false ✓
- [x] Test: Always returns 1 exit code
- [x] Test: Ignores all arguments
- [x] Test: Produces no output
- [x] Test: Handles empty arguments array
- [x] Test: Handles many arguments
- [x] Implement: Minimal implementation
- [x] Man page: Write concise man page

#### 19. test
- [ ] Test: File existence checks (-e, -f, -d, -r, -w, -x)
- [ ] Test: String comparisons (=, !=, -z, -n)
- [ ] Test: Numeric comparisons (-eq, -ne, -lt, -le, -gt, -ge)
- [ ] Test: Logical operators (-a, -o, !)
- [ ] Test: Complex expressions with parentheses
- [ ] Test: Exit codes (0 for true, 1 for false)
- [ ] Implement: Expression parser
- [ ] Implement: File test operations
- [ ] Implement: Comparison operations
- [ ] Man page: Write concise man page with examples

#### 20. date
- [ ] Test: Display current date/time
- [ ] Test: Custom format string (+FORMAT)
- [ ] Test: Set date/time (-s, --set)
- [ ] Test: Display file's date (-r, --reference)
- [ ] Test: UTC mode (-u, --utc)
- [ ] Test: RFC formats (--rfc-3339, --rfc-email)
- [ ] Test: Relative dates (-d "2 days ago")
- [ ] Implement: Format string parser (strftime-like)
- [ ] Implement: Date parsing for various formats
- [ ] Implement: Relative date calculations
- [ ] Man page: Write concise man page with examples

#### 21. env
- [ ] Test: Print current environment
- [ ] Test: Run command with modified env (env VAR=value cmd)
- [ ] Test: Clear environment (-i, --ignore-environment)
- [ ] Test: Unset variables (-u, --unset)
- [ ] Test: Change directory (-C, --chdir)
- [ ] Test: Split string arguments (-S)
- [ ] Implement: Environment manipulation
- [ ] Implement: Command execution with env
- [ ] Implement: Argument splitting parser
- [ ] Man page: Write concise man page with examples

#### 22. seq
- [ ] Test: Generate sequence (seq 10)
- [ ] Test: Start and end (seq 5 10)
- [ ] Test: Start, increment, end (seq 1 2 10)
- [ ] Test: Floating point sequences (seq 0.1 0.1 1.0)
- [ ] Test: Format string (-f "%03g")
- [ ] Test: Separator (-s ", ")
- [ ] Test: Equal width (-w)
- [ ] Implement: Number sequence generation
- [ ] Implement: Format string support
- [ ] Implement: Width calculation
- [ ] Man page: Write concise man page with examples

#### 23. tee
- [ ] Test: Write to stdout and file
- [ ] Test: Write to multiple files
- [ ] Test: Append mode (-a, --append)
- [ ] Test: Ignore interrupts (-i)
- [ ] Test: Diagnose write errors (-p)
- [ ] Test: Binary data handling
- [ ] Implement: Multi-writer system
- [ ] Implement: Signal handling
- [ ] Implement: Error diagnosis
- [ ] Man page: Write concise man page with examples

#### 24. yes
- [ ] Test: Repeat "y" infinitely
- [ ] Test: Repeat custom string
- [ ] Test: Multiple arguments joined with space
- [ ] Test: Performance (must be fast)
- [ ] Test: SIGPIPE handling
- [ ] Implement: Efficient output loop
- [ ] Implement: Buffer optimization
- [ ] Implement: Signal handling
- [ ] Man page: Write concise man page with examples

#### 25. whoami
- [ ] Test: Print effective username
- [ ] Test: No options accepted
- [ ] Test: Error when can't determine user
- [ ] Implement: Get effective user ID
- [ ] Implement: User lookup
- [ ] Man page: Write concise man page with examples

#### 26. id
- [ ] Test: Print all IDs (default)
- [ ] Test: User ID only (-u, --user)
- [ ] Test: Group ID only (-g, --group)
- [ ] Test: All group IDs (-G, --groups)
- [ ] Test: Names instead of numbers (-n, --name)
- [ ] Test: Real instead of effective (-r, --real)
- [ ] Test: Different user (id username)
- [ ] Implement: ID retrieval syscalls
- [ ] Implement: User/group lookups
- [ ] Implement: Format selection
- [ ] Man page: Write concise man page with examples

#### 27. printf
- [ ] Test: Basic format strings (%s, %d, %f)
- [ ] Test: Escape sequences (\n, \t, \x41)
- [ ] Test: Width and precision (%.2f, %10s)
- [ ] Test: Multiple arguments with reuse
- [ ] Test: Octal/hex formats (%o, %x, %X)
- [ ] Test: Error handling (type mismatches)
- [ ] Implement: Format string parser
- [ ] Implement: Type conversions
- [ ] Implement: Escape sequence handling
- [ ] Man page: Write concise man page with examples

#### 28. free
- [ ] Test: Basic memory information display (total, used, free, available)
- [ ] Test: Human readable format (-h) with K/M/G/T units
- [ ] Test: Show swap information (default)
- [ ] Test: Hide swap information (-s, --no-swap)
- [ ] Test: Continuous monitoring (-c, --count with interval)
- [ ] Test: Wide format (-w) for better readability
- [ ] Test: Color-coded memory usage levels (green/yellow/red)
- [ ] Test: Cross-platform support (Linux /proc/meminfo, macOS vm_stat)
- [ ] Test: Memory pressure indicators and warnings
- [ ] Test: Unicode glyphs and progress bars for visual appeal
- [ ] Implement: Linux memory parsing (/proc/meminfo)
- [ ] Implement: macOS memory info via syscalls (host_statistics64)
- [ ] Implement: Human-readable size formatting
- [ ] Implement: Color-coded output with terminal detection
- [ ] Implement: Progress bar visualization for memory usage
- [ ] Implement: Modern glyphs and icons for memory types
- [ ] Implement: Continuous monitoring with refresh
- [ ] Man page: Write concise man page with examples

### Phase 2: Text Processing Utilities

#### 29. dd
- [ ] Test: Basic copy (if=input of=output)
- [ ] Test: Block size (bs=1M, ibs=512, obs=4096)
- [ ] Test: Count limit (count=100)
- [ ] Test: Seek/skip (seek=10, skip=5)
- [ ] Test: Conversion (conv=ucase,lcase,notrunc,sync)
- [ ] Test: Status output (status=progress)
- [ ] Test: Direct I/O (iflag=direct, oflag=direct)
- [ ] Implement: Block-based I/O
- [ ] Implement: Conversion operations
- [ ] Implement: Progress reporting
- [ ] Man page: Write concise man page with examples

#### 30. realpath
- [ ] Test: Resolve to absolute path
- [ ] Test: Canonicalize existing (-e, --canonicalize-existing)
- [ ] Test: Canonicalize missing (-m, --canonicalize-missing)
- [ ] Test: No symlinks (-s, --strip, --no-symlinks)
- [ ] Test: Relative to directory (--relative-to)
- [ ] Test: Relative base (--relative-base)
- [ ] Implement: Path resolution
- [ ] Implement: Symlink following
- [ ] Implement: Relative path computation
- [ ] Man page: Write concise man page with examples

#### 31. readlink
- [ ] Test: Print symlink target
- [ ] Test: Canonicalize (-f, --canonicalize)
- [ ] Test: Canonicalize existing (-e)
- [ ] Test: Canonicalize missing (-m)
- [ ] Test: No newline (-n, --no-newline)
- [ ] Test: Error on non-symlink
- [ ] Implement: Symlink reading
- [ ] Implement: Path canonicalization
- [ ] Man page: Write concise man page with examples

#### 32. mktemp
- [ ] Test: Create temporary file
- [ ] Test: Create temporary directory (-d, --directory)
- [ ] Test: Custom template (mktemp /tmp/test.XXX)
- [ ] Test: Dry run (-u, --dry-run)
- [ ] Test: Custom tmpdir (--tmpdir)
- [ ] Test: Suffix (--suffix=.txt)
- [ ] Implement: Secure random name generation
- [ ] Implement: Atomic file creation
- [ ] Implement: Template parsing
- [ ] Man page: Write concise man page with examples

#### 33. timeout (Priority: High - Missing on macOS)
- [ ] Test: Basic timeout with seconds (timeout 5 sleep 10)
- [ ] Test: Command succeeds before timeout (exit status 0)
- [ ] Test: Command killed on timeout (exit status 124)
- [ ] Test: Floating point durations (timeout 2.5 sleep 3)
- [ ] Test: Time units (5s, 2m, 1h, 0.5d)
- [ ] Test: Zero timeout disables (timeout 0 sleep 1)
- [ ] Test: Exit status preservation (--preserve-status)
- [ ] Test: Kill after timeout (-k 2s kills if TERM ignored)
- [ ] Test: Custom signals (-s INT, -s KILL, -s 15)
- [ ] Test: Foreground mode (-f) for interactive commands
- [ ] Test: Verbose mode (-v) diagnostic output
- [ ] Test: Command not found (exit 127)
- [ ] Test: Command not executable (exit 126)
- [ ] Test: Signal handling (SIGTERM, SIGKILL propagation)
- [ ] Test: Child process handling
- [ ] Test: Error cases (invalid duration, invalid signal)
- [ ] Implement: Duration parser (float + units)
- [ ] Implement: Process spawning with exec
- [ ] Implement: Timer using setitimer or timerfd
- [ ] Implement: Signal management and propagation
- [ ] Implement: Foreground TTY handling
- [ ] Implement: Exit status handling
- [ ] Implement: Verbose diagnostic messages
- [ ] Man page: Write concise man page with examples

##### timeout - Implementation Notes
**Why Priority**: macOS lacks timeout, causing issues in scripts/CI
**Key Features**: Must support both simple (timeout 5 cmd) and complex (timeout -k 2s -s INT 10s cmd) usage
**Platform Considerations**: 
- Linux: Use timerfd_create for precise timing
- macOS/BSD: Use setitimer or kqueue timers
- Signal handling must be robust across platforms

#### 34. tac
- [ ] Test: Reverse file lines
- [ ] Test: Multiple files
- [ ] Test: Custom separator (-s, --separator)
- [ ] Test: Separator before line (-b, --before)
- [ ] Test: Regex separator (-r, --regex)
- [ ] Test: Large file handling
- [ ] Implement: Reverse line reading
- [ ] Implement: Memory-efficient algorithm
- [ ] Implement: Separator handling
- [ ] Man page: Write concise man page with examples

#### 35. nl
- [ ] Test: Number all lines (default)
- [ ] Test: Number non-empty lines (-b a, -b t)
- [ ] Test: Number format (-n ln, -n rn, -n rz)
- [ ] Test: Starting number (-v 100)
- [ ] Test: Increment (-i 2)
- [ ] Test: Width (-w 4)
- [ ] Test: Separator (-s ": ")
- [ ] Implement: Line numbering logic
- [ ] Implement: Format options
- [ ] Implement: Section handling
- [ ] Man page: Write concise man page with examples

#### 36. head
- [ ] Test: Default 10 lines
- [ ] Test: Custom line count (-n)
- [ ] Test: Byte count (-c)
- [ ] Test: Multiple files
- [ ] Test: STDIN input
- [ ] Test: File headers with multiple files
- [ ] Implement: Line-based reading
- [ ] Implement: Byte-based reading
- [ ] Implement: Multi-file handling
- [ ] Man page: Write concise man page with examples

#### 37. tail
- [ ] Test: Default 10 lines
- [ ] Test: Custom line count (-n)
- [ ] Test: Follow mode (-f)
- [ ] Test: Byte count (-c)
- [ ] Test: Multiple files
- [ ] Test: Reverse line reading
- [ ] Implement: Efficient line reading from end
- [ ] Implement: Follow mode with inotify
- [ ] Implement: Ring buffer for performance
- [ ] Man page: Write concise man page with examples

#### 38. wc
- [ ] Test: Line count (-l)
- [ ] Test: Word count (-w)
- [ ] Test: Byte count (-c)
- [ ] Test: Character count (-m)
- [ ] Test: Multiple files
- [ ] Test: STDIN input
- [ ] Test: Unicode handling
- [ ] Implement: Efficient counting
- [ ] Implement: Unicode support
- [ ] Implement: Parallel counting for large files
- [ ] Man page: Write concise man page with examples

#### 39. sort
- [ ] Test: Basic alphabetical sort
- [ ] Test: Numeric sort (-n)
- [ ] Test: Reverse sort (-r)
- [ ] Test: Key-based sort (-k)
- [ ] Test: Unique sort (-u)
- [ ] Test: Case-insensitive (-f)
- [ ] Test: Memory limit handling
- [ ] Implement: In-memory sorting
- [ ] Implement: External merge sort
- [ ] Implement: Key extraction
- [ ] Man page: Write concise man page with examples

#### 40. uniq
- [ ] Test: Remove adjacent duplicates
- [ ] Test: Count occurrences (-c)
- [ ] Test: Only duplicates (-d)
- [ ] Test: Only unique (-u)
- [ ] Test: Skip fields (-f)
- [ ] Test: Case-insensitive (-i)
- [ ] Implement: Line comparison
- [ ] Implement: Counting logic
- [ ] Implement: Field skipping
- [ ] Man page: Write concise man page with examples

#### 41. cut
- [ ] Test: Byte selection (-b)
- [ ] Test: Character selection (-c)
- [ ] Test: Field selection (-f)
- [ ] Test: Delimiter (-d)
- [ ] Test: Complement (-c)
- [ ] Test: Multiple files
- [ ] Implement: Range parsing
- [ ] Implement: UTF-8 character handling
- [ ] Implement: Field extraction
- [ ] Man page: Write concise man page with examples

#### 42. tr
- [ ] Test: Character translation
- [ ] Test: Character deletion (-d)
- [ ] Test: Squeeze repeats (-s)
- [ ] Test: Complement set (-c)
- [ ] Test: Character classes [:alpha:]
- [ ] Test: Range expansion [a-z]
- [ ] Implement: Translation tables
- [ ] Implement: Unicode support
- [ ] Implement: Character class parsing
- [ ] Man page: Write concise man page with examples

### Phase 3: File Information Utilities

#### 43. stat
- [ ] Test: File information display
- [ ] Test: Custom format (-c)
- [ ] Test: Filesystem info (-f)
- [ ] Test: Dereference (-L)
- [ ] Test: Terse output (-t)
- [ ] Implement: System call wrapper
- [ ] Implement: Format string parser
- [ ] Implement: Human-readable output
- [ ] Man page: Write concise man page with examples

#### 44. du
- [ ] Test: Directory size calculation
- [ ] Test: Human readable (-h)
- [ ] Test: Summary only (-s)
- [ ] Test: Max depth (-d)
- [ ] Test: Exclude patterns
- [ ] Test: Hard link handling
- [ ] Implement: Directory traversal
- [ ] Implement: Size calculation
- [ ] Implement: Caching for performance
- [ ] Man page: Write concise man page with examples

#### 45. df
- [ ] Test: Filesystem listing
- [ ] Test: Human readable (-h)
- [ ] Test: Filesystem type (-t)
- [ ] Test: Inode information (-i)
- [ ] Test: Mount point resolution
- [ ] Implement: Mount point parsing
- [ ] Implement: Space calculation
- [ ] Implement: Filesystem filtering
- [ ] Man page: Write concise man page with examples

### Phase 4: Advanced Utilities

#### 46. find
- [ ] Test: Name matching (-name)
- [ ] Test: Type filtering (-type)
- [ ] Test: Size filtering (-size)
- [ ] Test: Time filtering (-mtime)
- [ ] Test: Execution (-exec)
- [ ] Test: Logical operators
- [ ] Test: Depth control
- [ ] Implement: Expression parser
- [ ] Implement: Directory walker
- [ ] Implement: Action execution
- [ ] Man page: Write concise man page with examples

#### 47. grep
- [ ] Test: Basic pattern matching
- [ ] Test: Regular expressions (-E)
- [ ] Test: Case insensitive (-i)
- [ ] Test: Invert match (-v)
- [ ] Test: Line numbers (-n)
- [ ] Test: Recursive (-r)
- [ ] Test: Binary file handling
- [ ] Implement: Pattern compilation
- [ ] Implement: Line matching
- [ ] Implement: Performance optimizations
- [ ] Man page: Write concise man page with examples

## Testing Strategy
- **Coverage Goals**: 90%+ line, 85%+ branch, 100% error paths
- **Unit Tests**: Individual flags, combinations, edge cases
- **Integration Tests**: Pipes, signals, GNU compatibility, benchmarks

### Custom Argument Parser Implementation

#### Replace zig-clap Dependency (TDD)
**Goal**: Replace zig-clap's 3,000 lines with focused ~400-line library supporting 95% of real usage patterns

**Design Philosophy**:
- API-first design with type-safe interfaces
- Zero allocations for flag parsing (positionals may allocate)
- Compile-time validation where possible
- Self-documenting through struct field names
- OpenBSD-inspired simplicity with GNU compatibility

##### Phase 1: Core Parsing Engine (TDD)
- [ ] Test: Boolean flag parsing (-h, --help, -v, --verbose)
- [ ] Test: Combined short flags (-abc = -a -b -c)
- [ ] Test: Unknown flag error handling
- [ ] Test: Flag mapping generation from struct reflection
- [ ] Test: Memory management (no leaks)
- [ ] Implement: Core `Args.parse()` function with generic struct support
- [ ] Implement: Comptime flag mapping using `@typeInfo()`
- [ ] Implement: Boolean flag state management
- [ ] Implement: ParseResult with proper cleanup
- [ ] Implement: Error types (InvalidArgument, UnknownFlag, MissingValue)

##### Phase 2: String Options and Positionals (TDD)
- [ ] Test: String option parsing (--color=auto, --output file)
- [ ] Test: Both `--option=value` and `--option value` syntax
- [ ] Test: Missing value error for string options
- [ ] Test: Positional argument collection
- [ ] Test: GNU `--` separator handling
- [ ] Test: Single `-` as positional (stdin convention)
- [ ] Implement: String option value extraction
- [ ] Implement: Two-pass parsing (flags first, then values)
- [ ] Implement: Positional argument allocation and management
- [ ] Implement: State machine for parsing stages

##### Phase 3: Help Generation System (TDD)
- [ ] Test: Help text parsing from struct `help_text` field
- [ ] Test: Automatic help formatting matching GNU style
- [ ] Test: Usage line generation with positional indicators
- [ ] Test: Option description alignment and formatting
- [ ] Test: Integration with existing --help flag patterns
- [ ] Implement: `Args.printHelp()` function
- [ ] Implement: Help text parser for embedded descriptions
- [ ] Implement: GNU-style help formatting
- [ ] Implement: Usage line generation based on struct analysis

##### Phase 4: GNU Compatibility and Edge Cases (TDD)
- [ ] Test: POSIX compliance for argument ordering
- [ ] Test: Error message format matching GNU conventions
- [ ] Test: Complex combined flags with string options
- [ ] Test: Edge cases (empty args, only positionals, only flags)
- [ ] Test: Integration with all existing utility patterns
- [ ] Implement: Full GNU argument parsing compatibility
- [ ] Implement: Comprehensive error reporting
- [ ] Implement: Performance optimization (comptime where possible)

##### Migration Plan (Utility-by-Utility)
- [ ] **echo**: Migrate simplest case (boolean flags only)
- [ ] **cat**: Multiple boolean flags, combination flags (-A, -e, -t)
- [ ] **ls**: Complex case with string options (--color, --time-style)
- [ ] **cp/mv/rm**: Interactive flags and mixed option types
- [ ] **mkdir/rmdir/touch**: Mode settings and timestamp options
- [ ] **Remaining utilities**: Complete migration for all 9 implemented utilities

##### Integration and Cleanup
- [ ] Test: Drop-in compatibility with existing utility code
- [ ] Test: Performance benchmarks vs zig-clap
- [ ] Test: Binary size comparison
- [ ] Test: Compile time comparison
- [ ] Update: build.zig to remove zig-clap dependency
- [ ] Update: build.zig.zon to remove clap entry
- [ ] Verify: All existing tests pass with new parser
- [ ] Document: Migration guide and API documentation

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
- [x] **Coverage system**: Integrate Zig's native coverage support
- [x] **CI/CD pipeline**: GitHub Actions workflows for cross-platform testing
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
- [x] Graceful fallback for limited terminals
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
- [ ] BSD: Set up VM-based testing with vmactions
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
- [ ] test-privileged-bsd: BSD VMs with available tools

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

## Success Criteria
- [ ] All utilities pass GNU coreutils test suite
- [ ] Performance within 10% of GNU implementation
- [ ] 90%+ test coverage
- [ ] Clean static analysis reports
- [ ] Comprehensive benchmarking system
- [x] Privileged operations tested (Linux, macOS)
- [x] CI/CD pipeline operational
