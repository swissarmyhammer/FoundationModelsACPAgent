---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gjhtezqd4brvfjbfthcc46
  text: |-
    CORRECTION to point 3 and 4 of this task: AgentRun.sessionID is internal, but it is not needed. The session of a run has the id of the run (AgentRun.swift comment), so `run.id` is the Router session id of the child, and `run.caller` (public) is the session id of the caller (the root session or the parent run). Use these for the child id and the parent link. The observer `(AgentRun, SessionOutput)` gives the events of each child. The first observer event of a run triggers the announce, using the run id, the caller and the AgentDefinition (name, description); the directory started event is not needed for this.
    REMAINING GAP: the live RoutedSession of a child is not public (RouterSessionDirectory.liveSession and makeEventFeed are private; AgentRun has no public session). Step 1: feed the SessionProjector from the observer with `attach(_ outputs:, from: Source(id: run.id, session: nil))`. With session nil the relayHandler is nil, so a child elicitation is not asked under the child id (the Router relays it up to the parent, so the user still gets the question, under the root id). Step 2 (a Router card, being handled in a separate Router session): a public accessor for the live session or its event feed, then attach with the session and the child gets its own elicitation relay. Do not change the Router or FoundationModelsAgents from this task.
  timestamp: 2026-11-03T11:26:15.519471+00:00
- actor: wballard
  id: 01m6gmvekxqp6p5yb2fydgm9ft
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    1. The ACP id of a child is its Router ULID string (as for the root), so no id table is needed; keep only the parent link.
    2. The shared build is bigger than ledger, projector, relay, history sink and ActiveSession: see `activateSession` (SessionSetup.swift near lines 700 to 790): recordPlacement, shell identity bind, command registry, publishAvailableCommands, startTerminalProjection, reportMCPServerStatus. Write down which fields a child SHARES or BORROWS from its parent (surface, commands, configuration, instructions) and which it owns. A child must never shut down the surface of its parent in `tearDownSession`. The criterion that the root path has no copy of the shared code holds only for the parts a child needs.
    3. The history sink posts through `connections.path(forSession:)` (ConnectionTable owners). A child id has no owner unless it is recorded with the owner of its parent; release it when the connection closes. Each child needs its own `retainedHistory`. Add a test that a child update reaches the owner connection.
    4. Gate the child sink: no child event leaves before its `subagent_update` is queued (same ordered queue). Add a race test.
    5. Cleanup: retire the child entry when its run closes its session; the activeSessions gauge (RoutedACPAgent.swift near line 189) and the GraphQL tunnel and snapshot endpoints read `sessions`, so they must not count or show children wrongly.
    6. A finished AgentRun closes its session (AgentRun.swift header: a finished run holds no session). So a finished child is an association with a closed session, shown as idle; it is not a reusable live runtime.
    7. Split the criteria: step 1 (feed the projector from the run event observer, session nil) and step 2 (attach with the session, after Router card 01M6GJJKPTESHZGW7N2AAY83G3).
  timestamp: 2026-11-03T12:06:28.221063+00:00
- actor: claude-code
  id: 01m6gzxth0yt4bzbagfpzerke3
  text: |-
    IMPLEMENTATION NOTE (step 1).

    Built:
    - SessionBuild.swift: one function, registerSession(_:sessionId:parent:build:). The root calls it with parent nil (from activateSession). A nested session calls it through registerNestedSession(_:parent:). It builds the state ledger, the projector (with the elicitation relay), the history sink and the ActiveSession entry. It has no "if child" branch: the link, the owner record and the gate come from the parent argument.
    - SessionTree.swift: ancestors(of:) (root first), children(of:), parent(of:), link, remove. Typed errors: selfParent, cycle, secondParent. A Mutex holds the links.
    - SessionAnnouncementGate.swift: starts open for a root and closed for a nested session. The history sink always writes the retained history, and it posts only when the gate is open. The announce task opens it.
    - ConnectionTable: recordNested(_:under:) and forgetNested(_:). A nested session has no owner record. It takes the owner of its parent each time the owner is read, so a take of the parent and the close of the connection reach it with no extra step. Nothing is left to release.
    - retireSession(_:) removes a nested session (teardown, link, owner, entry). tearDownSession retires the children of the session it closes.

    A nested session BORROWS from its parent: configuration, instructions, workingDirectory, additionalRoots, surface (so the tools, the shell output stream, the shell identity, the MCP servers), commands (the registry), userPresence, isReplayOnly, selectedSlot, announcedConfigOptions.
    A nested session OWNS: session (its own Router session), transcriptDirectory, stateLedger, projector (with its relay and its own RunCallJoinTable), retainedHistory, announcement (gate), openPrompts, parentSessionId, children, titleRecorded (true: the Router owns the record of a sub-agent).
    The root-only steps stay in activateSession: recordPlacement, shell identity bind, command registry, publishAvailableCommands, startTerminalProjection, reportMCPServerStatus. A nested session borrows their results. If it did them, they would run twice on one surface (the shell identity would point to the child, and two loops would read one shell stream).
    The projector of a nested session has its own join table, because projector.stop() calls closeProjection() on the table, and that would seal the runs that the parent waits for.

    A nested session never shuts down the surface of its parent: ActiveSession.ownsSurface is true only without a parent. tearDownSession, markSessionClosed (shell stream finish), the GraphQL tunnel endpoint list and tunnelEndpoint(named:sessionId:viewer:) read it. A tunnel call that names a nested session gets NOT_FOUND. The active_sessions gauge counts only sessions with no parent.

    Observer feed (item 3): the observer in AgentsComposition.swift is made for the surface, so it has no access to the agent, and the live Router session of a child is not public (AgentRun.heldSession is internal, RouterSessionDirectory.session(id:) is not on the Router main). registerNestedSession takes a real Router session, so no production caller exists in this step. The caller that has the live session is step 2 (Router card 01M6GJJKPTESHZGW7N2AAY83G3) and the announce task. The tests make the child Router session with makeSession(agentSpawn:), as closingASessionClosesItsDescendants does. Nothing new goes on the wire.

    Test harness change: ScriptedPromptFixture.close() skips a session that the table no longer holds, because the close of a root session retires its nested sessions.

    Step record: implement - changed
    - evidence: root swift test: 1315 tests in 144 suites passed, 1 known issue (HarnessSmokeTests, expected). Filter SessionTreeTests|SessionSetup: 37 tests passed. IntegrationTests not run: no change touches that package.
    - open: the race test of the gate (plan review item 4) belongs with the announce task, which owns the ordered queue. Here the gate is closed and a test shows that it holds each send.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-03T15:20:00.288354+00:00
- actor: claude-code
  id: 01m6h07b9qky24zsfjrt55ntrs
  text: |-
    review - findings
    - evidence: review working (local): 1 finding, 1 refuted. ConnectionTable.swift:292 (second copy of the parent links, nestedUnder, next to SessionTree).
    - next: fix the finding, then run /review again. Task stays in review.
  timestamp: 2026-11-03T15:25:12.375289+00:00
- actor: claude-code
  id: 01m6h0g2fs4a0m7e33famss193
  text: 'Fix of the finding on ConnectionTable owner(of:in:). The nestedUnder map and the hand-written walk are gone. ConnectionTable now holds the one SessionTree (init(tree:)) and reads the parent links from it. owner(of:) takes the session and its ancestors from the tree and gives the first owner record. path(forSession:) uses the same lookup. recordNested and forgetNested are removed: SessionBuild links and removes in the tree only, and the agent sessionTree is now connections.tree, so one copy of the links exists. The table has no "if child" branch. New tests in Tests/FoundationModelsACPAgentTests/ConnectionTableTreeTests.swift: a child linked in the tree has the owner of its parent, a take of the parent reaches the child, an unlinked child and a stranger have no owner. They failed to compile before the fix (no tree). Root swift test: 1319 tests in 145 suites passed, 1 known issue (HarnessSmokeTests, not related).'
  timestamp: 2026-11-03T15:29:58.265125+00:00
- actor: wballard
  id: 01m6hhjzwa6tqkjgz8jcs6rv6m
  text: |-
    IMPLEMENTATION NOTE (step 1).

    What was built:
    - SessionBuild.swift: one function, registerSession(_:sessionId:parent:build:). The root calls it with parent nil (from activateSession). A nested session calls it through registerNestedSession(_:parent:). The function builds the state ledger, the projector (with the elicitation relay), the history sink and the ActiveSession entry. It has no "if child" branch: the parent link, the owner record and the gate come from the parent argument.
    - SessionTree.swift: ancestors(of:) (root first), children(of:), parent(of:), link, remove. Typed errors: selfParent, cycle, secondParent. A Mutex holds the links.
    - SessionAnnouncementGate.swift: a gate that starts open for a root and closed for a nested session. The history sink always writes the retained history, and it posts only when the gate is open. The announce task opens it.
    - ConnectionTable: recordNested(_:under:) and forgetNested(_:). A nested session has no owner record. It takes the owner of its parent each time the owner is read, so a take of the parent and the close of the connection reach it with no extra step. This is the "record with the owner of the parent" rule, and nothing is left to release.
    - retireSession(_:) removes a nested session (teardown, link, owner, entry). tearDownSession retires the children of the session it closes.

    Which fields a nested session BORROWS from its parent: configuration, instructions, workingDirectory, additionalRoots, surface (and so the tools, the shell output stream, the shell identity, the MCP servers), commands (the registry), userPresence, isReplayOnly, selectedSlot, announcedConfigOptions.
    Which fields it OWNS: session (its own Router session), transcriptDirectory, stateLedger, projector (with its relay and its own RunCallJoinTable), retainedHistory, announcement (gate), openPrompts, parentSessionId, children, titleRecorded (true: the Router owns the record of a sub-agent).
    The root-only steps stay in activateSession: recordPlacement, shell identity bind, command registry, publishAvailableCommands, startTerminalProjection, reportMCPServerStatus. A nested session borrows their results. If the nested session did them, they would run twice on the same surface (the shell identity would point to the child, and two loops would read one shell stream).
    The projector of a nested session has its own join table, because projector.stop() calls closeProjection() on the table, and that would seal the runs that the parent waits for.

    A nested session never shuts down the surface of its parent: ActiveSession.ownsSurface is true only without a parent. tearDownSession, markSessionClosed (shell stream finish), the GraphQL tunnel endpoint list and tunnelEndpoint(named:sessionId:viewer:) read it. A tunnel call that names a nested session gets NOT_FOUND. The active_sessions gauge counts only sessions with no parent.

    Observer feed (item 3 of the task): the observer in AgentsComposition.swift is made for the surface, so it has no access to the agent, and the live Router session of a child is not public (AgentRun.heldSession is internal, RouterSessionDirectory.session(id:) is not on the Router main). registerNestedSession takes a real Router session. So no production caller exists in this step: the caller that has the live session is the step 2 work (Router card 01M6GJJKPTESHZGW7N2AAY83G3) and the announce task. The tests make the child Router session with makeSession(agentSpawn:), as closingASessionClosesItsDescendants does. Nothing new goes on the wire.

    Test harness change: ScriptedPromptFixture.close() skips a session that the table no longer holds, because the close of a root session retires its nested sessions.
  timestamp: 2026-11-03T20:28:39.690714+00:00
position_column: done
position_ordinal: ffff9780
title: Register a nested sub-agent as an ordinary ACP session with a parent link (shared session build)
---
## What
A sub-agent session is an ordinary session that happens to be nested (user decision, 2026-11-03). It must go through the SAME code as a root session, with a parent link added. It must not get a parallel path.

Today a root session is built in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` (near line 700 to 790): a `SessionStateLedger`, a `SessionProjector` (with an `ElicitationRelay(sessionId:)`, `runCallJoins`, and `historySink(for: sessionId)`), `projector.attach(session)`, and an `ActiveSession` stored in `sessions[sessionId]`. Only the root session (and the replacement session in `ConfigOptions.swift:269`) is attached. A sub-agent session is not.

Do:
1. Factor the build of the per-session parts (ledger, projector, relay, history sink, `ActiveSession`) out of the root path into one function that takes a Router session, a new ACP `SessionId`, and an optional `parent: SessionId?`. The root calls it with `nil`.
2. Add `parentSessionId: SessionId?` and `children` to `ActiveSession`, and a small table (new file `Sources/FoundationModelsACPAgent/Agent/SessionTree.swift`) that gives `ancestors(of:)` (root first) and `children(of:)`. It refuses a cycle, a self parent, and a second parent. A child id is opaque, unique on the connection, and never reused.
3. Find the hook that tells the host a sub-agent session started and gives the live Router session. Candidates: the Router `RouterSessionDirectory.events()` feed (the registration has `kind: .subagent` and `parentID`), or `AgentEnvironment.runEventObserver` (gives only `AgentRun` and `SessionOutput`, and `AgentRun.sessionID` and `heldSession` are internal). Write the choice and the gap in a task comment. Do NOT change FoundationModelsAgents or FoundationModelsRouter from this task; a change there needs its own card, discussed first.
4. Map the Router session id (ULID) of the child to its ACP `SessionId`, and the parent link from `SessionRecord.agentSpawn` or the directory `parentID`.

This task does not send anything new on the wire. It only makes the child a session on the host side.

## Acceptance Criteria
- [ ] A root session and a child session are built by the same function; the root path has no copy of that code.
- [ ] `sessions[childId]` exists for a started sub-agent, with `parentSessionId` set, a projector attached to the child Router session, and its own ledger and history sink.
- [ ] `ancestors(of:)` gives the chain root first for a chain of three sessions, the same rule at every level; a cycle, a self parent and a second parent each throw a typed error.
- [ ] Existing root-session tests still pass unchanged.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionTreeTests.swift`: ancestors, children, refusals, concurrent access.
- [ ] A test with the stub model that starts a nested agent run and checks the child entry in `sessions`.
- [ ] Run `swift test --filter "SessionTreeTests|SessionSetup"`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-03 09:20)

> Scope: `review working` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/ConnectionTable.swift:292` `reuse/reuse` — The new static `owner(of:in:)` walks the parent chain by hand, with a bounded loop over `nestedUnder`. `SessionTree` already holds the same parent links and already walks them (`ancestors(of:)`, `parent(of:)`). The table keeps a second copy of those links (`nestedUnder`, line 154) and a second walk, so the two can drift apart. Use one source for the parent links. Either `ConnectionTable` asks `SessionTree` for the parent (`parent(of:)`) on each step of the owner walk, or the owner lookup moves to a single place that reads `SessionTree`. Keep the bounded loop only if it is still needed once the links come from one source. Do not keep two copies of the parent map.
