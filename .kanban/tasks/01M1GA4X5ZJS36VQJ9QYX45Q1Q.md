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
position_column: todo
position_ordinal: a080
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
- [ ] A nested shell run's terminal `tool_call_update` with `status: completed` reaches the client before or after the turn end
- [ ] Tier-2 proof 7 asserts `ACPSessionState.toolCalls[id].status == completed` and stays green