---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7t4tgvfnmwdhr4ap86e16nt
  text: |-
    Research done.
    - Router (RoutedSessionActorCompactionYield) stops the model call in the tool layer at a tool result. It rebuilds the stopped attempt (InFlightTranscript.rebuilt): the settled entries, the attempt prompt, a `.toolOutput` for each result, and it removes the calls of the last `.toolCalls` entry that have no output. Then it calls `replacingTranscript` and sends the continuation prompt "The context was compacted. Your last tool result is above. Continue the task.". This prompt does not contain the markers of `onPrompt` steps.
    - Thus the open pass is the entries after the last ended `.response`. Its first `.prompt` entry is the prompt of the pass. Each `.toolOutput` entry is a tool call of the pass that played. Text steps write no entry, but a stop occurs only at a tool result, so all steps up to the step of the last played call played.
    - The stub has no observer, so a cancelled scripted pass does not check cancellation between steps. It can play a later step after the Router stop. Not changed here (not on the card).
    - Token count (optional item 3): `CharacterCountTokenCounter` (EchoModel.swift, not a Scripted* file) counts one token for each character on purpose. It is the rule of Router's own `CharacterTokenCounter`, and `StubMetadata.window` is 32,768 (not 8,192) to compensate for the factor of about 4. It is not clearly wrong, so no change.
  timestamp: 2026-11-19T14:54:26.671469+00:00
- actor: claude-code
  id: 01m7t5db68f1e8s4hmqeqs5s2r
  text: |-
    Implementation landed (no commit).
    - `ScriptedPassStep.swift`: `makesToolCall`, `resolved(_:forPrompt:)` (puts each branch that the prompt of the pass matches in its place) and `remaining(_:afterToolCalls:)`.
    - `ScriptedPlaybook.swift`: `Progress(continuing:)` finds the open pass (the entries after the last ended `.response`), counts its `.toolOutput` entries, resolves the branches with the FIRST prompt of the open pass (not the continuation prompt), and keeps the steps after the last played tool call in `openPassRest`. The next call plays them. With no played tool call, the pass plays from its start as before (the restore at a gate test still passes).
    - `ScriptedSessionBackend.swift`: `playedToolCallCount` starts from the number of calls in the `.toolCalls` entries of the seeded entries.
    - Tests: `ScriptedPassContinuationTests.swift`, 7 tests. RED seen first: 6 failed before the change (the regression guard for an ended pass passed, as the card expects).
    - Blocker seen and gone: during the work, commit c7093c2 (^pqweam5) was merged and needed Router e437cda. The local pin moved to e437cda during the run, and the build then passed.
    - Full suite: 2577 tests, 1 failure, not in the scripted code: `TranscriptSearchAgentUpdatesTests/aRecordWithNoTitleGetsTheSlugOfTheRouter` (slug "default", expected the short id), from the ^pqweam5 merge.
    - Client check: FoundationModelsACPClient `IntegrationTests/LiveAgentServer/Package.swift` depends on FoundationModelsACPAgent by remote URL, branch main. It cannot see this change before the push. Run `timeout 1800 swift test --package-path IntegrationTests --filter aCancelOfOneChildEndsOnlyThatChild` there after the push.
    - Follow-up task: ^ptasrrj (a cancelled scripted pass stops before its next step).
  timestamp: 2026-11-19T15:04:43.464899+00:00
- actor: claude-code
  id: 01m7t5de9s969x1hwqyp160aae
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Configuration/ScriptedPassStep.swift, Sources/FoundationModelsACPAgent/Configuration/ScriptedPlaybook.swift, Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift, Tests/FoundationModelsACPAgentTests/ScriptedPassContinuationTests.swift
    - next: review; after the push, the client check in FoundationModelsACPClient

    ### test — red
    - evidence: `timeout 1800 swift test --skip-build`: 2577 tests, 1 failure (TranscriptSearchAgentUpdatesTests/aRecordWithNoTitleGetsTheSlugOfTheRouter, Search code of ^pqweam5, not this change), 1 known issue; ScriptedPassContinuationTests 7/7 pass; build "Build complete!" with 0 compiler warnings
    - next: the owner of ^pqweam5 corrects the Search failure
  timestamp: 2026-11-19T15:04:46.649874+00:00
position_column: doing
position_ordinal: '8180'
title: A scripted session continues its open pass after a Router compaction stop, and does not play it again from step 1
---
Bug report from the FoundationModelsACPClient session (2026-11-19). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/acpagent-scripted-continuation.md` (read it: it has the evidence).

## The failure

The FoundationModelsACPClient integration test `AgentNestedScenarioTests/aCancelOfOneChildEndsOnlyThatChild()` fails in CI (runs 44366478943 and 44530736484) and locally with fresh pins of the `acp-agent-stub` (ACPAgent 6a6eec1, Router e437cda, Extras f99b111). It passed with the pins of 2026-11-12.

## The cause (from the root transcript of a local reproduction)

1. The root pass plays step 1, `start agent researcher`, with call id `scripted-call-1`. After that call, the context goes over the compaction trigger (the stub counts one token for each character, and the root instructions are large). Router stops the model call to compact; the compaction fails, and the answer continues on a NEW backend.
2. The new backend comes from `ScriptedSessionBackend.replacingTranscript` (`Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift:207`). `ScriptedPlaybook.Progress(continuing:)` (`Configuration/ScriptedPlaybook.swift:49`, `:53`, `:74`) counts only the passes that ENDED. Pass 0 did not end, so the new backend plays pass 0 again from step 1, and its call counter (`ScriptedSessionBackend.swift:607`) starts again, so the call id is `scripted-call-1` again.
3. Each later continuation plays step 1 again, and the Router identical-tool-call check ends the root with `_repeated` (a symptom). Since ACPAgent eb8254c the Router tool layers are on the stub tools, so that check applies.
4. The client test waits for `scripted-call-2`, which never comes.

## Change

1. When Router continues an answer on a new backend, the scripted session continues the SAME pass: `ScriptedPlaybook.Progress(continuing:)` counts the steps that the open pass already played, from the seeded entries, and continues after them.
2. `playedToolCallCount` starts from the `.toolCalls` entries in the seeded entries, so each call id stays different.
3. Optional: examine whether the stub must count one token for each character. Large built-in instructions make a stub session compact after one tool call. Report what you find; change it only if it is clearly wrong.

## Tests

- A compaction stop after step 1 of a two-call pass plays step 2 next, with the id `scripted-call-2`.
- A continuation after a pass that ended still starts the next pass (the old behavior).
- With fresh pins, in FoundationModelsACPClient: `timeout 1800 swift test --package-path IntegrationTests --filter aCancelOfOneChildEndsOnlyThatChild` passes (run it in that repo only to check; do not change that repo).

When this lands, push to origin/main and send the sha to the FoundationModelsACPClient session (foundationmodelsacpclient-1d). #bug #scripted