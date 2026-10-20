---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d4ew44mq3qj8eeeqn5a49c
  text: |-
    Research done.
    - `deleteSession` calls `tearDownSession` only for a session in the table. `tearDownSession` returns at once for a closed session. The `SessionEnd` post event reaches `SnapshotHook` on the dispatcher queue, thus `deleteSession` must call `hooks.dispatcher.drain()` before `snapshotStore.remove(sessionKey:)`.
    - `SnapshotStore.remove(sessionKey:)` (checkout of FoundationModelsHooks) throws `sessionKeyOpen` when an owner has the key open, and does nothing for a missing directory. No change to FoundationModelsHooks is necessary.
    - The echo stub model of `composeStubAgent`/`runOneTurn` makes no tool call, thus it writes no file and makes no tool checkpoint. The card asks for "one turn that writes a file (a checkpoint exists)". Thus the tests go in `HookCompositionTests` and use the existing `ScriptedPromptFixture` with the `writeCode` script in a git work tree (the same setup as the existing rollback proof). The git work tree setup is extracted into one helper, so it is not copied.
    - `ACPAgentTelemetry.caseName(of:)` gives `unknown` for an enum case with no payload (for example `SnapshotError.sessionKeyOpen`), thus the log needs its own case name.
  timestamp: 2026-10-20T17:06:33.732760+00:00
- actor: claude-code
  id: 01m5d4mmdqr8fnh284cg7cqgdn
  text: |-
    ### implement — changed
    - evidence: 3 files. `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift` (`deleteSession` calls the new `removeSnapshotTimeline(sessionKey:)`: drain the hook dispatcher, then `snapshotStore.remove`; `sessionKeyOpen` gives one notice record with the key only; each other error gives one error record with the key and the error case; the delete always succeeds). `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift` (new `LogMetadataKey.snapshotSessionKey`, `errorCaseName(of:)`, `snapshotKeyMetadata(_:error:)`). `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift` (3 tests from the card, 1 parameterized log metadata test with 3 cases, `makeSnapshotWorkTree` extracted from the rollback proof so the git setup is not copied).
    - RED: `aSessionDeleteRemovesTheTimelineOfItsSessionKey` failed before the change. The close test and the second-owner test passed before the change, because they guard behavior that already existed.
    - `swift test`: 1043 tests in 115 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. The one build line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" is from SwiftPM for the mlx-swift dependency, not from this change.
    - No change to agent start, to `session/close`, or to FoundationModelsHooks.
    - Note: the tests do not use `composeStubAgent`/`runOneTurn`, because the echo stub model writes no file and makes no checkpoint. They use the existing `ScriptedPromptFixture` write script.
    - next: /review
  timestamp: 2026-10-20T17:09:42.455150+00:00
- actor: claude-code
  id: 01m5d4q7h7mt1b7mg7ngg34za5
  text: |-
    ### test — green
    - evidence: swift test (changed files touched first, so they were rebuilt) — 1043 tests in 115 suites passed, 0 failed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted). swift build --build-tests --package-path IntegrationTests — Build complete, 0 errors. Only warning in both runs: SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx bundle (accepted). No compiler warning in the changed files.
    - next: review
  timestamp: 2026-10-20T17:11:07.559850+00:00
- actor: claude-code
  id: 01m5d4v5pgewrd8wjk631z0qfa
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d9d64b1): 2 findings (2 confirmed, 1 refuted) — Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:385, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:302
    - next: Correct the two reuse/reuse findings in the Review Findings (2026-10-20 12:11) section. Then run the review again.
  timestamp: 2026-10-20T17:13:16.752063+00:00
- actor: wballard
  id: 01m5d4vmt1mxf8d2q9qgq3y11w
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files
    - test: green — swift test 1043 passed; IntegrationTests builds
    - commit: d9d64b1
    - review: findings — Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:385, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:302
  timestamp: 2026-10-20T17:13:32.225033+00:00
- actor: claude-code
  id: 01m5d4zymdkc7bp336ck3x61nm
  text: |-
    ### implement — changed
    - evidence: 2 files. `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift`: `caseName(of:fallback:)` has a fallback parameter (an autoclosure, default `unknown`). `errorCaseName(of:)` keeps only the non-enum branch and calls `caseName(of:fallback:)` with the description as the fallback. Thus there is one Mirror label read, and `sessionKeyOpen` still logs `sessionKeyOpen`. `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift`: new `makeSnapshotFixture(script:label:)` makes the work tree (`<label>-repo`) and the fixture. The rollback proof and `makeWrittenSnapshotFixture` call it. Each script stays at its call site. The log metadata test has a new `sessionKeyOpen` case that guards the no-payload behavior. The other `ScriptedPromptFixture.make` calls in the file use no work tree, so they are not copies of this setup.
    - `swift test`: 1043 tests in 115 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. The only build line is the SwiftPM "missing creator for mutated node" line for mlx-swift_Cmlx.bundle, not from this change.
    - Both findings of Review Findings (2026-10-20 12:11) are `- [x]`.
    - next: /review
  timestamp: 2026-10-20T17:15:53.357665+00:00
- actor: claude-code
  id: 01m5d52at0n905mtejht9wnnts
  text: |-
    ### test — green
    - evidence: touched ACPAgentTelemetry.swift and HookCompositionTests.swift, then ran `swift test`: 1043 tests in 115 suites passed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: Build complete. Only warning in both runs: the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx. No compiler warning in the changed files.
    - next: review
  timestamp: 2026-10-20T17:17:11.360740+00:00
- actor: claude-code
  id: 01m5d55425th8ggtaayr9z0x5m
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c4407e0): 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:371
    - next: Move the enum check into caseName(of:fallback:) and add a test that gives a struct and expects the fallback. Then run the review again.
  timestamp: 2026-10-20T17:18:42.757596+00:00
- actor: wballard
  id: 01m5d55jr99nd9z4k01mk13a44
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 2 files
    - test: green — swift test 1043 passed; IntegrationTests builds
    - commit: c4407e0
    - review: findings — Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:371
  timestamp: 2026-10-20T17:18:57.801640+00:00
- actor: claude-code
  id: 01m5d5bwb08msvhy1jjw9dg0mk
  text: |-
    ### implement — changed
    - evidence: 2 files. `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift`: new private `isEnum(_:)` (the one `displayStyle == .enum` check). `caseName(of:fallback:)` returns `fallback()` when `isEnum` is false. `errorCaseName(of:)` keeps only its type-name guard (through `isEnum`) and the call to `caseName`. The `value` parameter doc now says that only an enum value can give a case label. `Tests/FoundationModelsACPAgentTests/ACPAgentTelemetryTests.swift`: new test `caseNameOfAStructGivesTheFallback` (a struct with one stored property; before the change it gave `content`, now it gives the fallback).
    - RED: the new test failed with `"content"` before the change. GREEN: it passed after.
    - Callers of `caseName(of:)`: `MCPComposition.Refusal.logMetadata` (passes `Refusal`, an enum), `ACPEventTranslator.eventMetadata` (passes `SessionEvent`, an enum of Router), `ACPEventTranslator` `.discoveryPrimingFailed` (passes `DiscoveryPrimingFailure`, an enum of Router), and `errorCaseName` (only after its enum guard). No caller passes a value that is not an enum, thus no caller result changes.
    - `swift test`: 1044 tests in 115 suites passed, 0 failures, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests). The only warning is the SwiftPM "missing creator for mutated node" line for mlx-swift_Cmlx.bundle, not from this change. No compiler warning.
    - The finding of Review Findings (2026-10-20 12:17) is `- [x]`.
    - next: /review
  timestamp: 2026-10-20T17:22:24.224497+00:00
- actor: claude-code
  id: 01m5d5es2jqkrpyfhyhgzxzb9g
  text: |-
    ### test — green
    - evidence: touched ACPAgentTelemetry.swift and ACPAgentTelemetryTests.swift, then `swift test`: 1044 tests in 115 suites passed, 1 known issue (the accepted withKnownIssue). `swift build --build-tests --package-path IntegrationTests`: Build complete. The only warning in both runs is the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle. No compiler warning in the changed files.
    - next: review
  timestamp: 2026-10-20T17:23:59.186804+00:00
- actor: claude-code
  id: 01m5d5heknfyppwrjw8zkezsq3
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit dee0ce2). 0 findings, 0 confirmed, 0 refuted. 2 files reviewed. All prior findings are checked.
    - next: The task is in done. No more work is necessary.
  timestamp: 2026-10-20T17:25:26.773850+00:00
- actor: wballard
  id: 01m5d5hrcrcc4a664whx760pgv
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 2 files
    - test: green — swift test 1044 passed; IntegrationTests builds
    - commit: dee0ce2
    - review: clean — 0 findings; task is done
  timestamp: 2026-10-20T17:25:36.792627+00:00
position_column: done
position_ordinal: fff080
title: 'ACPA-15: session/delete removes the snapshot timeline of its session'
---
## What
ACPA-15 and D96(b): Archive of the app removes the timeline of the session. The user decided on 2026-10-20 that Archive is the existing `session/delete`. The user also decided that there is NO sweep of orphan timelines at start (many sessions can share a folder). The explicit command of card ^5ynrv0z removes orphans.

Now `deleteSession` (`Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift:44`) removes `<root>/<ULID>/` and the `sessions.jsonl` record, but it never calls `SnapshotStore.remove(sessionKey:)`. The session key is the ACP session id (`HookLineage`, `AgentHooks.swift:98-117`).

Do this in `deleteSession`:
1. If the session is open, end it first as `session/close` does (`tearDownSession`, line 144), so the `SnapshotHook` gets `SessionEnd` and releases the key. Drain the hook dispatcher so the release is done before the remove.
2. Call `hooks.snapshotStore.remove(sessionKey: <session id>)`.
3. If it throws `SnapshotError.sessionKeyOpen`, another session still has the key. Keep the timeline, log one line at notice level with the key only, and complete the delete with success.
4. Any other error: log it (key and error case only, no paths with content) and complete the delete with success. A missing directory is not an error (HOOKS-4).

Do not add a removal to agent start or to `session/close`.

## Acceptance Criteria
- [x] After `session/delete`, the shadow folder of the session key does not exist.
- [x] When another owner has the key open, `session/delete` succeeds and the shadow folder stays.
- [x] `session/close` and agent start keep the shadow folder.
- [x] The logs name only the key and the error case.

## Tests
- [x] A test: new session, one turn that writes a file (a checkpoint exists), `session/delete`, then `shadowSessionKeys()` does not have the key.
- [x] A test: open the key with a second owner on the same `SnapshotStore`, `session/delete`, the delete succeeds and the key stays.
- [x] A test: `session/close` keeps the key.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-15

## Review Findings (2026-10-20 12:11)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:385` `reuse/reuse` — errorCaseName(of:) repeats the Mirror child-label read of caseName(of:) at line 368. The only differences are the fallback value and the non-enum branch. The new function is a near-match that was not extended. It should reuse caseName(of:) or take the fallback as a parameter, so there is one canonical case-name read. Give caseName(of:) a fallback parameter, or have errorCaseName(of:) call caseName(of:) for the enum-with-payload case and keep only the differing fallback and non-enum branch in errorCaseName. Keep one Mirror label read.
- [x] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:302` `reuse/reuse` — makeWrittenSnapshotFixture repeats the fixture setup of the existing snapshot test in the same file. It builds a ScriptedPromptFixture with makeHookLayeredModelLoader, the same labelled work tree and the same workingDirectory. The new helper is a near-match of that setup that was not extended. It differs only in the script, so the shared part should be one helper that takes the script as a parameter. Move the shared setup into one helper that takes the script and the label, and have both the existing snapshot test and makeWrittenSnapshotFixture call it. Keep the scripts at their call sites.

## Review Findings (2026-10-20 12:17)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:371` `completeness/invariant-propagation` — The doc of caseName(of:fallback:) says a value that is not an enum gives the fallback. The body does not check for an enum. For a non-enum value with stored properties, Mirror's first child is a property, so the function returns that property's label instead of the fallback. The enum guard was added only in errorCaseName (line 384), so the sibling helper does not get the same rule. Move the enum check into caseName: return fallback() when Mirror(reflecting: value).displayStyle != .enum. Then errorCaseName can keep only its type-name branch. Add one test that passes a struct to caseName and expects the fallback.
