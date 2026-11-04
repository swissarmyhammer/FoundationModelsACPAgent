---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hg08kekzdktm5cxs88cbpt
  text: 'Router pushed both partial kinds: `TranscriptEvent.Kind.toolCallStarted` and `TranscriptEvent.Kind.promptStarted`. The host reader must map them like any other kind, with no special case. An unknown kind must not break the reader. A `promptStarted` entry has the joined message text and one mailDelivered record per mail. Work in the worktree `wt-transcript` from `origin/main`, and tell the coordinator before any push to `origin/main`. The card is still blocked by Extras card 01M6HAD7WQ56PXQZ5F4KAE59SS.'
  timestamp: 2026-11-03T20:00:57.454998+00:00
- actor: claude-code
  id: 01m6jmpv4rzgzrj62cw880m45h
  text: |-
    ## Review Findings (2026-11-04 00:45)

    > Scope: `review sha 3a9e864~1..3a9e864`, local backend. The engine gave 0 findings, but it read no file: the main checkout is at 0e56c33, so the new files are not on disk and 20 rule items declined with "found no file". The findings below come from a read of the commit (git archive of 3a9e864) and of Router at HEAD. Ranked, most important first. Do not move the card from this comment.

    - [ ] `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift:438` `transcripts/roots` — The reader gets its roots from `RegisteredRecordingRoots.resolve` only. The agent already has `recordingRootsOfTheDirectory()` (`Agent/KnownRecordingRoots.swift`), which adds the root of each session that the agent composed (`SessionSetup.swift:1013`). Its doc says that the project store can lack the folder of a live session. With the reader as written, a tool in a session of an unregistered folder gets `notFound` for its own session and for its children. Give the reader the roots of `recordingRootsOfTheDirectory()`, and add a test for a session in a folder that the project store does not hold.
    - [ ] `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift:438` `transcripts/failures` — The closure keeps `.roots` and drops `.failures`. The doc of `RegisteredRecordingRoots` says that each caller reports the failures. When the project store or the settings of one project cannot be read, the tool gets `notFound` with no log record and no reason. Log each failure, as the other callers do.
    - [ ] `Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift:261`, `Agent/SessionResume.swift:435`, `Agent/SessionSetup.swift:699` `tests/wiring` — No test goes through `RoutedACPAgent` to prove that session/new, cold-start resume and the model-slot switch give the reader. `SessionTranscriptToolTests.swift` calls `RoutedLLM.makeSession` and `restoreSession` directly. A call site that passes `nil` still compiles and no test fails. Add a test for each of the three paths (a tool in the session reads another session), and for the restore of a child session.
    - [ ] `Sources/FoundationModelsACPAgent/Transcripts/TranscriptEntryMapping.swift:109` `transcripts/lossy-payload` — The number mapping loses more than the doc says. (a) A fraction becomes `NSNumber.stringValue`, which keeps 16 digits: `0.30000000000000004` becomes `"0.3"`. (b) The type of a Double field depends on its value: `temperature` 0.7 becomes `.string("0.7")`, and 1.0 becomes `.int(1)`. A tool cannot read one type. (c) A whole number above `Int.max` wraps: `18446744073709551615` becomes `.int(-1)`. (d) A null in an array leaves a gap in the keys (`["a",null,"b"]` gives keys "0" and "2"). (e) An empty array and an empty object give the same value. (f) The keys "10" and "2" sort in text order. Document each change in the type doc (line 11 to line 26), and make (b) and (c) safe: for example, always a string for a Double field, and a string for a number that `Int` cannot hold. The doc at line 73 says "loses no digit" for the instant only; keep it that way.
    - [ ] `Sources/FoundationModelsACPAgent/Transcripts/TranscriptEntryMapping.swift:63` `tests/test-only-api` — `operationValue(fromJSON:)` has no caller in `Sources`. Only `RecordedSessionTranscriptReaderTests.swift:189` calls it, so that test checks code that production does not run. `entry(from:)` uses the private `operationValue(from:)`. Test the lossy shapes through `entry(from:)` with a real event (an array of tool calls, a temperature, a null), and remove the test-only function or make it private. Add tests for the cases in the finding above (array with null, empty array, large number).
    - [ ] `Sources/FoundationModelsACPAgent/Transcripts/RecordedSessionTranscriptReader.swift:92` `transcripts/cache` — The `isDirectory` check and the read are two steps. When the folder is deleted between them, `TranscriptEvent.read` gives no events for a missing file, so the tool gets an empty transcript and not `notFound`. A folder that holds no `transcript.jsonl` gives an empty transcript the same way. Check that the transcript file exists, or throw `notFound` when the folder is gone after the read. The actor makes the cache itself safe; two reads of an unknown id at the same time both resolve the roots (project store and settings of each project), and a loop of unknown ids pays that cost for each read. Consider one shared lookup for an id that is in flight.
    - [ ] `Sources/FoundationModelsACPAgent/Transcripts/RecordedSessionTranscriptReader.swift:10` `transcripts/risk-doc` — The risk text is true (no tree rule, no owner check, MCP tools included), but it is not complete and not actionable. (a) "Give a tool to a session only when you trust it" gives the reader no switch: the agent gives the reader to every session (`RoutedACPAgent.swift:152`), so the user cannot follow the advice. State this, or add a setting to turn the reader off. (b) The text does not say that the agent redacts nothing: Router has a redact hook (`GatingRecorder`), and no code of the agent sets it. State it. (c) The text is on an internal type only. The property `RoutedACPAgent.transcriptReader` (line 148) and the user docs do not say that every tool can read every transcript of the registered projects. Add the risk there.
    - [ ] `Sources/FoundationModelsACPAgent/Transcripts/TranscriptEntryMapping.swift:44` `tests/new-kind` — The mapping is generic and passes the check for `TranscriptEvent.Kind.modelChanged`: the code never switches on the kind (`kind.rawValue` and `kind` key removal only), and no exhaustive switch over `TranscriptEvent.Kind` exists in `Sources`. But no test proves the claim "a new kind needs no change here". Add a test that maps one event of every kind (a `modelChanged` event included, which needs the Router that has 30014aa6 and 6331c9c3) and checks the kind name and the payload.

    Checked, no finding: the `kind` and `ts` keys are removed from the payload; the `ts` instant keeps the millisecond; the cache is an actor and is safe for the threads; a deleted folder that is checked before the read gives `notFound`; an id that no root holds is not cached, so a new project is found at the next read; the session directory of Router is flat, so a child session folder is under the same root; the three call sites (`SessionSetup.swift:699`, `SessionResume.swift:435`, `ConfigOptions.swift:261`) pass the reader, and the parameter has no default, so a missing call site fails to compile.
  timestamp: 2026-11-04T06:42:26.072080+00:00
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