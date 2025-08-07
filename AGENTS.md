# Repository Guidelines

## Project Structure & Module Organization
- `src/`: Zig utilities (one per file, e.g., `ls.zig`, `cp.zig`).
- `src/common/`: Shared modules (argparse, I/O, style, privilege test helpers).
- `tests/privilege_integration/`: Integration tests that simulate privileged flows.
- `build.zig` + `build/`: Build configuration and helpers.
- `zig-out/bin/`: Built binaries. `docs/` and `scripts/` support docs and CI.

## Build, Test, and Development Commands
- `make build`: Build all utilities (Debug). Binaries go to `zig-out/bin/`.
- `make test`: Run unit tests for all utilities and common modules.
- `make test-privileged-local`: Run tests that require privilege simulation.
- `make coverage`: Generate coverage report (see `coverage/`).
- `make run-<utility> ARGS="..."`: Run a specific utility, e.g., `make run-echo ARGS="hi"`.
- `make fmt` / `make fmt-check`: Format or verify formatting.
- `make docs`: Generate API docs under `zig-out/docs/`.

## Coding Style & Naming Conventions
- Language: Zig 0.14.x. Use `zig fmt` (via `make fmt`).
- Indentation: Zig defaults (tabs), no trailing whitespace.
- Functions: CLI entry is `run<Name>` (e.g., `runRm`), not `runUtility`.
- Error handling: Writer-based pattern; pass `stdout_writer`/`stderr_writer` and use `common.printErrorWithProgram`.
- Allocation: Prefer arena allocators for CLI flows; avoid global/page allocators.
- Security model: Trust the OS (no path “safety” lists or traversal checks); report kernel errors clearly.

## Testing Guidelines
- Unit tests live alongside code in `.zig` files; run with `make test`.
- Privileged tests: Mark with prefix `"privileged:"`; run via `make test-privileged-local` or `fakeroot zig build test-privileged`.
- Integration tests: See `tests/privilege_integration/`.
- Coverage target: ~90%+ (kcov/native supported via `make coverage`).

## Commit & Pull Request Guidelines
- Commits: Imperative, concise summaries; emojis allowed (e.g., `🐛 Fix ...`, `✨ Add ...`).
- PRs: Include purpose, linked issues, user-facing changes, and test notes. Add before/after samples for CLI behavior when relevant.
- Checks: Run `make fmt`, `make test`, and `make test-privileged-local` locally. Update docs/man or help text if flags/behavior change.

## Security & Configuration Tips
- Do not implement “security theater.” Rely on filesystem permissions; avoid hardcoded protected paths.
- Use fakeroot for privileged-path tests on macOS/Linux.
- Keep utilities GNU-compatible while adopting safe, modern defaults.
