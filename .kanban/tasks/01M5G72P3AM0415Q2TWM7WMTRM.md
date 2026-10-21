---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g7anhn1pc6src8t7jt21h5
  text: |-
    Research (FoundationModelsACP 270f9e3):
    - Inbound routing lives in `RoleConnectionCore.init` (Connection/RoleConnectionCore.swift): the `requestHandler` closure throws `RequestError.methodNotFound(method)` for any wire method not in `RoleRouting.served(on:)` (the generated `ACPMethodTable`), and the `notificationHandler` closure silently returns. `AgentSideConnection.serve`/`ClientSideConnection.serve` switch on routing-table handler names only. `Connection` itself is method-agnostic (raw `request(method:params:)` / `notify(method:params:)`).
    - Each connection builds its role via `factory(self)`, so a role object is per connection: a natural home for per-connection extension handlers (ACPA-13 needs the connection of each `_sah/graphql/*` call).
    - SAH wire types (SAH/*.swift) already write `_meta.sah` with internal `SAH.payload(_:in:member:)` / `SAH.inject(_:into:member:)`; those are the generic "namespaced payload in `_meta`" mechanism that the ACP-3 capability part needs, so they move to a general public `ExtensionMeta` and SAH calls it (no duplicate).
    Plan: `ExtensionHandlers` registry (registerMethod / registerNotification, typed params, `_` prefix required); `Agent.extensionHandlers` / `Client.extensionHandlers` with an empty default; RoleConnectionCore falls back to the registry for names outside the routing table (no handler -> methodNotFound for a request, ignored for a notification; an undecodable notification is logged); outbound `callExtensionMethod(_:_:returning:)` / `sendExtensionNotification(_:_:)` on both connections.
  timestamp: 2026-10-21T21:54:24.949572+00:00
- actor: claude-code
  id: 01m5g7ncxmfy11axpbsyjxkskp
  text: |-
    ### implement — changed
    - evidence: FoundationModelsACP fb3c08d `feat(connection): dispatch _ extension methods and notifications (ACP-3)` on main, NOT pushed. RED: new Tests/FoundationModelsACPTests/ExtensionMethodTests.swift did not compile (ExtensionHandlers / callExtensionMethod / ExtensionMeta missing). GREEN: the 11 new tests (3 suites) pass. Full `swift test`: 536 tests in 60 suites + 135 tests in 17 suites passed, 0 failures, 0 warnings.
    - API: `ExtensionHandlers` (registerMethod/registerNotification, typed params, `_` prefix precondition); `Agent.extensionHandlers` / `Client.extensionHandlers` (default empty; read once when the factory returns); `AgentSideConnection` / `ClientSideConnection` `.callExtensionMethod(_:_:returning:)` and `.sendExtensionNotification(_:_:)`; `ExtensionMeta.payload(_:in:member:)` / `.inject(_:into:member:)` for capabilities in `_meta`.
    - Behavior: unregistered `_` request -> methodNotFound; unregistered `_` notification ignored (no log); bad request params -> invalidParams; bad notification params -> one warning, dropped.
    - Also: the SAH `_meta` helpers (SAH.payload/inject in:/into:) moved to the general ExtensionMeta (no duplicate); RoleDispatch.decodeNotification got a wire-method overload for extension notifications.
    - next: review, then push FoundationModelsACP, then `swift package update FoundationModelsACP` + full `swift test` in FoundationModelsACPAgent (last Done-when item, not done in this step).
  timestamp: 2026-10-21T22:00:16.564056+00:00
- actor: claude-code
  id: 01m5g7qbjrkx79knnx68yyjzna
  text: |-
    ### test — green
    - evidence: `swift test` in FoundationModelsACP at fb3c08d — 135 tests in 17 suites passed, 0 failed, 0 skipped. Forced rebuild (touched all Sources and Tests, `swift build --build-tests`, 122 steps) — 0 warnings, 0 errors. No release build run.
    - next: review
  timestamp: 2026-10-21T22:01:20.728616+00:00
- actor: claude-code
  id: 01m5g7rancvaxvmmvf4m0v5rj3
  text: |-
    ### review — stuck
    - evidence: the review was not run. The request was to review FoundationModelsACP 270f9e3..fb3c08d. The `review` skill says "Review only the repository that contains the current working directory", and "If the user gives a target outside the root, do not review it ... Do not change the working directory, and do not clone or fetch a different repository, to make the target valid." This session's repository root is /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent. FoundationModelsACP is a separate repository with its own root (/Users/wballard/github/swissarmyhammer/FoundationModelsACP). The brief and the skill's scope rule cannot both be obeyed.
    - blocker: a person must decide how this card is reviewed.
    - next: run `/review` from a session whose working directory is /Users/wballard/github/swissarmyhammer/FoundationModelsACP (`review sha 270f9e3..fb3c08d`), then record the findings on this card; or change the scope rule of the `review` skill to allow a cross-repo target.
  timestamp: 2026-10-21T22:01:52.556125+00:00
- actor: claude-code
  id: 01m5g7s9b20sz84kkb74hqsajr
  text: |-
    ### finish iteration 1 — stuck
    - implement: changed — FoundationModelsACP fb3c08d (not pushed), 11 new tests
    - test: green — FoundationModelsACP swift test 135 tests/17 suites, forced rebuild 0 warnings
    - commit: 4c9371d (card records here; code commit fb3c08d in FoundationModelsACP)
    - review: stuck — the review engine is scoped to the repo of this session (`Validator 'scope' error: path ... escapes the repository root`), and the code is in FoundationModelsACP. A person must decide: run `/review` from a session in FoundationModelsACP, or allow a review of another repo. fb3c08d is NOT pushed until a review passes.
  timestamp: 2026-10-21T22:02:23.970072+00:00
- actor: claude-code
  id: 01m5gchq6c033853jazxtczrmk
  text: |-
    ### review — clean (in FoundationModelsACP)
    - The FoundationModelsACP session (foundationmodelsacp-50) reviewed 270f9e3..72f9e9c. It fixed 4 findings in d8f79f4 and a78fb48 (named size constants, and the shared HTTPTestSupport.makeRequest). The re-review gave 0 findings.
    - Pushed: FoundationModelsACP origin/main a78fb48. swift test there 571/60 + 135/17, 0 warnings.
    - ACPAgent builds and passes against 72f9e9c (1178 tests, 1 known issue). The later commits change no public API.
  timestamp: 2026-10-21T23:25:38.892216+00:00
position_column: done
position_ordinal: ffff8680
title: 'ACP-3 (in FoundationModelsACP): dispatch of extension methods and notifications that start with `_`'
---
The work is in the repo /Users/wballard/github/swissarmyhammer/FoundationModelsACP (main 270f9e3), and not in this repo. The user gave the FoundationModelsACP work to this session, relayed through the Multitool coordinating session. ACP-3 is first, because it unblocks ACPA-5e and ACPA-13 here.

Spec: TestudoApp features/packages/foundationmodels-acp.md, "ACP-3 Extension methods and notifications" (agreed; D54, D55, D56).

## Change (in FoundationModelsACP)
- General support for extension methods and notifications whose names start with `_`, in both directions: client to agent, and agent to client.
- Today the dispatch gives `methodNotFound` for each method that it does not know. After this change:
  - A host registers handlers for `_` methods and notifications, and the dispatch sends each `_` message to its handler.
  - A `_` method with no handler still gives `methodNotFound`.
  - A `_` notification with no handler is ignored.
- Each side can advertise its extensions as capabilities in `_meta` (for example in `initialize`).
- The GraphQL tunnel (D55) uses this: `_sah/graphql/*` requests, with the SAH wire types in `Sources/FoundationModelsACP/SAH/` (ACP-5, 270f9e3).

## Done when
- A failing test first (TDD), in FoundationModelsACP: a registered `_x/y` method handler gets the call and its result goes back. An unregistered `_` method gives methodNotFound, an unregistered `_` notification is ignored, and a notification in the agent-to-client direction reaches the client handler.
- The full FoundationModelsACP `swift test` passes. Push to FoundationModelsACP main.
- Then in this repo, `swift package update FoundationModelsACP`, and the full `swift test` passes. #acp-3