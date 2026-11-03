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
position_column: todo
position_ordinal: '80'
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