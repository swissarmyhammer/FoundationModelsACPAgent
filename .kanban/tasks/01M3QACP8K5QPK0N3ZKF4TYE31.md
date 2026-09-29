---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3qb78a6eqh7qrmby39sr2nm
  text: |-
    Research: the pinned Multitool (`MultiTool.makeSessionToolsAndStaging`) vends `[searchTools, runCode]`, or `[runCode]` in direct mode. It mounts no `wait` tool in either mode. The snippet globals are `status()` and `cancel()`. A `wait()` global is removed and exists only to throw a repair message. `TierTwoTests.answeringCallId(in:)`, which plan.md §4.7 named, no longer exists. The TierTwoTests snippets settle inside the inline grace.

    Changes:
    - plan.md: the §1 composition diagram, §4.7 (the pending envelope: the result comes back as mail; `RoutedSession.drain()` is a test or host surface and not a model tool; removed the stale `answeringCallId` reference), the §11 intro, §11.1 (two tools, and no `wait` tool in either mode), the §11.3 agents paragraph (removed `wait(completionToken, seconds)`), and the §11.4 shell bullet (the globals are `status()` and `cancel()`, with no `wait()`).
    - README.md § Tools: two code-mode tools. A run that does not settle in the grace comes back as mail.
    - Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift: a doc comment only (the mount order is `searchTools` and `runCode`).
    - BuiltinInstructions.swift: it has NO defect. The model-facing text does not name a `wait` tool. The only match is the English quote "hmm, wait" in a doc comment.
    - cli-plan.md: it has no match (only the English verb).

    The remaining `wait` matches in plan.md and README.md say that no `wait` tool exists, or use the English verb.

    New work found (out of scope, filed): ^s51b6sb (Tests/ ScriptedModel and RecordedTranscriptFile still name a `wait` call) and ^xhc29kx (plan.md §11.1 names a stale `makeSessionTools(librarian:sampleGenerator:)` signature).
  timestamp: 2026-09-29T19:45:44.774526+00:00
- actor: claude-code
  id: 01m3qb7fgwdzs583e79rh4pj9h
  text: |-
    ### implement — changed
    - evidence: 3 files — plan.md, README.md, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift (a doc comment only). `swift test`: 615 tests in 70 suites passed (1 known issue that was there before), and there are zero compiler warnings. `swift build --build-tests` in IntegrationTests/: Build complete, with zero compiler warnings. The only `warning:` line in each build is the SwiftPM "missing creator for mutated node" message for the mlx bundle, which is not a compiler warning.
    - next: /review
  timestamp: 2026-09-29T19:45:52.156865+00:00
- actor: claude-code
  id: 01m3qbjn5vgg4bbdn3jp2yk7p5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b4d6977). 0 findings, 0 confirmed, 0 refuted. The engine reviewed 1 file (ToolCatalog.swift). It did not review README.md and plan.md, because no validator matches these files. The .kanban/ files are excluded by .reviewignore. The task had no prior Review Findings section.
    - next: none. The task is in done.
  timestamp: 2026-09-29T19:51:58.395020+00:00
- actor: claude-code
  id: 01m3qbk50q3x4spjhrdq02t7db
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — plan.md, README.md, Tools/ToolCatalog.swift (doc comment)
    - test: green — swift test 615 tests pass; IntegrationTests build ok
    - commit: b4d6977
    - review: clean — zero findings; task moved to done. The engine has no Markdown validator. The orchestrator read the plan.md and README.md diff by hand. The text is correct, except one unclear sentence in §11.1 ("holds the model for each session on it"). Card ^xhc29kx edits §11.1 and gets that sentence.
  timestamp: 2026-09-29T19:52:14.615646+00:00
position_column: done
position_ordinal: f980
title: Remove the obsolete `wait` tool from plan.md §4.7, §11, §11.1 and README.md
---
## Why

The model surface of Multitool is `searchTools` + `runCode`. There is no `wait` tool. A settled background run comes back to the session as mail and starts a new submission (plan.md §8.0). Some text still names `wait`, so a reader learns a wrong surface.

## What

Rewrite these places for the mail model. Write in ASD-STE100 Simplified Technical English.
- plan.md §4.7 (the text near "wait" in the `runCode` snippet section).
- plan.md §11 and §11.1 (for example "`wait` is mounted in both modes").
- README.md: "`searchTools`, `runCode` and `wait`".

## Acceptance Criteria

- [x] `rg -n "\bwait\b" plan.md README.md` shows no line that names a `wait` tool.
- [x] No code change.

Found by ^wqe0awe. #generation-queue