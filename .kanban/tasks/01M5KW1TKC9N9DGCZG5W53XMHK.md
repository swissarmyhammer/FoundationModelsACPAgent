---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5kwd612c9ncw4zkn22rcvj8
  text: |-
    ### Hooks 4f463f2 (2026-10-23) — use it in this card
    - Update the Hooks pin to 4f463f2.
    - `Checkpoint.owner: String` (SnapshotHook passes session.sessionID); `.pending` and `.rollback(to:)` carry the owner who asked.
    - `SnapshotChange.owners: Set<String>` (owners of the key at send time) and `SnapshotChange.owner` (= checkpoint.owner). Fan change events out to `change.owners`; show "session X's edit" from `owner`. Init is now `SnapshotChange(sessionKey:checkpoint:owners:)` — fix any code that builds one.
    - `SnapshotStore.shared(directory:)`: one store per resolved directory in the process (weakly held). AgentHooks must use it instead of `SnapshotStore(directory:)`.
    - Breaking: v1 timelines (old trailer) now throw `unreadableTimeline`. SnapshotInventory / the snapshots command must handle that as an unreadable timeline (warning), not crash.
    - Multitool's SnapshotsCapability maps key -> one session id; with owners in the change, ask Multitool to fan out by `change.owners` (asked 2026-10-23).
  timestamp: 2026-10-23T08:00:30.754428+00:00
- actor: claude-code
  id: 01m5kx5xfcyz68vv4wbwyarb47
  text: |-
    ### Multitool 743a022 (2026-10-23) — use it in this card
    - Update the Multitool pin to 743a0223412f8ddc7315995154d20f2337d3d4c6 (builds on Hooks 4f463f2; contains d2f6446 shell store too).
    - BREAKING: the `sessionId: (key) -> String?` resolver is gone. `SnapshotsCapability(store:sessionKey:)` and `SnapshotsGraph(store:sessionKey:)` now. Fix RoutedACPAgent.swift:419 and any other caller.
    - The change feed records one change per session in `change.owners`; a session that the sessionKey resolver maps to nil gets no change. With the shared cwd key, A's take/rollback reaches A and B.
    - Graph: `owner: ID!` on Checkpoint and SnapshotChange. Checkpoint ids stay `<sessionId>:<index>`.
    - Test: two sessions in one cwd — a take by A appears as a change for B with owner A.
  timestamp: 2026-10-23T08:14:01.196528+00:00
- actor: claude-code
  id: 01m5kzqv67d579gwef44r602q1
  text: |-
    Picked up. Research:
    - Pins moved in Package.resolved (gitignored): Hooks a3bbafb -> 4f463f2, Multitool 94c992c -> 743a022 (edited revisions + `swift package resolve`; both are origin/main tips). No other pin moved.
    - BLOCKER for the resume item: Router `restoreSession` / `restoreSessionTree` take no hook session key. `SessionTreeRestoration.rebuild` calls `makeSessionHooks(... isRestored: true)` with no `requestedKey`, so a restored root gets its own id as key (`HookLineage.make`, SessionHooks.swift). Router origin/main (3bd3cef1) has no such parameter either. The agent cannot pass `HookLineage(sessionKey: <cwd key>)` on `session/resume` until Router adds e.g. `restoreSession(..., hookSessionKey:)`. New and model-switch can (they go through `makeBudgetedSession` -> `SessionConfiguration.hookSessionKey`).
    - CodeContext `rootKey(for:)` is not in the pinned CodeContext (b0c8aba); only in the local repo. The agent gets its own key function with the same normalization (`standardizedFileURL.resolvingSymlinksInPath()`), shared with `AgentHome.projectKey`.
    - Multitool 743a022: the change feed of a store binds the `sessionKey` resolver of the FIRST endpoint over that store, and `SnapshotStore.shared` makes the store per directory per process. So the session id -> key map must be the same for the agent endpoint and each session's `SnapshotsCapability`, across agents of one process: a process-wide registry (session ids are ULIDs, so no collision).
    - A model-switch replacement is a new Router session id; it is an owner in `change.owners` but no ACP session id, so the feed records no change under the ACP id for checkpoints the replacement makes after the replaced session is released. Pre-existing shape, not in this card.
    - SnapshotInventory already turns any non-noTimeline summary error into `timelineUnreadable` warning, so v1 timelines (now `unreadableTimeline`) are warnings; needs a test.
  timestamp: 2026-10-23T08:58:45.831083+00:00
- actor: claude-code
  id: 01m5m0fpx010jdhdjv8q0qt8q8
  text: |-
    Implementation landed (not committed). Pins: Hooks 4f463f2, Multitool 743a022 in Package.resolved only (IntegrationTests/Package.resolved left as is; it was already stale at Hooks ff12698 / Multitool d3c70db).
    - Key: `AgentHome.projectKey(of:)` (now internal) = sha256 of `standardizedFileURL.resolvingSymlinksInPath().path`; it names the project state folder and is the hook key. `HookLineage(workingDirectory:origin:)` gives it.
    - session/new passes `HookLineage(workingDirectory:, origin: .new)`; model-switch passes `HookLineage(workingDirectory: entry.workingDirectory, origin: .replacement)`. `HookLineage.replacement(in:)` removed.
    - `AgentHooks` uses `SnapshotStore.shared(directory:)`; `SnapshotInventory` too (so a CLI remove of a key that an in-process agent has open throws sessionKeyOpen).
    - New `SnapshotSessionKeys` (AgentHooks.swift): process-wide ACP session id -> key map; the agent `snapshotsEndpoint` and each session's `SnapshotsCapability(store:sessionKey:)` use its resolver (one store = one change log that binds the first resolver). new records the cwd key, resume records the session id (see blocker), delete forgets.
    - session/delete: reads the recorded sessions of the candidate roots before the folder removal; removes the timeline only when no table entry and no recorded session (other than the deleted one) has the key, and when every root could be read; else one notice. sessionKeyOpen handling kept.
    - SnapshotInventory: entries get `sessionIds` (recorded sessions whose cwd key == key); `recorded` iff non-empty. v1 timelines already came out as `timelineUnreadable` warnings (the catch-all), now with a test.
    - Owner display: the Multitool graph (743a022) already exposes `owner` on Checkpoint/SnapshotChange; test reads it through the agent endpoint.
    Tests (RED seen first, then GREEN): AgentHomeTests symlink key; HookCompositionTests: new/replacement keys = cwd key, two sessions share one timeline (B lists A's checkpoint; A's rollback in B's timeline with owner A via the agent endpoint), two cwds + symlink keys, delete keeps until the last session of the cwd, AgentHooks shared store; SnapshotInventoryTests: recorded by cwd key with sessionIds, v1 timeline warning. ComposedAgentTests snapshot folder now the cwd key. Full suite: `swift test --skip-build -v` 1243 tests in 137 suites passed, 1 known issue (pre-existing), build has no warning besides the known mlx `missing creator` line.
    BLOCKER (resume): Router `restoreSession`/`restoreSessionTree` take no hook key (SessionTreeRestoration.rebuild calls makeSessionHooks with no requestedKey), so a resumed session still snapshots under its own id. Card item "Pass HookLineage(sessionKey: <cwd key>) on ... resume" cannot be done in this repo. Needs a Router change, e.g. `restoreSession(..., hookSessionKey: String?)` passed to the restored root's `makeSessionHooks(requestedKey:)`; then SessionResume passes `HookLineage(workingDirectory:, origin: .resumed)` and records the cwd key in SnapshotSessionKeys instead of the session id. Test aResumedSessionStartsWithTheOriginResumedAndTheACPSessionIdAsItsKey still asserts the session-id key and must flip then.
    Also noted: a model-switch replacement is a new Router session id; it is an owner in change.owners that the resolver does not know, so the change feed has no entry under the ACP id for its checkpoints after the replaced session is released (pre-existing shape).
  timestamp: 2026-10-23T09:11:47.872154+00:00
- actor: claude-code
  id: 01m5m0fv4n0gt8kwxr9yr0aqrw
  text: |-
    ### implement — stuck
    - evidence: 15 files — Sources/FoundationModelsACPAgent/{Agent/AgentHooks.swift, Agent/ConfigOptions.swift, Agent/SessionLifecycle.swift, Agent/SessionResume.swift, Agent/SessionSetup.swift, Agent/SnapshotInventory.swift, Configuration/AgentHome.swift, RoutedACPAgent.swift, Tools/ToolCatalog.swift}, Sources/acp-agent/SnapshotsCommand.swift, Tests/FoundationModelsACPAgentTests/{AgentHomeTests.swift, ComposedAgentTests.swift, HookCompositionTests.swift, SnapshotInventoryTests.swift, Support/GitVerbSupport.swift} (+ local Package.resolved pins). `swift test --skip-build -v`: 1243 tests / 137 suites passed, 1 known issue, 0 warnings (mlx missing-creator only).
    - gap: resume cannot pass the cwd key — Router restoreSession takes no hook session key.
    - next: Router card for `restoreSession(..., hookSessionKey:)`; then switch SessionResume to `HookLineage(workingDirectory:, origin: .resumed)` and flip the resume test. Everything else is ready for /review.
  timestamp: 2026-10-23T09:11:52.213925+00:00
- actor: claude-code
  id: 01m5m0k449s1yt5cgjnz1zq85r
  text: |-
    ### test — stuck
    - evidence: `swift test` — 1243 tests in 137 suites passed, 0 failed, 1 known issue (HarnessSmokeTests orderedSubsequenceAssertionChecksOrderWithGaps, a deliberate withKnownIssue proof of the harness assertion); one build-system warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" (SwiftPM, not source). `python3 -m unittest` in bench — 265 tests OK, skipped=1: test_swebench_harness.HarnessArgumentsTests.test_the_keys_agree_with_the_real_signature, skipped 'swebench is not installed'.
    - blocker: a skipped test is not acceptable. The fix is to install the `swebench` python package in this environment (no edit to bench/*.py allowed). Not done without approval, as it changes the machine's python environment.
    - next: approve `pip install swebench` (or say how to supply it), then rerun the bench unit tests once.
  timestamp: 2026-10-23T09:13:39.721106+00:00
- actor: claude-code
  id: 01m5m0m6vvv57h3p0axxq5yzgj
  text: |-
    ### test — green (supersedes the earlier "test — stuck" comment)
    - evidence: `swift test` — 1243 tests in 137 suites passed, 0 failed, 1 known issue (HarnessSmokeTests orderedSubsequenceAssertionChecksOrderWithGaps, deliberate harness proof); one SwiftPM build-system warning (missing creator for mutated node, mlx-swift_Cmlx.bundle), not from source. `cd bench && uv run --no-project --python 3.12 --with swebench==5.0.2 python -m unittest` — 265 tests OK, 0 skipped (the swebench skip is gone in the isolated env; nothing installed globally).
    - next: commit.
  timestamp: 2026-10-23T09:14:15.291281+00:00
- actor: claude-code
  id: 01m5m12pn3ve0gb76672rvcazb
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c301e3f) — 2 findings, 2 confirmed, 0 refuted — Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:215 (completeness/invariant-propagation), Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:215 (swift/initialization)
    - note: both findings are on the resume path, which the card description moves to ^fw9apv8 (resume needs a Router change). The findings are recorded as written; the implementer resolves them here or records a true conflict as a blocker.
    - next: implement the two open findings, then /review again
  timestamp: 2026-10-23T09:22:10.211928+00:00
- actor: claude-code
  id: 01m5m137n0209wzkkpwj90yyzn
  text: |-
    ### finish iteration 1 — findings
    - implement: stuck on resume only (Router restoreSession takes no hook key) — 15 files
    - test: green — swift test 1243 passed; bench 265 OK, 0 skipped (uv + swebench 5.0.2)
    - commit: c301e3f
    - review: findings — Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:215 (x2: resume records the session id, not the cwd key)
    - next: the fix needs Router ^yfc5bxw (`restoreSession(..., hookSessionKey:)`). When Router sends the sha, iteration 2 pins it, passes `HookLineage(workingDirectory:, origin: .resumed)` on resume, records the cwd key, flips the resume test. The resume half of ^fw9apv8 is then done here.
  timestamp: 2026-10-23T09:22:27.616504+00:00
- actor: claude-code
  id: 01m5m2gwsjnq61fe09r3py2jnm
  text: |-
    Iteration 2: resume now uses the cwd key (Router ^yfc5bxw landed).
    - Router pin: Package.resolved (gitignored) 4cb3879 -> 7c07fb2938fb198cc2c5f2e5398a85e7ebf3c525 (feature 768bcc62 + kanban 7c07fb29). Edited the revision, then ran `swift package resolve`. Nothing else in Package.resolved changed, and .build/checkouts/FoundationModelsRouter is at 7c07fb2. origin/main is now 3f5c66cd, which is one kanban-only commit later. I pinned 7c07fb29 as asked.
    - `restoreSessionWithHostChecks` (SessionSetup.swift) gets `hookSessionKey: String? = nil` and passes it to Router's `restoreSession(..., hookSessionKey:)`.
    - SessionResume.restoreSession builds `HookLineage(workingDirectory:, origin: .resumed)`, gives its key to the restore through `restoreRecordedSession(..., hookLineage:)`, and records `hookLineage.sessionKey` in SnapshotSessionKeys. I also removed the stale comment "Router's restore takes no hook session key". Nothing else in SessionResume.swift (or elsewhere in Sources/Tests) still assumes a resumed session's key is its session id.
    - TDD: renamed and flipped the test, now `aResumedSessionStartsWithTheOriginResumedAndTheKeyOfItsWorkingDirectory`. It asserts the SessionStart key == cwd key and the SnapshotSessionKeys entry == cwd key. RED: both expectations failed. GREEN after the fix. `aSessionWithAWorkingDirectoryMismatchEndsItsTurnWithNoSnapshots` resumes, so its key moved from the session id to the cwd key; it passes.
    - SessionLauncher check: NO. This repo never restores through `SessionLauncher.restoreSession(id:)`. Nothing in Sources, Tests or IntegrationTests conforms to `SessionLauncher` or calls `RouterSessionDirectory.use(launcher:)`, and the Multitool and Hooks checkouts don't either. Router's directory restore (RouterSessionDirectory.swift:870 -> :892 `launcher.restoreSession(id:)`) therefore throws `noLauncher` in this host. The agent uses RouterSessionDirectory only for `setAdditionalDirectories` (SessionSetup.swift:816), `recordedSessions(in:)` (SessionLifecycle.swift:394, TranscriptStore.swift:151) and the prompt directory (PromptExecution.swift:1052). Router needs no further change for this card.
  timestamp: 2026-10-23T09:47:23.826699+00:00
- actor: claude-code
  id: 01m5m2gz9k611zd0eytmje7hgf
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift, .kanban card (+ local Package.resolved Router pin 7c07fb29). `swift build --build-tests`: 0 errors, 0 warnings (only the SwiftPM mlx missing-creator line). `swift test --skip-build`: 1243 tests in 137 suites passed, 1 known issue (the deliberate HarnessSmokeTests one). Both findings and all 5 Do items are checked.
    - next: /review (not committed)
  timestamp: 2026-10-23T09:47:26.387513+00:00
- actor: claude-code
  id: 01m5m2k85gea8s4qnn4crdxbtq
  text: |-
    ### test — green
    - evidence: `swift test` — 1243 tests in 137 suites passed, 0 failed, 0 skipped, 1 known issue (deliberate withKnownIssue in HarnessSmokeTests); only warning is the known SwiftPM mlx "missing creator" line. `cd bench && uv run --no-project --python 3.12 --with swebench==5.0.2 python -m unittest` — Ran 265 tests, OK, 0 skipped.
    - next: review/commit (no code changed in this step)
  timestamp: 2026-10-23T09:48:41.008347+00:00
- actor: claude-code
  id: 01m5m2t7dm12115ycv0031qyj1
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (7bba627) — 0 findings, 0 confirmed, 1 refuted, 7 attempted; 3 files reviewed, 2 .kanban files ignored; both prior findings at SessionResume.swift:215 checked
    - next: moved to done
  timestamp: 2026-10-23T09:52:29.620186+00:00
- actor: claude-code
  id: 01m5m2tjewzwjvbtf5gedma0g7
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — SessionResume.swift, SessionSetup.swift, HookCompositionTests.swift; Router pin 7c07fb29
    - test: green — swift test 1243 passed; bench 265 OK, 0 skipped
    - commit: 7bba627
    - review: clean — 0 findings
  timestamp: 2026-10-23T09:52:40.924287+00:00
position_column: done
position_ordinal: ffff9080
title: Sessions in one cwd share one snapshot timeline (hook session key = hash of the resolved cwd)
---
User design 2026-10-23: sessions in one process with the same cwd share ONE snapshot timeline. A rollback restores the whole work tree anyway (SnapshotStore.swift:459-468), so one per-cwd timeline is the honest model; per-session timelines go stale when another session rolls back.

## Today
- One SnapshotStore per agent (Agent/AgentHooks.swift:38); timeline key = hook session key = ACP session id (Router default, SessionHooks.swift:72-98). session/new and resume pass nil lineage (SessionSetup.swift:1113,1147); replacement passes the session id (AgentHooks.swift:72, ConfigOptions.swift:259).
- SnapshotStore already allows many owners per key and closes it after the last owner leaves (:178, :203-214).

## Do
- [x] One cwd key function: sha256 of `standardizedFileURL.resolvingSymlinksInPath()`. Use it for `AgentHome.projectKey` too (AgentHome.swift:250 does not resolve symlinks today; Router's same-directory check does, SessionHooks.swift:132-133).
- [x] Pass `HookLineage(sessionKey: <cwd key>)` on new and model-switch replacement. (Resume, and the replacement's checkpoints reaching the ACP session's feed, moved to ^fw9apv8: resume needs a Router change.)
- [x] Session delete (SessionLifecycle.swift:90,354-357): remove the timeline only when no other session of that cwd is left (the store refuses with sessionKeyOpen while open — handle it).
- [x] Snapshots GraphQL endpoint (RoutedACPAgent.swift:419) and SnapshotInventory (SnapshotInventory.swift:22-23,220): stop assuming key == session id; map a key to the sessions of that cwd.
- [x] When Hooks gives the checkpoint owner (asked of the Hooks session), show it; until then do not block on it.

## Tests (first)
- Two sessions in one cwd: both snapshot into one timeline; B sees A's checkpoints; A's rollback appears in B's timeline.
- Two cwds: two timelines.
- A symlinked path to the same folder gives the same key.
- Deleting one of two sessions keeps the timeline; deleting the last removes it. #share-per-cwd

## Review Findings (2026-10-23 04:14)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:215` `completeness/invariant-propagation` — SessionSetup.createSession records the working directory's projectKey as the snapshot timeline key (SessionSetup line 651: `record(hookLineage.sessionKey, for: sessionId)`), enforcing the invariant that sessions in the same working directory share one timeline. SessionResume.restoreSession violates this invariant by recording the session ID itself as the key instead of the working directory's projectKey (line 215: `record(params.sessionId.rawValue, for: params.sessionId)`). This breaks timeline sharing—a resumed session ends up with its own isolated timeline instead of sharing with new sessions in the same working directory. Line 215 should create a HookLineage for the resumed session and record the working directory's projectKey, matching SessionSetup's pattern: replace with `let hookLineage = HookLineage(workingDirectory: workingDirectory, origin: .resumed)` (after the session restoration) and `SnapshotSessionKeys.shared.record(hookLineage.sessionKey, for: params.sessionId)`. The sessionId remains the same for the resumed session, so only the timeline key mapping needs to be corrected.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift:215` `swift/initialization` — The session key being recorded is the session ID's rawValue (a ULID string) instead of the working directory's project key. This breaks the snapshot timeline sharing mechanism—each session would receive a unique snapshot key instead of sharing with other sessions in the same working directory. Change to `SnapshotSessionKeys.shared.record(AgentHome.projectKey(of: workingDirectory), for: params.sessionId)` to match the SessionSetup pattern and ensure sessions in the same working directory share the same snapshot timeline.
