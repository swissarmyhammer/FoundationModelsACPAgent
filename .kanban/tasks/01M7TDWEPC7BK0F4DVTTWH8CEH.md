---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: 'D207: the host can read the change stream of the server transcript search index'
---
Gap from the TestudoApp search work (2026-11-19).

## Current behavior

`RoutedACPAgent.transcriptSearchIndex` is internal. Thus the Mac app cannot read the change stream of the server index (^5qbe4fb), and Spotlight gets no turns of the server's own sessions.

## Change

1. Give the host a public read of the server index's change stream: `changes()`, `turns(of:)` and `allTurns()`. Choose one form and say why: for example a public read-only property on `RoutedACPAgent` (and `ComposedAgent` if the app uses that) that gives the `TranscriptSearchIndex`, or a narrower public type that exposes only these three reads.
2. Do not expose the write functions of the index to the host (index, remove, load) if a narrower type is easy.
3. README/ARCHITECTURE: say how the app reads the server changes.

## Tests

- A host reads `changes()` of the server index and gets the turns of a session after a prompt.
- `turns(of:)` and `allTurns()` give the server sessions.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d207 #search