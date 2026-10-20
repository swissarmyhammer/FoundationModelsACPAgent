---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dhks8qq11m5q2dfgcenmy5
  text: |-
    ### Research: the parent context cannot cross the Router mail boundary from this repo (Router checkout at .build/checkouts/FoundationModelsRouter)

    How a mail wake gets its parent today:
    - `RoutedSessionActor.beginSubmission(cause:mailIds:)` (RoutedSessionActorSubmissionEvents.swift) opens `FoundationModelsRouter.submission` with `context: ServiceContext.current ?? .topLevel`.
    - The pump that calls it is a `Task.detached` (RoutedSessionActor.swift docs), so no task-local of this repo reaches it.
    - `runAnswer(of:workId:)` (RoutedSessionActorPump.swift) binds `ServiceContext.$current` to `callerContext = batch.userMail.first.flatMap { callers[$0.id]?.serviceContext }`. Only user-type mail counts.
    - Run mail (`MailBody.runEvent`) is put by `SessionOutbox.stage(event:as:)` with `queue.put(Mail(... body: .runEvent(event)))`. It records no `MailCaller` at all (`noteCaller` is only called in `RoutedSessionActor.mail(_:)`).
    - So a batch of only run mail (cause `mail`, as in telemetry-16 django__django-13447, submission id 4) always runs with `ServiceContext.current == nil` and starts a new root trace. Nothing the ACP agent does (a work span, a task-local, `afterRespondingInCurrentInstrumentationContext`) can reach it.

    Rejected in-repo workaround: pass `Router(tracer:)` a decorating tracer that reparents top-level `FoundationModelsRouter.submission` spans onto an ACP work span. The tracer is per Router (shared by every session), `startSpan` sees only the span name and a context (the session attributes are set after), so it cannot tell which ACP session the span belongs to. It would also hard-code Router span names. That fakes parentage; not done.

    What Router needs (for the Router session to own):
    1. A parent for a submission that no user-type mail starts. One of:
       a. a host-set work context on the session, e.g. `RoutedSession.setWorkContext(_ context: ServiceContext?)` (or a per-session `ServiceContext` in `SessionConfiguration`), that `runAnswer` uses when `callerContext` is nil; the ACP agent would set it to the context of its `FoundationModelsACPAgent.session.work` span at the prompt and clear it at no-work; or
       b. `SessionOutbox.stage(event:as:)` keeps the `ServiceContext.current` of the poster of the run event (the run task, a descendant of the tool-call span that started the run), and `runAnswer` falls back to the caller context of the first delivered mail that has one.
    2. A span link from each `mail` / `continuation` submission to the span context of each delivered mail's sender (`span.addLink(SpanLink(context:attributes:))`), so a wake joins the run that sent the mail even when its parent is the work span.

    With 1a in place, this card is: open `FoundationModelsACPAgent.session.work` at prompt start (keep `FoundationModelsACPAgent.prompt` as is), hand its context to the Router session, end it where `SessionStateLedger` sends the `idle` with `_meta.noWork`.

    No code changed, no commit. Card stays in doing, stuck on the Router change.
  timestamp: 2026-10-20T20:56:26.135957+00:00
- actor: claude-code
  id: 01m5dhkztary469n3y663cf3q5
  text: |-
    ### implement — stuck
    - evidence: no files changed, no commit, no test run. The Router pump (`Task.detached`) parents a run-mail-only submission on nothing: `runAnswer` takes `callerContext` only from user-type mail, and `SessionOutbox.stage(event:as:)` records no caller for run mail. See the research comment above for the Router change needed.
    - next: the Router session adds a session work context (or a run-mail caller context) plus a span link from a `mail` submission to its sender's span; then this card adds `FoundationModelsACPAgent.session.work` from prompt to no-work.
  timestamp: 2026-10-20T20:56:32.842597+00:00
- actor: claude-code
  id: 01m5dhnbsgn4zx5g3hd4cpmbgz
  text: |-
    ### waits on Router ^yx6931z
    - Router plan (option B): stage(event:as:) saves the poster's ServiceContext. runAnswer falls back to the first delivered mail that has one. Each submission links to the sender context of each delivered mail. No host API.
    - With B, the wake on the coder's mail has the coder run span as its parent, so it is already in the prompt trace. Then the work span here is needed only to time the whole instance (prompt to no-work). Check again when the sha comes. If Router uses setWorkContext(_:) in place of B, this card does the host side as planned.
  timestamp: 2026-10-20T20:57:17.872459+00:00
position_column: doing
position_ordinal: '8280'
title: 'telemetry: one span covers the work of a session from the prompt to no-work, so a mail wake is in the same trace'
---
## The gap (telemetry-16, django__django-13447)

`FoundationModelsACPAgent.prompt` ends when `session/prompt` returns: 20:08:41 to 20:16:20 (459 s, `end_turn`). But the work of the session goes on. The coder agent run (`FoundationModelsAgents.run`, 1035 s) ends at 20:33:19. Then the root session wakes on the agent's mail: `FoundationModelsRouter.submission` (cause `mail`, id 4, 38 s, 20:33:19 to 20:33:57). That submission is a root span in a new trace (`ff8c93…`), with no parent and no link. So the last 17 minutes of the instance are not under the prompt, and the wake on mail cannot be joined to the run that sent the mail.

The headless exit comes from the no-work state of the session, not from the end of a turn (see the work registry). The telemetry must follow the same rule.

## The change

- A span for the work of a session (for example `FoundationModelsACPAgent.session.work`). It starts with the prompt and ends when the session reports no work (the idle `_meta.noWork` event). It is the parent context of each submission that starts while it is open, a submission on mail included.
- Keep `FoundationModelsACPAgent.prompt` as it is: it measures the ACP call.

## Done when

- A failing test first (TDD): a prompt that returns before a child run ends, then a mail wake. Today the wake submission is a root span. After the fix it is in the trace of the work span, and the work span ends at no-work.
- In a bench telemetry file, each `FoundationModelsRouter.submission` of an instance has a parent.

If the parent cannot cross the Router mail boundary from here, ask the Router session for a span link from a `mail` submission to the span that sent the mail. #telemetry