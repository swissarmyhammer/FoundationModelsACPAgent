---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5kwd612c9ncw4zkn22rcvj8
  text: |-
    ### Hooks 4f463f2 (2026-10-23) — use it in this card
    - Update the Hooks pin to 4f463f2.
    - `Checkpoint.owner: String` (SnapshotHook passes session.sessionID); `.pending` and `.rollback(to:)` carry the owner who asked.
    - `SnapshotChange.owners: Set<String>` (owners of the key at send time) and `SnapshotChange.owner` (= checkpoint.owner). Fan change events out to `change.owners`; show "session X's edit" from `owner`. Init is now `SnapshotChange(sessionKey:checkpoint:owners:)` — fix any code that builds one.
    - `SnapshotStore.shared(directory:)`: one store per resolved directory in the process (weakly held). AgentHooks must use it instead of `SnapshotStore(directory:)`.
    - Breaking: v1 timelines (old trailer) now throw `unreadableTimeline`. SnapshotInventory / the snapshots command must handle that as an unreadable timeline (warning), not crash.
    - Multitool's SnapshotsCapability maps key -> one session id; with owners in the change, ask Multitool to fan out by `change.owners` (asked 2026-10-23).
  timestamp: 2026-10-23T08:00:30.754428+00:00
- actor: claude-code
  id: 01m5kx5xfcyz68vv4wbwyarb47
  text: |-
    ### Multitool 743a022 (2026-10-23) — use it in this card
    - Update the Multitool pin to 743a0223412f8ddc7315995154d20f2337d3d4c6 (builds on Hooks 4f463f2; contains d2f6446 shell store too).
    - BREAKING: the `sessionId: (key) -> String?` resolver is gone. `SnapshotsCapability(store:sessionKey:)` and `SnapshotsGraph(store:sessionKey:)` now. Fix RoutedACPAgent.swift:419 and any other caller.
    - The change feed records one change per session in `change.owners`; a session that the sessionKey resolver maps to nil gets no change. With the shared cwd key, A's take/rollback reaches A and B.
    - Graph: `owner: ID!` on Checkpoint and SnapshotChange. Checkpoint ids stay `<sessionId>:<index>`.
    - Test: two sessions in one cwd — a take by A appears as a change for B with owner A.
  timestamp: 2026-10-23T08:14:01.196528+00:00
position_column: todo
position_ordinal: '80'
title: Sessions in one cwd share one snapshot timeline (hook session key = hash of the resolved cwd)
---
User design 2026-10-23: sessions in one process with the same cwd share ONE snapshot timeline. A rollback restores the whole work tree anyway (SnapshotStore.swift:459-468), so one per-cwd timeline is the honest model; per-session timelines go stale when another session rolls back.

## Today
- One SnapshotStore per agent (Agent/AgentHooks.swift:38); timeline key = hook session key = ACP session id (Router default, SessionHooks.swift:72-98). session/new and resume pass nil lineage (SessionSetup.swift:1113,1147); replacement passes the session id (AgentHooks.swift:72, ConfigOptions.swift:259).
- SnapshotStore already allows many owners per key and closes it after the last owner leaves (:178, :203-214).

## Do
- [ ] One cwd key function: sha256 of `standardizedFileURL.resolvingSymlinksInPath()`. Use it for `AgentHome.projectKey` too (AgentHome.swift:250 does not resolve symlinks today; Router's same-directory check does, SessionHooks.swift:132-133).
- [ ] Pass `HookLineage(sessionKey: <cwd key>)` on new, resume and model-switch replacement.
- [ ] Session delete (SessionLifecycle.swift:90,354-357): remove the timeline only when no other session of that cwd is left (the store refuses with sessionKeyOpen while open — handle it).
- [ ] Snapshots GraphQL endpoint (RoutedACPAgent.swift:419) and SnapshotInventory (SnapshotInventory.swift:22-23,220): stop assuming key == session id; map a key to the sessions of that cwd.
- [ ] When Hooks gives the checkpoint owner (asked of the Hooks session), show it; until then do not block on it.

## Tests (first)
- Two sessions in one cwd: both snapshot into one timeline; B sees A's checkpoints; A's rollback appears in B's timeline.
- Two cwds: two timelines.
- A symlinked path to the same folder gives the same key.
- Deleting one of two sessions keeps the timeline; deleting the last removes it. #share-per-cwd