---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gjcrcrjtfnb7zft14v002w
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:29.560382+00:00
- actor: claude-code
  id: 01m6j6dbm9nczbvkva3g6xfj6h
  text: |-
    Finding on session/list: the listing already leaves out sub-agent sessions. TranscriptStore.isListable requires firstActivityAt, no forkParentId and no agentSpawn. The store test spawnedSessionIsExcludedFromTheListing covers the store. I added only a regression test at the agent level (theListNeverReturnsAChild): the child has a record with activity and agentSpawn, and the wire listing returns only the root.

    Finding on methods: this agent has no handler for session/fork, session/load or session/set_mode (the Agent protocol of the wire package has none of them). The set refuses them for a child by name (tested), and a handler that is added later calls requirePermitted. Wired now: prompt, close, delete, resume, set_config_option; session/cancel is ignored with a log line when the set does not permit it.

    Design: SessionCapabilitySet (Agent/SessionCapabilitySet.swift) is data on ActiveSession.capabilities. The root build gives .all. The nested build gives SessionCapabilitySet(advertised: SubagentAnnouncer.childCapabilities), the same value the subagent_update advertises. Default is not permitted. Refusal: RequestError.methodNotPermitted, invalid params with sessionId, method and reason in data. No "if child" branch added. Test support change: ScriptedPromptFixture.close sends session/close to root sessions only, because a child now refuses the client close.

    Tests: swift test --filter SessionCapabilityTests, 15 passed. Also ran the nested, lifecycle, child, config option, cancellation and announcer suites: 167 passed.
  timestamp: 2026-11-04T02:32:35.209448+00:00
- actor: claude-code
  id: 01m6j6ddaq4p85knk4nkpmweac
  text: |-
    ### implement — changed
    - evidence: 11 files. New: Sources/FoundationModelsACPAgent/Agent/SessionCapabilitySet.swift, Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift. Changed: ConfigOptions.swift, PromptExecution.swift, SessionBuild.swift, SessionLifecycle.swift, SessionResume.swift, SessionSetup.swift, SubagentAnnouncement.swift, Tests/.../Support/ScriptedPromptFixture.swift. All 7 checkboxes of the card checked. SessionCapabilityTests 15 passed.
    - next: /review
  timestamp: 2026-11-04T02:32:36.951109+00:00
- actor: claude-code
  id: 01m6j6nqdd9vxqzyweqnxgcw2j
  text: |-
    ### review — findings
    - scope: review sha HEAD~1..HEAD. Counts: 2 findings, 2 confirmed, 0 refuted.

    ## Review Findings (2026-11-03 20:34)

    - [ ] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift:189` `test-integrity/no-test-cheating` — The test aRefusedCloseLeavesTheChildOpen discards the result of Self.refusal. It never checks that the close was refused with the typed invalidParams error for session/close. The test passes when closeSession throws any error, including a transport failure, as long as the child is still idle. The test name claims a refusal, but the refusal is not proven. Capture the result and assert it with Self.isRefusal(error, of: ACPMethod.sessionClose, on: childId), as closeOnAChildIsRefused already does. Keep the availability check as a second assertion.
    - [ ] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift:216` `test-integrity/no-test-cheating` — The test aRefusedDeleteLeavesTheEntryOfTheChild discards the result of Self.refusal. It never checks that session/delete was refused with the typed error. The test passes when deleteSession throws any error, so the refusal is not proven. Capture the result and assert it with Self.isRefusal(error, of: ACPMethod.sessionDelete, on: childId). Keep the table-entry check as a second assertion.

    - next: the implementer fixes both findings. The task stays in review. The description was not changed, as the caller asked (append only).
  timestamp: 2026-11-04T02:37:09.421172+00:00
- actor: claude-code
  id: 01m6j6p17k5r9vnwj3krdxvpvs
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files, 7 of 7 items checked
    - test: red — root 1572 tests, only the known blocker ShellSessionOwnerTests (card ^wd0cwz7) failed; IntegrationTests deterministic 38 passed
    - commit: d778a71
    - review: findings — Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift:189, Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift:216
    - next: implement works the 2 open findings (listed in the review comment)
  timestamp: 2026-11-04T02:37:19.475896+00:00
- actor: claude-code
  id: 01m6j6qb22sp38x3akek9eb2z3
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift. Finding 1 (aRefusedCloseLeavesTheChildOpen) and finding 2 (aRefusedDeleteLeavesTheEntryOfTheChild) fixed: each test keeps the refusal result and asserts Self.isRefusal for sessionClose / sessionDelete, then keeps the second check. No other test in the file discards a refusal result. swift format run. `swift test --filter SessionCapabilityTests`: 15 tests passed.
    - next: review
  timestamp: 2026-11-04T02:38:02.306965+00:00
- actor: claude-code
  id: 01m6j6sbw4167tdq4hdt4y675z
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD. Counts: 0 findings, 0 confirmed, 0 refuted. Both prior items are fixed in SessionCapabilityTests.swift: aRefusedCloseLeavesTheChildOpen and aRefusedDeleteLeavesTheEntryOfTheChild now keep the refusal result and assert Self.isRefusal. Every prior item is checked.
    - next: the task moves to done. The description was not changed (append only).
  timestamp: 2026-11-04T02:39:08.676284+00:00
depends_on:
- 01M6GH2K0VV6RWV5R6SN3HB9SV
position_column: done
position_ordinal: ffff9f80
title: 'Per-session capabilities: a child allows only what it advertises; refuse every other client mutation of a child'
---
## What
A child session is an ordinary session whose capabilities differ by DATA. Do not write "if child" branches (design rule, user 2026-11-03). Give each session entry a capability set: `entry.capabilities.permits(method)`. The root has all of them. A child has only what it advertises in `subagent_update.capabilities` (today only `cancel`). Every client mutation not advertised is refused, also a method added later (the default is "not permitted").

Methods to gate (in `Sources/FoundationModelsACPAgent/Agent/`): `session/prompt` (`PromptExecution.swift`), close, delete, fork (`SessionLifecycle.swift`), load and resume (`SessionResume.swift`), set mode and set config option (`ConfigOptions.swift`). Refuse with a typed `RequestError` that names the child and the method. `session/cancel` on a child is permitted when the child advertises `cancel` (the cancel task does the work). Do not offer the slash commands of a child as input.

`session/list`: children are found through the parent, not as standalone entries. Check what `session/list` returns today for a recorded sub-agent session (the listing goes through the Router transcript store; I did not verify whether it already leaves out sessions with an `agentSpawn`). Write the finding in a task comment. If sub-agents are listed, leave them out; if not, add only a regression test.

Needs the wire type for the child capabilities (FoundationModelsACP wire card `01M6GJ664BHY454C5NFPFCSP79`).

## Acceptance Criteria
- [x] The session entry has a capability set; the root permits all methods; a child permits only `cancel`.
- [x] `session/prompt`, close, delete, fork, load, resume, set mode and set config option on a child id each return the typed error.
- [x] A method that the gate does not know is refused for a child.
- [x] No `if child` branch outside the capability set.
- [x] `session/list` never returns a child id (regression test).

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift`: one test for each refused method, the unknown method, the root, and the list.
- [x] Run `swift test --filter SessionCapabilityTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-11-03)
- [x] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift` test `aRefusedCloseLeavesTheChildOpen`: the test now keeps the result of `Self.refusal` and asserts `Self.isRefusal(error, of: ACPMethod.sessionClose, on: childId)`. The availability check stays as the second assertion.
- [x] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift` test `aRefusedDeleteLeavesTheEntryOfTheChild`: the test now keeps the result of `Self.refusal` and asserts `Self.isRefusal(error, of: ACPMethod.sessionDelete, on: childId)`. The table-entry check stays as the second assertion.
- [x] Cause removed from the whole file: no other test in the file discards the result of `Self.refusal`. All other refusal tests already capture it and assert it.
