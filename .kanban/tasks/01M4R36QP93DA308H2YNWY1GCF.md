---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4r5qqy896jphs0yayywz04e
  text: |-
    ### Acceptance criterion 1 — done (2026-10-12)
    - FoundationModelsCodeContext task ^dca8jxc (01M4R5QEWH1SMFGTK3WDCA8JXC): "Make detectProjects answer in less than 6 s during the first index pass". It is in todo on the CodeContext board. It has the evidence of run no-otel-1011, the likely cause (actor contention with the first index pass), the order to measure first, and the two possible fixes.
    - The CodeContext session (foundationmodelscodecontext-26) sends the commit sha when the task is done.
    - Still open: the bench run noop-stop-1012 (started 08:20, 6 instances), and its score.
  timestamp: 2026-10-12T13:44:49.864231+00:00
- actor: claude-code
  id: 01m4rap1xct7wvgydh9j280wh5
  text: |-
    ### CodeContext ^dca8jxc done and pushed (2026-10-12)
    - Commits on origin/main of FoundationModelsCodeContext: 1d13754 (detect projects without waiting for index work), c8f69dc (review fixes), d4c4482 (kanban). Pin CodeContext at d4c4482 or later.
    - Measured cause (not the guess): the waits for the CodeContext actor and the main actor were 0 ms. All the time was the gitignore-aware tree walk (5.5 to 10 s in a debug build on Django), and the walk ran synchronously on the actor.
    - Fix: a new ProjectDetector apart from the index, with one marker-file strategy for each project kind (from the LanguageModule markers); detectProjects is nonisolated and walks on a GCD queue; a faster gitignore check; start() uses the same detector.
    - Results: Django clone during the first index pass 0.95 to 1.42 s (before 5.5 to 10 s); gate test with the index pass and both actors held 0.034 s.
    - next: the run noop-stop-1012 uses the build from before this commit. After that run ends, `swift package update` to take d4c4482.
  timestamp: 2026-10-12T15:11:17.420385+00:00
position_column: doing
position_ordinal: '80'
title: Bench check of the no-op stop, and the detectProjects settle task for CodeContext
---
## Why

Task ^ys32tj4 wired the no-op tool-call check (commit d29e628): while work is pending, a `runCode` call with no `tools.*` verb stops the generation, and the session does not run it. The run `no-otel-1011` (2026-10-11) had 186 no-op `runCode` calls in 12 of 16 instances (73 in django__django-13964, 57 in django__django-14382, 33 in django__django-14016) and one duplicate test command (django__django-13447). The fix must be proved with a bench run. This task holds item 3 and acceptance criterion 2 of ^ys32tj4.

## Work

1. Ask a FoundationModelsCodeContext session for a task (the session was not running on 2026-10-12): make `detectProjects` answer in less than 6 s on a Django clone during the first index pass. Evidence and text: the comment "CodeContext task request: not sent" on ^ys32tj4.
2. `swift build -c release`, then run a SWE-bench run with the swebench skill: at least 5 instances, with the same config as `no-otel-1011` (`bench/code-context.config.yaml`, `--timeout 5400`). The 16 instances of `no-otel-1011` give a direct comparison.
3. Score it with the swebench-score skill, and compare with `no-otel-1011`.

## Acceptance criteria

- A CodeContext task for the `detectProjects` settle exists, and its id is on this task.
- The bench run has 0 no-op `runCode` loops: no instance with more than 8 `runCode` calls whose snippet calls no `tools.*` verb.
- The bench run has 0 duplicate test commands that a pending result caused.
- The score is not lower than `no-otel-1011` (13/16) on the same instances, or each new unresolved instance has a cause that is not the no-op stop.

## Tests

- Count the no-op calls in each transcript: a `runCode` call whose `code` field has no `tools` identifier. Use the scan of the swebench skill as well. #bench