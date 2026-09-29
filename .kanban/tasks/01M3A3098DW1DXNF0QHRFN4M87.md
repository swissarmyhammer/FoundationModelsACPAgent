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
- actor: claude-code
  id: 01m3mz9zw4kevrwddrectwjwyf
  text: |-
    ### implement — stuck
    - evidence: Router card ^ake8sax is on Router `origin/main` (commit b7359b1, 2026-09-25, "do not count a wait for a queue place as a stalled generation, and report the wait to the consumer"). The local `Package.resolved` pins Router at bbad3ce (2026-09-23). `git merge-base --is-ancestor b7359b1 bbad3ce` returns 1: the pin does not contain the ^ake8sax API. Step 1 of this task (`swift package update FoundationModelsRouter`) moves Router past API that `main` of this repository uses (`cancelCurrentTurn` is gone, new request event names, `.repeatedPartRemoval`), and Multitool `makeSessionToolsAndStaging(librarian:)` changed too (see the comments on ^258q0h3). The adoption of that newer Router is the scope of ^tz867gz, which is blocked by 01M3A30KQBCN1051EVS6KCTS5V and 01M3A30WN7D2CB2X7EGM0K2VN6. No file changed.
    - next: do ^tz867gz (and the Multitool adoption) first. Then this task can update Router and use the final queue-wait shape of ^ake8sax. Suggest: add ^tz867gz to `depends_on` of this task.
  timestamp: 2026-09-28T21:39:02.660935+00:00
- actor: claude-code
  id: 01m3n1sjx8yk8qfkh15exngmbh
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The task needs Router b7359b1 (^ake8sax). The local pin bbad3ce does not contain it. The Router update is the scope of ^tz867gz, which is blocked.
    - test, commit, review: not run
    - next: this task waits for ^tz867gz. A person must decide the order.
  timestamp: 2026-09-28T22:22:30.824749+00:00
- actor: claude-code
  id: 01m3py62z811b5fqkknxnrgm0d
  text: |-
    External dependency resolved (2026-09-29). The Router change is on Router main and in this repository: HEAD 394a277 pins Router c49e453 (adopted by 4ac665b). Router ^ake8sax shipped as `passQueued`/`passStarted`, and Router ^1psqdm9 renamed them to `SessionEvent.submissionQueued(SubmissionID)` / `.submissionStarted(SubmissionStart)` (see `.build/checkouts/FoundationModelsRouter/generation-queue.md`, "A wait for a queue place is not a stall"). The stall watch counts `GenerationStall.timeWithoutProgress` only while a pass holds its queue place. A queue wait and a tool body between two passes give no `generationStalled`. `timeInFlight` still includes the wait and the tool bodies. No Router card is necessary, and no Router file changed. Step 1 of the card (`swift package update FoundationModelsRouter`) is not necessary: the pin already contains the change.

    Discoveries:
    - `endsTurn(_:sawOutput:)` needs no logic change. It reads only `timeWithoutProgress`, which never counts a queue wait. The work is the `notice` log line, the doc comments and plan.md.
    - `submissionQueued` carries only a `SubmissionID`. The model name is on `PromptTurn`, so `EventProjection` gets a new stored `modelName` (one construction site, `PromptTurn.drive`).
    - TDD: `queueWaitNeverEndsTheRequestAsStalled` passed on its first run, because the fix is in the Router. It is a regression test. A change that makes the guard read `timeInFlight` makes it fail (the stall report after the wait has `timeInFlight` past the bound and `timeWithoutProgress` of one interval). The `notice` line goes through `os.Logger` (`turnLogger`), which a unit test cannot read, so no test asserts the log line.
  timestamp: 2026-09-29T15:57:55.048067+00:00
- actor: claude-code
  id: 01m3py6pa3cy1pqh0j8cytdw6x
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift (`submissionQueued` is a `notice` line with the session id and the model name, through the new `reportQueueWait()`; new stored `modelName`), Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift (passes `modelName` to the projection; doc comments of `stalledGenerationBound`, `endsTurn(_:sawOutput:)` and `modelName` state the queue rule), plan.md (§8.4 table row `submissionQueued(SubmissionID)`, and a guard paragraph "A wait for a place in the model queue is not a stall"), Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift (new `queueWaitNeverEndsTheRequestAsStalled`; doc of `aStallPastTheBoundAfterAToolCallDoesNotEndTheTurn` no longer describes the old watch, and its expectations did not change), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift (new `submissionQueued()` helper). `swift test --filter PromptTurnTests`: 31 tests, all pass, `queueWaitNeverEndsTheRequestAsStalled` and the four `_stalled` guard tests among them. `swift test`: 605 tests in 69 suites pass (the one known issue is the `withKnownIssue` self-check in `HarnessSmokeTests`, which was there before). No compiler warning; the only `warning:` line is the SwiftPM mlx bundle "missing creator" line, which was also there before the change.
    - next: /review. Not committed.
  timestamp: 2026-09-29T15:58:14.851549+00:00
- actor: claude-code
  id: 01m3pynmbxk14fx94w7mg8e2pv
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0eae8bb): 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift:21 (swift/fluent-usage).
    - next: Rename the factory `submissionQueued()` to `makeSubmissionQueued()`. Apply the `make` prefix to all factory helpers in ProjectionTestSupport.swift. Then run the tests, commit, and review again.
  timestamp: 2026-09-29T16:06:24.381644+00:00
- actor: claude-code
  id: 01m3pyp0d77rggacbesrbxcc25
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files (EventProjection.swift, PromptTurn.swift, plan.md, PromptTurnTests.swift, ProjectionTestSupport.swift)
    - test: green — swift test 605 tests pass; IntegrationTests build ok
    - commit: 0eae8bb
    - review: findings — Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift:21 (swift/fluent-usage: factory helper must begin with make)
  timestamp: 2026-09-29T16:06:36.711405+00:00
- actor: claude-code
  id: 01m3pywnp5h533yzgmjj63bqg5
  text: |-
    Finding swift/fluent-usage (ProjectionTestSupport.swift:21) done for the whole file. The three factory helpers that make and return a `SessionEvent` now start with `make`: `submissionQueued()` -> `makeSubmissionQueued()`, `submissionStarted()` -> `makeSubmissionStarted()`, `submissionEnded(_:)` -> `makeSubmissionEnded(_:)`. The other helpers in the file already had the prefix (`makeSinkedTurn`, `makeEventStream`), or they are readers that return a value from an update and do not make one (`toolCallUpdates(in:)`, `idleState(of:)`, `jsonString(of:)` and the others). Call sites changed in PromptTurnTests.swift (20), EventProjectionTests.swift (1) and CancellationTests.swift (1). A search for a bare `submissionQueued(`, `submissionStarted(` or `submissionEnded(` call in all Swift files finds nothing; the leading-dot enum cases stay as they are.

    Discovery: the `files` tool `edit file` with `replace_all: true` replaced only the first match in each call. Thus the edits of PromptTurnTests.swift went in multi-line blocks. The next agent must not trust `replace_all`, and must search again after an edit.
  timestamp: 2026-09-29T16:10:15.109628+00:00
- actor: claude-code
  id: 01m3pywrwbfwrj8vzjnh3nm2ye
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, Tests/FoundationModelsACPAgentTests/CancellationTests.swift. `swift test`: 605 tests in 69 suites pass, 0 failures (1 known issue: the `withKnownIssue` self-check in HarnessSmokeTests, which was there before). No compiler warning; the only `warning:` line is the SwiftPM mlx bundle "missing creator" line, which was there before. The finding is `- [x]`.
    - next: /test, /commit, then /review. Not committed. The task stays in `doing`.
  timestamp: 2026-09-29T16:10:18.379583+00:00
position_column: doing
position_ordinal: '8180'
title: Do not stop a prompt as _stalled while its request waits for a place in the model queue
---
## Why

The Router plan (FoundationModelsRouter board, tag `generation-queue`) puts each generation pass into one queue for each model. A request of this agent can then wait a long time for a queue place while other sessions generate.

The Router stall watchdog starts at the start of the model call (`../FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:652`), and not at the start of a pass. The queue wait is inside that model call. Thus a request that only waits for the GPU reports `generationStalled` with `.fragments(0)`, and `PromptTurn.endsTurn(_:sawOutput:)` (`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:329`) ends it with `_stalled` after `stalledGenerationBound` (30 minutes). With some agent sessions on one model, this is possible.

## External dependency (discuss before you start)

RESOLVED 2026-09-29: Router ^ake8sax is on Router `main`, and this repository pins it (Router c49e453, adopted by 4ac665b). The final shape is `SessionEvent.submissionQueued` then `SessionEvent.submissionStarted`, and the stall watch does not count a queue wait. See the comment of 2026-09-29.

The agent cannot see a queue wait now. The Router must tell it, for example one of:
- `GenerationStall` gets a field that says "waiting for a queue place" (the watchdog does not count queue time), or
- a new `SessionEvent` case for "queued" and "pass started".

This needs a task on the FoundationModelsRouter board. Per memory `stop-before-router-changes`, discuss it with the user first, then write the card with `sah --cwd ../FoundationModelsRouter tool kanban task add`. Put the Router card id in a comment on this task. Do not start the code of this task before the Router change is on Router `main`.

## What

1. `swift package update FoundationModelsRouter`. (Not necessary: the pin already contains Router ^ake8sax.)
2. `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`: `endsTurn(_:sawOutput:)` returns `false` for a report about a queue wait. Update its doc comment and the doc comment of `stalledGenerationBound`. (No logic change: the guard reads only `timeWithoutProgress`, which never counts a queue wait.)
3. `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift`: project the new report or event. It is a log line (`notice`) with the session id and the model name. It is not a wire message (plan.md §8.4 gives a stall report no wire message). Add the new case to the §8.4 table in `plan.md`.

## Acceptance Criteria

- [x] A request that waits for a queue place for longer than `stalledGenerationBound` does not end with `_stalled`.
- [x] A pass that runs and makes no fragment for the full bound still ends with `_stalled` (the old guard stays).
- [x] The log shows one `notice` line when a request waits for a queue place.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: add `queueWaitNeverEndsTheRequestAsStalled` (a synthetic event stream with a queue-wait report past the bound, then text, then usage; the stop reason is `end_turn`).
- [x] Same file: keep the current `_stalled` tests green without change to their expectations.
- [x] Run `swift test --filter PromptTurnTests` and then `swift test`. All pass. Read the real test names in the output (a filter that matches nothing also passes).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue #upstream

## Review Findings (2026-09-29 11:01)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift:21` `swift/fluent-usage` — Factory methods should begin with `make`. The function `submissionQueued()` constructs and returns a `SessionEvent` value, making it a factory method that should follow Apple's Swift API Design Guidelines naming convention. Rename `submissionQueued()` to `makeSubmissionQueued()` to follow the factory method naming convention.
