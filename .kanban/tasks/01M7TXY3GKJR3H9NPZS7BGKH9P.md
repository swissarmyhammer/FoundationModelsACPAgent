---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ty6cs3gfk4d1y62bwap7dc
  text: |-
    Dependency available (2026-11-19): FoundationModelsACP `SessionSnapshot` (D208) is in ACPMarkdown on main at fb08304.
    - From the retained history: `SessionSnapshot.build(updates: history.transcriptUpdates (or the recorded updates), options: .init(includeThoughts:, includeToolOutput:, title:, agentName:))`. Both switches default to true. The same updates and options always give the same snapshot, the same as the UI path. Use the same updates as the exporter (`replayedTranscriptUpdates`, without the mail-delivery pause), so the server snapshot equals the UI snapshot.
    - `.markdown`, `.turnCount`, `.updates`; `try snapshot.encoded()` gives `updates.json` (formatVersion 1).
    Still waiting for the Multitool `SessionSharer` sha.
  timestamp: 2026-11-19T22:17:50.115720+00:00
- actor: claude-code
  id: 01m7tzjghphddt8k9z2fre36hj
  text: |-
    Dependency available (2026-11-19): the Multitool `SessionSharer` protocol is on origin/main, commit 7c2f6355 (head 87ed8df6; tested against Extras 4f3afb5). All deps are now on main; this task can start.
    API (Sendable, Equatable, Codable, public memberwise inits):
    - `protocol SessionSharer: Sendable`: `share(_ session: ULID, options: SessionShareOptions) async throws -> SessionShare`; `update(_ session: ULID, options: SessionShareOptions) async throws -> SessionShare` (NOTE: update takes the options, so `keepUpdated` reaches the sharer; Multitool sends the existing options with `keepUpdated` changed); `stop(_ session: ULID) async throws`; `share(of: ULID) async throws -> SessionShare?`; `shareChanges() -> AsyncStream<ULID>` (the session id of each share change outside a Multitool call; default: a stream that finishes at once).
    - `SessionShareOptions`: `includeThoughts`, `includeToolOutput`, `anyoneWithLink`, `keepUpdated`; `.defaults` = true, true, true, false. `SessionShare`: `url`, `anyoneWithLink`, the options, `updatedAt`.
    - Host API: `SessionsTool(directory:exporter:searcher:sharer:)`, `SessionsGraph.endpoint(of:exporter:searcher:sharer:)` (nil default). No sharer: SHARING_UNAVAILABLE; a sharer that throws: SHARE_FAILED; update/stop with no share: NOT_SHARED. No risk mark: normal permission rules.
    So the adapter of this task must give the host closures for share, update (with options), stop, the current share, and the change stream (the host passes its CloudShareStore stream through).
  timestamp: 2026-11-19T22:41:55.766054+00:00
position_column: todo
position_ordinal: '9880'
title: 'D208: the server session snapshot and the host sharer for the sessions tool'
---
Decision D208 in `TestudoApp/features/decisions.md` (commit d803f1a; final), parts (g) and (k), with the answers Q74–Q80 in D208 (m). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/share/acpa-brief.md`. Overview: `overview.md` in the same folder. Wave 2.

## Dependencies (not on this board)

- FoundationModelsACP on `main`: `SessionSnapshot` in `ACPMarkdown` (the content rules: thoughts and tool output, both in by default; the coded form `updates.json` with a format version; the Markdown; `SessionSnapshot.build`).
- FoundationModelsMultitool on `main`: the host protocol `SessionSharer`; `share session`, `update share`, `stop sharing`; `SHARING_UNAVAILABLE`.
Do not start until both shas come.

## Rules from the answers (do not build these)

- No secret check and no removal of text (Q77). No 64 KB cut of the share (Q76). No extra approval of a share by the agent (Q80): the tool calls run under the normal permission rules (D3).
- The agent does not name CloudKit. The host gives the cloud part (the rule of `FoundationModelsAgents/Tests/FoundationModelsAgentsTests/NoCloudSyncCodeTests.swift:42-51` applies in spirit).

## Current state

1. `AgentTranscriptExporter` reads the retained history and renders the Markdown (`Sources/FoundationModelsACPAgent/Agent/SessionTranscriptExport.swift`). A session with no history gives `noHistory`.
2. `CatalogContext` gives the exporter to the tools (`Sources/FoundationModelsACPAgent/Tools/CatalogContext.swift`).

## Change

1. A server snapshot source: `snapshot(of session: ULID, options: SessionSnapshot.Options) async throws -> SessionSnapshot`, from the retained history, through `SessionSnapshot.build`. Reuse the history read of the exporter; do not copy it. A session with no history gives the same `noHistory` error and text.
2. `CatalogContext` gets `sessionSharer: (any SessionSharer)?`, default nil, and gives it to the `sessions` tool (the Multitool host API).
3. A small public adapter type for the host: it takes the server snapshot source and a closure of the host that saves a `SessionSnapshot` as a share (and updates and stops it), and it conforms to `SessionSharer`. The app gives the closures from its `CloudShareStore`. Give the host a way to pass it in (for example a parameter of `RoutedACPAgent.init` / `ComposedAgent.compose`).
4. Keep Updated (Q74): the host must learn the end of each turn of a session. If an event of the end of a turn already exists for the host (for example the transcript search change stream of ^twh8ceh, or another public stream), document it for this use; else add one public turn-end stream. The host does the update; the agent does not.

## Tests

- A snapshot of a recorded session equals `SessionSnapshot.build` of its history.
- A session with no history gives `noHistory`.
- With a fake host closure, `share session` through the `sessions` tool gives a URL; `update share` and `stop sharing` call the host.
- With no sharer, the tool gives `SHARING_UNAVAILABLE`.
- The host gets one turn-end event for each turn.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d208 #share