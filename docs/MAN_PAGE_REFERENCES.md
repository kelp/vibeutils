# Man Page References

When implementing a new command, consult POSIX specifications,
OpenBSD, and GNU coreutils man pages to determine the most
useful flags to support.

## POSIX.1-2017 Specifications

The authoritative standard:
- Index: https://pubs.opengroup.org/onlinepubs/9699919799/idx/utilities.html
- Direct lookup: `https://pubs.opengroup.org/onlinepubs/9699919799/utilities/<command>.html`
- Utility conventions: https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html
- Free online, includes rationale for design decisions

## OpenBSD Man Pages

Access at `https://man.openbsd.org/<command>`

Focus on security, simplicity, and correctness. Often have
cleaner, more focused flag sets.

## GNU Coreutils Man Pages

- **Linux**: `man <command>`
- **macOS** (with `brew install coreutils`): `man g<command>`
  (e.g., `man gls`, `man gcp`)
- **Online**: https://www.gnu.org/software/coreutils/manual/html_node/index.html

More extensive feature set. Required for GNU compatibility.

## Implementation Strategy

1. Start with POSIX-required functionality as the baseline
2. Verify behavior against the POSIX specification
3. Add commonly used GNU extensions for compatibility
4. Include OpenBSD security/safety features where applicable
5. Document any intentional differences from POSIX/GNU/BSD

## House Style for Our Man Pages

Our pages live in `man/man1/` and use mdoc format. A
skeleton is in
`.claude/skills/new-util/references/template.md`.

Section order, all required: NAME, SYNOPSIS,
DESCRIPTION, EXIT STATUS, EXAMPLES, SEE ALSO, STANDARDS,
AUTHORS.

- **No HISTORY section.** This is a clean-room
  implementation.
- Validate with `mandoc -T lint man/man1/<utility>.1`.
- Include two or three practical examples.
- Document both the short (`-f`) and long (`--force`)
  spelling of every flag.
- Author line: `vibeutils implementation by Travis Cole`.
