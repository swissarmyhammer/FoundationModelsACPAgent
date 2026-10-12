---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4qx11q5jyhaqjsfv3cy524h
  text: |-
    Research done. Findings:
    - `session/new` (`createSession` in `SessionSetup.swift`) and `session/resume` (`restoreSession` in `SessionResume.swift`) both use `validatedWorkingDirectory`, which checks only the absolute rule.
    - Places that write to disk for a session: `ProjectRegistry.recordSessionStart` (user layer, in `activateSession`), `recordResumedRootSet` (`sessions.jsonl` append, `SessionIndex.materializeRoot` creates the root), `writeHistory` at teardown (`SessionHistoryFile.write` creates the transcript dir), and the tool surface (code context creates `<cwd>/.code-context`).
    - With the default `transcripts.location: project`, the transcripts are under `<cwd>/.<name>/transcripts/`. When the cwd is deleted, the resume finds no session and gives `unknownSession`. A replay-only resume is possible only with a `home` or an absolute location (from the user layer, because the project layer is deleted with the cwd).
    - Router `restoreSession(instructions: nil, tools: [])` keeps the recorded instructions and writes no divergence event. Plan: a replay-only resume restores the Router session with no tools and no instructions override, mounts an empty `SessionSurface`, announces no commands, skips the project registry, the `sessions.jsonl` append and the history-file write, and `session/prompt` refuses with `-32602`.
    - Test plan: the agent-level test writes the transcripts location in the project layer for `session/new`, then after the close writes the same location plus an enabled `codeContext` (no auto install, no semantic search) in the user layer, deletes the cwd and resumes. The old code then composes the code context, which creates the cwd again (RED).
  timestamp: 2026-10-12T11:12:37.605769+00:00
- actor: claude-code
  id: 01m4qxeyxh0rtw3g9vwwh4nt72
  text: |-
    Implementation landed (not committed).
    - `SessionSetup.DirectoryDefect`, `defect(of:)`, `requireExistingDirectory(_:field:)`, `requireExistingDirectories(workingDirectory:additionalRoots:)` and `allDirectoriesExist(workingDirectory:additionalRoots:)` are next to `validatedWorkingDirectory`. The refusal is `RequestError.missingDirectory(_:field:defect:)`: `-32602`, data `{field, path, reason}`, reason `does not exist` or `is not a directory`.
    - `session/new` runs the check after the absolute check and before the composition.
    - `session/resume`: `composeResumedSession` gives `SessionComposition.replayOnly(from:)` (empty `SessionSurface.makeEmpty()`, no instructions, no command source) when the cwd or an additional root is missing. The Router restore then keeps the recorded instructions (`instructions: nil`, so no divergence event) and gets no tools. The `sessions.jsonl` append is skipped.
    - `activateSession` skips the project registry and the builtin commands for a replay-only composition. `ActiveSession.isReplayOnly` is new.
    - `session/prompt` refuses a replay-only session with `RequestError.missingSessionWorkingDirectory(id:)`: `-32602`, data `{sessionId, reason: "the working directory of this session does not exist"}`.
    - `writeHistory` writes nothing for a replay-only session.
    - RED was seen first: `session/new` made the missing cwd, and the old resume made the deleted cwd again through the code-context index (`<cwd>/.code-context`). The replay itself already worked.
    - Known behavior: the resume response of a replay-only session still carries the `_meta.missingTools` report, with each recorded tool name, because the restore gets no tools. `session/set_config_option` on a replay-only session is not changed; Router makes no working directory, so it makes no directory.
  timestamp: 2026-10-12T11:20:13.489964+00:00
- actor: claude-code
  id: 01m4qxf26yr8209pth5wk3xyv2
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift, Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift (5 new tests), Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift (3 new tests). `swift test --filter 'SessionSetupTests|SessionResumeTests'`: 37 tests passed (RED before: 12 issues). Full `swift test`: 911 tests in 98 suites passed, 1 known issue that was there before. `swift build`: no warning but the accepted mlx "missing creator" warning.
    - next: review
  timestamp: 2026-10-12T11:20:16.862717+00:00
- actor: claude-code
  id: 01m4qxxwp52a105ph1watn4srf
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 613b69d): 4 findings (4 confirmed, 1 refuted). Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:228, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:282, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:265, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:283. All are `reuse/reuse`.
    - next: implement — do the 4 items in "## Review Findings (2026-10-12 06:23)". The task stays in review.
  timestamp: 2026-10-12T11:28:22.725155+00:00
- actor: claude-code
  id: 01m4qxydr6np2gwq4fevx01zze
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files (SessionSetup, SessionResume, PromptExecution, SessionHistory, ToolCatalog, SessionSetupTests +5, SessionResumeTests +3)
    - test: green — swift test 911 tests / 98 suites passed; IntegrationTests build complete
    - commit: 613b69d
    - review: findings — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:228, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:282, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:265, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:283
  timestamp: 2026-10-12T11:28:40.198586+00:00
- actor: claude-code
  id: 01m4qya6chyzsy3t7cmevtdh6w
  text: |-
    Review findings of 2026-10-12 06:23 are done (not committed).
    - Finding 1: `ReadableDirectoryState.of` answers a different question (readability, and no is-directory test). So the new `PathKind` (`Sources/FoundationModelsACPAgent/Doctor/PathKind.swift`: `missing`, `directory`, `notADirectory`) is the one existence and is-directory probe. `SessionSetup.defect(of:)`, `ReadableDirectoryState.of`, `WritableDirectoryCheck.check` (it had a private `isFile` copy, now deleted) and `WritableDirectoryCheck.nearestExistingDirectory` all call it. `PathKindTests` is new (missing path, directory, plain file, symbolic link to a directory). RED was seen first: "cannot find 'PathKind' in scope".
    - Finding 2: `SessionSetup.firstDirectoryFailure(workingDirectory:additionalRoots:)` is the one ordered walk (cwd first, then each root in wire order). It returns a `DirectoryFailure` (directory, field, defect). `requireExistingDirectories` throws on it, and `allDirectoriesExist` tests it for nil. `requireExistingDirectory(_:field:)` had no production caller after this, so it is deleted; the unit tests now call `requireExistingDirectories`.
    - Same cause in the file: `RequestError.relativePath` and `RequestError.missingDirectory` built the same `data` object two times. The private `RequestError.pathRefusal(field:reason:path:)` is now the one builder.
    - Finding 3: `expectedRefusalData(naming:reason:path:)` takes the reason (default: the relative-path reason) and an optional path. `expectedMissingDirectoryData` is deleted.
    - Finding 4: `expectRefusal(carrying:naming:from:)` is the one refusal assertion. It takes the expected `data` and a failure label. `expectRelativePathRefusal` and `expectMissingDirectoryRefusal` are deleted. The callers in SessionSetupTests, SessionResumeTests, SessionListTests and MultiRootConfinementTests use it, with the per-case data at the call site.
  timestamp: 2026-10-12T11:35:05.873859+00:00
- actor: claude-code
  id: 01m4qyaasb4dwsvd69a9x9de7p
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACPAgent/Doctor/PathKind.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Doctor/ReadableDirectoryState.swift, Sources/FoundationModelsACPAgent/Doctor/WritableDirectoryCheck.swift, Tests/FoundationModelsACPAgentTests/PathKindTests.swift (new), Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift, SessionResumeTests.swift, SessionListTests.swift, MultiRootConfinementTests.swift. 4 of 4 findings checked. `swift build`: no warning but the accepted mlx "missing creator" warning. `swift test --filter 'SessionSetupTests|SessionResumeTests|Doctor|PathKindTests|SessionListTests|MultiRootConfinementTests'`: 117 tests in 13 suites passed.
    - next: review
  timestamp: 2026-10-12T11:35:10.379175+00:00
- actor: claude-code
  id: 01m4qymbvm8a20vyc3daevtgs7
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 36eb18c). Counts: 1 finding, 1 confirmed, 0 refuted. Finding: Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:161 (`reuse/reuse`). The engine gives no finding on the 4 items of "Review Findings (2026-10-12 06:23)". All 4 items are checked.
    - next: Implement the item in "Review Findings (2026-10-12 06:37)". Extend `InitializationTests.expectRequestError` with an optional `data` parameter, and make one helper own the `RequestError` assertion. Then review again.
  timestamp: 2026-10-12T11:40:39.156645+00:00
- actor: claude-code
  id: 01m4qymra7rfev8bsfewbcaf2x
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 9 files (PathKind.swift new, SessionSetup, ReadableDirectoryState, WritableDirectoryCheck, PathKindTests new, SessionSetupTests, SessionResumeTests, SessionListTests, MultiRootConfinementTests); 4/4 prior findings checked
    - test: green — swift test 915 tests / 99 suites passed; IntegrationTests build complete
    - commit: 36eb18c
    - review: findings — Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:161
  timestamp: 2026-10-12T11:40:51.911428+00:00
- actor: claude-code
  id: 01m4qyw0by3ymaehzpd0sraz9r
  text: |-
    Review finding of 2026-10-12 06:37 is done (not committed).
    - `InitializationTests.expectRequestError` has a new optional `data: FoundationModelsACP.JSONValue? = nil` parameter. When the caller gives `data`, the helper also does `#expect(error.data == data)`. Now this helper is the only one that owns the `RequestError` assertion.
    - `InitializationTests.invalidParamsWireValue` (-32602) is new, next to `methodNotFoundWireValue` and `invalidRequestWireValue`. The private copies in SessionSetupTests and SessionListTests are deleted.
    - `SessionSetupTests.expectRefusal` is deleted. Each caller in SessionSetupTests, SessionResumeTests, SessionListTests and MultiRootConfinementTests now calls `InitializationTests.expectRequestError(.invalidParams, wireValue:data:)` directly. The why text of the old helper (the ACP schema names no path validator) is now in the doc comment of `expectedRefusalData`.
    - Same cause in SessionResumeTests: `expectMissingWorkingDirectoryRefusal` had its own do/catch on `RequestError`. Now it only sends the prompt and gives the exact data `{sessionId, reason}` to the shared helper. (`RequestError.missingSessionWorkingDirectory` puts exactly these two members in `data`.)
    - Not changed: the do/catch blocks in SessionResumeTests for the unknown id, the malformed id, the deleted session dir, the cwd mismatch and the unknown cursor. They were there before this task, and they check only some `data` members with `errorDataField`, not the full `data`.
    - The rules file from `dump validators` is approx. 750 KB, so it was not possible to read it in full. The edit follows the reuse, duplication, code-hygiene and swift validators by name.
  timestamp: 2026-10-12T11:44:49.534538+00:00
- actor: claude-code
  id: 01m4qyw2xdnw6a2emkw6a0kjh8
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsACPAgentTests/InitializationTests.swift, SessionSetupTests.swift, SessionResumeTests.swift, SessionListTests.swift, MultiRootConfinementTests.swift. Finding Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:161 checked (1 of 1). `swift test --filter 'SessionSetupTests|SessionResumeTests|SessionListTests|MultiRootConfinementTests|InitializationTests|PathKindTests'`: 67 tests in 6 suites passed. No warning but the accepted mlx "missing creator" warning.
    - next: review
  timestamp: 2026-10-12T11:44:52.141655+00:00
- actor: claude-code
  id: 01m4r15ky6ynv1wyehrx15srsd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (335a8b2); counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0; 5 files reviewed, 2 .kanban files ignored. All 5 prior findings (2026-10-12 06:23 and 06:37) are checked.
    - next: none. The task is in done.
  timestamp: 2026-10-12T12:25:01.638494+00:00
- actor: claude-code
  id: 01m4r164w25cbeqkt7cwh4cwmq
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 5 test files (InitializationTests, SessionSetupTests, SessionResumeTests, SessionListTests, MultiRootConfinementTests); 1/1 prior finding checked
    - test: green — swift test 915 tests / 99 suites passed; IntegrationTests build complete
    - commit: 335a8b2 (the first try was stuck: the sah MCP server was disconnected; the retry after the reconnect made the commit)
    - review: clean — 0 findings; all 5 prior findings checked; the task is in done
  timestamp: 2026-10-12T12:25:18.978738+00:00
position_column: done
position_ordinal: ffc780
title: 'Never create a missing session cwd: refuse session/new, replay-only session/resume'
---
## Why

Report from the AgentViewKit session (2026-10-11): the AgentViewKit Gallery restores recorded SWE-bench sessions with `acp-agent acp`, `session/list` and `session/resume` (`replayFrom: start`). The recorded cwd is a deleted temporary dir of the bench run (for example `/private/var/folders/l7/.../T/tmp20i_gz66/repo`). On resume the agent creates that dir again and writes `.code-context/kit.db` into it. Each view of a recorded session leaves a new dir and an index in the system temp folder.

Cause: `SessionSetup.validatedWorkingDirectory(path:field:)` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:198`) checks only that the path is absolute. It does not check that the dir exists. Then the code-context index store calls `FileManager.createDirectory(at: <cwd>/.code-context, withIntermediateDirectories: true)` (FoundationModelsCodeContext `Index/Store.swift:143`), which creates the missing cwd too.

## Decision

- The agent never creates a session cwd.
- `session/new` with a cwd that does not exist (or is not a dir): refuse with `-32602`, with data that names the cwd and the reason.
- `session/resume` of a session whose cwd does not exist: replay the history as now (the history is in the transcripts folder, not in the cwd). Mount no tool surface: no code-context index, no files, no shell, no MCP. A later `session/prompt` on that session gives `-32602` with "the working directory of this session does not exist". `session/close` and `session/delete` work as now.
- The same rule for each `additionalDirectories` entry: a missing entry refuses `session/new`; on resume, a missing entry makes the session replay-only.

## Work

1. Add an existence check (a dir, not a file) next to `validatedWorkingDirectory`.
2. Use it in `session/new`, and in `session/resume` before the composition of the tool surface (`SessionResume.swift`).
3. Make a replay-only resumed session: history replay, no tool surface, prompt refusal.
4. Check each other place that can create a dir under the cwd (for example `SessionHistory`, `ProjectRegistry`, the transcripts under `<cwd>/.<name>/`) and make sure that none of them runs for a replay-only session.

## Acceptance criteria

- `session/new` with a missing cwd gives `-32602`, and the dir does not exist after the call.
- `session/resume` of a recorded session whose cwd was deleted replays all entries, and after the resume the cwd still does not exist (no `.code-context`, no `.acp-agent`).
- `session/prompt` on that session gives `-32602` with the reason.
- A resume with an existing cwd works as now.

## Tests

- Unit: the existence check (missing path, a file in place of a dir, an existing dir).
- Agent-level test with the harness: create a session in a temp dir, close it, delete the dir, resume it; check the replay, the absent dir, and the prompt refusal.
- `session/new` with a missing cwd: the error and the absent dir.

Reported by: agentviewkit-d0.

## Review Findings (2026-10-12 06:23)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:228` `reuse/reuse` — `defect(of:)` reimplements a directory existence and is-directory check that already exists in the Doctor code. Two copies of the same file-system probe can drift apart, for example on how a symbolic link or a file-in-place-of-directory is treated. Check whether `ReadableDirectoryState.of` or a shared helper can return the existence and is-directory answer. If one can, call it from `defect(of:)`. If the Doctor checks answer a different question (readability or writability), extract the shared existence and is-directory probe into one helper that both call.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:282` `reuse/reuse` — `allDirectoriesExist` repeats the same ordered walk over the working directory and the additional roots that `requireExistingDirectories` already performs. It is a second, parallel copy of one rule: which directories a session needs. Define one walk that returns the first defect with its field, then have `requireExistingDirectories` throw on it and `allDirectoriesExist` test it for nil. This keeps the cwd-first, wire-order rule in one place.
- [x] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:265` `reuse/reuse` — `expectedMissingDirectoryData` is a near-match of the existing `expectedRefusalData(naming:)` (line 131). Both build the same refusal `data` object from a `field` and a `reason`. The new helper only adds a `path` member. The right move was to extend `expectedRefusalData` with optional `path` and `reason` parameters, so the refusal shape has one canonical builder. Instead, the file now has two builders that must stay in step with the wire shape. Generalize `expectedRefusalData` to take the reason and an optional path, for example `expectedRefusalData(naming: field, reason: String = Self.mustBeAbsoluteReason, path: URL? = nil)`, and delete `expectedMissingDirectoryData`. Call sites at lines 308, 322, 346, and 367 then pass the reason and path.
- [x] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:283` `reuse/reuse` — `expectMissingDirectoryRefusal` is a near-copy of the existing `expectRelativePathRefusal` (line 148). Both run the same do/catch around a `body`, assert `.invalidParams`, and compare `error.data` to an expected object. The new helper differs only in the expected data and the failure text. Writing a parallel helper means two refusal assertions that can drift apart. Generalize `expectRelativePathRefusal` into one helper that takes the expected `data` value and a failure label, then have both the relative-path and missing-directory tests call it. Keep the per-case data at the call sites.

## Review Findings (2026-10-12 06:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift:161` `reuse/reuse` — The new `expectRefusal` helper has the same shape as the existing `InitializationTests.expectRequestError`. Both helpers run a body, expect a `RequestError` with a given code, and record an issue for each other error. The new helper only adds a `data` check. Thus there are now two almost identical test helpers. A correction to one helper does not go into the other helper. Extend the existing helper with an optional `data` parameter. Do not copy it. Add an optional `data: FoundationModelsACP.JSONValue? = nil` parameter to `InitializationTests.expectRequestError`. When the caller gives `data`, the helper adds `#expect(error.data == data)`. Then make `SessionSetupTests.expectRefusal` call it, or make the callers use it directly, so that one helper owns the `RequestError` assertion.
