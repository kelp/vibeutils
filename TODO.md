# Zutils - GNU Coreutils in Zig

## Progress Summary
- **Utilities Completed**: 3/46 (echo ✓, cat ✓, ls ✓)
- **Utilities In Progress**: 0/46
- **GNU Compatibility**: echo 100%, cat 100%, ls ~90% (most useful features + colors + responsive layout + directory grouping + recursive + modern enhancements)
- **Common Library**: Core functionality implemented (including user/group lookup, terminal utils)
- **Documentation**: Design philosophy, Zig patterns, man page style established
- **Build System**: Basic structure with tests working
- **New Approach**: Balancing OpenBSD simplicity with GNU's most-used features + modern UX

## Project Goals
- **Practical GNU compatibility** - implement features people actually use
- **OpenBSD-inspired simplicity** - clear, orthogonal options
- **Modern enhancements** - better colors, icons, smart formatting, performance
- **High test coverage** (90%+)
- **Test-Driven Development** approach
- **OpenBSD-style concise man pages** with practical examples
- **Balance**: ~80% of GNU's usefulness with ~20% of the complexity

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

#### 3. ls - Phase 1 ✓, Phase 2 ✓, Phase 3 ✓, Phase 4 ✓
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

###### Phase 5: Modern Enhancements (Stretch Goals)
- [ ] Test: Nerd font icon detection
- [ ] Test: Icon mapping for common file types
- [ ] Test: Git status integration (modified/new files)
- [ ] Test: Smart date formatting ("2 hours ago")
- [ ] Test: Parallel stat() for performance
- [ ] Implement: Optional icon system
- [ ] Implement: Git repository detection
- [ ] Implement: Human-friendly date formatting
- [ ] Implement: Parallel I/O for large directories

##### ls - Features We're NOT Implementing
- SELinux context (-Z, --context) - Too Linux-specific
- Author field (--author) - Nobody uses this
- Emacs dired mode (-D, --dired) - Too niche
- Complex quoting styles - Just escape when needed
- Multiple time formats - One smart format is enough
- Block size gymnastics (--block-size) - Just -h and -k
- All the --indicator-style variants - Just -F
- Explicit --si flag - We use binary (1024) for -h

#### 4. cp
- [ ] Test: Single file copy
- [ ] Test: Directory copy (-r)
- [ ] Test: Preserve attributes (-p)
- [ ] Test: Interactive mode (-i)
- [ ] Test: Force overwrite (-f)
- [ ] Test: Symbolic link handling
- [ ] Test: Permission preservation
- [ ] Test: Error cases (permission denied, disk full)
- [ ] Implement: Basic file copying
- [ ] Implement: Directory recursion
- [ ] Implement: Attribute preservation
- [ ] Implement: Symlink handling
- [ ] Man page: Write concise man page with examples

#### 5. mv
- [ ] Test: File rename in same directory
- [ ] Test: Move to different directory
- [ ] Test: Directory move
- [ ] Test: Interactive mode (-i)
- [ ] Test: Force mode (-f)
- [ ] Test: Cross-filesystem move
- [ ] Test: Atomic rename when possible
- [ ] Implement: Basic move/rename
- [ ] Implement: Cross-filesystem support
- [ ] Implement: Directory handling
- [ ] Man page: Write concise man page with examples

#### 6. rm
- [ ] Test: Single file removal
- [ ] Test: Multiple files
- [ ] Test: Directory removal (-r)
- [ ] Test: Force mode (-f)
- [ ] Test: Interactive mode (-i)
- [ ] Test: Write-protected file handling
- [ ] Test: Non-existent file behavior
- [ ] Implement: Basic removal
- [ ] Implement: Recursive removal
- [ ] Implement: Safety checks
- [ ] Man page: Write concise man page with examples

#### 7. mkdir
- [ ] Test: Single directory creation
- [ ] Test: Parent creation (-p)
- [ ] Test: Mode setting (-m)
- [ ] Test: Multiple directories
- [ ] Test: Already exists error
- [ ] Test: Permission denied
- [ ] Implement: Basic mkdir
- [ ] Implement: Parent directory creation
- [ ] Implement: Permission setting
- [ ] Man page: Write concise man page with examples

#### 8. rmdir
- [ ] Test: Empty directory removal
- [ ] Test: Non-empty directory error
- [ ] Test: Parent removal (-p)
- [ ] Test: Multiple directories
- [ ] Test: Non-existent directory
- [ ] Implement: Basic removal
- [ ] Implement: Parent cleanup
- [ ] Man page: Write concise man page with examples

#### 9. touch
- [ ] Test: Create new file
- [ ] Test: Update existing file timestamp
- [ ] Test: Specific time (-t)
- [ ] Test: Reference file (-r)
- [ ] Test: Access time only (-a)
- [ ] Test: Modification time only (-m)
- [ ] Implement: File creation
- [ ] Implement: Timestamp manipulation
- [ ] Implement: Reference file support
- [ ] Man page: Write concise man page with examples

#### 10. pwd
- [ ] Test: Basic working directory
- [ ] Test: Logical path (-L)
- [ ] Test: Physical path (-P)
- [ ] Test: Symlink resolution
- [ ] Implement: Basic pwd
- [ ] Implement: Path resolution options
- [ ] Man page: Write concise man page with examples

#### 11. chmod
- [ ] Test: Basic permission changes (numeric: 755, 644)
- [ ] Test: Symbolic mode changes (u+x, g-w, o=r)
- [ ] Test: Recursive mode (-R)
- [ ] Test: Preserve root (-c, --changes)
- [ ] Test: Error handling (permission denied)
- [ ] Test: Special bits (setuid, setgid, sticky)
- [ ] Implement: Numeric mode parser
- [ ] Implement: Symbolic mode parser
- [ ] Implement: Recursive directory walker
- [ ] Man page: Write concise man page with examples

#### 12. chown
- [ ] Test: Basic ownership change (user:group)
- [ ] Test: User only change
- [ ] Test: Group only change (:group)
- [ ] Test: Recursive mode (-R)
- [ ] Test: Dereference/no-dereference (-h, -H, -L, -P)
- [ ] Test: From reference file (--reference)
- [ ] Implement: User/group parsing
- [ ] Implement: Ownership change syscalls
- [ ] Implement: Recursive walker with symlink handling
- [ ] Man page: Write concise man page with examples

#### 13. ln
- [ ] Test: Create hard link
- [ ] Test: Create symbolic link (-s)
- [ ] Test: Force overwrite (-f)
- [ ] Test: Interactive mode (-i)
- [ ] Test: Create links in directory (-t)
- [ ] Test: Relative symlinks (--relative)
- [ ] Test: Error cases (cross-device hard link)
- [ ] Implement: Hard link creation
- [ ] Implement: Symbolic link creation
- [ ] Implement: Path resolution for relative links
- [ ] Man page: Write concise man page with examples

#### 14. basename
- [ ] Test: Strip directory from path
- [ ] Test: Strip suffix (-s, --suffix)
- [ ] Test: Multiple paths (-a, --multiple)
- [ ] Test: Zero delimiter (-z, --zero)
- [ ] Test: Edge cases (/, //, no slash)
- [ ] Implement: Path parsing logic
- [ ] Implement: Suffix stripping
- [ ] Implement: Multiple file handling
- [ ] Man page: Write concise man page with examples

#### 15. dirname
- [ ] Test: Extract directory from path
- [ ] Test: Multiple paths
- [ ] Test: Zero delimiter (-z, --zero)
- [ ] Test: Edge cases (/, //, no slash, .)
- [ ] Implement: Path parsing logic
- [ ] Implement: Multiple path handling
- [ ] Man page: Write concise man page with examples

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

#### 18. false
- [ ] Test: Always returns 1 exit code
- [ ] Test: Ignores all arguments
- [ ] Implement: Minimal implementation
- [ ] Man page: Write concise man page

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

### Phase 2: Text Processing Utilities

#### 28. dd
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

#### 29. realpath
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

#### 30. readlink
- [ ] Test: Print symlink target
- [ ] Test: Canonicalize (-f, --canonicalize)
- [ ] Test: Canonicalize existing (-e)
- [ ] Test: Canonicalize missing (-m)
- [ ] Test: No newline (-n, --no-newline)
- [ ] Test: Error on non-symlink
- [ ] Implement: Symlink reading
- [ ] Implement: Path canonicalization
- [ ] Man page: Write concise man page with examples

#### 31. mktemp
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

#### 32. timeout
- [ ] Test: Run command with timeout
- [ ] Test: Exit status preservation (--preserve-status)
- [ ] Test: Kill after timeout (-k, --kill-after)
- [ ] Test: Foreground mode (--foreground)
- [ ] Test: Different signals (-s TERM)
- [ ] Test: Time units (5s, 2m, 1h)
- [ ] Implement: Process spawning
- [ ] Implement: Timer management
- [ ] Implement: Signal handling
- [ ] Man page: Write concise man page with examples

#### 33. tac
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

#### 34. nl
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

#### 35. head
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

#### 36. tail
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

#### 37. wc
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

#### 38. sort
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

#### 39. uniq
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

#### 40. cut
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

#### 41. tr
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

#### 42. stat
- [ ] Test: File information display
- [ ] Test: Custom format (-c)
- [ ] Test: Filesystem info (-f)
- [ ] Test: Dereference (-L)
- [ ] Test: Terse output (-t)
- [ ] Implement: System call wrapper
- [ ] Implement: Format string parser
- [ ] Implement: Human-readable output
- [ ] Man page: Write concise man page with examples

#### 43. du
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

#### 44. df
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

#### 45. find
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

#### 46. grep
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

### Unit Tests
- Test each flag individually
- Test flag combinations
- Test error conditions
- Test edge cases (empty files, huge files, special characters)

### Integration Tests
- Test pipe compatibility
- Test signal handling
- Test GNU coreutils compatibility
- Test performance benchmarks

### Test Coverage Goals
- Line coverage: 90%+
- Branch coverage: 85%+
- Error path coverage: 100%

## Architecture Decisions

### Design Philosophy for ls
- **Balance OpenBSD clarity with GNU usefulness**
- **Start minimal, add features users actually use**
- **Modern UX improvements neither BSD nor GNU have**
- **Performance matters - parallel I/O where beneficial**
- **Smart defaults: color auto, responsive columns, readable dates**

### Shared Components
- [x] Create common library for:
  - [x] Error handling (fatal, printError, ExitCode)
  - [x] Color output (Style with terminal detection)
  - [x] Progress indicators (Progress with ETA)
  - [x] Version/help support (CommonOpts)
  - [x] Advanced argument parsing (using zig-clap)
  - [x] File operations helpers (stat wrappers, permission formatting)
  - [x] Size formatters (bytes, -k kilobytes, -h human readable)
  - [x] Date/time formatting helpers (smart recent vs old)
  - [x] User/group name lookup (getpwuid/getgrgid via C interop)
  - [ ] Terminal width detection for responsive layouts
  - [ ] Parallel I/O utilities for performance

### Build System
- [x] Set up build.zig
- [x] Configure test runner
- [x] Common library module system
- [x] Integrate zig-clap dependency
- [x] Basic Makefile for common tasks
- [ ] Set up CI/CD pipeline with GitHub Actions
- [ ] Configure coverage reporting with kcov
- [ ] Add install targets for man pages
- [ ] Add benchmarking infrastructure

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

## Success Criteria
- [ ] All utilities pass GNU coreutils test suite
- [ ] Performance within 10% of GNU implementation
- [ ] 90%+ test coverage
- [ ] Clean cppcheck/valgrind reports
- [ ] Successful fuzzing campaigns