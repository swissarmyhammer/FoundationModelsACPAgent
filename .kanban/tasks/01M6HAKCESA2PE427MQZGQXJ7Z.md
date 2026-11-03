---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hg08kekzdktm5cxs88cbpt
  text: 'Router pushed both partial kinds: `TranscriptEvent.Kind.toolCallStarted` and `TranscriptEvent.Kind.promptStarted`. The host reader must map them like any other kind, with no special case. An unknown kind must not break the reader. A `promptStarted` entry has the joined message text and one mailDelivered record per mail. Work in the worktree `wt-transcript` from `origin/main`, and tell the coordinator before any push to `origin/main`. The card is still blocked by Extras card 01M6HAD7WQ56PXQZ5F4KAE59SS.'
  timestamp: 2026-11-03T20:00:57.454998+00:00
position_column: doing
position_ordinal: '8180'
title: Give ToolContext a session transcript reader from TranscriptStore
---
## What
A tool must read the transcript of a session through `ToolContext.transcript(of:)`. Extras defines the protocol and the type. This task is the host side: the ACP agent gives the reader.

Blocked by Extras card 01M6HAD7WQ56PXQZ5F4KAE59SS (`SessionTranscriptReader`, `SessionTranscript`, `SessionTranscriptError`). Do not start before Extras publishes them. Do not make a local copy of those types.

## Decisions from the user
- A tool can read any session that the hosting Router can reach. The ACP agent adds no tree rule.
- The reader gives only what is on disk. It does not flush. A running session can lack its latest events.
- An id that the agent does not know throws `SessionTranscriptError.notFound`.

## Plan
- New type in `Sources/FoundationModelsACPAgent/Transcripts/`, a `SessionTranscriptReader` conformer built on `TranscriptStore`.
- Map each `TranscriptEvent` to one `SessionTranscript` entry: kind string, timestamp, JSON payload. Keep the order of `(ts, seq)`.
- `TranscriptStore.transcript(for:inProject:)` needs a project. It merges all events of the project on each call. Decide how to find the project of an id from another project, and how to avoid the full merge on each call.
- Give the reader when the agent makes the run plane (see `SessionBuild.swift`).

## Risk
Any tool, MCP tools included, can then read every reachable session. A transcript can hold a secret. Say this in the doc comment of the reader.

## Acceptance Criteria
- [ ] A tool in a session calls `ToolContext.current?.transcript(of:)` with the id of another session and gets its entries in order.
- [ ] An unknown id throws `notFound`.
- [ ] A run plane with no reader throws `noSource`.
- [ ] A running session gives the events on disk, with no error.

## Tests
- [ ] Unit test of the event mapping: kinds, timestamps, order, payload round trip.
- [ ] Test with two recorded sessions: read the other session from a tool.
- [ ] Test of the unknown id.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd`: write the failing tests first. #transcripts