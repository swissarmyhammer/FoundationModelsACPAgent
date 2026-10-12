---
assignees:
- claude-code
position_column: todo
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