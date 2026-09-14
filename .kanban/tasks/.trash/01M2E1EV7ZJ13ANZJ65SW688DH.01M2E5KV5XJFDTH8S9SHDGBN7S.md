---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2e3fhfm6k06sdd13r33n4q2
  text: |
    ### A second instance shows the same waste, and a third shows it costs a patch

    `django__django-13933`, instance 4 of the run of 2026-09-13. The agent
    finished with `end_turn` in 1526 s and made a patch of 5 files.

    | File | Added lines | Kind |
    |---|---|---|
    | `django/forms/models.py` | 7 | source |
    | `tests/admin_widgets/tests.py` | 7 | test |
    | `tests/model_forms/test_modelchoicefield.py` | 5 | test |
    | `tests/model_forms/tests.py` | 1 | test |
    | `tests/model_formsets/tests.py` | 2 | test |

    The source is 7 of 22 added lines, which is 32%. The agent wrote in FOUR test
    files, and the scorer removes all four before one test runs.

    The two instances that made a patch so far:

    | Instance | Source lines | Added lines | Source share |
    |---|---|---|---|
    | `django__django-13447` | 4 | 33 | 12% |
    | `django__django-13933` | 7 | 22 | 32% |

    **And the same behaviour cost a whole patch.** `django__django-13710`, instance
    2, gave an EMPTY patch after 500 s of agent time. It never changed one file.
    Its last reasoning block repeats two sentences again and again:

    ```
    Let me look at the existing tests for the inline verbose_name. Let me look at
    the test that tests the inline's verbose_name. Let me search for the test that
    uses "verbose_name" in the context of inline in the admin tests. Let me look
    at the test file for the inline verbose_name. Let me search for the specific
    test.
    ```

    The agent spent the whole turn in search of an existing test to copy, and it
    never made the fix.

    So this card is not a card of speed alone. The instruction to write no test
    also removes one cause of an empty patch.
  timestamp: 2026-09-13T19:21:35.988435+00:00
position_column: todo
position_ordinal: '8280'
title: 'bench: tell the agent to change the source only, so it stops writing docs, release notes and tests'
---
## The measurement

`django__django-13447`, the first instance of the run of 2026-09-13. The
agent finished on its own with `end_turn` in 1342 s, and it made a patch of
4636 bytes across 4 files.

| File | Added | Removed | Share of the added lines |
|---|---|---|---|
| `django/contrib/admin/sites.py` | 4 | 3 | 12% |
| `tests/admin_views/tests.py` | 25 | 0 | 76% |
| `docs/releases/4.0.txt` | 3 | 0 | 9% |
| `docs/ref/contrib/admin/index.txt` | 1 | 0 | 3% |

The fix of the issue is the 4 lines in `sites.py`. The other 88% of the
output is work that the score THROWS AWAY:

* The SWE-bench harness restores the test files of the instance from the base
  commit, and then it applies the official test patch. So every line the agent
  writes in `tests/` is removed before one test runs.
* The documents and the release notes are not read by any test.

## Why it happens

The agent gets the problem statement and nothing more. A problem statement of
django reads like a ticket of django, so the model does what a contributor of
django does: it changes the code, it adds a test, it writes a release note,
and it updates the reference documents. That is correct behaviour for the
project, and it is waste for this measurement.

The same behaviour explains the exploration that comes before it. The agent
listed `docs/`, and then it listed every file of `docs/releases/`, to find
which release note file to write in.

## The work

Put a short instruction in front of the problem statement of each instance:
change only the source that the fix needs, and write no test, no release note
and no documentation.

`swebench_run.py` sends the problem statement as one text content block, at
the `server.turn(...)` call. The instruction goes in the same block, in front
of the statement.

Two conditions hold it honest:

* The instruction must NOT say what the fix is, and it must not name a file.
  It says what to leave out, and nothing more.
* The run must record which prompt it used, so two runs can be compared. The
  record row of the instance is the place.

## When it is complete

* A run with the instruction makes a patch whose files are source files.
* A measurement of the same instances shows the seconds of each instance
  before and after.
* The README says what the agent is told, because "the problem statement and
  nothing more" is no longer true.

Related: [[bench-the-wait-round-trip-doubles-the-model-turns-of-every-operation]]
#bench