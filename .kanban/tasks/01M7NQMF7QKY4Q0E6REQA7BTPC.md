---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qmekc6k73p5h5a44tzf13q
  text: |-
    Dependency available (2026-11-18): Router ^jf3j3v5 is on FoundationModelsRouter origin/main 709d82c5. All 5 Router D199 tasks are on main.
    - `SessionDirectoryEvent.messageDelivered(SessionMessage)` comes one time for each delivered directory message, on each path: direct to an idle target; queued (when the target takes it, NOT when it is queued); the inbox scan when a host opens a recorded target; the first message of an agent start. An inbox read with `markRead` gives the event one time. A refused, cancelled or lost mail gives no event.
    - The event comes before the first model output of the turn of that message.
    - `SessionMessage`: `from` is `.user(clientID:)` or the sender session; `sourceSession` is set for a user message with a source session; `to` is the target; plus the text.
    - The prompt of a user message with a source session starts with "From the user, in <title> (<folder>)", a blank line, then the text. A session message keeps the JSON `AgentMessageHeader`.
    - CHANGE OF MEANING: `messageDelivered` now means "the target took the message", not "the message went into the queue". Check each current use of `messageDelivered` in this package.
  timestamp: 2026-11-18T15:29:49.958793+00:00
- actor: claude-code
  id: 01m7qmvx9g25s45tndvhxc7ghb
  text: |-
    Research (2026-11-18):
    - The build before the change is good: `swift build --build-tests` gives "Build complete!" with Router 709d82c, Extras 92660bf. The new Router causes no break here.
    - This package has NO subscription to `SessionDirectory.events()` today, and no switch on `SessionDirectoryEvent`. The wiring is new.
    - `SessionMessage.id` (the event) is the same `MailID` as the `mailDelivered(MailID)` event of the target session (Router `hand(...)` mails with `id: delivered.id`).
    - Router sends `messageDelivered` from the mail-fate observer BEFORE the session gives `mailDelivered`. But the agent reads the two streams in two tasks, so the order in the agent is not certain. Fix: at `mailDelivered` of a key that the projector does not know, the projector reads `directory.message(mail, to: target)`. Router writes the ledger in `hand(...)` with no suspension point, so the ledger has the message when the actor serves the read. Both paths run at take time, never at queue time.
    - The host mail route (`AgentRunLinks.callerMail`) sends through the directory too, so it also gives `messageDelivered`. It must keep its current views (outgoing + incoming + link). Plan: the route records an expected host mail (sender, recipient, text) before `directory.send`; the directory path skips that message.
    - The `agents` tool mails straight to the session (FoundationModelsAgents `AgentRun.admit`), not through the directory, so it gives no `messageDelivered`.
    - Inbox read with `markRead` (^ksepr6x) gives `messageDelivered` with no `mailDelivered`: the registration waits in a bounded table and sends nothing. That task stays open.
    - Inbox scan on open: the scan hands the mail to the session (`hand`), so the pump takes it and the same path gives the update.
    - Plan: projector gets an optional `SessionDirectory`; a feed task per surface reads `events()` with `guard case .messageDelivered`; `_meta` via `SAH.SessionMessage.inject`.
  timestamp: 2026-11-18T15:37:06.096126+00:00
- actor: claude-code
  id: 01m7qnag55389s3mtpvb233n8y
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift`: `DirectoryMessage` (the view data and the incoming view with `_meta`), `ExpectedHostMail`, `DirectoryMessageSource` (reads `message(_:to:)` and `summary(of:)`, builds `SAH.SessionMessage` and injects it), `DirectoryMessageFeed` (one task for each surface that reads `events()`; the projector stops it in `deinit`).
    - `SubagentMessageProjector`: `init(directory:)`, the directory route (`directoryEventArrived` with `guard case .messageDelivered`, `learnDirectoryMessage(of:takenBy:)`, `expectHostMail`, `forgetHostMail`), and new state (`directoryMessages`, `directoryKeys`, `expectedHostMails`). `receive` gives the view of a waiting directory message at the take.
    - `ACPEventTranslator+Messages.receiveMessage(of:)` reads the directory first for an unknown mail, then sends the views. The view goes out at `mailDelivered`, before the output of the turn.
    - `ToolCatalog.sessionSurface` gives the directory to the projector of the surface.
    - `AgentRunLinks.callerMail` records the host mail before `directory.send`, so the host mail route keeps its outgoing, incoming and link views and gets no second view.
    - No exhaustive switch on `SessionDirectoryEvent` exists in this package. The new code uses `guard case`, so a new Extras case (`messageQueued`) does not break the build, and it gives no view.
    - ARCHITECTURE.md: the "The messages" bullet now names the directory route.
    - Tests: `DirectoryMessageProjectorTests` (9, in-memory directory) and `DirectoryMessageWireTests` (4, Router + scripted model: user message idle, order before the reply, session sender, queued message after the turn before it). RED seen for both suites before the wiring.
    - Follow-up for the TestudoApp session (not written to their board): ACPA-6 status and the rule 2 note of the category document (^k6wacyz).
  timestamp: 2026-11-18T15:45:04.165948+00:00
- actor: claude-code
  id: 01m7qncej2vnkrmp3je57hmzkv
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/.../Agent/DirectoryMessage.swift (new), SubagentMessageProjector.swift, ACPEventTranslator+Messages.swift, ACPEventTranslator.swift, AgentRunLinks.swift, Tools/ToolCatalog.swift, ARCHITECTURE.md, Tests/.../DirectoryMessageProjectorTests.swift (new), Tests/.../DirectoryMessageWireTests.swift (new)
    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings. The only warning line is the SwiftBuild message "missing creator for mutated node" for the mlx-swift_Cmlx bundle; it is not a compiler warning and is not from this change. `swift test --skip-build`: 2309 tests in 245 suites passed, 0 failures, 1 known issue (the `withKnownIssue` in HarnessSmokeTests that was there before).
    - next: /review
  timestamp: 2026-11-18T15:46:08.066217+00:00
position_column: doing
position_ordinal: '8180'
title: 'ACPA-6: send a session_message update for each delivered directory message'
---
Decision D199 (f) in `TestudoApp/features/decisions.md` (commit 740cd1a), and ACPA-6 in `TestudoApp/features/packages/foundationmodels-acpagent.md:76-84`. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, items 1, 2 and 6.

## Dependency

- FoundationModelsRouter task 01M7NQNGH4YGB2Y1SS0JF3J3V5 (the host event of a delivered directory message). Also the Router header for a user message with a source session. Do not start until the Router change is available.
- FoundationModelsExtras adds `SessionMessage.sourceSession`.

## Event to use

Use the existing event `SessionDirectoryEvent.messageDelivered(SessionMessage)` (FoundationModelsExtras). Extras adds no new directory event. `SessionMessage.to` gives the target session, and `SessionMessage.sourceSession` gives the source session of a user message. Do not use a `messageDelivered(_, to:)` form. (Change from the brief, sent by the TestudoApp session.)

## Current behavior

- `mailDelivered` (`Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift:468-472`) calls `receiveMessage(of:)` (`ACPEventTranslator+Messages.swift:84-86`). `SubagentMessageProjector.receive(key:by:text:)` (`SubagentMessageProjector.swift:455-466`) gives `[]` for a mail that is not registered.
- Only the messages of the `agents` tool and the host mail route (`AgentRunLinks.swift:26-40`, `.mailed(...)`) register a message.
- So the client of the target sees no entry for a message from the `sessions` tool or from the user in another session.

## Change

1. For each `messageDelivered` event whose `SessionMessage.to` is a session of this agent, register the message with the projector. `mailDelivered` then gives one `session_message` update to the client of the target: `messageId`, `senderSessionId` (the sender session, or `sourceSession` for a user message), `recipientSessionId`, and the text as content.
2. Put `SAH.SessionMessage` in `_meta` with `SAH.SessionMessage.inject` (FoundationModelsACP, `SAH/SAHMeta.swift:66-180`; no change there):
   - A message from the user: `sender.kind = user`, with `sessionId`, `title` and `cwd` of the source session.
   - A message from a session: `sender.kind = session`, with `title`, `agent` and `cwd`.
3. Order: the `session_message` update comes before the first chunk of the turn that the message starts. A queued message shows when its turn starts, not when it is queued.
4. The messages of the `agents` tool keep their current updates. Make sure that no message gets two updates.
5. When this lands, tell the TestudoApp session to update the ACPA-6 status and the "(to confirm with the ACP spec)" note of rule 2 of the category document (TestudoApp task ^k6wacyz). Do not write to the TestudoApp board.

## Tests

- A user message with a source session, delivered to an idle hosted session: one `session_message` update with `_meta.sah.message.sender.kind == "user"` and the source session id and title, then the agent chunks.
- A message from a session through the `sessions` tool: `sender.kind == "session"`, with title, agent and cwd.
- A queued message: the update comes when its turn starts, not before.
- A message of the `agents` tool: the same updates as today, no second update. #d199 #at-sessions #acpa-6