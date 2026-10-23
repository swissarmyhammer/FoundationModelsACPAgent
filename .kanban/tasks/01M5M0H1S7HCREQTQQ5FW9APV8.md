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
depends_on:
- 01M5KW1TKC9N9DGCZG5W53XMHK
position_column: doing
position_ordinal: '8180'
title: Resumed sessions and model-switch replacements join the shared per-cwd snapshot timeline
---
Split from ^w53xmhk (2026-10-23). Two gaps left after ^w53xmhk:

1. Resume: Router `restoreSession` / `restoreSessionTree` take no hook session key, so a resumed session uses its own id as key, not the cwd key. Asked the Router session for a `hookSessionKey` parameter passed to the restored root's `makeSessionHooks(requestedKey:)`. Then SessionResume.swift passes `HookLineage(workingDirectory:, origin: .resumed)` and the existing resume test flips to the cwd key.
2. Model switch: the replacement session gets a new Router id that `SnapshotSessionKeys` does not know. Checkpoint owners are Router session ids (HookSession.sessionID), so after the replaced session is released the change feed records nothing under the ACP session id for checkpoints the replacement makes. Map the replacement's Router id to the ACP session (or make the owner the ACP session id).

## Do
- [x] Update the Router pin to the sha that adds the restore hook key; resume passes the cwd key. (Done in ^w53xmhk round 2, 7bba627, Router 7c07fb29.)
- [ ] Model-switch replacement: its checkpoints reach the ACP session's change feed and show the ACP session as owner.

## Tests (first)
- Resume a session in a cwd where another session is open: both share one timeline.
- After a model switch, a take by the replacement appears as a change for the ACP session id. #share-per-cwd