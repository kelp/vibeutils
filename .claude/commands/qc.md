# Quality Check Command (/qc)

  Perform a comprehensive quality review of the specified file or module using a 4-agent workflow with the following phases:

  ## Phase 1: REVIEWER AGENT
  Conduct a thorough quality review checking for:

  ### Code Quality Issues:
  - Dead/unused code that should be removed
  - Code duplication that can be eliminated
  - Overly complex abstractions that add no value
  - Memory management issues (hardcoded allocators, leaks)
  - Error handling problems (silent failures, inadequate error context)
  - Security theater (unnecessary validation that belongs in the OS)
  - Non-idiomatic Zig patterns
  - Missing or incorrect documentation
  - Over-engineering, needless complexity
  - Poor quailty or weak tests
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
  - Must follow writer-based error handling pattern (stdout_writer, stderr_writer parameters)
  - No direct stderr access (use printErrorWithProgram, fatalWithWriter, etc.)
  - Explicit allocator parameters (no hardcoded c_allocator)
  - Follow pre-1.0 philosophy: "break things to fix them"
  - Trust the OS for security, don't add unnecessary validation
  - Avoid Over-engineering and needless complexity for cli tools

  ### Provide:
  - Quality score (1-10) with justification
  - List of specific issues with line numbers
  - Severity classification (critical/major/minor)
  - Specific changes needed to reach 10/10

  ## Phase 2: ARCHITECT AGENT (if score < 10)
  Design architectural fixes for all identified issues:
  - Detailed design for each fix
  - API changes required
  - Implementation approach
  - Functions to delete entirely
  - Focus on simplicity and correctness

  ## Phase 3: PROGRAMMER AGENT (if approved)
  Implement the architectural fixes:
  - Follow pre-1.0 philosophy (break things to fix them)
  - Delete problematic code entirely
  - Make breaking changes for better design
  - Write clean, maintainable code
  - Follow Zig idioms

  ## Phase 4: REVIEWER AGENT (final review)
  Verify all issues are fixed:
  - Confirm each issue is resolved
  - Provide new quality score
  - Identify any remaining improvements
  - Overall assessment

  ## Workflow Requirements:
  1. Complete each phase fully before moving to the next
  2. Provide summary after each review phase
  3. Ask for user confirmation before proceeding to next phase
  4. If quality score is already 10/10, report this and stop

  ## Key Principles:
  - **Pre-1.0 Philosophy**: Zero external users, prioritize getting design right
  - **No Security Theater**: Trust the OS for security decisions
  - **Writer-Based Pattern**: All error output through explicit writer parameters
  - **Explicit Memory**: Always pass allocators explicitly
  - **Simple & Direct**: No unnecessary abstractions or frameworks

  ## Example Issues to Flag:
  - Functions checking for "../" in paths (security theater)
  - Direct `std.debug.print()` calls (should use writers)
  - Hardcoded `std.heap.c_allocator` (should be parameter)
  - Unused structs, functions, or imports
  - Complex abstractions that could be simple functions
  - Silent error swallowing without context

  Usage: `/qc <file_path>` or `/qc <module_name>`
