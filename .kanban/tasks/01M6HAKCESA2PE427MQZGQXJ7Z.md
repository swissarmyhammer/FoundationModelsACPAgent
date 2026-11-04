---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6hqdwdper2fk85nak8b27qn
  text: |-
    ### implement - stuck
    - blocker: Router gap. The Router builds the MountSite itself in RoutedModel.makeSessionToolWiring (Sources/FoundationModelsRouter/RoutedLLM.swift, internal, 3 MountSite(...) calls plus ToolOutputCapping). No call passes transcriptReader, and no public Router API lets the host give one. Router origin/main (bb52caa) has no mention of SessionTranscriptReader. Extras (d692c69) has the parameter on MountSite and ToolContext, but the ACP agent never makes a MountSite: it gives tools to the Router.
    - needed: a Router card. The Router must take an optional transcript reader (for example on the router or session configuration) and pass it to each MountSite it makes: the root site, the recordedSpawn site, and the restore path. A child site keeps the reader of its parent (Extras does this in childSite).
    - no code was written. Stopped as the task rule says: no change in Router or Extras.
    - design point for the reader, for when the Router is ready: find the project of an id from a session folder scan of the registered recording roots (RegisteredRecordingRoots, TranscriptStore.allProjects), cache id to recording root after the first hit, and read only that session folder, not the merged project. This needs a read of one folder in TranscriptEvent (merged(under:) takes a root of many folders). Decide this in the implement step.
  timestamp: 2026-11-03T22:10:43.766976+00:00
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