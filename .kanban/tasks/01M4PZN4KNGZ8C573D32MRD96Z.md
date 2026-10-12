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
position_column: doing
position_ordinal: '80'
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