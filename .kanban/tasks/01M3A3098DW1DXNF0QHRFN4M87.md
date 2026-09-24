---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a38p46dwpgzyzsj3a55a6c
  text: 'Review 2026-09-24: this task can land after the rename tasks 01M3A32E8EVDZ16ZQ8QF9513F2 and 01M3A33AGHQSCNQR8J2WQE0AWE. If they landed first, use the new names (`PromptExecution`, `endsPrompt`, `promptLogger`). Added acceptance criterion: the new code, comments and log text use the name rule of 01M3A33AGHQSCNQR8J2WQE0AWE (prompt / request / attempt / pass; "turn" only for ACP protocol words), and its `rg -n -i "\bturns?\b"` check on the changed files shows no new line.'
  timestamp: 2026-09-24T16:16:35.462007+00:00
- actor: claude-code
  id: 01m3a3p0gzn31bzy1bq3mpfgne
  text: 'Router dependency (2026-09-24): the Router change is card ^ake8sax (01M3A3NCG6FA1TA07BNAKE8SAX) on the FoundationModelsRouter board. The "discuss, then write the card" step of this task is done. Do not start before ^ake8sax is on Router `main`, and read its comment for the choice of a `GenerationStall` field or new `SessionEvent` cases. This task changes only this repository.'
  timestamp: 2026-09-24T16:23:52.095488+00:00
- actor: claude-code
  id: 01m3a5p1jt6kt4c6crh1vye5n5
  text: 'Router update (2026-09-24, from the Router session; Router card ^ake8sax was rewritten). (1) The seam: the queue wait is in the executor of the per-session queued wrapper (Router ^8csj2hw). The wrapper reports "waiting for a place", "took the place" and "pass ended" to the session actor through an observer. (2) Behavior change: the stall watch runs only while a pass holds its queue place. It does NOT run during the queue wait, and it does NOT run while a tool body runs between two passes. Thus a long tool body gives no `generationStalled` report after ^ake8sax. We replied that this is correct for us: `endsPrompt` (now `endsTurn`) ends a prompt only if the prompt made no output, and a tool call is output, so a report during a tool body never ends a prompt. The only effect here is that the `notice` log line for a long tool body goes away. When you do this task: read the Router comment on ^ake8sax for the final event or field names and for any change in the meaning of `GenerationStall.lastProgress` and `timeInFlight`. Keep `aStallPastTheBoundAfterAToolCallDoesNotEndTheTurn` (it is a synthetic stream, so it stays valid), and update the doc comment of `endsTurn` and of `stalledGenerationBound`: the text about a stall "raised while a tool runs" and the 2026-09-08 "0 fragments while runCode ran" note describe the old watch.'
  timestamp: 2026-09-24T16:58:50.330841+00:00
- actor: claude-code
  id: 01m3a5q9ef2a569cyp2a63bp3f
  text: 'Router update 2 (2026-09-24). Router card ^ake8sax recommends these `GenerationStall` meanings after the change: `timeWithoutProgress` counts only the time a pass holds its queue place (from the later of the last progress and the moment the current pass took its place); `timeInFlight` is unchanged (the whole model call, queue waits and tool bodies included); `visibility .fragments(n)` is unchanged (fragments of the whole model call); `lastProgress` is unchanged (taking a queue place is not progress). The shape (a `GenerationStall` field or new `SessionEvent` cases) is not decided; the Router implementer writes it in a comment on ^ake8sax before the change lands. Effect on this task: with these meanings, a request that only waits for a queue place can never reach `stalledGenerationBound`, because the Router does not watch during the wait and does not count the wait in `timeWithoutProgress`. So `endsTurn` may need NO logic change. Scope of this task becomes: (1) a regression test that a stream with a queue-wait report (in the final shape) and no stall past the bound ends with `end_turn`; (2) a test that the old `_stalled` case still holds; (3) project the new queue report or event as a `notice` log line, if the Router adds one; (4) the doc-comment updates of the earlier comment. Do not use `timeInFlight` for a stop decision: it includes queue waits and tool bodies.'
  timestamp: 2026-09-24T16:59:31.151844+00:00
position_column: todo
position_ordinal: '8180'
title: Do not stop a prompt as _stalled while its request waits for a place in the model queue
---
## Why

The Router plan (FoundationModelsRouter board, tag `generation-queue`) puts each generation pass into one queue for each model. A request of this agent can then wait a long time for a queue place while other sessions generate.

The Router stall watchdog starts at the start of the model call (`../FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:652`), and not at the start of a pass. The queue wait is inside that model call. Thus a request that only waits for the GPU reports `generationStalled` with `.fragments(0)`, and `PromptTurn.endsTurn(_:sawOutput:)` (`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:329`) ends it with `_stalled` after `stalledGenerationBound` (30 minutes). With some agent sessions on one model, this is possible.

## External dependency (discuss before you start)

The agent cannot see a queue wait now. The Router must tell it, for example one of:
- `GenerationStall` gets a field that says "waiting for a queue place" (the watchdog does not count queue time), or
- a new `SessionEvent` case for "queued" and "pass started".

This needs a task on the FoundationModelsRouter board. Per memory `stop-before-router-changes`, discuss it with the user first, then write the card with `sah --cwd ../FoundationModelsRouter tool kanban task add`. Put the Router card id in a comment on this task. Do not start the code of this task before the Router change is on Router `main`.

## What

1. `swift package update FoundationModelsRouter`.
2. `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`: `endsTurn(_:sawOutput:)` returns `false` for a report about a queue wait. Update its doc comment and the doc comment of `stalledGenerationBound`.
3. `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift`: project the new report or event. It is a log line (`notice`) with the session id and the model name. It is not a wire message (plan.md §8.4 gives a stall report no wire message). Add the new case to the §8.4 table in `plan.md`.

## Acceptance Criteria

- [ ] A request that waits for a queue place for longer than `stalledGenerationBound` does not end with `_stalled`.
- [ ] A pass that runs and makes no fragment for the full bound still ends with `_stalled` (the old guard stays).
- [ ] The log shows one `notice` line when a request waits for a queue place.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: add `queueWaitNeverEndsTheRequestAsStalled` (a synthetic event stream with a queue-wait report past the bound, then text, then usage; the stop reason is `end_turn`).
- [ ] Same file: keep the current `_stalled` tests green without change to their expectations.
- [ ] Run `swift test --filter PromptTurnTests` and then `swift test`. All pass. Read the real test names in the output (a filter that matches nothing also passes).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue #upstream