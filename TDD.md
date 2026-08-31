# daily-notes-migration — TDD

## Rule

Any change to `migrate-notes.sh` or `transform.py` must pass every test in
this file before it's considered done. Run:

```bash
./tests/run_tests.sh
```

If any test fails: fix, rerun, repeat until all pass. Don't ship/commit on
a red run.

## Why this exists

On 2026-08-19 (`2bfa99d`) a bug was fixed: Tomorrow content wasn't merging
into the next day's Today list. On 2026-08-28 (`9c84c69`), an unrelated
rewrite (added rich-format preservation) silently reintroduced the exact
same bug — it only lived in one of two code paths, and the rewrite missed
porting the fix to the other path. Nobody re-checked it against the
original scenario, so it shipped and broke a real Friday→Monday transfer
on 2026-08-31. This suite exists so that class of regression fails loudly
instead of sitting silent for days.

## What the tests check

The script has two independent write paths — target note doesn't exist
yet (`create-new`) vs target note already exists (`append`) — and the bug
lived in only one of them. Both are tested with the same fixture shape:

- **Test A — create-new path**: target note absent when the script runs.
- **Test B — append path**: target note already exists (simulates the
  user pre-creating today's note, or the launchd job re-running).

Each test's source fixture has: one item above `@@@FINISHED@@@` (today,
unfinished), one item below it (today, done), and two Tomorrow items.
After running, each test asserts:

1. Script exits 0.
2. The today-unfinished item survived.
3. The done item (below `@@@FINISHED@@@`) was dropped — it must never
   carry forward.
4. Both Tomorrow items appear in the output.
5. Both Tomorrow items sit **above** `@@@FINISHED@@@` (i.e. landed in
   Today, not Tomorrow) — this is the exact assertion that would have
   failed on 2026-08-28.
6. The new note's own Tomorrow section (between its Tomorrow and
   Reference headers) is empty of those items — the regression put them
   here instead of Today.

Test B additionally checks pre-existing note content survives the append.

## How it runs

`tests/run_tests.sh` → `tests/run_tests.py`, using `tests/notes_helpers.py`
(AppleScript via osascript) to create/read/delete real Notes.app notes
under a `TEST9xxx-` prefix — chosen because it can never collide with a
real `MMDD-` daily note. Fixtures are deleted at the end of the run
regardless of pass/fail.

`migrate-notes.sh` supports two env vars, `TEST_SOURCE_PREFIX` and
`TEST_TARGET_NAME`, that bypass the weekend/holiday skip and real-date
math so tests can run any day, deterministically, without touching real
notes. Production (launchd) runs never set these vars, so behavior there
is unchanged.

## Known gaps (not covered yet)

- Rich formatting (bold/lists/embedded images) surviving the round-trip —
  covered manually so far, not asserted by this suite.
- The >5MB body-write truncation warning path.
- Holiday-file skip logic.

Add a case here if any of these bite again.
