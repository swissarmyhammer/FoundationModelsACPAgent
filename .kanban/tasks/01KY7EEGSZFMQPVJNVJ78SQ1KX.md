---
comments:
- actor: claude-code
  id: 01kyjcvksr750gy33pb2gttcxg
  text: |-
    **Added 2026-07-26 — `additionalDirectories` is now supported**, so the golden transcripts need to cover it:

    - `initialize` advertises `capabilities.session.additionalDirectories: {}` (an object marker, not `true`).
    - `session/new` with additional roots: a `files` call inside a secondary root succeeds; one outside every root is rejected.
    - **Relative paths still resolve against `cwd` only**, even when a secondary root would also match — the spec keeps `cwd` as the relative-path base.
    - **`cwd` stays singular:** assert the config layer, the AGENTS.md walk, and the transcript slug are keyed off `cwd` alone and do not fan out across additional roots.
    - **Resume replaces rather than inherits.** Three cases, and the last is the one most likely to be implemented wrong:
      - resume with a *different* non-empty list → confinement is exactly the new list;
      - resume with the *same* list → unchanged;
      - resume with the field **omitted or empty** → **no additional roots**, i.e. confinement narrows back to `cwd`. A lenient implementation that keeps yesterday's roots silently re-widens a boundary the client just closed — assert against that explicitly.
    - `session/list` returns `SessionInfo.additionalDirectories` as the **complete ordered** list; assert order is preserved through a persist/reload round-trip (a `Set` round-trip would pass a membership check and fail this one).
    - A malformed/relative entry in the array is **skipped and logged**, not a session failure (`x-deserialize-skip-invalid-items`).
  timestamp: 2026-07-27T18:19:39.192394+00:00
depends_on:
- 01KY7EEGS0JJ5G6720FGSEBT3M
position_column: todo
position_ordinal: '8980'
title: 'Golden conformance tests: ReplayTransport + resume semantics'
---
Plan §9.1/§10-carryover. Drive the conformance over the wire package's `ReplayTransport`/`InMemoryTransport` with a scripted fake session backend. Deterministic, no model. DEPENDS on the conformance task.

**Revised 2026-07-26 to the ACP v2 semantics** — the golden transcripts must assert the v2 turn model, not v1's.

- Golden request/response transcripts for `initialize` / `session/new` / `session/prompt` / `session/cancel` / `session/resume` / `session/list` / `session/close`.
- **`session/prompt` returns `{}` immediately** — assert the response does NOT carry a `stopReason`, and that the turn's outcome arrives as a separate `state_update` `idle` notification.
- **`state_update` ordering**: `running` → … → `idle(stopReason)`, and a `requires_action` around a scripted permission round-trip with a return to `running` on the answer.
- **`session/cancel` confirmation**: pending permission requests get the cancelled outcome, then `idle` with `stopReason: "cancelled"`.
- **`tool_call_update` upsert semantics**: a first update with an unseen `toolCallId` creates; a later partial update patches only named fields; `null` clears; an array field replaces wholesale. Stable `toolCallId`s across two concurrent same-name tool calls.
- **`replayFrom: {"type":"start"}`** replays full recorded history as ordinary `session/update`s *before* the `session/resume` response returns; omitted/`null` skips replay. Assert replay-from-full-history vs construct-from-checkpoint (the two-transcripts rule).
- **`session/resume` cwd mismatch** is an error, not a silent re-rooting.
- **`session/list` pagination**: a `nextCursor` walk covers every session exactly once; a garbage cursor errors.
- **Compaction emits message upserts**: `agent_message`/`user_message` with `content: null` for folded messages plus the summary message — assert the client's accumulated view matches the record after the fold (this is the §9.2 decision that replaced the old `_meta` + `session/load` scheme).
- **`usage_update`** is emitted with `{used, size}` at turn end.
- `available_commands_update` fires on registry change (streaming provider tick), and `AvailableCommandInput` carries its `type` discriminator.
- **Snake_case discriminators** on the wire: `agent_message_chunk`, `tool_call_update`, `in_progress`. A golden byte-comparison catches camelCase slips.
- **Negative assertions**: no `tool_call` create variant is ever emitted; no `plan_update`; no `fs/*` or `terminal/*` request is ever issued.