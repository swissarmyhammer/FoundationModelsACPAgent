---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1xskqev973b7zkjdan6mjcs
  text: |-
    ## Research — the two repositories, and what each side can prove

    ### Router side (`/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`)

    - `Router` is a `public actor`. `resolve(profile:reporting:)` (Router.swift:228)
      opens a span and calls `runResolve` (:254).
    - `runResolve` takes the single-flight permit with `await poolLock.wait()`
      (:259) and gives it back in a `defer`. `poolLock` is
      `AsyncSemaphore(value: 1)` (:148).
    - Stage order: `beginSizing` -> `hostBudget` -> `sizeCandidates` (one `await`
      per candidate) -> `JointFit.resolve` (pure, synchronous) -> `markChosen` ->
      acquire standard, flash, embedding -> preload each fresh key -> build the
      profile.
    - `metadataResult` (:556) turns EVERY non-`RepoMetadataError` into
      `.failure(.metadataUnavailable(...))`. A `CancellationError` raised by the
      metadata read is swallowed there and becomes a `ResolutionFailure`. This is
      the sharpest edge of the sizing stage.
    - `recordLoadFailure` (:1037) stringifies the error into `Phase.failed`, so a
      cancelled resolve reads `.failed("CancellationError()")` today.
    - `ModelLoader` (Resolution/ModelLoader.swift:88) is the seam a test stubs.
      `Router.init(loader:)` takes it. Nothing in the resolve path removes a file,
      so "leave the part files" is a property to prove and to write down, not a
      deletion to remove.
    - `AsyncSemaphore.wait()` has 45 call sites across the package. Its doc says it
      is non-interrupting on purpose, and
      `AsyncSemaphoreTests.cancelledWaiterDoesNotLeakOrStrand` (:150) asserts that.
      `Tests/.../Helpers/AwaitedEvent.swift:25` records the same decision.
      This card orders the opposite, so both the test and both doc comments change
      with it.
    - Test command: `swift test` at the repository root.

    ### Agent side (`/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent`)

    - `Package.swift` pins `FoundationModelsRouter` as
      `.package(url: "git@github.com:swissarmyhammer/FoundationModelsRouter.git",
      branch: "main")`, and `Package.resolved` pins revision `bd8b6ff`, which is
      the current local Router `main` HEAD. A local Router commit is therefore
      invisible to this repository until it is pushed, and I must never push.
    - The chain is `Run.run()` -> `perform` -> `compose` ->
      `AgentComposition.compose` -> `RoutedACPAgent.init` ->
      `ProfileConfiguration.resolveResident` -> `Router.resolve`.
    - `InterruptHandler` (Sources/acp-agent/InterruptHandler.swift) is armed only
      by `RunTurn.drive` (RunTurn.swift:141), after the wire is open. Composition
      runs before that, with `SIGINT` at its killing default. `Acp.run()` arms
      nothing at all.
    - `Tests/.../InterruptTests.swift:205` pins the signal handler body by literal
      source text, so the handler body itself must not change.

    ### The finding that unblocks the agent side

    The agent side does NOT need the new Router symbols. A `SIGINT` that cancels
    the composition `Task` reaches a `ModelLoader` conformance the AGENT owns, and
    a `Task.sleep` inside that loader throws `CancellationError` on the pinned
    Router with no change at all. `Router.runResolve` already rethrows a loader
    error. So both agent-side acceptance criteria — exit 4, and the part files
    stay — can be proved against the pinned revision.
  timestamp: 2026-09-07T11:21:16.507589+00:00
- actor: claude-code
  id: 01m1xw21ycy0gf2vpyqrb3q6km
  text: |
    ### finish — stuck

    - blocker: this card names work in the `FoundationModelsRouter` repository. The user stopped that work and gave a standing rule: a change in a sibling package needs a task on that project, discussed first. No Router file was changed. The Router working copy is clean at `bd8b6ff`.
    - blocker: this repository cannot prove the Router behaviour anyway. `Package.swift` pins every family package as a remote dependency on `main`, so the agent side builds against the published Router.
    - state: 9 files of agent-side work stay uncommitted in this repository at the user's request. They are `Sources/acp-agent/InterruptibleComposition.swift` and `Tests/FoundationModelsACPAgentTests/CompositionInterruptTests.swift`, both new, plus edits to `Sources/acp-agent/AcpCommand.swift`, `Sources/acp-agent/InterruptHandler.swift`, `Sources/acp-agent/RunCommand.swift`, `Tests/FoundationModelsACPAgentTests/InterruptTests.swift`, `cli-plan.md` and this card's two `.kanban/` files.
    - next: the user decides what task goes on the Router board. The four pieces are the stage checks in `runResolve`, a cancellable `AsyncSemaphore.wait()`, cancellation carried into the transfer with the part files kept, and a cancelled phase on `ResolutionProgress`.
    - the card stays in `doing`, so the batch does not pick it up again.
  timestamp: 2026-09-07T12:04:03.148349+00:00
- actor: claude-code
  id: 01m1xwz5vszkje3gjpakr0fx2f
  text: |
    ### blocked — the Router work is now on the Router board

    The agent side of this card is written and it is not committed: `Sources/acp-agent/InterruptibleComposition.swift` and the other eight files stay in the working tree, as the user instructed.

    The code is inert until `Router.resolve` obeys a cancel. Two cards on the FoundationModelsRouter board carry that work:

    - `^h59152d` — Stop Router.resolve when the caller cancels the Task. It covers the stage checks in `runResolve` (Router.swift:254), a cancellation path in `AsyncSemaphore.wait()` (Concurrency/AsyncSemaphore.swift:34, the pool lock at Router.swift:148), and the cancel carried into the download (Resolution/LiveModelLoader.swift:433 and :446) with the part files kept in the Hugging Face cache.
    - `^dpq4yxk` — Add a cancelled phase to ResolutionProgress (Resolution/ResolutionProgress.swift:74-85). It depends on `^h59152d`.

    No Router file was changed from this repository. Each family package is a remote dependency pinned to `main` in `Package.swift`, so this card can continue only after the Router cards land and the pin moves.
  timestamp: 2026-09-07T12:19:57.433843+00:00
- actor: claude-code
  id: 01m1y44bxja1gfrj6cr9461e3s
  text: |
    ## The Router half landed upstream, and the pin moved

    `swift package update` moved the `FoundationModelsRouter` pin to `main` at
    `7360e20`. `.build/checkouts/FoundationModelsRouter` holds the cancellation
    work, and I read the API shape there. Two commits carry the four Router
    boxes:

    - `4ca1ad5` `fix(router): stop Router.resolve when the caller cancels the
      Task` (card `^h59152d`). It adds the stage checks in `runResolve`, a
      cancellation path in `AsyncSemaphore.wait()` with the new
      `Sources/FoundationModelsRouter/Concurrency/CancellableWait.swift`, and
      the cancel carried into `Resolution/LiveModelLoader.swift`. It brings
      `Tests/FoundationModelsRouterTests/ResolveCancellationTests.swift`, which
      proves the throw at each stage — sizing, generation acquire, embedding
      acquire, preload, and a waiter queued on the pool lock.
    - `ab9f2de` `feat(resolution): add cancelled phase to ResolutionProgress`
      (card `^dpq4yxk`). It adds `ResolutionProgress.Phase.cancelled`, which
      carries no message, and makes `phases` finish on it.

    No file of the Router repository was changed from here.

    ## What the pin move asks of this repository: nothing

    `Phase.cancelled` is a new case on a public enum. No file of this
    repository switches over `ResolutionProgress.Phase`. The only readers are
    `Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift`,
    which takes a `ResolutionProgress` as a parameter, and
    `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift`, which makes one.
    So the new case breaks no build here.

    ## The one constraint the agent side must obey

    `ProfileConfiguration.resolveResident(fallbackName:router:reporting:)`
    catches `any Error` and rewraps it as `ProfileResolutionError`. A
    `CancellationError` from `Router.resolve` therefore never reaches the CLI
    as itself. `InterruptibleComposition.run(interruptedBy:_:)` reads the
    composition task's own `isCancelled` flag instead of the error type, which
    is why an interrupted composition is reported as `CompositionInterrupted`
    and not as a resolution failure.

    ## Both compose sites are covered

    `AgentComposition.compose` has two production call sites, and each now
    stands inside the composition watch:

    - `Sources/acp-agent/RunCommand.swift` — `perform` returns the `cancelled`
      stop reason, and `exitCode(of:)` maps that to exit 4.
    - `Sources/acp-agent/AcpCommand.swift` — `run()` throws
      `ExitCode(InterruptHandler.cancelledExitCode)`.
  timestamp: 2026-09-07T14:25:07.506381+00:00
- actor: claude-code
  id: 01m1y993x41pjh6hyz72f85t2g
  text: |
    ## What this pass added to the work already in the tree

    The earlier run left `InterruptibleComposition`, `CompositionInterruptTests`
    and the edits to the two command files, `InterruptHandler`, `InterruptTests`
    and cli-plan.md. This pass finished them:

    - **One arrival loop, not two.** `InterruptibleComposition` repeated the
      ordinal contract of `RunTurn.react(to:cancelling:over:)` word for word —
      the same `for await`, the same `guard ordinal == firstArrival`, the same
      `endAtOnce()`. Only the one statement under the guard differed. The
      contract now stands once, in
      `InterruptHandler.react(to:stoppingWith:)`, and both windows call it.
      `RunTurn.react(to:cancelling:over:)` keeps its signature, so
      `InterruptTests.theInterruptSendsSessionCancelToTheAgent` is unchanged.
    - Removed a `Task` wrapper in
      `aFirstInterruptDuringTheDownloadEndsTheRunCancelled` that was made and
      immediately awaited. The case now awaits `perform` directly, as its
      sibling case does.
    - Named the park duration's seconds count, so no literal stands in a call
      argument. It follows the pattern the tier-3 `InterruptTests` already
      uses for `firstOutputLimitSeconds`.

    ## The signal handler body is unchanged

    `InterruptTests.theSignalHandlerBodySetsTheFlagAndResumesTheContinuation`
    reads the source text between `source.setEventHandler {` and the first
    closing line. The new `react` stands above `endAtOnce()`, far from that
    handler, and the two-statement body is untouched.

    ## Lint and format

    Both gates the review validators use are clean over the seven changed
    Swift files:

    - `swiftlint` over `force_unwrapping`, `implicitly_unwrapped_optional`,
      `force_try`, `force_cast`, `unused_optional_binding`,
      `unowned_variable_capture`, the three legacy rules,
      `function_body_length`, `closure_body_length`, `no_magic_numbers`
      (allowed 0, 1, -1, 100) and `missing_docs`: 0 violations in 7 files.
    - `swiftformat --lint` over the idiom roster: 0 of 7 files require
      formatting.

    ## Test evidence

    - Root: `swift test` — 428 tests in 45 suites passed, 1 known issue. The
      known issue is the `withKnownIssue` at
      `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`.
      `CompositionInterruptTests` contributes 4 cases, all passing.
    - Nested: `swift test --package-path IntegrationTests --no-parallel` —
      30 tests in 8 suites, 4 issues, all four the same known live-model
      defect at
      `IntegrationTests/.../Evaluations/PythonCLIEvaluation.swift:335`
      (`mean >= pythonCLIEvalMeanFloor`, every sample reading `tokens=0/0`),
      card `^pez780d`. The tier-3 `InterruptTests` suite, which sends a real
      `SIGINT` to a real `acp-agent`, passed both cases.
    - The only build message is
      `warning: missing creator for mutated node: (...mlx-swift_Cmlx.bundle...)`,
      which the build system writes and no source causes.

    ## The pin needs no commit

    `Package.resolved` is in `.gitignore`. `Package.swift` pins
    `FoundationModelsRouter` to `branch: "main"`, so the move to `7360e20`
    carries no file change in this repository.
  timestamp: 2026-09-07T15:55:06.020432+00:00
- actor: claude-code
  id: 01m1y99b1xk00tesva1x7z1a7r
  text: |
    ### implement — changed

    - evidence: 9 files. New: `Sources/acp-agent/InterruptibleComposition.swift`,
      `Tests/FoundationModelsACPAgentTests/CompositionInterruptTests.swift`.
      Changed: `Sources/acp-agent/InterruptHandler.swift`,
      `Sources/acp-agent/RunTurn.swift`, `Sources/acp-agent/RunCommand.swift`,
      `Sources/acp-agent/AcpCommand.swift`,
      `Tests/FoundationModelsACPAgentTests/InterruptTests.swift`, `cli-plan.md`,
      and this card's two `.kanban/` files. No file of any sibling repository
      was changed, and nothing was pushed.
    - tests: root `swift test` — 428 tests in 45 suites passed, 1 known issue
      (`HarnessSmokeTests` `withKnownIssue`). Nested
      `swift test --package-path IntegrationTests --no-parallel` — 30 tests in
      8 suites, 4 issues, all the known `PythonCLIEvaluation.swift:335`
      live-model defect, card `^pez780d`.
    - lint: `swiftlint` 0 violations in 7 files; `swiftformat --lint`
      0 of 7 files require formatting.
    - boxes: all ten are ticked. The four Router boxes cite `4ca1ad5` and
      `ab9f2de` on `FoundationModelsRouter` `main`, which this repository pins
      at `7360e20`.
    - next: `/review`.
  timestamp: 2026-09-07T15:55:13.341613+00:00
- actor: claude-code
  id: 01m1y9k0xkd1bzen5d2g91dabc
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on the commit `477a3d0`. 7 files reviewed, 0 findings, 0 confirmed, 0 refuted, 0 failed. 4 kanban files and `cli-plan.md` were not reviewed: an ignore rule and no matching validator.
    - next: none. The card moves to `done`.
  timestamp: 2026-09-07T16:00:30.643283+00:00
- actor: claude-code
  id: 01m1y9kw22yyt053m20kz7j9w0
  text: |
    ### finish iteration 1 — clean

    - implement: changed — 9 files. `Sources/acp-agent/InterruptibleComposition.swift` and `Tests/FoundationModelsACPAgentTests/CompositionInterruptTests.swift` are new. The ordinal contract now stands one time only, in `InterruptHandler.react(to:stoppingWith:)`, and the turn window and the composition window both call it. The four Router boxes are ticked, with the upstream commits `4ca1ad5` and `ab9f2de` named.
    - test: root `swift test` — 428 tests in 45 suites passed with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`. Nested `swift test --package-path IntegrationTests --no-parallel` — 30 tests in 8 suites with 4 issues, all four the known live-model zero-token defect at `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Evaluations/PythonCLIEvaluation.swift:335`, card `^pez780d`. Both are exceptions that this card names, and this change did not cause either one. `swiftlint` gives 0 violations in 7 files. `swiftformat --lint` gives 0 of 7 files that need a change.
    - commit: `477a3d0` `feat(acp-agent): stop the model download with the first Ctrl-C`
    - review: clean — `review sha HEAD~1..HEAD`, 7 files reviewed, 0 findings.

    Necessary conditions before this iteration: the two Router cards `^h59152d` and `^dpq4yxk` became done and were pushed, and `swift package update` moved the pin to `main` at `7360e20`.

    One fact to carry: `ProfileConfiguration.resolveResident` catches `any Error` and puts it in a `ProfileResolutionError`. Thus a `CancellationError` from `Router.resolve` does not reach the CLI as itself, and `InterruptibleComposition` reads the composition task's own `isCancelled` flag in its place.
  timestamp: 2026-09-07T16:00:58.434953+00:00
position_column: done
position_ordinal: b480
title: 'Router: make resolve honour Task cancellation, so Ctrl-C can stop a download'
---
### What

`FoundationModelsRouter`'s `Router.resolve(profile:reporting:)` did not
honour Task cancellation. A caller that cancelled the task kept waiting
until the whole sizing, download and load pipeline ended. For a 15 GB
profile that is many minutes.

This card was raised out of `^0t67p98` ("Interrupt: Ctrl-C sends
session/cancel and exits 4"). cli-plan.md §5.9 claimed that the first
`Ctrl-C` stops a resolution and exits 4. The runtime could not do that
then, so `^0t67p98` dropped the download case and this card carries
it.

### The evidence

The state that raised this card, read at the revision
`FoundationModelsACPAgent` pinned then:

- `Sources/FoundationModelsRouter/Router.swift` held zero occurrences
  of `Task.checkCancellation()`, `Task.isCancelled` and
  `withTaskCancellationHandler`.
- The count was zero as well in every file of `Resolution/`, `Sizing/`,
  `Core/` and `Concurrency/`.
- Every cancellation check the package had was in `Session/` and in
  `Hosting/ToolRun.swift` — the turn path, not the resolve path.
- `AsyncSemaphore`, the single-flight gate of the resolve, had no
  cancellation handler, so a cancelled task that waited on it kept
  waiting.

### The work, in the Router repository

Done upstream on `FoundationModelsRouter` `main`, and pushed. This
repository pins `main` at `7360e20`, which holds both commits. No file
of the Router repository was changed from here.

- [x] Check for cancellation between the stages of `runResolve`:
      sizing, metadata read, each acquire, each preload.
      Commit `4ca1ad5` `fix(router): stop Router.resolve when the
      caller cancels the Task`, card `^h59152d`.
- [x] Give `AsyncSemaphore.wait()` a cancellation path, so a cancelled
      waiter leaves the queue and throws `CancellationError`.
      Commit `4ca1ad5`, with the new
      `Sources/FoundationModelsRouter/Concurrency/CancellableWait.swift`.
- [x] Carry cancellation into the download: the loader must stop the
      transfer and leave the part files in the Hugging Face cache.
      Remove nothing on the way out, so the next run continues.
      Commit `4ca1ad5`, in `Resolution/LiveModelLoader.swift`.
- [x] Report the resolve as cancelled through `ResolutionProgress`, so a
      frontend can draw the end of the bar.
      Commit `ab9f2de` `feat(resolution): add cancelled phase to
      ResolutionProgress`, card `^dpq4yxk`. `Phase.cancelled` carries no
      message.

### The work, back in this repository

- [x] Return the download paragraph to cli-plan.md §5.9.
- [x] Extend `InterruptHandler` to the resolve window: a `SIGINT` before
      the wire opens cancels the composition task and exits 4.
- [x] A test that a `SIGINT` during a resolve exits 4, and that the part
      files stay in the cache.

### Acceptance Criteria

- [x] A cancelled task in `Router.resolve(profile:reporting:)` throws
      `CancellationError` inside a named time limit.
- [x] The partly downloaded files stay in the Hugging Face cache after a
      cancelled resolve.
- [x] `acp-agent` exits 4 on a `SIGINT` during a download.
