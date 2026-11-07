---
assignees:
- claude-code
position_column: done
position_ordinal: ffffc480
title: Put the identity of the person into each GraphQLViewer
---
Step 3 of 5 (Extras done, ACPClient done, ACPAgent, Kanban, KanbanViewKit).

Problem: a GraphQL tunnel call gets a GraphQLViewer with no person, so an endpoint writes each UI edit as the agent.

Work:
- Read `GraphQLActor.fromMeta(params.meta)` in `Initialization.swift` `initialize(_:from:)`. Store the actor in the `ConnectionRow` of the caller.
- userDevice with a valid claim: the claimed actor.
- userDevice with no claim or a bad claim: `local/<NSUserName()>` with `NSFullUserName()`. Inject the two names so a test does not depend on the machine.
- external: never the claim. Use `external/<clientId>`, name "External client <clientId>".
- `.direct` or no row: nil.
- `ConnectionTable.viewer(of:)` fills `actor:` from the row, in the same locked read.
- A model tool call keeps viewer nil (it means the agent of the session).
- Run `swift package update` for FoundationModelsExtras (dbbd53e needs mlx-swift-lm stable 021b934).

Tests (unit, deterministic): userDevice claim accepted; no claim gives the fallback; bad claim gives the fallback; external claim refused and gets `external/<id>`; `viewer(of:)` carries the actor; a GraphQL tunnel call reaches a test endpoint with `viewer.actor`.

Done when: the package builds, the unit tests pass, the review is clean, the commit is pushed, and the commit id goes to the peer session swissarmyhammer-75.

Wait for the design to be accepted before code.