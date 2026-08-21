# Repository Guidelines

## Project Structure & Module Organization
- `src/`: Zig utilities (one per file, e.g., `ls.zig`, `cp.zig`).
- `src/common/`: Shared modules (argparse, I/O, style, privilege test helpers).
- `tests/privilege_integration/`: Integration tests that simulate privileged flows.
- `build.zig` + `build/`: Build configuration and helpers.
- `zig-out/bin/`: Built binaries. `docs/` and `scripts/` support docs and CI.

## Environment Setup
- Requires Zig (version pinned in `build.zig.zon`) and bash 4.0+.
- No toolchain? Run `scripts/bootstrap.sh` — idempotent; installs Zig,
  `just`, `mandoc`, `fakeroot`. Agent containers run it automatically at
  session start, so if `zig` is missing, re-run it and it will wait.
- macOS: `brew install zig`, `nix develop`, or `gale`.
- Detail, optional tools, and container caveats: `docs/TOOLCHAIN.md`.

## Build, Test, and Development Commands
- `just build`: Build all utilities (Debug). Binaries go to `zig-out/bin/`.
- `just test`: Run unit tests for all utilities and common modules.
- `just test-privileged-local`: Run tests that require privilege simulation.
- `just coverage`: Generate coverage report (see `coverage/`).
- `just run <utility> -- ...`: Run a specific utility, e.g.,
  `just run echo -- hi`.
- `just fmt` / `just fmt-check`: Format or verify formatting.
- `just docs`: Generate API docs under `zig-out/docs/`.

## Coding Style & Naming Conventions
- Language: Zig (version pinned in `build.zig.zon`). Use `zig fmt` (via `just fmt`).
- Indentation: Zig defaults (tabs), no trailing whitespace.
- Functions: CLI entry is `run<Name>` (e.g., `runRm`), not `runUtility`.
- Error handling: Writer-based pattern; pass `stdout_writer`/`stderr_writer` and use `common.printErrorWithProgram`.
- Allocation: Prefer arena allocators for CLI flows; avoid global/page allocators.
- Security model: Trust the OS (no path “safety” lists or traversal checks); report kernel errors clearly.

## Testing Guidelines
- Unit tests live alongside code in `.zig` files; run with `just test`.
- Privileged tests: Mark with prefix `"privileged:"`; run via `just test-privileged-local` or `fakeroot zig build test-privileged`.
- Integration tests: See `tests/privilege_integration/`.
- Coverage target: ~90%+ (kcov/native supported via `just coverage`).

## Commit & Pull Request Guidelines
- Commits: Imperative, concise summaries; emojis allowed (e.g., `🐛 Fix ...`, `✨ Add ...`).
- PRs: Include purpose, linked issues, user-facing changes, and test notes. Add before/after samples for CLI behavior when relevant.
- Checks: Run `just fmt`, `just test`, and `just test-privileged-local` locally. Update docs/man or help text if flags/behavior change.
- Landing a `TODO.md` item: load the `land-todo-slice` skill. One heading is one pull request. Do not skip plan review or the comment drain.

## Security & Configuration Tips
- Do not implement “security theater.” Rely on filesystem permissions; avoid hardcoded protected paths.
- Use fakeroot for privileged-path tests on macOS/Linux.
- Keep utilities GNU-compatible while adopting safe, modern defaults.

## Cursor Cloud specific instructions
- The Cloud Agent environment is defined by `.cursor/environment.json`, which
  runs `.cursor/install.sh` (installs the pinned Zig plus `just` via
  `scripts/bootstrap.sh`, adds the `fakeroot`/`mandoc` apt tools, and warms
  `zig build`). No `start`/`terminals` are needed — vibeutils is a CLI library
  with no long-running services.
- The base image exports `NO_COLOR=1`. vibeutils honors `NO_COLOR` even over
  `--color=always`, so the `ls truecolor icons emit RGB sequences` integration
  test fails under the ambient value. Run the integration suite with the
  variable scrubbed — `env -u NO_COLOR just it` — to get a fully green run
  (`zig build test`, privileged tests, and every other suite pass as-is).
