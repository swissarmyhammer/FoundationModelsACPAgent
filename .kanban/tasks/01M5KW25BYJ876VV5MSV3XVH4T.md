---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5kwr17twez7gsw2bxr1kd3g
  text: |-
    ### Multitool d2f6446 (2026-10-23) — use it in this card
    - Update the Multitool pin to d2f6446cc0fc477d12ee5857ba1717a21f28b8b1 (or later: Multitool's Hooks 4f463f2 snapshot owners change comes next; take that sha if it lands first).
    - `public final class ShellStore: Sendable`, `init(storeDirectory: URL? = nil) throws`, `directory: URL`.
    - `ShellCapability.init(store:sandbox:outputChunkStream:defaultWorkingDirectory:)` (non-throwing); builder `withShell(store:sandbox:outputChunkStream:defaultWorkingDirectory:)`.
    - One store = one ShellState: getLines, grep and the command list see every command of the store; command ids are unique ULIDs. Results do not say which session ran a command.
    - Appends are one O_APPEND write.
    - Make ONE ShellStore per resolved store directory in the process (registry, ref-counted like the code context) and give it to each session's capability. Two stores on one directory still stay separate, so the registry is required.
  timestamp: 2026-10-23T08:06:26.298833+00:00
- actor: claude-code
  id: 01m5kznefj092cda3ktt35wj6c
  text: |-
    ### Multitool 7e6c35a (2026-10-23) — use this pin instead of d2f6446
    - Pin Multitool to 7e6c35a (shell attribution 4a49c2d + snapshots list owner 7e6c35a).
    - Use `withShell(store:sessionID:sandbox:outputChunkStream:defaultWorkingDirectory:)` (or `ShellCapability(store:sessionID:...)`) and pass the ACP session id as `sessionID`.
    - Results carry `sessionID`: the execute report (`sessionID` key), `GetLinesResult.sessionID`, each `GrepHistoryMatch.sessionID`. No sessionID = no field.
    - Test: session B reads A's command and sees sessionID == A in get lines and grep.
    - tools.snapshots list/take/rollback checkpoints now have `owner` (no API change).
  timestamp: 2026-10-23T08:57:27.282289+00:00
position_column: todo
position_ordinal: '8280'
title: Sessions in one cwd share one shell store (history, log and command records)
---
User design 2026-10-23: one shell log per cwd, shared by the sessions of that cwd in the process.

## Today
- The store folder is already per cwd: `<local>/projects/<sha256 cwd>/shell` (AgentHome.swift:206-221). But each session builds a new ShellCapability (ToolCatalog.swift:425-448 → SandboxComposition.swift:109-155), and Multitool's `ShellCapability.init` always makes a new internal `ShellState` actor with a random sessionID (ShellState.swift:159, :285-290). Lines are written `{sessionID}:{commandID}:{n}:{text}`; get lines / grep return only the caller's own lines (:633-707); command records are in memory only. Two ShellState actors append with seekToEnd+write, not O_APPEND (:499-502), so lines can overwrite each other.

## Waits on
A Multitool change (no Multitool session is live): a public shareable `ShellStore` (wraps ShellState, `init(storeDirectory:)`) and `ShellCapability.init(store:sandbox:outputChunkStream:defaultWorkingDirectory:)`. Sandbox, output stream and default working directory stay per session. Decide in Multitool whether get lines / grep / list commands show all sessions' commands of the store.

## Do
- [ ] Process-wide registry keyed by the resolved store directory (it can be overridden by tools.shell.storeDirectory), ref-counted like the code context.
- [ ] Each session's ShellCapability uses the shared store.

## Tests (first)
- Session B can list and read a command that session A ran in the same cwd.
- Two cwds keep separate stores.
- Concurrent commands from two sessions leave every log line whole. #share-per-cwd