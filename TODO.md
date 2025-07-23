# Zutils - GNU Coreutils in Zig

## Progress Summary
- **Utilities Completed**: 2/22 (echo ✓, cat ✓)
- **Utilities In Progress**: 1/22 (ls - Phase 1 & most of Phase 2 complete)
- **GNU Compatibility**: echo 100%, cat 100%, ls ~50% (most useful features)
- **Common Library**: Core functionality implemented (including user/group lookup)
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

#### 3. ls - Phase 1 ✓, Phase 2 in progress
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
- [ ] Test: Color capability detection (isatty, TERM)
- [ ] Test: --color=auto/always/never modes
- [ ] Test: Basic color scheme (dirs, executables, symlinks)
- [ ] Test: LS_COLORS environment variable parsing
- [ ] Test: --group-directories-first option
- [ ] Test: Terminal width detection for columns
- [ ] Test: Smart column formatting (-C is default)
- [ ] Implement: Color system with graceful degradation
- [ ] Implement: LS_COLORS parser (simplified)
- [ ] Implement: Directory grouping logic
- [ ] Implement: Responsive column layout

###### Phase 4: Recursive & Nice-to-Have (TDD)
- [ ] Test: Recursive listing (-R) with proper formatting
- [ ] Test: Recursive with cycle detection
- [ ] Test: Inode display (-i) before filename
- [ ] Test: Numeric user/group IDs (-n) 
- [ ] Test: Comma-separated output (-m)
- [ ] Test: Single column force (-1) ✓ already done
- [ ] Implement: Recursive directory walker
- [ ] Implement: Symlink cycle detection
- [ ] Implement: Inode display formatting
- [ ] Implement: Comma-separated formatter

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

### Phase 2: Text Processing Utilities

#### 11. head
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

#### 12. tail
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

#### 13. wc
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

#### 14. sort
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

#### 15. uniq
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

#### 16. cut
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

#### 17. tr
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

#### 18. stat
- [ ] Test: File information display
- [ ] Test: Custom format (-c)
- [ ] Test: Filesystem info (-f)
- [ ] Test: Dereference (-L)
- [ ] Test: Terse output (-t)
- [ ] Implement: System call wrapper
- [ ] Implement: Format string parser
- [ ] Implement: Human-readable output
- [ ] Man page: Write concise man page with examples

#### 19. du
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

#### 20. df
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

#### 21. find
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

#### 22. grep
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