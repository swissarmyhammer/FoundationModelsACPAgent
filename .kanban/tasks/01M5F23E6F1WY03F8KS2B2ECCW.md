---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'ACPA-13: a GraphQLViewer for each _sah/graphql/* tunnel call, from the owner registry (blocked on ACPA-5)'
---
Spec: TestudoApp/features/packages/foundationmodels-acpagent.md, ACPA-13 (status agreed). Asked for by the Multitool session: without it, the viewer rules of every endpoint cannot be tested end to end (EXTRAS-9 rule 4).

## Change
Each `_sah/graphql/*` call that the tunnel carries gets a `GraphQLViewer` (EXTRAS-5; it exists in FoundationModelsExtras `GraphQL/GraphQLViewer.swift`). The viewer holds the client id, the trust of the connection, and the sessions that the client owns. The host also checks the folder of a `sessionFolder` call (rule 4). Today `SettingsGraph.execute` takes `viewer _: GraphQLViewer?` and ignores it.

## Blocked
- ACPA-5 (one `RoutedACPAgent` for each connection, with one shared session registry that knows the owner of each session) is only a **proposal** in the spec. This repo has no owner registry yet: `RoutedACPAgent` is bound to one connection, and a second bind replaces the first. The user must agree ACPA-5 first, and then it needs its own card.
- Also needs the tunnel wire types of ACP-3/ACP-5 (`FoundationModelsACP/SAH/SAHGraphQL.swift` exists; check what it carries).

## Done when
- A failing test first (TDD): two clients on two connections each make a `_sah/graphql/*` call. Each resolver gets a viewer with its own client id and trust, and an `external` client sees only the sessions that it owns. #acpa-13 #blocked