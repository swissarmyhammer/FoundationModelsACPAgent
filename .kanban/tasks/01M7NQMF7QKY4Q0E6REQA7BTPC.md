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
- actor: claude-code
  id: 01m7qnpnpycnn8hww49x2f1v7g
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 7 findings (7 confirmed, 4 refuted). DirectoryMessage.swift:63, DirectoryMessage.swift:66, DirectoryMessage.swift:69, DirectoryMessage.swift:87, SubagentMessageProjector.swift:621, DirectoryMessageWireTests.swift:107, DirectoryMessageWireTests.swift:202.
    - next: Correct each item in the section "Review Findings (2026-11-18 09:46)". Then do the review again.
  timestamp: 2026-11-18T15:51:43.070042+00:00
- actor: claude-code
  id: 01m7qnq67w0kgfawcfbgbaznxj
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files
    - test: green — swift test --skip-build, 2309 tests in 245 suites passed; 0 compiler warnings
    - commit: 7d35965 (pushed to origin/main at the request of the user)
    - review: findings — DirectoryMessage.swift:63, :66, :69, :87; SubagentMessageProjector.swift:621; DirectoryMessageWireTests.swift:107, :202
  timestamp: 2026-11-18T15:51:59.996004+00:00
- actor: claude-code
  id: 01m7qp37kpx47m92da88126fb8
  text: |-
    Review findings (2026-11-18 09:46) corrected, not committed:
    - Findings 1-3 (dead-code-swift, `ExpectedHostMail.sender`, `.recipient`, `.text`): the properties stay. The projector finds a record with `firstIndex(of:)`, so the synthesized `Equatable` is their only reader. The `dead-code-swift` rule says: do not delete such a property, write `// periphery:ignore` above it with the reason. Each property now has the reason in its doc comment and the marker on the line above the declaration. The other properties of the file have real readers.
    - Finding 4 (preconditions): `DirectoryMessageSource.message(of:takenBy:)` now calls `assertionFailure("session id is not a ULID: ...")` and `ACPAgentTelemetry.logger(.session).error(...)` with the `sessionId` metadata key before `return nil`. No unit test reaches this path: `assertionFailure` stops a debug test run. The full suite passed, so no test sends a session id that is not a ULID through this path.
    - Finding 5 (duplication): new `State.deliverDirectoryView(of:to:)` inserts the key in `directoryKeys` and gives the delivery. `register` and `receive` call it. The two copies are gone.
    - Finding 6 (reuse): new `Tests/FoundationModelsACPAgentTests/Support/SessionIdULID.swift` with `extension SessionId { func ulid() throws -> ULID }` (needs `import FoundationModelsRouter` for `ULID`). `AgentSessionLauncherTests` and `DirectoryMessageWireTests` call it. The two private copies are gone.
    - Finding 7 (concurrency): each test of `DirectoryMessageWireTests` has `defer { await pair.fixture.close() }` (Swift 6.4 accepts `await` in `defer`). The queued test has `defer { busy.cancel() }` after the busy Task; the defers run in reverse order, so the cancel comes before the close. The scripted gate wait checks cancellation. The suite also has `@Suite(.closesHarnesses)` (test rule T1), so a `Pair.make` that throws after its fixture opened also closes the harness.
  timestamp: 2026-11-18T15:58:34.614249+00:00
- actor: claude-code
  id: 01m7qp3bkmcv3kazcxq1erm513
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift, Sources/FoundationModelsACPAgent/Agent/SubagentMessageProjector.swift, Tests/FoundationModelsACPAgentTests/Support/SessionIdULID.swift (new), Tests/FoundationModelsACPAgentTests/AgentSessionLauncherTests.swift, Tests/FoundationModelsACPAgentTests/DirectoryMessageWireTests.swift, .kanban card (7 of 7 findings checked)
    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftBuild line "missing creator for mutated node" for the mlx-swift_Cmlx bundle, not a compiler warning). `swift test --skip-build`: 2309 tests in 245 suites passed, 0 failures, 1 known issue (the `withKnownIssue` in HarnessSmokeTests that was there before).
    - next: /review
  timestamp: 2026-11-18T15:58:38.708656+00:00
- actor: claude-code
  id: 01m7qp8wg4bhkycdy9jkk1k8cz
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (06a16d0). 0 findings, 0 confirmed, 0 refuted. 5 files reviewed. All 7 items of "Review Findings (2026-11-18 09:46)" are checked.
    - next: The task is in done. Tell the TestudoApp session to update the ACPA-6 status and the "(to confirm with the ACP spec)" note (TestudoApp task ^k6wacyz).
  timestamp: 2026-11-18T16:01:39.844302+00:00
- actor: claude-code
  id: 01m7qp97609s0kgetm4ay4tx9a
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 5 files; 7/7 findings checked
    - test: green — swift test --skip-build, 2309 tests in 245 suites passed; 0 compiler warnings
    - commit: 06a16d0
    - review: clean — 0 findings
    - The TestudoApp session got the request to update ACPA-6 (^k6wacyz) with the push of 7d35965.
  timestamp: 2026-11-18T16:01:50.784119+00:00
position_column: done
position_ordinal: ffffff8280
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

## Review Findings (2026-11-18 09:46)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 9 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift:63` `code-hygiene/dead-code-swift` — var.instance `sender` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift:66` `code-hygiene/dead-code-swift` — var.instance `recipient` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift:69` `code-hygiene/dead-code-swift` — var.instance `text` is assignOnlyProperty.
- [x] `Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift:87` `swift/preconditions` — The guard returns nil with no log and no assertion when the session id of a directory read is not a ULID. A session id that does not parse as a ULID is an unexpected condition. The silent nil hides the defect from the author and from production logs. Add `assertionFailure("session id is not a ULID: \(session.rawValue)")` and a `ACPAgentTelemetry.logger(.session).error(...)` call with the `sessionId` metadata key before `return nil`, as the preconditions rule describes.
- [x] `Sources/FoundationModelsACPAgent/Agent/SubagentMessageProjector.swift:621` `duplication/duplication` — The take of a stored directory message repeats the same two steps as the register path: it marks the key in `directoryKeys` and returns one delivery of `message.incomingView` to a session. If the rule for marking a directory key done changes in one place and not the other, the two paths drift apart. Extract one `mutating func deliverDirectoryView(of message: DirectoryMessage, to session: SessionId) -> [Delivery]` in `State` that inserts the key and returns the delivery. Call it from both `register` (526-527) and `receive` (620-621), and delete the two copies.
- [x] `Tests/FoundationModelsACPAgentTests/DirectoryMessageWireTests.swift:107` `reuse/reuse` — The private static `ulid(_:)` helper reimplements the same conversion from a wire `SessionId` to a `ULID` that already exists in `AgentSessionLauncherTests`. It is a second copy of one behavior, so a fix to one would not reach the other. Move the helper to shared test support (for example `Tests/FoundationModelsACPAgentTests/Support/`) as one non-private function, and have both suites call it. Do not keep two private copies.
- [x] `Tests/FoundationModelsACPAgentTests/DirectoryMessageWireTests.swift:202` `swift/concurrency` — The unstructured Task at line 202 is awaited only at line 214. If a throw happens first (at line 207 while the wait for the target runs, or at line 213 while the wait for the reply runs), the Task is never awaited or cancelled. The busy prompt then stays blocked at the gate, and the fixture is never closed. Cancel the task and close the fixture on every exit path. Use `defer { busy.cancel() }` before the waits, or run the busy prompt in `async let` or a `withThrowingTaskGroup`, so that it ends when the scope ends. Keep `await pair.fixture.close()` in a `defer` as well.