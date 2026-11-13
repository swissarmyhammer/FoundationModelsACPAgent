---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79mwp31yt5wqm5y05ns0nsy
  text: |-
    Research and work:
    - Cause: `openPrompt(of:hold:)` in HotResumeTests.swift returns at the first update of the child (any update, for example the announcement or the `running` state). `startLiveTree`, `startWindowTree` and `startQuestionWindowTree` returned at that time. `startGatedTree` and `startHeldReplayTree` already waited for the text of the child, with an inline copy of the wait.
    - The slow setup is in the child, not before the resume: the time between the first update of the child and its text. A delay before the resume makes the race smaller, not larger.
    - Test-only delay: the child of `startLiveTree` now waits on a hold before its text. A structured `async let` releases the hold `childTextDelay` (300 ms) after the first update of the child. No product code changed.
    - RED (delay, no fix): `swift test --filter 'HotResumeTests/theReplay(AnnouncesTheChildBeforeItsHistory|HoldsTheHistoryOfTheChildBeforeTheResponse)'` gave 2 of 2 failed: "Expectation failed: history" and "Expectation failed: trace.firstIndex { $0.isHistory(of: child) }".
    - GREEN (delay and fix): the same command gave 2 of 2 passed.
    - Fix: new helper `waitForTheTextOfTheChild(of:)` (the same condition as `PausedChildTree.isChildText(under:)`: a text chunk of the child that holds the text). `startLiveTree`, `startWindowTree` and `startQuestionWindowTree` call it. `startGatedTree` and `startHeldReplayTree` call it in place of their inline copies.
    - `startAskingTree` is not changed: its child plays no text before its question, and its setup waits for the question (`waitForCreates`). Its tests do not read the history of the child.
    - `swift format lint` gives 8 warnings on the file. The same 8 are in HEAD. None is on a changed line.
    - The build prints "warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)". This is a warning of the build system for the mlx-swift resource bundle, not a compiler warning, and it is not from this change.
  timestamp: 2026-11-13T05:08:09.441621+00:00
- actor: claude-code
  id: 01m79ngf9m5kj0kq0y9wdax5q6
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/HotResumeTests.swift. No product code changed. RED with the test-only delay (300 ms before the text of the child): the 2 replay tests failed. GREEN with the fix: the 2 tests passed. `swift test --filter HotResumeTests` (each run with `timeout 300`): 20 of 20 runs passed, 26 tests in each run. `timeout 900 swift test`: exit 0, 2042 tests in 222 suites passed, 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps, an expected issue that was there before). Zero compiler warnings. The build prints the warning "missing creator for mutated node" for the mlx-swift_Cmlx bundle. That warning is from the build system and was there before this change.
    - next: /review
  timestamp: 2026-11-13T05:18:57.844823+00:00
- actor: claude-code
  id: 01m79nkswd7tff1qmdq38rwkns
  text: |-
    ### review — clean
    - evidence: review sha 8402f77~1..8402f77 — 0 findings (0 confirmed, 0 refuted); 1 file reviewed (Tests/FoundationModelsACPAgentTests/HotResumeTests.swift), 6 .kanban files not reviewed (ignore rule).
    - next: The task is in done.
  timestamp: 2026-11-13T05:20:46.989180+00:00
position_column: done
position_ordinal: ffffe380
title: 'HotResumeTests: the setup waits for any update of the child, not for the child text, so two replay tests can fail'
---
## What
Found during ^wpsm1jx (2026-11-12). `HotResumeTests.theReplayAnnouncesTheChildBeforeItsHistory` and `theReplayHoldsTheHistoryOfTheChildBeforeTheResponse` fail with `history -> nil` in 3 of 9 runs when session setup is slower (with the ^wpsm1jx change), and 0 of 7 without it. Each passes alone. The setup of these tests waits for any update of the child, not for the text of the child, so the history of the child can be empty when the resume runs. This is a race in the test, not in the product (the same form as the fixture race of 6b43e19).

1. Find the shared setup of the two tests in Tests/FoundationModelsACPAgentTests/HotResumeTests.swift.
2. Make it wait for the text of the child (the entry that the replay must hold), the same as `PausedChildTreeFixture.start` does since 6b43e19 (`isChildText(under:)`), so the history is never empty at the resume.
3. Check the other tests of the file for the same wait.

## Acceptance Criteria
- [ ] The two tests pass in 20 runs of the suite in a row, also with a slower setup (for example with an injected delay in the test before the resume, or with the ^wpsm1jx change applied).

## Tests
- [ ] The changed setup; a loop of 20 runs of `swift test --filter HotResumeTests` passes.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1