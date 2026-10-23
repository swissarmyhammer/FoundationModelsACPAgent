---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5m4mjb67xvm0d3pmzcm7gp7
  text: |-
    Picked up (model-switch item only; resume done in ^w53xmhk / 7bba627). Research against the pinned checkouts (Multitool 7e6c35a, which contains 743a022; Hooks 4f463f2; Router 7c07fb2):
    - Store owners are Router session ids: SnapshotHook opens/takes/releases with `session.sessionID` (HookSession), and `SnapshotStore` keeps `owners: Set<String>` per key; `release` removes the string. Router `makeSession` always does `ULID.generate()` for the session id; there is no host-given hook session id.
    - Multitool feed (SnapshotsGraphChanges.swift `record`): one event per `owner in change.owners where sessionKey(owner) != nil`, with `event.sessionId = owner` and `event.owner = change.owner`. The `changes` subscription filters on `event.sessionId` (`canSee` + named sessionId). `Checkpoint.owner` = `checkpoint.owner` verbatim (SnapshotsGraphSchema). There is no owner -> host session mapping anywhere.
    - After a switch, owners of the cwd key = {R2} once R1 (== ACP id A) is released. So the feed records the change under R2 (only if the resolver knows R2), never under A, and both `SnapshotChange.owner` and `Checkpoint.owner` are R2.
    - What THIS repo can change: (1) record R2 -> key in SnapshotSessionKeys: gives events under sessionId R2, which a client subscribing for A (or canSee-filtered to A) never gets — does not meet the card. (2) the agent holds the key open as owner A itself after the replaced session closes: the change then appears under A, but its owner is still R2, and the open/release must be ordered around R1's SessionEnd (A == R1 in the Set, so R1's release would drop an earlier open by A). Neither makes the ACP session the owner. Rewriting the graph JSON in GraphQLTunnel would be a response-text hack, not a fix.
    - Also found: `rollbackTimeline(sessionId: A)` after the switch calls `store.rollback(owner: A)`, which is unavailable once R1 is released (same root cause, not on the card).
    BLOCKER: the owner half needs a package change. Exact API asked (Multitool): an owner mapping on both endpoints, `SnapshotsGraph(store:sessionKey:hostSession:)` and `SnapshotsCapability(store:sessionKey:hostSession:)`, `hostSession: @Sendable (String) async -> String?` mapping a store owner (Router session id) to the host session id (nil = the owner itself). The feed fans out to the distinct `hostSession(o) ?? o` for o in `change.owners` that `sessionKey` knows; `SnapshotChange.owner` and `Checkpoint.owner` are `hostSession(owner) ?? owner`. (For the rollback gap, the reverse: the rollback mutation needs a live store owner for a host session, e.g. `storeOwner: (hostSessionId) async -> String?`.) Then this repo: SnapshotSessionKeys records Router id R2 -> ACP id A in applyModelSlot (forget on delete) and passes its `hostSession` resolver to both endpoints; test "after a model switch, a take by the replacement appears as a change for the ACP session id" with owner == A. No files changed; no failing test left in the tree.
  timestamp: 2026-10-23T10:24:21.350466+00:00
- actor: claude-code
  id: 01m5m4mn4bwdm6tft5bgwb99s9
  text: |-
    ### implement — stuck
    - evidence: no files changed. Multitool SnapshotsGraphChanges.swift `record` fans out only to `change.owners` (Router ids) and sets `owner = change.owner`; Router `makeSession` generates the session id; no mapping hook exists to make the ACP session id the sessionId/owner of a replacement's take.
    - next: Multitool card for `hostSession: @Sendable (String) async -> String?` on SnapshotsGraph and SnapshotsCapability (feed + Checkpoint.owner + SnapshotChange.owner map through it; reverse mapping for rollback). When the sha lands: pin it, record R2 -> A in SnapshotSessionKeys at applyModelSlot, write the failing test first.
  timestamp: 2026-10-23T10:24:24.203635+00:00
- actor: claude-code
  id: 01m5m4nff655p7jn81nffhzfcv
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 0 files. Needs Multitool: `hostSession: @Sendable (String) async -> String?` on SnapshotsGraph / SnapshotsCapability (feed fan-out by mapped id, SnapshotChange.owner and Checkpoint.owner mapped) + a reverse mapping (host session -> live store owner) so rollbackTimeline works after a model switch.
    - next: when a Multitool session is live, send it this; then pin, record R2 -> A in SnapshotSessionKeys in applyModelSlot, pass the resolver, test first.
  timestamp: 2026-10-23T10:24:51.174283+00:00
- actor: claude-code
  id: 01m5m67ape3b5674yn6nna63jg
  text: |-
    ### Multitool 17f92b6 (2026-10-23) — unblocks this card
    - Pin Multitool to 17f92b6 (on top of a042548).
    - `SnapshotsGraph.init(store:sessionKey:hostSession:storeOwner:)` and `SnapshotsCapability.init(store:sessionKey:hostSession:storeOwner:)`; both closures `@Sendable (String) async -> String?`, default `{ _ in nil }`.
    - hostSession: store owner (Router id) -> host (ACP) id; nil keeps the owner. The feed maps every id in change.owners and fans out once per distinct mapped id that sessionKey knows; sessionKey is now called with the HOST id. SnapshotChange.owner and GraphQL Checkpoint.owner go through the map. Model verbs (tools.snapshots list/take/rollback) map owner via hostSession too.
    - storeOwner: host id -> live store owner; rollbackTimeline(sessionId: A) uses store.rollback(owner: storeOwner(A) ?? A).
    - One store = one change feed, which keeps the closures of the FIRST endpoint built over it: give every endpoint/capability on a store the same closures (one process-wide map, as SnapshotSessionKeys).
    - Do: record R2 -> A (and A -> R2 for storeOwner) in applyModelSlot; forget on release/delete. Tests first: after a model switch, a take by the replacement appears as a change for A with owner A; rollbackTimeline(A) works after the replaced session is released.
  timestamp: 2026-10-23T10:52:04.686591+00:00
- actor: claude-code
  id: 01m5m88bwqyqmmx8zhjy2xv9fr
  text: |-
    Implementation landed (not committed), Multitool 17f92b6.
    - Pin: Package.resolved Multitool a042548 -> 17f92b61bfca442f9560ca1ad5a7f9d62e66452d (only that line; `swift package resolve`). Package.resolved is gitignored, so the pin is local only.
    - SnapshotSessionKeys (AgentHooks.swift) now holds three maps under one Mutex: keys (ACP id -> key), hostSessions (replacement Router id -> ACP id), storeOwners (ACP id -> live replacement Router id). New: recordReplacement(_:of:), forgetLiveOwner(of:), hostSession(of:), storeOwner(of:), makeEndpoint(over:), makeCapability(over:). The old `resolver` property is gone; RoutedACPAgent and ToolCatalog build the endpoint and the capability only through makeEndpoint/makeCapability, so every endpoint on a store gets the same three closures (one store = one feed, first endpoint wins).
    - applyModelSlot records R2 -> A and A -> R2. tearDownSession (close, delete, resume-replace) calls forgetLiveOwner(A) after the Router session closes; delete's forget(A) also drops each hostSessions entry whose value is A. Decision: hostSessions is kept on close (not only delete) so the replacement's old checkpoints still list owner A after a close/resume; storeOwner is dropped on close because the closed R2 no longer owns the key and a resume restores the Router session under A.
    - RED observed: change test timed out at 60s with no change for A (nil); rollback test got null rollbackTimeline (owner A not live); list test answered owners=<R2>. Unit tests for the new map API failed to compile before the API existed.
    - Test gotcha: `import GraphQL` in HookCompositionTests makes `SourceLocation` ambiguous with Swift Testing; the rollback mutation puts the index in the document instead of using Map/Number.
  timestamp: 2026-10-23T11:27:35.831928+00:00
- actor: claude-code
  id: 01m5m88hx03j8091xjfpvhkkse
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift, Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift, Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift, Tests/FoundationModelsACPAgentTests/SnapshotSessionKeysTests.swift (new); plus local Package.resolved Multitool pin 17f92b6 (gitignored). `swift build --build-tests` no code warnings; `swift test`: 1267 tests in 141 suites passed (1 pre-existing known issue in HarnessSmokeTests, intentional).
    - next: /review. Not committed (per brief).
  timestamp: 2026-10-23T11:27:41.984200+00:00
- actor: claude-code
  id: 01m5m8b1gfw5pafw7s6nqjtvyv
  text: |-
    ### test — green
    - evidence: swift test — 1267 tests in 141 suites passed (1 deliberate known issue); bench unittest (uv, swebench 5.0.2) 265 OK
    - next: commit, review
  timestamp: 2026-10-23T11:29:03.503478+00:00
- actor: claude-code
  id: 01m5m8mnttav3gpvn13mwx072s
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (149de5c) — 7 findings (7 confirmed, 1 refuted): Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:185, :195, :204, :215, :223, :229, :235 (all duplication/duplication)
    - next: implement the 7 open findings in the 2026-10-23 06:29 Review Findings section, then re-review
  timestamp: 2026-10-23T11:34:19.226447+00:00
- actor: claude-code
  id: 01m5m8n3j5vacrg4pc8npcbczd
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 7 files (AgentHooks.swift, ConfigOptions.swift, SessionLifecycle.swift, RoutedACPAgent.swift, ToolCatalog.swift, 2 tests); Multitool 17f92b6
    - test: green — swift test 1267 passed; bench 265 OK
    - commit: 149de5c
    - review: findings — Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:185, :195, :204, :215, :223, :229, :235 (duplication)
  timestamp: 2026-10-23T11:34:33.285460+00:00
- actor: claude-code
  id: 01m5m8vm8f3w79mk6za4fqeev4
  text: |-
    Review round 2026-10-23 06:29 fixed in AgentHooks.swift (SnapshotSessionKeys), behaviour unchanged:
    - Lock-and-read: new private `value(for:in: KeyPath<Maps, [String: String]>)` does `maps.withLock { $0[keyPath: map][id] }`; sessionKey(of:), hostSession(of:), storeOwner(of:) each call it with their map.
    - Endpoint/capability: new private generic `make<Endpoint>(over:with:)` takes the `init(store:sessionKey:hostSession:storeOwner:)` of the type and passes the store and the three resolvers; makeEndpoint and makeCapability pass `SnapshotsGraph.init(...)` / `SnapshotsCapability.init(...)`.
    - Resolvers: the three `*Resolver` closure properties are gone. Swift 6 converts the method references `sessionKey(of:)`, `hostSession(of:)`, `storeOwner(of:)` (self is Sendable) straight to `@Sendable (String) async -> String?`, so `make` passes them directly; a `makeResolver` wrapper would only re-wrap the same function (the finding's "e.g."). Private `Resolver` typealias names the closure type.
    - TDD: pure refactor, no new behaviour; SnapshotSessionKeysTests and the HookCompositionTests model-switch tests cover the three maps and both endpoints.
    - The only build warning is the SwiftPM `missing creator for mutated node` on mlx-swift_Cmlx.bundle (dependency build graph, there before this change).
  timestamp: 2026-10-23T11:38:06.991744+00:00
- actor: claude-code
  id: 01m5m8vntqp618nngd6f8y94ap
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift. `swift build --build-tests` exit 0, no code warnings; `swift test` 1267 tests in 141 suites passed (1 deliberate known issue in HarnessSmokeTests). 7/7 findings of 2026-10-23 06:29 flipped to [x]. Not committed (per brief).
    - next: /review
  timestamp: 2026-10-23T11:38:08.599296+00:00
- actor: claude-code
  id: 01m5m8y1vbgx6fw9nkk6jw07c1
  text: |-
    ### test — green
    - evidence: swift test — 1267 tests in 141 suites passed (1 deliberate known issue); bench unittest (uv, swebench 5.0.2) 265 OK
    - next: commit, review
  timestamp: 2026-10-23T11:39:26.443291+00:00
depends_on:
- 01M5KW1TKC9N9DGCZG5W53XMHK
position_column: doing
position_ordinal: '80'
title: Resumed sessions and model-switch replacements join the shared per-cwd snapshot timeline
---
Split from ^w53xmhk (2026-10-23). Two gaps left after ^w53xmhk:

1. Resume: Router `restoreSession` / `restoreSessionTree` take no hook session key, so a resumed session uses its own id as key, not the cwd key. Asked the Router session for a `hookSessionKey` parameter passed to the restored root's `makeSessionHooks(requestedKey:)`. Then SessionResume.swift passes `HookLineage(workingDirectory:, origin: .resumed)` and the existing resume test flips to the cwd key.
2. Model switch: the replacement session gets a new Router id that `SnapshotSessionKeys` does not know. Checkpoint owners are Router session ids (HookSession.sessionID), so after the replaced session is released the change feed records nothing under the ACP session id for checkpoints the replacement makes. Map the replacement's Router id to the ACP session (or make the owner the ACP session id).

## Do
- [x] Update the Router pin to the sha that adds the restore hook key; resume passes the cwd key. (Done in ^w53xmhk round 2, 7bba627, Router 7c07fb29.)
- [x] Model-switch replacement: its checkpoints reach the ACP session's change feed and show the ACP session as owner.

## Tests (first)
- Resume a session in a cwd where another session is open: both share one timeline.
- After a model switch, a take by the replacement appears as a change for the ACP session id. #share-per-cwd

## Review Findings (2026-10-23 06:29)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:185` `duplication/duplication` — The `hostSession` method duplicates the identical `maps.withLock { $0.<field>[<param>] }` pattern found in `sessionKey` (line 175) and `storeOwner` (line 195). Extract a parameterized helper method to consolidate the lock-and-access logic.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:195` `duplication/duplication` — The `storeOwner` method duplicates the identical `maps.withLock { $0.<field>[<param>] }` pattern found in `sessionKey` (line 175) and `hostSession` (line 185). Extract a parameterized helper method to consolidate the lock-and-access logic.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:204` `duplication/duplication` — The `makeEndpoint` method duplicates the logic found in `makeCapability` (line 215). Both methods construct an object with identical parameters: `store`, `sessionKeyResolver`, `hostSessionResolver`, and `storeOwnerResolver`, differing only in the type being instantiated. Extract a shared generic factory method that takes a type parameter and returns the constructed wrapper, eliminating the duplicated parameter-passing logic.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:215` `duplication/duplication` — The `makeCapability` method duplicates the logic found in `makeEndpoint` (line 204). Both methods construct an object with identical parameters, differing only in the type being instantiated. Extract a shared generic factory method that takes a type parameter and returns the constructed wrapper.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:223` `duplication/duplication` — The `sessionKeyResolver` property duplicates the closure pattern `{ [self] <param> in <method>(of: <param>) }` found in `hostSessionResolver` (line 229) and `storeOwnerResolver` (line 235). All three differ only in the method being forwarded to, not in the closure logic itself. Extract a private factory method, e.g., `private func makeResolver(_ getter: @escaping (String) -> String?) -> (@Sendable (String) async -> String?)`, and call it from all three resolver properties.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:229` `duplication/duplication` — The `hostSessionResolver` property duplicates the identical closure pattern `{ [self] <param> in <method>(of: <param>) }` found in `sessionKeyResolver` (line 223) and `storeOwnerResolver` (line 235). Extract a factory method that takes the getter method as a parameter and returns the wrapped closure.
- [x] `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:235` `duplication/duplication` — The `storeOwnerResolver` property duplicates the identical closure pattern `{ [self] <param> in <method>(of: <param>) }` found in `sessionKeyResolver` (line 223) and `hostSessionResolver` (line 229). Extract a factory method that takes the getter method as a parameter and returns the wrapped closure.
