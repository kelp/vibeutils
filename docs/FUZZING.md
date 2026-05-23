# Fuzzing vibeutils

vibeutils ships with a small, self-contained mutational fuzzer at
`tools/fuzz.zig`. It's a dev tool: no external dependencies, no
`common` library import, std-only. It runs on macOS and Linux and
supports three input modes per utility (stdin, argv, file_arg)
selected by a static config table at `tools/fuzz_targets.zig`.

## Running

```
just fuzz wc                  # default: 10000 runs, 2s timeout
just fuzz wc -- --max-runs 5000 --seed 42 --timeout-ms 1000
zig build fuzz-cat -- --max-runs 100
```

Arguments after `--` pass through to the fuzzer binary:

- `--max-runs N` — total iterations (default 10000).
- `--timeout-ms N` — per-run wall-clock timeout (default 2000).
- `--max-input-size N` — cap on mutated input bytes (default 65536).
- `--seed N` — PRNG seed (default wall-clock). The seed used is
  logged on startup; record it from the output of a flaky run.

Stats print every 1000 iterations and once at the end. Exit
status is 1 if any crashes were found, 0 otherwise.

## Layout

```
tests/fuzz/
  .gitkeep
  <util>/
    corpus/      hand-curated seed inputs (tracked in git)
    crashes/     SHA-256-named crash artifacts (gitignored)
```

The fuzzer creates the per-utility `crashes/` directory on
demand. Both `corpus/` and `crashes/` are local to each utility
so a crash in `wc` doesn't pollute `cat`'s corpus.

## Adding seeds

Drop files into `tests/fuzz/<util>/corpus/`. Aim for small,
diverse inputs: empty files, plain ASCII, multibyte UTF-8,
known boundary cases. Anything in there gets loaded at startup
and used as a starting point for mutation. If the corpus dir
is missing or empty, the fuzzer falls back to a built-in
default (empty, `"a"`, `"0"`, `"\n"`, 32 random bytes).

## Triaging a crash

Each crash writes a pair of files:

```
tests/fuzz/wc/crashes/
  <sha256>.bin    raw input bytes
  <sha256>.txt    signal, run number, seed, input size
```

Reproduce a crash with the binary directly:

```
zig-out/bin/wc < tests/fuzz/wc/crashes/<sha256>.bin
```

If the crash reproduces, the input is your test case. Add a
failing unit or integration test, fix the bug, confirm the
crash no longer reproduces, then commit the input as a
regression seed under `tests/fuzz/<util>/corpus/`.

If it doesn't reproduce, the bug is likely timing-dependent
or driven by something other than stdin. The `seed` recorded
in the metadata lets you replay the exact mutation stream
that found it.

## Harness modes

Each utility runs in one of three modes, looked up by name
from `tools/fuzz_targets.zig`:

- **stdin** (default for unlisted utilities) — mutated bytes
  go to the child's stdin. Good for filters: `wc cat sort
  uniq tee tr head tail nl tac grep cut`.
- **argv** — mutated bytes substituted into an argv template
  where `{INPUT}` is the placeholder. Used for utilities
  whose attack surface is the command line: `printf` (format
  string), `grep` (regex), `date` (date string), `test`.
- **file_arg** — mutated bytes written to a unique temp file
  under `/tmp/fuzz-harness-<hex>`; the path is substituted
  into the argv template. Used for utilities that take a
  file path: `stat readlink realpath`. The temp file is
  removed after each run.

To add a new utility to a non-stdin mode, edit
`tools/fuzz_targets.zig` and add a `lookup` branch with the
appropriate template. Templates must contain exactly one
`{INPUT}` token; this is validated at fuzzer startup.

## Limitations

No coverage feedback. The corpus stays fixed at the seeds
loaded at startup. Without an instrumentation signal we can't
tell which mutations explored new code, and blindly growing
the corpus degrades mutation quality.

## Roadmap

**v2.x** — additive improvements:
- Dictionary support: per-utility token tables to splice into
  mutated inputs (printf format specifiers, regex metachars,
  etc.).
- Corpus minimization — shrink a crashing input to the
  smallest still-crashing form.
- More argv/file_arg entries in `fuzz_targets.zig` as we find
  bugs in the obvious targets and want to widen the surface
  (e.g. `find`, `dd`, `seq`, `du`).

**v3** — coverage-guided fuzzing via Zig's
`-fsanitize-coverage=trace-pc-guard`. Record edge hits in
shared memory and grow the corpus AFL-style. CI integration:
short fuzz budget per PR, longer nightly run, auto-file new
crashes.
