---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyfyg91ndtrqpeh7gp4hkry3
  text: |-
    Upstream asks filed on the **FoundationModelsShelltool** board 2026-07-26 (cross-repo, so not expressible as `depends_on`). Both are hard blockers for this task:

    - `q819s54` — **Expose raw output bytes.** `OutputBuffer` stores `[UInt8]` internally but coerces at every exit (`stdout: String` via `String(decoding:as:UTF8.self)`, `extractCompletedStdoutLines() -> [String]`). `terminal_output_chunk` is base64 of raw bytes, so byte fidelity is unreachable today. API-surface change, not a rewrite — the bytes are already preserved. `binaryDetected` / `storedByteCount` already exist and map onto the `TerminalOutput` snapshot case.
    - `416c6yq` — **Public incremental output chunk stream + session-safe command identity.** `ShellRunner` streams internally to a single consumer and nothing escapes, so output can only be observed after exit. Also carries the `commandID` problem: it is an `Int` scoped to one `ShellState`, while ACP's `TerminalId` must be unique across the whole session.

    The second also serves the *pre-terminal* path: incremental `tool_call_content_chunk` for ordinary shell tool calls, which ships before terminals do.
  timestamp: 2026-07-26T19:30:18.805512+00:00
- actor: claude-code
  id: 01kym9cxved9zwgq16xt9ccs1e
  text: |-
    **Upstream status check, 2026-07-28 — both Shelltool blockers are DONE and verified green** (`swift build` clean, 294 tests in 20 suites passing).

    Available now:

    - **`ShellOutputChunkStream`** (`AsyncSequence` of `ShellOutputEvent`) — public. `.output(stream:bytes:)` carries raw `[UInt8]`, so byte fidelity reaches the wire. Maps to `terminal_output_chunk` (base64 per chunk).
    - **`.gap(stream:droppedByteCount:)`** — backpressure drops are *reported*, not silent. Delivered in the position the hole occupies. There is no ACP equivalent, so decide how to render it — a visible "N bytes dropped" marker is the honest option.
    - **`.completed`** — exactly once per command, never dropped, and explicitly distinguishes "finished" from "gone quiet." This is the cue to emit `TerminalUpdate.exitStatus`.
    - **`ShellCommandID(sessionID:sequence:)`** — session-safe and `CustomStringConvertible` (`"sessionID:sequence"`), so it maps straight onto ACP's `TerminalId` string with no qualification needed. The `commandID` → `terminalId` mapping this task assumed now works.
    - `maxPendingBytes` (default 1 MiB) is the tunable behind `.gap`.

    **One gap found, filed upstream as `882ettr`: there is no public snapshot accessor**, so ACP's `TerminalOutput` ("an authoritative replacement snapshot") has no source. `OutputBuffer`, its `RawOutput`, `rawStdout`/`rawStderr`, and `CommandRecord` are all internal. This matters specifically because `.gap` can punch a hole in the stream and nothing lets a consumer resync — `.completed`'s own doc says to "read the record back," which a host cannot do.

    **Not blocking this task.** Ship chunk streaming first and render gaps honestly; add the snapshot when `882ettr` lands. Note also that `RawOutput` documents that after truncation the stored bytes are "not necessarily a prefix" and may be discontiguous — so even once exposed, the snapshot must be reported with its `truncated` / `binaryDetected` flags rather than as unconditionally authoritative.
  timestamp: 2026-07-28T11:57:41.102564+00:00
depends_on:
- 01KY7EEGS0JJ5G6720FGSEBT3M
position_column: todo
position_ordinal: 8c80
title: 'Shell → ACP display terminals: terminal_update + terminal_output_chunk'
---
## What

Plan §8.6, "Agent-owned display terminals". **Filed 2026-07-26 after verifying the vendored `acp-v2.json`** — an earlier revision of the plan recorded this stream as unverified and said "do not plan `ShellTool` → display-terminal plumbing yet… confirm against the vendored schema first." That confirmation is done and came back **positive**. The docs mislead because there is no v2 Terminals page and the Content page omits terminals; they are documented under Tool Calls.

Present in `acp-v2.json` (stable, not the unstable meta):

| Type | What it is |
|---|---|
| `TerminalId` | "Unique identifier for an agent-owned terminal within a session." |
| `Terminal` (a `ToolCallContent` variant) | "A display-only reference to an agent-owned terminal" — `{terminalId}` |
| `TerminalUpdate` (`session/update`) | Upsert of stored terminal state; only `terminalId` required, other fields patch (omitted = unchanged, `null` = cleared) |
| `TerminalOutputChunk` (`session/update`) | "A chunk of bytes appended to an agent-owned terminal's output" — independently base64-encoded |
| `TerminalOutput` | "An authoritative replacement snapshot of terminal output bytes" |
| `TerminalExitStatus` | `{exitCode?, signal?}`; "the presence of this object marks the terminal as exited, even when neither an exit code nor a signal is known" |

This is **display-only** and must not be confused with v2's *removed* `terminal/*` client-execution methods. We execute (Shelltool, in-process — one of the three built-in tools per §7.1); the client renders. It is the user-visible payoff of `shell` being a built-in.

## Work

- `commandID` (Shelltool) → `terminalId`. One identity again, alongside `toolCallId` / `OperationEvent.correlationID`.
- Incremental line streaming → `terminal_output_chunk`, base64 per chunk, so output is **byte-faithful**. Do not let the shell tool's output path coerce raw bytes to `String` before the wire — that is the one design constraint this task imposes on the `shell` built-in, and it is worth honoring even before this task ships.
- Shelltool's stored record → `TerminalOutput` (authoritative replacement snapshot) — what a reconnecting or truncation-recovering client needs.
- Command exit → `TerminalUpdate.exitStatus`. Note the "exited even when neither code nor signal is known" semantics fit a soft-deadline kill exactly.
- The tool call emits a `Terminal` content reference; the bytes ride the terminal stream, not the tool-call content.
- `CommandPermissionSubject` carries a `terminalId` — wire it so a permission prompt for a command can point at the terminal that will show it.

## Sequencing

Additive over ordinary tool-call content. `shell` ships text-in-`content` first (the conformance task) and gains the terminal stream here. Not day one.

## Acceptance Criteria

- [ ] A shell command produces a `Terminal` content reference on its tool call plus a `terminal_update`/`terminal_output_chunk` stream keyed by a stable `terminalId`.
- [ ] Output is byte-faithful end to end — arbitrary non-UTF-8 bytes survive the round trip.
- [ ] `exitStatus` is set on completion, including the unknown-code case for a killed command.
- [ ] A `TerminalOutput` snapshot replaces accumulated chunks correctly.
- [ ] No `terminal/*` client method is ever called (those are removed in v2).

## Tests

- [ ] A command emitting invalid UTF-8 (e.g. raw binary on stdout) round-trips unchanged through base64 chunks.
- [ ] Chunks arriving out of a single command are appended in order under one `terminalId`.
- [ ] A soft-deadline kill yields `exitStatus` present with no `exitCode`.
- [ ] A snapshot replaces, rather than appends to, previously streamed chunks.

## Workflow

- Use `/tdd`.