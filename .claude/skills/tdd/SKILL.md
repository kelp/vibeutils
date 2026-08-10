---
description: Test-first discipline for vibeutils — how to prove a test has teeth before trusting the change it guards. Use before writing a bug fix, a new feature, or a behavior-preserving refactor.
model-invocation: true
---

# Test-First Discipline

The goal is not ceremony. It is that **no change lands
without a test that provably catches a regression in the
behavior being changed.**

Two things are strictly enforced; everything else is
judgment.

## 1. Tests and implementation come from separate agents

For a single unit of work, the agent writing the test is
never the agent writing the code. A fix-writing agent
must not author or alter the test that guards its fix —
that contaminates the verification.

Parallelism across *independent* units (different
utilities, unrelated areas) is fine and encouraged. The
only prohibition is test-writing and code-writing the
**same** thing at the same time.

If the implementer concludes that a *test* is wrong
(rather than the code), it does not edit the test. It
routes the change back to the test-writer with
instructions. The test-writer adjudicates judge-first:
it fixes the test — keeping it toothful — only if the
test is genuinely wrong, and otherwise refuses, leaving
the implementer to fix the code. This is what stops a
fix-writer from dodging a real bug by rewriting the test
that caught it.

## 2. A test must be proven able to fail

A test that can never fail is a bug in the test. How you
prove it depends on the kind of work.

### Bug fixes — classic red → green

1. Write the failing test first (separate agent).
2. **Verify RED.** Run it and see it fail for the *right
   reason* — the assertion matching the bug, not a
   compile error or a skip. Validate on macOS and Linux;
   push to CI and confirm the failure there.
3. Only then write the fix (separate agent), minimal.
4. **Verify GREEN** on the same platforms and in CI.

### New features — define behavior, then build

1. Write tests that define the expected behavior.
2. Verify they fail (RED) for the right reason.
3. Implement until they pass (GREEN).
4. Refactor if needed, staying GREEN.

### Refactors — behavior-preserving

A refactor changes structure, not behavior, so its tests
*should not* fail against the real code. Demanding a red
here is theater. Prove the tests have teeth by
**transient sabotage** (manual mutation testing):

1. Write or identify characterization tests for the
   behavior being preserved.
2. Confirm they pass on the real, unchanged code
   (GREEN).
3. **Prove red-ability.** Temporarily mutate the
   implementation to break the asserted behavior, run
   the tests, and confirm they go RED. Then revert the
   mutation — never commit it — and confirm GREEN again.
   A test that stays green under sabotage is worthless;
   fix it.
4. Perform the refactor. All tests stay GREEN
   throughout.

## Always

- **Tests must verify behavior, not parsing.** A test
  asserting `parsed.follow == true` without checking
  that the program actually follows the file is not a
  real test. Integration tests in `tests/utilities/`
  cover behavioral verification for every flag.
- **Integration tests must actually run in CI.** Verify
  the runner picks them up — binary-name matching, bash
  version requirements, and so on. A suite that silently
  skips is worse than no suite.
- **Validate on both macOS and Linux before pushing.**
  On a macOS dev machine use `orb -m ubuntu` for the
  Linux side. In an agent container you are already on
  Linux and have no `orb`: run the suites natively and
  let CI cover macOS.
- **Never disable or skip a failing test to make the
  suite pass.** Diagnose the root cause. If it is an
  upstream bug, document it explicitly and write a
  proper workaround — do not comment the test out.

Patterns, fixtures, filter-utility handling, and the
privileged-test architecture:
[`docs/TESTING_STRATEGY.md`](../../../docs/TESTING_STRATEGY.md).
