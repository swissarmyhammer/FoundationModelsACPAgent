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
- actor: claude-code
  id: 01m7s66dmg6h6dq27hxc1q75pc
  text: |-
    ### review — findings
    - evidence: review sha 26fe29c~1..26fe29c — 1 finding (confirmed 1, refuted 1, attempted 7, failed 0): Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:182 completeness/public-output-contract.
    - next: implement the finding. A throw after `directory.fork(forkRequest)` in `openFork` must not leave a live fork with no cleanup. Then review again.
  timestamp: 2026-11-19T05:59:10.736117+00:00
- actor: claude-code
  id: 01m7s6nr05x0ee03ty1f99p78r
  text: |-
    Finding SessionFork.swift:182 (completeness/public-output-contract) is done (2026-11-19, not committed).
    - Choice: move the project save before the fork, and close the fork on the one throw that stays after the fork. Reasons: the project save needs only the folder, and the fork works in the folder of its source, which the mount of the source registered already. So a save before the fork makes no fork on failure and needs no cleanup, and a later refusal adds no new project. Log-and-continue was not chosen: `session/new` and `session/resume` fail on the same save error, so the fork keeps that contract.
    - `forkSession(_:from:)` calls `registerProject(of:)` before `RouterSessionDirectory.fork(_:)`. `openFork` no longer takes the placement.
    - The `internalError` path of `openFork` (no activation, or no table entry) now calls the new `discardUnopenedFork(_:)` before the throw: a fork in the table gets `tearDownSession` (closes the Router session, stops the projector, releases the surface), its entry and its snapshot key go, and `recordActiveSessions()` runs, as `session/delete` does. Then the agent closes `sessionDirectory.session(id:)` if it is still live (a fork that the table does not hold). The close unregisters the fork from the directory and releases its `heldForks` hold. The record stays on disk, as for each closed session.
    - Tests (SessionForkHandlerTests, "A fork that the agent cannot open"): project save fails (a file at `home.projectsDirectory`): error / no fork in the table / no live fork in the directory. The `internalError` path is reached with a test launcher (`UnopenedForkLauncher`) set through `sessionDirectory.use(launcher:)`: `.agentWithNoRequest` calls `launchFork(request, for: nil)` (the table holds the fork, no activation), `.sourceTools` calls `request.makeFork()` (the table does not hold it): internal error / no fork in the table / no live fork in the directory (both modes).
    - RED: 5 of 7 failed for the expected reason (a fork stayed in the table or live in the directory). The 2 error tests passed before the fix, because the request already threw; they guard the error contract. GREEN: 7 passed.
    - ARCHITECTURE.md (fork handler) now tells that the project save comes before the fork call and that a fork the handler cannot open is closed before the error.
  timestamp: 2026-11-19T06:07:32.869858+00:00
- actor: claude-code
  id: 01m7s6nsyccx7zkcvbgyr3nk8j
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionFork.swift, Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift, ARCHITECTURE.md
    - next: review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings. `timeout 1800 swift test --skip-build`: 2460 tests in 256 suites passed, 0 failures, 1 known issue (HarnessSmokeTests, by design), 0 skipped.
    - next: review
  timestamp: 2026-11-19T06:07:34.860530+00:00
- actor: claude-code
  id: 01m7s6xeqs718z3a365jj7h5we
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (06e0274); 6 findings (6 confirmed, 3 refuted, 0 failed) — Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1463, :1475, :1512, :1538, :1587, :1594
    - next: correct the 6 open items in the section "Review Findings (2026-11-19 00:08)", then commit and review again.
  timestamp: 2026-11-19T06:11:45.529826+00:00
- actor: claude-code
  id: 01m7s784s3kwc10k52bmhpnpvs
  text: |-
    Findings of "Review Findings (2026-11-19 00:08)" are done (2026-11-19, not committed). All 6 items are `- [x]`.
    - :1463, :1475: the project save tests call `expectProjectSaveError(on:)`. The test makes the same save in the blocked project store first (`#expect(throws: CocoaError.self)`, Code 516), then expects `RequestError` from the fork and compares it with `RequestError.internalError(detail: String(describing: saveError as NSError))`. Discovery: an exact compare cannot pass. The description of the save error holds the pointer address of its `NSUnderlyingError`, and each error instance has a different address. Also `String(describing:)` of a `CocoaError` value adds a `CocoaError(_nsError: ...)` wrapper, but the agent describes the bridged `NSError`. Thus the check compares the two full descriptions after it replaces each `0x...` address with `0x` (`withoutAddresses(_:)`). Code, message, domain, code 516, path and underlying error all stay in the compare. The test is renamed `aForkWhoseProjectSaveFailsGetsTheSaveError`.
    - :1512, :1538: the unmounted and no-surface tests call `expectUnopenedForkError(on:)`: `#expect(throws: RequestError.self)`, then the error must equal `RequestError.unopenedFork(<id of the recorded fork>)`. New production constructor `RequestError.unopenedFork(_:)` in Agent/SessionFork.swift, which `openFork` now throws (same code, message and detail text as before). The test is renamed `anUnmountedForkGetsTheUnopenedForkError`.
    - :1587: `forks(in:includesRecorded:)` has a parameter (default `true`); `liveForks(in:)` is deleted.
    - :1594: `UnopenedForkLauncher` is plainly `Sendable`; `agent` is a `weak let` (the pattern of `AgentTranscriptExporter`).
    - Same cause in the whole file: the `try?` in `holdsForkNode(_:)` hid a listing error. It now gives `false` only for a folder that does not exist, and throws other listing errors (`pollUntil` takes a throwing condition). No other `try?` or `(any Error).self` stays in the file.
  timestamp: 2026-11-19T06:17:35.779216+00:00
- actor: wballard
  id: 01m7s798yhegrq2kgb7bcan7e1
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionFork.swift, Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift
    - next: review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftPM note "missing creator for mutated node" for the mlx bundle). `timeout 1800 swift test --skip-build`: 2460 tests in 256 suites passed, 0 failures, 1 known issue (HarnessSmokeTests, by design), 0 skipped.
    - next: review
  timestamp: 2026-11-19T06:18:12.817376+00:00
depends_on:
- 01M7RWC0Q3R664RM3W2AGKNBVR
position_column: doing
position_ordinal: '8180'
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

## Review Findings (2026-11-18 23:56)

> Scope: `review sha 26fe29c~1..26fe29c` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:182` `completeness/public-output-contract` — The new call `try registerProject(of: placement)` runs after `directory.fork(forkRequest)` has already created the fork and mounted it in the session table. If the project file save throws, `openFork` throws. The client gets an error, but the fork stays live with no response and no cleanup. Before this change, this path completed. The `launchFork` catch block releases the surface on failure, but that catch does not cover this later throw point. The same gap also applies to the existing `internalError` throw at line 179, so the new throw adds to a pattern that already exists. Move `registerProject(of:)` before the fork is created, or make the failure path close the fork and release its surface, as `launchFork` does. If the project save error should not fail the request, log it and continue, and say so in the doc comment at lines 172-173.

## Review Findings (2026-11-19 00:08)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1463` `test-integrity/no-test-cheating` — The test named aForkWhoseProjectSaveFailsGetsAnError asserts only that some error is thrown (`(any Error).self`). It does not check that the error is the project save failure. The test would pass if the fork failed for an unrelated reason, so it does not prove the save-failure path. This is a weakened assertion. Assert the specific error the project store save raises, or at least the specific error type the agent maps the save failure to, and check it the same way line 1499 checks its error code.
- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1475` `test-integrity/no-test-cheating` — `_ = try? await Self.fork(fixture)` discards the fork error. The following assertion (the session table holds only the source) also passes if the fork never ran, for example because of a broken fixture or an unrelated early failure. The test does not prove that the project save failure caused the missing fork. This is a swallowed failure. Assert that the fork throws the expected save error first, for example with `await #expect(throws:)`, and then check the table. The table check then proves the cleanup after that specific failure.
- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1512` `test-integrity/no-test-cheating` — `_ = try? await Self.fork(fixture)` discards the fork error. The following assertion (the session table holds only the source) also passes if the fork never ran, so it does not prove that the unmounted-fork path caused the clean table. This is the same swallowed failure as the save-failure tests. Assert that the fork throws the internal error first, for example with `await #expect(throws:)` on `RequestError.self` with `.internalError`, and then check the table.
- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1538` `test-integrity/no-test-cheating` — `_ = try? await Self.fork(fixture)` discards the fork error. The assertion that no live fork remains in the directory passes if the fork fails for any reason, so it does not prove that the no-agent-surface path closed the fork. Assert the specific error the no-surface build produces before checking the directory, so the empty live-fork list is tied to that failure.
- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1587` `reuse/reuse` — The new helper liveForks(in:) repeats the query of the existing helper forks(in:) at line 580. The only difference is the flag includesRecorded, which the new helper leaves out. A near-match should be extended with a parameter, not copied. Two copies of one sessions(matching:) call can drift apart. Give forks(in:) a parameter, for example `forks(in fixture:, includesRecorded: Bool = true)`, and build liveForks on it with includesRecorded: false. Or delete liveForks and call the extended helper in the new tests.
- [x] `Tests/FoundationModelsACPAgentTests/SessionForkHandlerTests.swift:1594` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.