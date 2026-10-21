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
position_column: doing
position_ordinal: '80'
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