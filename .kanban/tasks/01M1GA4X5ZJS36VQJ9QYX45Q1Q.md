---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gmtc0wr6v8wq8zt2vgxme2
  text: |-
    ## Verification — where the nested settlement is lost

    Checkout: FoundationModelsRouter at 87c660b (git rev-parse confirms the pin).

    The loss is in Router. Multitool selects the path. The trace, with file:line evidence in the pinned checkouts:

    1. Multitool mounts an inner tool through the default overload: FoundationModelsMultitool/Sources/FoundationModelsMultitool/Invocation/RunBinding.swift:156 `context.mount(tool, op: journalOp, as: innerMount)`. This overload posts each mounted-run event through `MountedRunUpstreamSink` (FoundationModelsRouter/Sources/FoundationModelsRouter/Hosting/ToolContext.swift:300 and 429-431).
    2. `ToolContext.post(_:)` re-stamps each event with the mounting runCode run's tool, op, and completionToken (ToolContext.swift:131-143). The nested run's own token does not go upstream.
    3. The re-stamped terminal reaches the mounting run's `RunEventFunnel.post(event:)`. A background mount returns its envelope at once, thus the mounting run settles first. The funnel drops the second terminal: ToolRun.swift:311 `guard !hasDeliveredTerminal else { return }`. The session outbox never receives a terminal for the nested run. Router documents this exact drop as intended behavior (ToolContext.swift:267-274).
    4. `runSettled` fires only in the journal, on outbox delivery of a `.completed` event (RoutedSessionActorRunJournal.swift:16-18). Without the drop, the copy also fails: it carries the outer correlationID, and `claimJournalWrite` admits one terminal for each correlation (RoutedSessionActorRunJournal.swift:41-44). The outer run's own terminal claims that correlation first.
    5. The true terminal, with the nested token and the real outcome, goes only to the mailbox: BackgroundToolRunner.swift:120-127 `settling: Task { await work.value.terminal }`. The mailbox does not forward it to the outbox. Only `close()`'s sweep writes the nested token to the journal, at session end.

    Why this package cannot repair it alone, without fake data:

    - The one nested-run signal this package receives is the terminal stream's `.completed` marker (FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Shell/OutputChunkStream.swift:90-103). The marker says only "the run ended". It carries no outcome. A cancelled run and a failed run send the same marker.
    - Multitool's doc tells the host to read the `CommandRecord` back for the authoritative status (OutputChunkStream.swift:98-102). But `CommandRecord` and `ShellState.record(commandID:)` are internal (ShellState.swift:45 and 477). The host cannot read them.
    - Plan.md §8.4 maps the settlement status from the terminal event's outcome (succeeded → completed, cancelled → cancelled, failed → failed; EventProjection.wireStatus applies this map). An unconditional synthesized `completed` status reports a cancelled or a failed run as completed. That is a settlement the events do not carry.

    Decision: the fix must land upstream in Router (path 2b). The card stays in todo.
  timestamp: 2026-09-02T08:47:23.676226+00:00
- actor: claude-code
  id: 01m1gmv6g4d6ned9qfx7abbx3j
  text: |-
    ## Upstream ask

    Filed as Ask 5 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md.

    The ask: forward a nested background run's terminal `OperationEvent` to the session outbox under the run's own `completionToken`, so that `runSettled` fires for nested runs too. The exact code path that drops it, at Router commit 87c660b:

    - The nested run's terminal goes up through `MountedRunUpstreamSink.post` (Hosting/ToolContext.swift), because Multitool's `RunBinding` mounts inner tools through the re-stamping `ToolContext.mount(_:op:as:)` overload (Invocation/RunBinding.swift).
    - `ToolContext.post(_:)` re-stamps the event with the mounting run's stamps (Hosting/ToolContext.swift). The nested run's own token does not go upstream.
    - The mounting run's `RunEventFunnel.post(event:)` drops the copy, because the mounting run already delivered its own terminal (Hosting/ToolRun.swift).
    - `runSettled` fires only in the journal, on outbox delivery of a `.completed` event (Session/RoutedSessionActorRunJournal.swift). The mailbox holds the true terminal but does not forward it (Hosting/BackgroundToolRunner.swift).

    Possible seam named in the ask: at mailbox settlement, hand the terminal to the outbox journal in the way the `close()` sweep already does. `claimJournalWrite(for:)` refuses a duplicate terminal for each correlation, thus the write is safe.
  timestamp: 2026-09-02T08:47:50.788211+00:00
- actor: claude-code
  id: 01m1gmvfkk2w1w05v9w5j9sfft
  text: |-
    ### finish — stuck
    - evidence: The fix must land upstream in Router. File:line evidence at the pinned checkouts (Router 87c660b): the nested run's terminal is re-stamped by ToolContext.post (Hosting/ToolContext.swift:131-143) after MountedRunUpstreamSink.post (ToolContext.swift:429-431), selected by Multitool RunBinding.swift:156; the mounting run's funnel then drops it at ToolRun.swift:311; runSettled fires only on outbox delivery (RoutedSessionActorRunJournal.swift:16-18), and claimJournalWrite admits one terminal per correlation (RoutedSessionActorRunJournal.swift:41-44); the mailbox holds the true terminal but does not forward it (BackgroundToolRunner.swift:120-127). This package's one signal, the shell stream's `.completed` marker (Multitool OutputChunkStream.swift:90-103), carries no outcome, and the authoritative CommandRecord is internal (ShellState.swift:45, 477) — a synthesized `completed` status is a settlement the events do not carry. The ask is filed as Ask 5 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md and repeated on this card under "## Upstream ask". No code change and no commit. The card stays in todo.
    - next: When Router lands Ask 5, map the nested run's `runSettled` through the existing projectSettlement path (Sources/FoundationModelsACPAgent/Agent/EventProjection.swift) and restore the `completed` assertion in tier-2 proof 7 (Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift, aStreamedShellRunRidesTheTerminalStreamAndConverges).
  timestamp: 2026-09-02T08:48:00.115854+00:00
- actor: claude-code
  id: 01m1jrk1y4fshz9n7xgp1gm0aw
  text: |-
    ## Verification — the upstream fix landed (Router ba55154, Multitool 03e43bb)

    Ask 5 is answered. Router commits cbe41e1 and 6ddc873 forward a settled run's terminal from the mailbox to the outbox journal. The new path, with file:line evidence at Router ba55154:

    1. `BackgroundToolRunner` gives the mailbox a `settling` task that resolves to the run's true terminal, with the run's own `completionToken` (Hosting/BackgroundToolRunner.swift, unchanged seam).
    2. `SessionMailbox.track` awaits `settling.value`, then `markSettled(completionToken:terminal:)` retains the bounded terminal (Hosting/SessionMailbox.swift:148-153, :370-372). A run the sweep already removed returns `nil` and is not forwarded.
    3. `forwardToSettlementObserver(_:)` hands the terminal to the attached `BackgroundRunSettlementObserver` (Hosting/SessionMailbox.swift:400-401). The protocol is in Session/OperationEventJournal.swift:147.
    4. `RoutedSessionActor` is that observer (Session/RoutedSessionActorRunJournal.swift:86). `deliver(settledTerminal:)` calls `outbox.journalWithoutStaging(event:)` (RoutedSessionActorRunJournal.swift:96-97; Session/SessionOutbox.swift:130-132).
    5. The journal write reaches `record(event:)`, which fires `deliverLive(.runSettled(event))` for a `.completed` event (RoutedSessionActorRunJournal.swift:13-19). `claimJournalWrite` still refuses a second terminal for the same correlation (RoutedSessionActorRunJournal.swift:45-48), so a top-level run whose funnel already delivered its terminal is not journaled twice.

    Router's own proof: Tests/FoundationModelsRouterTests/NestedRunTerminalForwardingTests.swift asserts "a run mounted through mount(_:op:as:) produces exactly one runSettled under its own token, without close()" (line 239) and decodes the nested token from the outer terminal detail (lines 210-213). UPSTREAM_ASKS.md records the answer under Ask 5, with the known limit: a run the `close()` sweep already removed drops its late natural terminal.

    Next: TDD in this package — restore the `completed` assertion in tier-2 proof 7, watch the run, adjust `EventProjection.projectSettlement` only if needed.
  timestamp: 2026-09-03T04:31:47.140907+00:00
- actor: claude-code
  id: 01m1jrwma3tcwwf33s8rmt7kwv
  text: |-
    ## Implementation — the test pins the forwarded settlement

    TDD note: the strengthened assertion did not fail, because the upstream fix alone completes the path. The historical RED is on this card: at Router 87c660b the settled status never arrived, and the assertion was removed for that reason (the comment in proof 7 marked it). At Router ba55154 the test passes in 0.7 s, so the settled status arrives promptly — a wait that never settles would burn the full 10 s poll budget and record an issue.

    Changes, both in the unit test target:

    1. Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift — proof 7 (`aStreamedShellRunRidesTheTerminalStreamAndConverges`) now waits for the container to hold the settled `completed` status, then asserts `settledCall.status == .value(.completed)` beside the existing Terminal-reference assertion. The "not asserted here" comment is gone.
    2. Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift — new bounded wait `waitForCompletedToolCall(of:sessionId:id:)`, in the fixture's Waits section beside `waitForAvailability`. It polls `ACPSessionState.toolCalls[id].status` on the MainActor with the fixture's shared poll constants, because the settlement rides `runSettled` and can land after the terminal exit report, and because the recording client appends to the collector before it applies the update to the client state — a collector wait alone can read the state one apply early.

    `EventProjection.projectSettlement` needed no change: it already maps a `.completed` event with a `succeeded` outcome to `status: .value(.completed)` keyed by `toolCallId = correlationID` (Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:375-417), and the nested run's forwarded terminal carries the run's own token, which is the terminalId. The test proves the whole path.

    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift; `swift test --filter TierTwoTests/aStreamedShellRunRidesTheTerminalStreamAndConverges` passed (1 test)
    - next: run the full test step
  timestamp: 2026-09-03T04:37:00.867672+00:00
- actor: claude-code
  id: 01m1jrxnpc5cxp24x8dfkfbmsc
  text: |-
    ### test — green
    - evidence: `swift test` — 352 tests in 39 suites passed, 0 failures, 0 skipped, 1 known issue (the expected withKnownIssue in HarnessSmokeTests). `swift build --build-tests` shows no compiler warning in the changed files; the one "missing creator for mutated node" line is the pre-existing mlx-swift bundle build-system note, present before this change.
    - next: commit
  timestamp: 2026-09-03T04:37:35.052982+00:00
- actor: claude-code
  id: 01m1jry3xx2djnxqnd9eyryd5p
  text: |-
    ### commit — changed
    - evidence: fc1544b test(tier-two): restore the completed-status assertion in the streamed-shell proof (^yx45q1q) — 4 files, 91 insertions, 12 deletions; local only, not pushed
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-03T04:37:49.629163+00:00
- actor: claude-code
  id: 01m1js18v9ypm5106001dg84dj
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 7 attempted, 0 failed; the two .kanban files were excluded by .reviewignore. No prior findings sections on the card. Task moved to done.
    - next: finish ledger
  timestamp: 2026-09-03T04:39:32.969624+00:00
- actor: claude-code
  id: 01m1js1fqjy3scfk59n0k3pbcz
  text: |-
    ### finish iteration 1 — done
    - Verified: the upstream fix landed at Router ba55154 (commits cbe41e1 and 6ddc873, Ask 5 answered in UPSTREAM_ASKS.md). The mailbox forwards a settled run's terminal to the outbox journal, and `runSettled` fires under the run's own completionToken.
    - implement — changed: proof 7 asserts `settledCall.status == .value(.completed)` behind the new bounded wait `ScriptedTurnFixture.waitForCompletedToolCall`. `EventProjection` needed no change; the test pins the behavior.
    - test — green: swift test — 352 tests in 39 suites, 0 failures, 0 skipped, 1 expected known issue; no new warnings.
    - commit — changed: fc1544b, local only.
    - review — clean: 0 findings on HEAD~1..HEAD.
    - Both acceptance boxes checked. Card in done.
  timestamp: 2026-09-03T04:39:40.018036+00:00
position_column: done
position_ordinal: a180
title: Forward a nested background run's settlement to the wire
---
## What
The tier-2 streamed-shell proof (task ^qg1rfct) found this gap: a nested background run — `tools.shell.execute` started inside a `runCode` snippet — never gets a `runSettled` event on the session stream. The run completes, `wait` collects its result, the terminal stream reports the exit, but no terminal `tool_call_update` with `status: completed` reaches the client. The call stays `in_progress` in `ACPSessionState.toolCalls` forever.

The outer `runCode` run's own settlement DOES reach the wire, so the forwarding works for runs the turn's context starts directly. Only the nested run's terminal event is lost.

## Why
Plan.md §8.4 maps `runSettled(OperationEvent)` to the terminal `tool_call_update`, and §11.6 wants the settlement replace as the convergence step. A client that shows the run as still running after it ended is wrong.

## How
- Trace where a nested run's terminal `OperationEvent` goes in Router's context forks (`ToolContext` mailbox and outbox).
- Decide with the Router or Multitool owners whether the fix is upstream (forward nested run events to the session outbox) or in this package.
- Then restore the `completed` status assertion in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` proof 7 (see the comment in `aStreamedShellRunRidesTheTerminalStreamAndConverges`).

## Acceptance Criteria
- [x] A nested shell run's terminal `tool_call_update` with `status: completed` reaches the client before or after the turn end
- [x] Tier-2 proof 7 asserts `ACPSessionState.toolCalls[id].status == completed` and stays green