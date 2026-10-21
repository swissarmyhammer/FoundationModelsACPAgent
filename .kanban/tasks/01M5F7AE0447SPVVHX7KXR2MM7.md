---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f7c6npbystb4thgjgkngz8
  text: |-
    Coordinator update (2026-10-21): Router branch router-3-session-index at 29ae4767 has only SessionIndex, no ProjectRegistry yet. Router is adding ProjectRegistry (^k176prd) to that branch and will send the sha.
    - Do the SessionIndex half first.
    - Do the ProjectRegistry half last. Before removing ProjectRegistry.swift, run `swift package update FoundationModelsRouter` on the acpa-14 branch and check that Router's ProjectRegistry is in .build/checkouts/FoundationModelsRouter.
    - If it is not there yet, keep ProjectRegistry.swift and report that this half waits for the Router sha.
  timestamp: 2026-10-21T12:36:00.822082+00:00
- actor: claude-code
  id: 01m5f86nshv3fwxyf9vw9c7tas
  text: |-
    Coordinator update 2 (2026-10-21): Router's ProjectRegistry is on router-3-session-index at 5b9423f7. Build acpa-14 against that sha and do both halves (supersedes "keep ProjectRegistry.swift").
    Router public API:
    - ProjectRegistryRecord(path:firstSeen:lastSeen:), public vars for all three.
    - ProjectRegistry(directory:): registryFileName "projects.jsonl", .directory, recordSessionStart(workingDirectory:at:) (at defaults to Date()), projects() (drops folders that no longer exist).
    - SessionIndex, SessionIndexRecord, SessionIndexReadResult, SessionIndexWarning, SessionIndexError keep the same names.
    - Old ACPAgent files read back the same; new entries write the same bytes.
    Name clashes Router found in a scratch build of 93e11c9 that ACPA-14 must clear:
    - TranscriptStoreTests.swift:503 (ProjectRegistry)
    - TranscriptRecordingFixtures.swift:138 and TranscriptStoreTests.swift:53 (SessionIndex)
    Also remove this package's ProjectRegistryRecord.
  timestamp: 2026-10-21T12:50:28.273991+00:00
- actor: claude-code
  id: 01m5f8jvb795etssngca8z4m7b
  text: |-
    Coordinator update 3 (2026-10-21): Router is landing SessionIndex and ProjectRegistry on FoundationModelsRouter main itself; RouterSessionDirectory (EXTRAS-3) is on main (19254b88). Rule: if Router main holds them, do ACPA-14 on main against Router main (no acpa-14 branch, no pin; drop a branch and move its commits to main). If not, keep the branch plan. The Router update and ACPA-14 must land in one change (the name clashes break the test target).
    Check at 2026-10-21: `git ls-remote` main = be3f0811 (tip "^k176prd is on router-3-session-index at 5b9423f7"); main's tree has RouterSessionDirectory.swift but no SessionIndex/ProjectRegistry. router-3-session-index = 5b9423f7. So for now: branch plan. Check again when this card starts.
  timestamp: 2026-10-21T12:57:07.175087+00:00
- actor: claude-code
  id: 01m5fd91x0vzjhp6890zhywehw
  text: |-
    ### implement — changed (local branch acpa-14, not pushed, not merged)
    - Deviation from the plan, pin: `branch: "router-3-session-index"` in Package.swift does NOT resolve: "foundationmodelsrouter is required using two different revision-based requirements (router-3-session-index and main), which is not supported". FoundationModelsAgents/Package.swift requires Router `branch: "main"`. So acpa-14 has NO pin commit; Package.swift stays on main. The build used `swift package edit FoundationModelsRouter --revision 5b9423f7` (Packages/FoundationModelsRouter, untracked, never committed); `swift package unedit FoundationModelsRouter` was run before switching back to main. To rebuild acpa-14 against the branch again, repeat that edit. When Router merges to main no pin is needed at all: `swift package update FoundationModelsRouter` is enough.
    - Name clashes seen against 5b9423f7 before the change: TranscriptRecordingFixtures.swift:138, TranscriptStoreTests.swift:53, SessionSetupTests.swift:369 (SessionIndex); TranscriptStoreTests.swift:503, SessionSetupTests.swift:365 (ProjectRegistry).
    - RED A (SessionIndex half), TranscriptStoreTests `listingGivesThePastSessionRoutersSessionIndexHolds` (record written with FoundationModelsRouter.SessionIndex, read with TranscriptStore.sessions(inProject:)): `TranscriptStoreTests.swift:251:25: error: binary operator '==' cannot be applied to operands of type '[FoundationModelsACPAgent.SessionIndexRecord]' and '[FoundationModelsRouter.SessionIndexRecord]'`.
    - RED B (ProjectRegistry half), `allProjectsGivesTheProjectRoutersProjectRegistryHolds` (Router ProjectRegistry.recordSessionStart, read with TranscriptStore.allProjects()): `TranscriptStoreTests.swift:543:22: error: binary operator '==' cannot be applied to operands of type '[FoundationModelsACPAgent.ProjectRegistryRecord]' and '[FoundationModelsRouter.ProjectRegistryRecord]'`. (The RED runs are swiftc -typecheck of the test file, because the build stops at the clash errors of other files.)
    - GREEN: both tests passed (2 tests in 1 suite).
    - Full `swift test` on acpa-14 against 5b9423f7: "Test run with 1174 tests in 127 suites passed after 19.970 seconds with 1 known issue" (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps).
    - Commits on acpa-14: 40806f3 refactor(transcripts): read past sessions from Router's SessionIndex; 993dbf8 refactor(transcripts): use Router's ProjectRegistry. 40806f3 alone does not build the test target (the ProjectRegistry clash stays until 993dbf8).
    - Removed: Transcripts/SessionIndex.swift, Transcripts/ProjectRegistry.swift, Transcripts/JSONLines.swift (only those two used it), Tests SessionIndexTests.swift and ProjectRegistryTests.swift (Router holds the same suites). No type SessionIndex*, ProjectRegistry or ProjectRegistryRecord is declared in this package.
    - Router API gap: `SessionIndex.lastActivityDate(inSessionDirectory:)` is internal in Router, so TranscriptStore now has a private copy of that fallback (the `updatedAt` of a session with no index line: the mtime of transcript.jsonl, then session.json, cut to whole seconds). If Router makes it public, TranscriptStore should call it and drop the copy.
    - next: tell the Router session (foundationmodelsrouter-08) that ACPA-14 is ready on acpa-14; after Router merges, run `swift package update FoundationModelsRouter`, run the full suite again, and merge acpa-14 to main.
  timestamp: 2026-10-21T14:19:09.088769+00:00
- actor: claude-code
  id: 01m5fe0mq2xy6md8k01191kvky
  text: |-
    ### done — on main 7031203 (pushed)
    - Router merged ROUTER-3 to main; `swift package update FoundationModelsRouter FoundationModelsExtras` gave Router 62d1e875 and Extras 6716646 (contains fda3a55). No pin, no `swift package edit` left.
    - What the update broke, fixed in 07301d5: RoutedSession gained `nonisolated var facts: SessionFacts` (ROUTER-1); test double CloseCountingRoutedSession now forwards it.
    - 7031203 refactor(transcripts): use Router's SessionIndex.lastActivityDate: TranscriptStore's private copy is removed. No RED test is possible here: Router's public helper has the same file order (transcript.jsonl, then session.json), the same whole-second truncation and the same Date() fallback, so a test could not fail before the change. The existing tests cover it.
    - Full `swift test` on acpa-14 before the merge: "Test run with 1174 tests in 127 suites passed after 19.085 seconds with 1 known issue" (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps). main fast-forwarded from f8e70ef to 7031203, so the suite was not run again; acpa-14 deleted.
    - Commits: 40806f3, 993dbf8, 6d2762b, 07301d5, 7031203.
  timestamp: 2026-10-21T14:32:02.018872+00:00
position_column: done
position_ordinal: ffff8280
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