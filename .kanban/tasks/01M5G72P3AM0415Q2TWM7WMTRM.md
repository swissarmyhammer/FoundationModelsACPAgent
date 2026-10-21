---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
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