---
assignees:
- claude-code
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