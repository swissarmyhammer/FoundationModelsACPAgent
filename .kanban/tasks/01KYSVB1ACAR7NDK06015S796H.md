---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSV7GHQ7049N8DW5NH9MYWS
- 01KYSVA1A4HXA6RYSJBE2XERFM
position_column: todo
position_ordinal: 8f80
title: 'session/resume: cwd equality, restore, replay as whole-message upserts'
---
## What
Plan.md §7.4 (+§8.3). In `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`:

- `session/resume(sessionId, cwd, mcpServers, additionalDirectories, replayFrom)`:
  - `cwd` MUST equal the recorded original — compare against Router's recorded creation cwd; mismatch → error, never silent re-rooting.
  - Reassemble this package's side from the recorded cwd: config layer, instructions, tools/confinement; reconnect config + client MCP servers (client list is authoritative per reconnect, never persisted).
  - `additionalDirectories` is authoritative and replaceable: non-empty = the complete new root set; omitted/empty = **no** additional roots — never inherit former roots (§7.2). Persist the new ordered list to the index.
  - Router restores the live session from the newest compaction checkpoint (Router board `6j4bven` — if the restore API is not yet landed when this task starts, mark the task blocked and coordinate upstream rather than reimplementing restore here).
- Replay: `replayFrom: {"type": "start"}` replays before the response returns; omitted/null → no replay. Replay sends **whole-message upserts** (`user_message`/`agent_message`/`agent_thought`) with the original `messageId`s — never `*_chunk` — so a client that saw chunks converges via §8.3's replace row. Replay reads Router's **full recorded history** (fold checkpoints are not messages and are not emitted). Write the replay path with `ReplayFrom` as an inclusive cursor parameter — do not hardcode replay-everything.
- Resume of a deleted session fails naturally (transcript gone).
- `ResumeSessionResponse` carries `configOptions` (same source as session/new).

- [ ] cwd equality check
- [ ] Composition reassembly + root-set replacement
- [ ] Cursor-shaped replay emitting whole-message upserts
- [ ] Deleted-session failure path

## Acceptance Criteria
- [ ] Record a scripted two-turn session, resume with `replayFrom: start`: collector receives whole-message upserts with the original messageIds, no chunks, before the resume response completes
- [ ] Resume with a different cwd → error
- [ ] Resume omitting `additionalDirectories` on a session that had extra roots → confinement rebuilt with cwd only (assert a file outside cwd now refused)
- [ ] Resume after delete → error

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift` — harness; record-then-resume round trips in temp repos
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.