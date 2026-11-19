---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rx2tge7cpjhp0vtsp10qve
  text: 'Dependency available (2026-11-18): Router ^1vesqjj is on origin/main at de36cd24. Removed public API: `SessionTreeRestorationError.notARootSession`, `RestoredSessionTree.session(_:)` and `RestoredSessionTree.children(of:)`. I checked: this package does not use them (the `children(of:)` calls in the tests are on this package''s own `SessionTree`), so the build does not break. Restore a fork only by its own id; a fork that the directory holds does not move on a model switch, so move it with a restore by its id. This task still waits for Router ^vhy7017 (the launcher operation).'
  timestamp: 2026-11-19T03:19:55.662902+00:00
- actor: claude-code
  id: 01m7rytrtrdg31v7q8kejckf27
  text: |-
    Dependency available (2026-11-18): Router ^vhy7017 is on origin/main at 4435599b. The launcher operation:

        // SessionLauncher
        func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession
        // default (protocol extension): try await request.makeFork()   — the tools of the source

        public struct SessionLaunchForkRequest: Sendable {
            public let sourceID: ULID
            public let forkID: ULID
            public let forkedAtHistoryOrdinal: Int
            public let workingDirectory: URL
            public let requestedByClient: String?
            public func makeFork(tools: [any Tool]) async throws -> any RoutedSession  // this agent's surface
            public func makeFork() async throws -> any RoutedSession                    // the source's tools
        }
        public enum SessionLaunchForkError: Error, Sendable, Equatable {
            case forkAlreadyMade(ULID), notTheRequestedFork(ULID), requestClosed(ULID)
        }

    Rules: call `request.makeFork(tools:)` ONE time inside `forkSession` and return that session. The Router has done the cut, so do not map it again. `RouterSessionDirectory.fork(_:)` maps the cut, calls the launcher, checks that the session is the requested fork, registers it, and only THEN mails the first prompt. So no prompt runs before this agent's surface is in place, and the agent holds the fork from its start (no stop/restore). The request closes when the fork call ends: a later or second build throws, and a build in flight at the close discards its fork. If the launcher throws, nothing is registered and the fork folder is removed. The current launcher compiles with the default.
    This task starts after ^ccx24tw, because both change Agent/SessionFork*.swift.
  timestamp: 2026-11-19T03:50:28.952663+00:00
- actor: claude-code
  id: 01m7s1p1vead2c1a2s4bv2z51w
  text: |-
    Research (2026-11-18). Router pin: 9453588f (has 4435599b and de36cd24). Extras bd5009e2 and Multitool 0c22a31a stay; the Router builds with them. The current code builds with zero compiler warnings on the new pin.

    Findings:
    - The launcher gets only SessionLaunchForkRequest. It does not tell a `session/fork` from a tool fork. `session/fork` sends `requestedByClient = caller`; the tool sends nil (a user fork through the `sessions` endpoint sends a client id too). So the agent keeps the surface of a `session/fork` request by (source id, client id) until the launcher takes it, and it lets only one such fork run at a time for one key, because the directory can call the launchers of two forks in any order.
    - `activateSession` writes the additional directories through `sessionDirectory.setAdditionalDirectories(for:)`. In the launcher the fork is not registered yet, so the write must come after the fork call. `session/fork` writes it after the fork call. A tool fork has no step after the fork call, and the Router has no public way to set the record of an unregistered fork. So the record of a tool fork does not hold the additional directories of its source (the surface has them). This needs a Router API change.
    - `AgentSessionLauncher.restoreSession(id:)` refused each session with a parent, so the directory could not restore a recorded fork by its id (`unknownSession`).
    - `claimedRuns(of:)` already reads the runs of the restored id only, so a restore of a fork by its id claims the runs of the fork.
    - RED: the four new tests fail for the expected reason: the tool fork is not in the table; the fork keeps `standard` after a switch of its source; the first prompt of a tool fork never ends after a resume (time limit); the launcher throws `unknownSession` for a fork.
  timestamp: 2026-11-19T04:40:20.078685+00:00
- actor: claude-code
  id: 01m7s231njkw4h6gp1v1tmtd95
  text: |-
    Implementation landed (not committed).

    - New `Agent/SessionForkLaunch.swift`: `AgentSessionLauncher.forkSession(_:)` calls `RoutedACPAgent.launchFork(_:)`. It records the agent of the source for the fork, composes the surface (the surface of the `session/fork` request from `ForkLaunchBook`, else the MCP servers, directories and user presence of the source), calls `request.makeFork(tools:)` one time, writes the history file of the fork, records the hook key of the folder, sets the owner of a `session/fork`, and mounts the fork in the table before the directory registers it.
    - `SessionFork.forkSession`: holds the key (source, connection), puts the surface and the copied history in the book, calls the directory, then records the additional directories (the fork is registered now), seeds the history and announces the name. The response and the copied history are the same as before.
    - `SessionSetup.activateSession` = `recordPlacement` + new `mountSession`; the launcher calls `mountSession` only.
    - Removed `Agent/SessionForkRestore.swift` and its three calls in `restoreColdRoot` (stop of the live directory fork, agent inheritance at restore, history from tool calls at restore). The tool-call copy (`forkEnd(keepingToolCalls:)`) now runs in the launcher.
    - `restoreSessionForDirectory` accepts a fork (kind `fork`), so the directory restores a fork by its own id; the claims stay those of the restored id.
    - `ModelSlotSwitch.moveSession`: after a switch, `moveHeldForks(of:to:)` switches each held fork of the session by its id (`applyModelSlot`) and reconciles its options.

    Router API need (that part stopped): the record of a tool fork (`fork session`) does not hold the additional directories of its source. `RouterSessionDirectory.setAdditionalDirectories(to:for:)` needs a registered session, the launcher runs before the registration, and a tool fork has no agent step after the registration. The surface of the fork has the directories; only the `index.md` record lacks them. A fix needs a Router way to set the record of the fork in the launcher (for example `SessionLaunchForkRequest.makeFork(tools:additionalDirectories:)`).
    Known limit: a user fork through the `sessions` endpoint with a client id that is the raw id of a connection that runs a `session/fork` of the same source at the same time would read that request. The launcher request has no other field that tells them apart.
  timestamp: 2026-11-19T04:47:25.874162+00:00
- actor: claude-code
  id: 01m7s24bqfk63y1t352gcpn9qj
  text: |-
    ### implement — stuck
    - evidence: Router pin 9453588f (has 4435599b, de36cd24); Extras bd5009e2 and Multitool 0c22a31a stay the same. Files: Agent/SessionForkLaunch.swift (new), Agent/SessionForkRestore.swift (removed), Agent/AgentSessionLauncher.swift, Agent/SessionFork.swift, Agent/SessionResume.swift, Agent/SessionSetup.swift, Agent/ModelSlotSwitch.swift, RoutedACPAgent.swift, README.md, ARCHITECTURE.md, Tests SessionForkHandlerTests.swift and ResumeNestedSessionsTests.swift. Each of the 4 new tests failed first for the expected reason.
    - gap: the record (`index.md`) of a tool fork does not hold the additional directories of its source. To write it, the Router API must change (see the comment before this one). Everything else on the card is done.
    - next: a person decides on the Router change; then /review.

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings; `timeout 1800 swift test --skip-build` ran 2444 tests in 256 suites, all passed (1 known issue that was already there and is expected: HarnessSmokeTests withKnownIssue).
  timestamp: 2026-11-19T04:48:08.943017+00:00
depends_on:
- 01M7QV7TASP791JZFKKEMD9F4N
position_column: doing
position_ordinal: '8180'
title: 'D205: build a fork through the Router launcher operation, and adopt the root-only restore'
---
Follow-up of ^emd9f4n (2026-11-18). Answers of the Router session to two questions about the fork.

## Dependencies (not on this board; start when the Router sends the shas)

- Router ^vhy7017 (01M7RWB7YTPYSWRXZJAVHY7017): a new `SessionLauncher` operation for a fork. `RouterSessionDirectory.fork(_:)` calls it with the source id, the cut position and the fork id, so the host builds the fork with its own surface. Only then does the directory register the fork and mail the first prompt. A default implementation keeps today's behavior. The Router sends the exact signature.
- Router ^1vesqjj: `restoreSession(id:)` of a root restores the root ONLY: no session, no directory entry and no hooks for a fork under it. A fork is restored only by its own id. With `switchingModel`, a recorded fork that has no session moves on disk with one `modelChanged` event; a fork that the directory holds (live or suspended) does not move, and the host moves it with a restore by its id. A run of a fork is claimed only with a restore by the fork id (a claim through the root throws `runNotClaimable`). `SessionTreeRestorationError.notARootSession` is removed.

## Current behavior (from ^emd9f4n, commit 8447ce3)

- A fork from the `sessions` tool stays live in the Router on the tools of the source until a client resumes it, and a first prompt runs on the surface of the source. On `session/resume`, the agent stops the live Router fork and restores it on its own surface (`Agent/SessionForkRestore.swift`), which can cancel that first prompt.
- A cold resume of a source restored its recorded forks with it, which could make a second live instance of a fork that the agent holds.

## Change

1. Implement the new launcher operation in this agent's `SessionLauncher`: build the fork with this agent's surface (the MCP servers and directories of the request, or none when the request omits them, per the ACP spec decision on ^emd9f4n; the agent of the source), so the agent holds the fork from its start.
2. Remove the stop-and-restore path for a tool fork (`SessionForkRestore.swift`), if the launcher makes it unnecessary.
3. Adopt the root-only restore: remove each use of `SessionTreeRestorationError.notARootSession`; restore a fork only by its own id; move a fork that the agent holds on a model switch with a restore by its id; claim a run of a fork only through its id.
4. Update README.md and ARCHITECTURE.md.

## Tests

- A `fork session` from the tool with a first prompt: the prompt runs on the surface of this agent, and no resume cancels it.
- A cold resume of a source does not make a second live instance of a fork that the agent holds.
- A model switch of a source with a fork that the agent holds moves the fork through a restore by its id.
- A run of a fork is claimed by the fork id. #d205 #fork