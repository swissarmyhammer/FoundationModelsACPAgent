---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s27c2zrhde4ps5grbrx9nz
  text: |-
    Router answers (2026-11-18; the Router change is a new Router task, sha comes later):
    1. Directories: `SessionLaunchForkRequest.makeFork(tools:additionalDirectories:)`. `makeFork(tools:)` stays and gives no directories. The Router writes the directories to the fork record in the same way as for a new session, so they are in index.md and after a restart. The default `makeFork()` gives the source's own additional directories. Use `makeFork(tools:additionalDirectories:)` with the directories of the session/fork request (none when omitted), or of the source for a tool fork.
    2. Correlation: NO new field. The Router guarantees (doc and test) that `SessionLauncher.forkSession(_:)` runs in the TASK of the caller of `RouterSessionDirectory.fork(_:)`: no `Task {}` and no `Task.detached` between them. Thus set a `@TaskLocal` of this agent (for example the id of the waiting session/fork request) around the `fork(_:)` call in the session/fork handler, and read it in the launcher. A fork from the `sessions` endpoint runs in another task, so it does not have the value and cannot take the request. Remove the (source id, client id) key. If the token must cross a new task on this side, tell the Router.
    Add a test: a session/fork and a `sessions` endpoint fork of the same source with the same client id at the same time; each gets its own surface.
  timestamp: 2026-11-19T04:49:47.615727+00:00
- actor: claude-code
  id: 01m7s3a5mvbr0bsnn327tev68g
  text: |-
    Part 2 (correlation) is done under ^agknbvr (2026-11-18, not committed). The (source id, client id) key is removed. The `session/fork` handler sets a `@TaskLocal` id (`ForkLaunchID.current`) around `RouterSessionDirectory.fork(_:)` (`RoutedACPAgent.whileForkRequestWaits(_:_:)`), and `AgentSessionLauncher.forkSession(_:)` reads it. A `sessions` endpoint fork or a tool fork has no id and builds with the surface of its source. The test `aSessionForkAndAnEndpointForkOfOneClientGetTheirOwnSurfaces` (SessionForkHandlerTests) covers the third test of this card. No new task crosses the token on this side, so the Router needs no other change for part 2.
    Still open: part 1 (the additional directories in the `index.md` record through `makeFork(tools:additionalDirectories:)`) and its two tests. They wait for the Router sha.
  timestamp: 2026-11-19T05:08:47.899702+00:00
- actor: claude-code
  id: 01m7s3r53c7p0qs38kb3qx3xc0
  text: |-
    Dependency available (2026-11-18): Router ^et5r7pv is on origin/main at 5eeb6a50. Run `swift package update FoundationModelsRouter` when this task starts.
    - `public func makeFork(tools: [any Tool], additionalDirectories: [URL]) async throws -> any RoutedSession` on `SessionLaunchForkRequest`. The directories go to `SessionRecord.additionalDirectories` of the fork (the same field as a new session), so they are in index.md and stay after a restart. `makeFork(tools:)` gives none; `makeFork()` gives the directories of the source record. The closed-state rules (`forkAlreadyMade`, `requestClosed`) apply to the new call too.
    - The same-task guarantee is now in the docs of `SessionLauncher.forkSession(_:)`, `RouterSessionDirectory.fork(_:)` and `launchFork(_:)`, with a Router test. Part 2 of this task (the task-local `ForkLaunchID`) is already done in acd95d0.
    - Also on Router main since 694d51ea: a fork asks for a copy of the source's prompt cache before its first prompt (`SessionPromptCacheCopying`). It has no effect until `MLXLanguageModel` conforms (a later Router step after an mlx-swift-lm release). No work for this task.
    This task starts after ^d03gc6x, because both change Agent/SessionForkLaunch.swift.
  timestamp: 2026-11-19T05:16:26.092941+00:00
- actor: claude-code
  id: 01m7s5xh5bkh9fdfpy93yd8ddb
  text: |-
    Part 1 landed.
    - Pins: `swift package update FoundationModelsRouter` moved Router 9453588 -> 5eeb6a5 (5eeb6a508b0072f9067b0e51cf0add8221314ed3). Extras (bd5009e) and Multitool (0c22a31) did not change; the Router did not need them. Package.resolved is in .gitignore, so no commit holds the pins.
    - `SessionForkLaunch.launchFork(_:for:)` calls `makeFork(tools:additionalDirectories:)` one time with `placement.additionalRoots`: the directories of the `session/fork` request (none when omitted), else the directories of the source (`sourceForkPlacement(of:)`) for a tool fork and for a `sessions` endpoint fork.
    - `openFork` no longer writes the directories after the registration (`setAdditionalDirectories`). It only records the project (`registerProject(of:)`, split out of `recordPlacement(of:placement:)`). The record has the directories from the build.
    - Tests (SessionForkHandlerTests, "The additional directories of the record of a fork"): tool fork, endpoint fork, session/fork with request directories, session/fork with omitted directories, tool fork after a restart (the first agent closes, a second agent resumes the source cold, then the test reads index.md). RED: 4 failed with `recorded -> []` after the removal of the late write; the omitted test passed before and after, because no path gave directories to that fork. GREEN: 5 passed.
    - Note: a cold `session/resume` of a fork takes the client list (the client is authoritative on each reconnect), so the restart test resumes the source and not the fork, and reads the record of the fork from disk.
    - ARCHITECTURE.md (fork handler and launcher) and README.md (fork section) now tell that the record holds the directories.
  timestamp: 2026-11-19T05:54:19.435953+00:00
- actor: claude-code
  id: 01m7s5xktx49tqtet9g17j374g
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionForkLaunch.swift, Sources/FoundationModelsACPAgent/Agent/SessionFork.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift, ARCHITECTURE.md, README.md; Router 5eeb6a5, Extras bd5009e, Multitool 0c22a31
    - next: review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftPM note "missing creator for mutated node" for the mlx bundle). `timeout 1800 swift test --skip-build`: 2453 tests in 256 suites passed, 0 failures, 1 known issue (HarnessSmokeTests, by design), 0 skipped.
    - next: review
  timestamp: 2026-11-19T05:54:22.173953+00:00
depends_on:
- 01M7RWC0Q3R664RM3W2AGKNBVR
position_column: doing
position_ordinal: '8280'
title: 'D205: the record of a tool fork has the directories of its source, and the launcher knows which session/fork request it builds'
---
Found during ^agknbvr (2026-11-18). Both items need a Router API change; the Router session (foundationmodelsrouter-f1) is asked. Do not start until the Router sends the sha.

## Current behavior

1. A fork that the `sessions` tool `fork session` makes does not get the additional directories of its source in its `index.md` record. The tools of the fork do get them. Writing the record needs a Router API change.
2. `SessionLaunchForkRequest` has only the source id, the fork id, the cut ordinal, the working directory and the client id. This agent keeps the tools and history of a `session/fork` request under the pair (source id, client id) until its launcher reads them, and one request per pair runs at a time. In theory, a fork that a client asks for through the `sessions` endpoint, with the same client id for the same source at the same time, can take that waiting request.

## Change (after the Router change)

1. Give the Router the additional directories of a tool fork (and of a `session/fork` fork, from its request), so the `index.md` record holds them.
2. Use the new correlation field of the launcher request to find the waiting `session/fork` request, not the (source id, client id) pair.

## Tests

- A tool fork: its `index.md` record has the directories of the source.
- A `session/fork` fork: its record has the directories of the request (none when omitted).
- Two forks of the same source with the same client id at the same time, one through `session/fork` and one through the `sessions` endpoint: each gets its own surface. #d205 #fork