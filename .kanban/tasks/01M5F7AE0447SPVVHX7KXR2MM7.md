---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'ACPA-14: read past sessions from Router; remove the ACPAgent copies of SessionIndex and ProjectRegistry'
---
Spec: TestudoApp/features/packages/foundationmodels-acpagent.md, ACPA-14 (status agreed; D23, D72; depends on ROUTER-3).

## Why now
The Router session has ROUTER-3 done and green on the branch `router-3-session-index` (29ae4767) of FoundationModelsRouter. It holds Router's own SessionIndex, and next its ProjectRegistry. With it, the name `SessionIndex` is ambiguous in this test target. The library still compiles, but these lines fail:
- Tests/FoundationModelsACPAgentTests/TranscriptRecordingFixtures.swift:138
- Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift:53
Both import FoundationModelsRouter and `@testable` FoundationModelsACPAgent. The Router user chose ACPA-14 over qualified names. Router merges its branch to main only when ACPA-14 is ready.

## Change
- Remove `Sources/FoundationModelsACPAgent/Transcripts/SessionIndex.swift` and `Transcripts/ProjectRegistry.swift`.
- `session/list` and `session/resume` read the record of past sessions from Router.
- `TranscriptStore` uses the Router types. ACPAgent only carries the record over ACP.

## How
- Work on a local branch `acpa-14` of this repo. Point the Router dependency to the branch `router-3-session-index` there (Package.swift, `routerDependencyName`), and build against it.
- When it is green, tell the Router session (foundationmodelsrouter-08) that ACPA-14 is ready. Router merges and sends the sha. Then move the pin back to main, run `swift package update FoundationModelsRouter`, test again, and merge `acpa-14` to main.

## Done when
- A failing test first (TDD), where a test can show the change: for example, `session/list` gives a past session that the Router index holds.
- No type named SessionIndex or ProjectRegistry is left in this package. The full `swift test` passes against Router main after the merge. #acpa-14