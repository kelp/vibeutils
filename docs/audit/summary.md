# Audit Summary

**Date:** 2026-03-28
**Scope:** 47 utilities, 141 audit reports (code + unit + integration
tests each)
**GNU Reference:** GNU coreutils is the primary behavioral reference
per project spec. Five code reports were re-audited 2026-03-28 with
GNU-primary framing: `ls`, `df`, `cp`, `du`, `stat`.

---

## Top-Level Totals

| Report Type   | CRITICAL | IMPORTANT | SUGGESTION |
|---------------|----------|-----------|------------|
| Code          |   95     |   189     |    90      |
| Unit Tests    |   67     |   154     |   108      |
| Integ Tests   |   47     |   231     |   142      |
| **ALL TOTAL** | **209**  | **574**   | **340**    |

---

## Per-Utility Table

Sorted by combined CRITICAL count (Code + Unit + IT) descending.

| Utility   | Code C/I/S | Unit C/I/S | IT C/I/S  | Assessment  |
|-----------|-----------|-----------|-----------|-------------|
| find      | 9/11/3    | 7/6/3     | 3/6/5     | NEEDS_FIXES |
| printf    | 6/5/2     | 3/5/3     | 2/3/3     | BLOCKED     |
| chmod     | 2/5/2     | 7/6/0     | 0/5/3     | NEEDS_FIXES |
| stat      | 5/5/3     | 3/3/2     | 4/5/2     | BLOCKED     |
| dd        | 6/6/3     | 3/7/4     | 0/11/5    | NEEDS_FIXES |
| chown     | 2/3/1     | 3/5/0     | 3/10/4    | NEEDS_FIXES |
| uniq      | 1/4/0     | 2/4/2     | 0/4/3     | NEEDS_FIXES |
| touch     | 3/4/0     | 2/4/1     | 0/5/5     | NEEDS_FIXES |
| mv        | 3/4/1     | 1/4/2     | 0/4/2     | BLOCKED     |
| tail      | 0/3/2     | 2/5/3     | 2/3/3     | NEEDS_FIXES |
| tr        | 1/3/0     | 2/3/2     | 1/2/3     | NEEDS_FIXES |
| timeout   | 0/1/2     | 2/4/1     | 2/5/2     | NEEDS_FIXES |
| tac       | 2/3/2     | 1/3/2     | 1/3/2     | NEEDS_FIXES |
| realpath  | 4/4/2     | 1/3/2     | 0/3/2     | NEEDS_FIXES |
| nl        | 5/4/0     | 0/4/2     | 3/4/2     | NEEDS_FIXES |
| ls        | 4/8/1     | 0/10/7    | 4/13/3    | NEEDS_FIXES |
| cp        | 0/5/2     | 5/5/0     | 0/8/2     | NEEDS_FIXES |
| tee       | 0/3/0     | 0/3/1     | 1/5/0     | NEEDS_FIXES |
| sort      | 3/6/3     | 3/3/2     | 2/5/2     | NEEDS_FIXES |
| cat       | 0/2/1     | 1/4/3     | 0/4/2     | NEEDS_FIXES |
| echo      | 0/0/3     | 0/3/3     | 2/4/2     | NEEDS_FIXES |
| wc        | 2/3/0     | 0/4/3     | 2/7/5     | NEEDS_FIXES |
| ln        | 2/4/3     | 2/4/2     | 0/9/1     | NEEDS_FIXES |
| readlink  | 2/3/2     | 0/1/2     | 0/2/2     | NEEDS_FIXES |
| id        | 1/3/2     | 0/4/4     | 1/7/3     | NEEDS_FIXES |
| env       | 3/4/2     | 2/3/0     | 0/3/3     | NEEDS_FIXES |
| mktemp    | 3/2/2     | 0/5/2     | 0/3/2     | NEEDS_FIXES |
| du        | 4/2/0     | 0/4/2     | 0/6/2     | BLOCKED     |
| df        | 4/4/2     | 3/5/3     | 0/6/2     | BLOCKED     |
| grep      | 2/7/4     | 2/5/3     | 0/9/8     | NEEDS_FIXES |
| head      | 1/2/2     | 0/3/4     | 0/3/3     | NEEDS_FIXES |
| date      | 3/3/2     | 2/4/3     | 0/8/3     | NEEDS_FIXES |
| seq       | 0/5/2     | 0/5/2     | 3/3/2     | NEEDS_FIXES |
| basename  | 1/1/2     | 1/2/2     | 1/3/2     | NEEDS_FIXES |
| rm        | 1/3/1     | 0/2/2     | 0/3/2     | NEEDS_FIXES |
| yes       | 0/2/2     | 0/0/3     | 0/2/3     | NEEDS_FIXES |
| true      | 0/1/1     | 0/0/2     | 0/0/2     | NEEDS_FIXES |
| free      | 0/3/3     | 0/4/3     | 0/5/3     | NEEDS_FIXES |
| sleep     | 0/2/2     | 0/3/2     | 0/3/2     | NEEDS_FIXES |
| cut       | 0/2/1     | 0/4/2     | 0/3/2     | NEEDS_FIXES |
| mkdir     | 0/2/2     | 0/2/2     | 0/2/2     | NEEDS_FIXES |
| test/[    | 0/3/0     | 0/2/0     | 0/3/0     | NEEDS_FIXES |
| rmdir     | 0/1/2     | 0/1/2     | 0/1/2     | NEEDS_FIXES |
| whoami    | 0/0/2     | 0/3/2     | 0/4/2     | NEEDS_FIXES |
| dirname   | 0/1/0     | 0/2/3     | 0/4/2     | NEEDS_FIXES |
| pwd       | 0/0/2     | 0/4/2     | 0/3/2     | APPROVED    |
| false     | 0/1/1     | 0/0/3     | 0/0/2     | NEEDS_FIXES |
| echo      | 0/0/3     | 0/3/3     | 2/4/2     | NEEDS_FIXES |

---

## Assessment Summary

| Assessment  | Count |
|-------------|-------|
| BLOCKED     |   5   |
| NEEDS_FIXES |  41   |
| APPROVED    |   1   |

**BLOCKED utilities:** `df`, `du`, `mv`, `printf`, `stat`

**APPROVED utilities:** `pwd`

Note: `false` and `true` code reports are NEEDS_FIXES (missing
--help/--version output) but integration tests are APPROVED.
`echo` code is APPROVED; integration tests are NEEDS_FIXES.
`dirname` code is APPROVED (1 IMPORTANT); all three report types
considered for overall utility assessment.
`whoami` code is APPROVED; other reports are NEEDS_FIXES.
