---
assignees:
- claude-code
position_column: todo
position_ordinal: 9c80
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

- [ ] Find the seam that tells when the first delta reached the answer
      writer.
- [ ] Hold the interrupt until that seam reports the delta.
- [ ] Do not add a sleep, and do not weaken the text assertion.

## Acceptance Criteria

- [ ] The test states the order it depends on.
- [ ] Twenty full `swift test` runs give 442 tests in 46 suites with
      exactly one known issue, the `withKnownIssue` at
      `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`.
- [ ] The text assertion still reads `arrivedText`.

## Notes

Found while working `^k4rq6ab`. That card changed
`ConfigurationLoaderTests.swift` only, thus it is not the cause. An
earlier comment on `^k4rq6ab` records the same shape: "A first
`swift test` run reported 2 issues (including 1 known issue), but the
four runs after it all report exactly 1 known issue. The cause was not
found." This card is that cause, named.
