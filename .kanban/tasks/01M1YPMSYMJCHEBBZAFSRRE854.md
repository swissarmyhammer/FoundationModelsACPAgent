---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ysr649tmhzkfb3qq3dq1bm
  text: |
    ### Research

    The seam that tells when the first delta reached the answer writer is the
    `AnswerCapture` file itself. `AnswerWriter.receive(_:)` writes each chunk with
    `write(2)`, which carries no user-space buffer, thus the byte is on the
    descriptor when the call returns. A reader of the capture file sees the delta
    at the moment the turn wrote it.

    There is no event seam earlier in the path that stands for the same fact. A
    model-side seam reports only that the model emitted the delta, not that the
    delta crossed the wire and reached the writer, thus it would leave the same
    race open.

    `CompositionInterruptTests.armed(after:)` is the prevailing pattern in this
    repository for the same class of defect: the watch offers one arrival, and
    only after the production code reports the fact. This card copies that shape.

    ### What was done

    1. `Tests/FoundationModelsACPAgentTests/Support/PollUntil.swift` (new): one
       shared `pollUntil(_:_:sourceLocation:)`. It polls a condition to a 30 s
       deadline and records an issue that names the fact if the deadline passes.
       `MCPCompositionTests` had a private copy of this loop; the copy is deleted
       and its four call sites now use the shared function, thus the repository
       has one wait for a fact and no second copy.
    2. `Support/AnswerCapture.swift`: added `holds(_:)`, which gives a
       `@Sendable` test of whether the capture holds a text. The closure holds the
       file location and not the capture, thus another task can read what already
       arrived while the turn still runs. `text()` and the new test share one
       private `text(at:)` reader.
    3. `InterruptTests.swift`: `repeatingFirstArrival()` is replaced by
       `armed(after:)`. The watch waits until the delta is on the answer
       descriptor, and then offers the one arrival. The repeat is no longer
       necessary: a turn that already wrote a chunk is running, thus the agent
       cannot ignore the cancel (plan.md §8.6). The `arrivalInterval` constants
       are removed with the ticker.
    4. The case doc now states the order it depends on: the delta reaches the
       answer descriptor, and the interrupt follows it.

    ### The other case in the file

    `theInterruptSendsSessionCancelToTheAgent` does not depend on winning a race.
    It waits for the running update with `ScriptedTurnFixture.waitForRunning`
    before it reacts, and it reads the tap only after `waitForIdle`, which the
    agent sends after it handled the cancel. The three remaining cases are
    synchronous and touch no clock. Thus one case needed the correction.

    ### Falsification

    The property was broken on purpose in `Sources/acp-agent/RunTurn.swift`: the
    `agentMessageChunk` arm of `collect(from:into:)` was changed to drop the text
    instead of writing it. The case failed:

    ```
    Test aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived() recorded an
    issue at InterruptTests.swift:83:36: Caught error: "timed out while waiting
    until the first delta reached the answer descriptor"
    Test aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived() recorded an
    issue at InterruptTests.swift:147:9: Expectation failed:
    try capture.text() == Self.arrivedText
    Test run with 1 test in 1 suite failed after 30.121 seconds with 2 issues.
    ```

    The production code was then put back, and `git status` shows
    `Sources/acp-agent/RunTurn.swift` unchanged.
  timestamp: 2026-09-07T20:42:57.033507+00:00
- actor: claude-code
  id: 01m1ytd4ksh1ykav4p7ttf74rc
  text: |
    ### Rule check, and the two corrections it produced

    A read of the whole validator rule set against the diff gave two findings.
    Both are corrected.

    **1. `swift/immutability` — a top-level `func`.** Rule body, word for word:

    > - **A function belongs to a type.** A top-level `func` carries no
    > namespace, so its name must state the whole context and every file that
    > imports the module sees it. DON'T: `func formatDuration(_ seconds: Int)
    > -> String`. DO: `extension Int { var formattedDuration: String { … } }`,
    > or a `static func` on an `enum` namespace.

    `Support/PollUntil.swift` held `func pollUntil` at file scope, with its four
    constants beside it. The file is now `Support/Poll.swift`, and it holds
    `enum Poll` with `static func until(_:_:sourceLocation:)` and the four
    constants as `private static let` members. The five call sites read
    `Poll.until(...)`.

    **2. `swift/concurrency` — the loop a stored `Task` runs checks no
    cancellation.** Rule body, word for word:

    > - **Don't leak unstructured `Task { }`; prefer structured concurrency.**
    > DO: `async let a = fetchA(); async let b = fetchB()`, or `withTaskGroup`
    > for a dynamic set. Store long-lived `Task` handles, cancel them in
    > teardown, and check `Task.isCancelled`/`Task.checkCancellation()` in loops
    > — `cancel()` is a no-op if nothing checks. DON'T: `Task { while true {
    > await tick() } }`.

    `InterruptTests.armed(after:)` stores the handle and cancels it in `disarm`,
    but the loop the task runs — the poll loop — checked neither flag. The loop
    now calls `try Task.checkCancellation()` on each turn.

    ### Evidence after the corrections

    - The falsification was run again against the corrected code. It failed the
      same way: `Caught error: "timed out while waiting until the first delta
      reached the answer descriptor"` at `InterruptTests.swift:83:37`, and
      `Expectation failed: try capture.text() == Self.arrivedText` at
      `InterruptTests.swift:147:9`. The production code was then put back, and
      `git status -- Sources/` reports nothing.
    - Twenty full `swift test` runs after the corrections: 20 runs, 0 failures,
      each one 442 tests in 46 suites with exactly 1 known issue.
    - Twenty-one full runs before the corrections: 0 failures, the same counts.
      41 runs in all.
    - `swift build` reports no source warning. The one line it prints,
      `missing creator for mutated node` for the `mlx-swift_Cmlx.bundle` path,
      comes from a package dependency and stands on `main` as well.
  timestamp: 2026-09-07T20:54:23.609107+00:00
- actor: claude-code
  id: 01m1ytd9d6ndnz7ts3fnd2gtj6
  text: |
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/Support/Poll.swift (new), Tests/FoundationModelsACPAgentTests/Support/AnswerCapture.swift, Tests/FoundationModelsACPAgentTests/InterruptTests.swift, Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift. Falsification: "Expectation failed: try capture.text() == Self.arrivedText" at InterruptTests.swift:147:9, beside "timed out while waiting until the first delta reached the answer descriptor" at InterruptTests.swift:83:37. Full `swift test`: 41 runs, 0 failures, each 442 tests in 46 suites with exactly 1 known issue (20 of them after the two rule corrections). `swift build`: no source warning.
    - next: /review
  timestamp: 2026-09-07T20:54:28.518836+00:00
- actor: claude-code
  id: 01m1ytvrf30wfgbexdevtvn17q
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (955202a) — 0 findings, 0 confirmed, 2 refuted, 7 attempted, 0 failed. 4 files reviewed. The 6 `.kanban/` files are not reviewed, because an ignore rule holds them.
    - judgement on the four questions the review had to answer:
      - Order: `armed(after: capture.holds(Self.arrivedText))` gives the one arrival only after the capture file holds exactly `arrivedText`. Thus the cancel cannot go out before the text is on the descriptor, at any machine speed.
      - The one arrival: the ticker is not necessary. The fact that arms the watch is proof that the turn runs, and thus the agent cannot ignore the cancel. The script holds the turn open after the delta, thus the turn cannot end before the arrival.
      - Safety of `holds(_:)`: the closure holds the URL and not the capture, thus it is `@Sendable` and it shares no mutable state. The test is equality with the full text, thus a short read gives `false` and the poll reads again. A short read cannot give a wrong `true`.
      - The moved loop: `Poll.until` keeps the 30 s deadline, the 50 ms interval and the same timeout message as the private copy that it replaces. It adds `try Task.checkCancellation()` and `#_sourceLocation`. The four call sites in `MCPCompositionTests` keep their conditions and their labels, thus `^04kf7ha` and `^vhmwars` keep what they prove.
    - note: the card body writes `pollUntil`; the code gives `Poll.until` in `Tests/FoundationModelsACPAgentTests/Support/Poll.swift`. The code governs. This is not a finding.
    - next: none. The card is in `done`.
  timestamp: 2026-09-07T21:02:22.691762+00:00
- actor: claude-code
  id: 01m1ytwyqcxqq0vb1fb38w6cx2
  text: |
    ### finish iteration 1 — clean

    - implement: changed — 4 test files, no production file. `Tests/FoundationModelsACPAgentTests/Support/Poll.swift` is new: `enum Poll` with `until(_:_:sourceLocation:)`, which calls `try Task.checkCancellation()` on each turn. `MCPCompositionTests` held a private copy of that loop; the copy is deleted and its four call sites use the shared one. `AnswerCapture` gained `holds(_:)`, a `@Sendable` test of what the capture holds, which copies the file location and not the capture. `InterruptTests` now arms the watch with `armed(after: capture.holds(...))`, the shape `CompositionInterruptTests` already uses, and the repeating ticker is gone.
    - falsification: the `agentMessageChunk` arm of `RunTurn.collect(from:into:)` was made to drop the text. The case failed with `Expectation failed: try capture.text() == Self.arrivedText` at `InterruptTests.swift:147:9`. The production code was then put back, and `git status -- Sources/` reports nothing.
    - test: 41 full `swift test` runs, 0 failures. Each run 442 tests in 46 suites with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`. The defect used to appear about one run in five, so 41 clean runs is the measure. `swift build` gave no source warning.
    - commit: `955202a` `test(interrupt): order the first delta before the interrupt`
    - review: clean — 0 findings, 2 refuted, 7 attempts.

    The review answered four questions and found nothing wrong:

    1. The cancel is not made until the delta is on the answer descriptor, so a slow machine makes the wait longer and does not change the order.
    2. One arrival is enough. The ticker repeated because a cancel that reaches an agent with no active turn is ignored (plan.md §8.6), and nothing told the old case when the turn started. The new fact answers that directly: a turn that already wrote a chunk is a turn that runs.
    3. `holds(_:)` is safe while the writer appends. It tests equality with the whole expected text and not a prefix, so a short read gives `false` and the poll reads again. A partial read cannot give a wrong `true`.
    4. The moved poll loop keeps the 30 s deadline, the 50 ms interval and the same timeout message. The four call sites keep their conditions and labels word for word, so what `^04kf7ha` and `^vhmwars` proved is intact.

    One mismatch to correct on a later pass: the card body above names the new file `Support/PollUntil.swift`, and the file on disk is `Support/Poll.swift`. The code governs.
  timestamp: 2026-09-07T21:03:01.868899+00:00
position_column: done
position_ordinal: b980
title: 'InterruptTests: order the first delta before the interrupt, so the text assertion cannot race'
---
## What

`aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived` in
`Tests/FoundationModelsACPAgentTests/InterruptTests.swift` fails
sometimes. The failure came one time in five full `swift test` runs on
2026-09-07:

```
Test aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived()
recorded an issue at InterruptTests.swift:140:9:
Expectation failed: try capture.text() == Self.arrivedText
```

The `stopReason` assertion above it held. Only the text assertion
failed.

## The cause

The test scripts `[.textDelta(arrivedText), .hold]` and starts the
interrupt with `repeatingFirstArrival()`. Nothing orders the delta
before the interrupt. Thus the cancel can reach the agent before the
delta reaches the answer writer, and the capture is then empty.

The full test run puts many suites on the machine together, thus the
race opens there. The suite alone does not show it: eight runs of
`swift test --filter InterruptTests` each passed.

## Do

Make the delta arrive first, by order and not by a delay. The card
`^832y3wq` ("Prove the no-stage negative by order, not by a 300 ms
settle delay") holds the pattern this repository uses for the same
class of race. Read it first.

- [x] Find the seam that tells when the first delta reached the answer
      writer.
- [x] Hold the interrupt until that seam reports the delta.
- [x] Do not add a sleep, and do not weaken the text assertion.

## Acceptance Criteria

- [x] The test states the order it depends on.
- [x] Twenty full `swift test` runs give 442 tests in 46 suites with
      exactly one known issue, the `withKnownIssue` at
      `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`.
- [x] The text assertion still reads `arrivedText`.

## Notes

Found while working `^k4rq6ab`. That card changed
`ConfigurationLoaderTests.swift` only, thus it is not the cause. An
earlier comment on `^k4rq6ab` records the same shape: "A first
`swift test` run reported 2 issues (including 1 known issue), but the
four runs after it all report exactly 1 known issue. The cause was not
found." This card is that cause, named.

The seam is the `AnswerCapture` file. `AnswerWriter.receive(_:)` puts
each chunk on the descriptor with `write(2)`, which carries no
user-space buffer, thus a reader of that file sees the delta at the
moment the turn wrote it. `AnswerCapture.holds(_:)` gives that fact as
a `@Sendable` test, and the watch waits for it before it offers the one
arrival — the shape `CompositionInterruptTests.armed(after:)` already
uses.

No sleep decides an expectation. The shared `pollUntil` sleeps only to
space two reads of the fact; the fact ends the wait, and a deadline
that passes records an issue that names the fact.
