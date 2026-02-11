# Quality Check Command (/qc)

Perform a comprehensive quality review of the specified file
or module using a 3-phase workflow:

## Phase 1: REVIEWER AGENT

Conduct a thorough quality review checking for:

### Code Quality Issues:
- Dead/unused code that should be removed
- Code duplication that can be eliminated
- Overly complex abstractions that add no value
- Memory management issues (hardcoded allocators, leaks)
- Error handling problems (silent failures, inadequate context)
- Security theater (unnecessary validation that belongs in the OS)
- Non-idiomatic Zig patterns
- Missing or incorrect documentation
- Over-engineering, needless complexity
- Poor quality or weak tests
- Missing critical tests

### Writing Style Issues (per "The Elements of Style"):
- Passive voice in documentation or comments
- Needless words that should be omitted
- Negative form when positive would be clearer
- Non-parallel construction in lists
- Vague language instead of specific terms
- Unalphabetized lists (unless order matters logically)
- Repetitive information stated in multiple places
- Facts that could be single-sourced but are duplicated

### Project-Specific Requirements (vibeutils):
- Writer-based error handling (stdout_writer, stderr_writer)
- No direct stderr access (use printErrorWithProgram, etc.)
- Explicit allocator parameters (no hardcoded c_allocator)
- Pre-1.0 philosophy: break things to fix them
- Trust the OS for security
- Avoid over-engineering for CLI tools

### Provide:
- Quality score (1-10) with justification
- List of specific issues with line numbers
- Severity classification (critical/major/minor)
- Specific changes needed to reach 10/10

## Phase 2: PROGRAMMER AGENT (if score < 10)

After user approval, implement fixes:
- Follow pre-1.0 philosophy (break things to fix them)
- Delete problematic code entirely
- Make breaking changes for better design
- Write clean, maintainable code
- Follow Zig idioms

**If fixes require architectural changes** (API redesign,
module restructuring, new abstractions), suggest entering
plan mode instead of proceeding directly. Let the user
decide.

## Phase 3: REVIEWER AGENT (final review)

Verify all issues are fixed:
- Confirm each issue is resolved
- Provide new quality score
- Identify any remaining improvements
- Overall assessment

## Model Selection:
- **Reviewer agents** (Phase 1 & 3): Use `opus` for thorough
  code analysis
- **Programmer agent** (Phase 2): Use `opus` for correct Zig
  0.15.x code generation

Always pass the `model` parameter explicitly when spawning
sub-agents. Do not rely on model inheritance.

## Workflow Requirements:
1. Complete each phase fully before moving to the next
2. Provide summary after each review phase
3. Ask for user confirmation before proceeding
4. If quality score is already 10/10, report and stop
5. If fixes need architectural design, suggest plan mode

## Key Principles:
- **Pre-1.0 Philosophy**: Zero external users, get design right
- **No Security Theater**: Trust the OS for security decisions
- **Writer-Based Pattern**: Error output through writer parameters
- **Explicit Memory**: Always pass allocators explicitly
- **Simple & Direct**: No unnecessary abstractions

## Example Issues to Flag:
- Functions checking for "../" in paths (security theater)
- Direct `std.debug.print()` calls (should use writers)
- Hardcoded `std.heap.c_allocator` (should be parameter)
- Unused structs, functions, or imports
- Complex abstractions that could be simple functions
- Silent error swallowing without context

Usage: `/qc <file_path>` or `/qc <module_name>`
