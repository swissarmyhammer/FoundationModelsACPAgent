---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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