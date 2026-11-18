---
assignees:
- claude-code
depends_on:
- 01M7NQMWNNTAYWET485V2Y341X
position_column: todo
position_ordinal: '8780'
title: 'D202: export a session as Markdown from its retained history (SessionTranscriptExporter)'
---
Decision D202 in `TestudoApp/features/decisions.md` (commit 40450ab). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/export-markdown/acpa-brief.md`. Overview: `overview.md` in the same folder.

## Dependencies

- ^v2y341x (ACPA-6 replay of the `session_message` entries). On the board.
- FoundationModelsACP on `main`: the `ACPMarkdown` product (`SessionMarkdown.render(updates:options:)`) and the public `SessionMergeEngine.init(replaying:)` in the core target (`acp-brief.md`). Not on the board: do not start until it lands.
- FoundationModelsMultitool on `main`: the `SessionTranscriptExporter` protocol (`mt-brief.md`). Not on the board: do not start until it lands.

## Current state

1. The agent keeps the retained history of each session as a `SessionMergeEngine` and writes it to `session-history.json` in the transcript directory (`Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift:7-23`, `:33-56`). `SessionHistoryFile.read(from:)` reads it (`:66-73`). A session from an earlier build has no file (`:62-64`).
2. `SessionMergeEngine.init(replaying:)` is an internal extension here (`SessionHistory.swift:136-146`).
3. `replayUpdates(from:)` (`SessionHistory.swift:198-203`) gives `transcriptUpdates` without the mail-delivery pause, then the state updates.
4. A resume takes the live history (`SessionResume.swift:210-214`) or restores a cold one with the recorded plans (`resumedHistory`, `SessionResume.swift:286`).
5. `makeSessionsTool(context:)` (`Tools/ToolCatalog.swift:564-569`) makes `SessionsTool(directory:)` over the Router session directory.

## Change

1. Add the package product `ACPMarkdown` to the target dependencies.
2. Add a type that conforms to `SessionTranscriptExporter`. For a session id:
   - Use the live history when the session is in memory. Else use the history of a cold restore (the same history that `session/resume` replays, with the recorded plans). Else use `SessionHistoryFile.read(from:)` of the transcript directory.
   - Render `transcriptUpdates` of that history without the mail-delivery pause (the same filter as `replayUpdates(from: .start)`) with `SessionMarkdown.render(updates:options:)`. The title is the title of the session in the directory. `agentName` is the name of the agent of the session. The labels are `.english`. `includeThoughts` comes from the call.
   - When the server has no history for the session, throw an error that the tool turns into this corrective: "This server has no history of the session. Use Export as Markdown… in the app."
3. `makeSessionsTool(context:)` gives the exporter to `SessionsTool`.
4. Remove the local `SessionMergeEngine.init(replaying:)` (`SessionHistory.swift:136-146`) and use the public one of FoundationModelsACP.
5. The same updates and options always give the same text: no date, time, random id or locale-dependent text.

## Tests

- A session with user and agent messages, a tool call with a diff, a terminal and a plan: the export of the live session and the export after a restart (from `session-history.json`) are the same text.
- The export is the same text as `SessionMarkdown.render(updates:)` of the updates that a `session/load` of the same session sends, without the state updates.
- A delivered message from another session is in the export with the heading "From <title>".
- A session with no history gives the corrective.
- `includeThoughts` true includes a thought; false leaves it out.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d202 #export-markdown