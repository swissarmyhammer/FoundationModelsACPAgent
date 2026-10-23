---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5kwe114723em6r69vwngvjt
  text: |-
    ### CodeContext cf1552b (2026-10-23) — use it in this card
    - Update the CodeContext pin to cf1552b.
    - One process-wide `CodeContextManager(embedder:autoInstall:eventSource:indexDirectory:)`. Each session: `acquire(root: cwd)` at start, `release(root: cwd)` at shutdown, in place of its own `CodeContext(...)` + start()/stop(). The last release stops. `close`/`shutdown` still stop at once (use only at host exit).
    - A root inside an open root leases the context of that open root (a session in a subfolder shares the parent's index) — test it.
    - Key: `CodeContextManager.rootKey(for:)` = standardized + resolvingSymlinksInPath. Use the same normalization for the cwd key of ^w53xmhk / AgentHome.projectKey.
    - Embedder: one per manager; acquire takes none. Sessions whose profiles give different embedders (or semanticSearch off = nil) need different managers: keep one manager per embedder identity.
    - indexDirectory closure gets the rootKey: return `<local home>/projects/<sha256 of rootKey>/code-context`. nil keeps `<root>/.code-context`.
  timestamp: 2026-10-23T08:00:58.404406+00:00
depends_on:
- 01M5KW1TKC9N9DGCZG5W53XMHK
position_column: todo
position_ordinal: '8180'
title: Sessions in one cwd share one CodeContext (ref-counted), and its index lives under the local home
---
User design 2026-10-23: one code index per cwd, shared by every session of that cwd in the process.

## Today
- Each session makes `CodeContext(rootDirectory:embedder:autoInstall:)` + start() (ToolCatalog.swift:523-548) and SessionSurface.shutdown() stops it (ToolCatalog.swift:192-195; SessionLifecycle.swift:256; SessionResume.swift:391,436). N sessions = N watchers, index loops, LSP fleets and DatabasePools on one `<cwd>/.code-context/kit.db`.
- AgentHome.swift:199-202 says the index lives under `<local>/projects/<key>/`; it does not.

## Waits on
CodeContext session (asked 2026-10-23): ref-counted acquire/release in CodeContextManager, and an index folder parameter. Update the pin to its sha.

## Do
- [ ] One process-wide CodeContextManager; composeCodeContext acquires for the session's cwd (same cwd key as the snapshot card); shutdown releases; the last release stops.
- [ ] Pass the index folder `<local home>/projects/<cwd key>/code-context`, so an iCloud project folder does not sync kit.db. Fix the AgentHome doc to match.
- [ ] Embedder: follow the package's documented rule for a second acquire with another embedder.

## Tests (first)
- Two sessions in one cwd get the same CodeContext; closing one keeps it running; closing the last stops it.
- Two cwds get two contexts.
- With a custom home, no `.code-context` folder appears in the cwd; the index is under home.local. #share-per-cwd #home