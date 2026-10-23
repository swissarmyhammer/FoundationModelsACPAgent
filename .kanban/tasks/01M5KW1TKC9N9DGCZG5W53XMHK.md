---
assignees:
- claude-code
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