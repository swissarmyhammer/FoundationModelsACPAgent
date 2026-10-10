---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gpcrn9bbf2s3sgrqmv965q
  text: |-
    Context from session foundationmodelsacp-43 (2026-10-09). The Extras display API is done, local, not pushed yet.

    Keep these two rules in the projection:

    1. A nil field means "no change". The `.metadata` event that `ToolContext.update(title:kind:locations:)` makes has `rawInput` nil. In the `tool_call_update` patch, omit each nil field. Do not send `null`: in ACP, `null` clears the field.
    2. Display events of the background grace period are not withdrawn. Thus a `tool_call_content_chunk` can arrive for a run that then settles inline. The projection must accept a content chunk before an inline settlement, and the settlement replace must still be the last update.

    Add a test for each rule.
  timestamp: 2026-10-09T16:02:00.489846+00:00
- actor: claude-code
  id: 01m4hdazy46eebsnkvqbdk82dm
  text: |-
    Status from session foundationmodelsacp-43 (2026-10-09): Router ^twha0gz and ^xhmws92 are done (tests green, reviews clean) in the local Router commits 7f20163b, 1b77ef2b and 29b60440. They are NOT pushed. The user decides the push. Do not start this task before the push.

    After the push:
    1. `SessionEvent` has a new case `.toolDisplay(ToolDisplayEvent)`. It is live on `streamEvents(to:)` and on `streamSessionEvents()`. It is never staged and never journaled. Display events that arrive in the settle period are delivered.
    2. The Router re-exports `ToolDisplayEvent` and `ToolDisplayContent`, so this package needs no new import.
    3. COMPILE BREAK: each exhaustive `switch` on `SessionEvent` (in `Agent/EventProjection.swift`) must add `.toolDisplay`.
    4. The same push also changes `toolInvocation(record)` to `toolInvocation(record, toolCallID:)` (see ^e1yq4gh). Do the two changes in one commit, because both break the build of this package.
  timestamp: 2026-10-09T22:42:59.652452+00:00
- actor: claude-code
  id: 01m4hgxnehr14n8nhv9fwygb5h
  text: 'Upstream status (session foundationmodelsacp-43, 2026-10-09): NOT READY. Extras ^1vhftw2 (23974f0) and ^jt7qx6k (ba381a0, 315c17b, 5ca30c9) are pushed. Router ^twha0gz (29b60440, adds `SessionEvent.toolDisplay`) is done and reviewed but NOT pushed. /finish skips this task until Router 29b60440 is on origin/main.'
  timestamp: 2026-10-09T23:45:37.233618+00:00
- actor: claude-code
  id: 01m4jamzkztr155z38j0dbvqf3
  text: 'Router is pushed (session foundationmodelsacp-43, 2026-10-10): origin/main holds 29b60440 (^twha0gz) and 1b77ef2b (^xhmws92). This task is READY. Run `swift package update FoundationModelsRouter` first. The same Router move also changes `toolInvocation(record)` to `toolInvocation(record, toolCallID:)` (task ^e1yq4gh), and `EventProjection.swift` must compile after the move. Thus, the first of ^a6mndxz and ^e1yq4gh that runs must make both switch arms compile in its commit.'
  timestamp: 2026-10-10T07:15:15.711911+00:00
- actor: claude-code
  id: 01m4jy7wk2ye9q65kcff3wxvxv
  text: |-
    ### FoundationModelsAgents moves with Router (session foundationmodelsagents-3d, 2026-10-10)

    FoundationModelsAgents main is now 016945e, and it uses Router main dc642256. It reads `SessionEvent.toolInvocation(_, toolCallID:)` and handles `.toolDisplay`. The pinned Agents dfd406b was built against the old Router API. Thus, when this task moves the Router pin, move FoundationModelsAgents to 016945e or later in the same update: `swift package update FoundationModelsRouter FoundationModelsAgents` (same gRPC retry rule; no hand edit; no local path override). Report every pin that moves. CI for 016945e was running when this was written; check that session's report first.

    Other changes in Agents 016945e that the agent tests can see:
    - BREAKING: the agents tool of a RUN does not show the run's own agent. "start agent" with its own agent name gives a corrective, and "send agent" with its own run id also gives a corrective. The host root session has no run, so the rule does not apply to it.
    - The agents tool description changed: the model compares each task with each agent description, gives the task to a matching agent, calls "list agents" when no agent matches, and does the task itself only when no agent matches after that. A test that checks the tool description text can need an update.
  timestamp: 2026-10-10T12:57:38.146063+00:00
position_column: todo
position_ordinal: '8680'
title: Project tool display events as tool_call_content_chunk and metadata patches
---
## Goal

Send the tool display events of the Router to the ACP client as the v2 prompt-lifecycle wire shapes (https://agentclientprotocol.com/protocol/v2/prompt-lifecycle). Terminals are out of scope.

## Dependency

This task waits for FoundationModelsRouter task ^twha0gz (01M4GH44FNNNW2WB32CTWHA0GZ) "Forward tool display events as SessionEvent.toolDisplay". It is on the Router board. Do not start before it is on `origin/main` of FoundationModelsRouter.

## What to change

In `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift`:

1. Map `.contentChunk` to `tool_call_content_chunk`.
2. Map `.contentReplace` to a `tool_call_update` that replaces the content.
3. Map `.metadata` to a `tool_call_update` patch with `title`, `kind`, `locations` and `rawInput`.

## Facts

- Now nothing sends `tool_call_content_chunk`. The type is in FoundationModelsACP, `Generated/Models8.generated.swift:862`. The plan names it in §8.4 (`plan.md:1142-1153`).
- Keep the settlement replace as the last step of a tool call, so that the final content is correct (`plan.md:1888-1894`).

## Acceptance

- [ ] A content chunk event gives one `tool_call_content_chunk` on the wire.
- [ ] A content replace event gives a `tool_call_update` with the new content.
- [ ] A metadata event gives a `tool_call_update` patch with `title`, `kind`, `locations` and `rawInput`.
- [ ] The settlement replace is still the last update of a tool call.
- [ ] Each case has a test that reads the wire messages.