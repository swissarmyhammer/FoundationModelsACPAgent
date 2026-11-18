---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: 'D199 (b): give the Router the agent name and id at session start, so the default name is the agent name'
---
Gap found by the TestudoApp integration test (2026-11-18, ACPAgent 16fdd67, Router 6b1abce). Decision D199 (b) in `TestudoApp/features/decisions.md`. Follow-up of ^8pqam4g.

## Current behavior

The sessions of the app get the default names `session` and `session-2`, not the name of the agent. The Router rule is `SessionName.default(agentName:usedNames:)` (`FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionDefaultTitle.swift:51-60`). It takes `SessionFacts.agentName`, else `SessionFacts.agentID` (`FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/SessionFacts.swift:11`). When both are empty, the name is `session`. ACPAgent gives the Router no agent name and no agent id when it starts a session for the app.

## Change

1. When this agent starts a root session (`session/new`), give the Router the agent of the session in its `SessionFacts`: `agentID` (the resolved catalog id, `default` for the root agent, D71) and `agentName` (the name of the agent: the `name` of its AGENT.md, or the name of the default agent).
2. Find where the session facts are made for the Router (look at `RoutedACPAgent.swift:120`, `:492-537`, `ComposedAgent.swift:210-247`, and the session setup code) and set the two fields there.
3. Do the same for a session that the agent starts for another agent (for example `@<agent name>`), if that path makes its own facts.
4. Make sure that the start `session_info_update` of ^8pqam4g sends that name.

## Tests

- A new session of the default agent gets the name of that agent, not `session`.
- A second new session of the same agent in the same folder gets `<name>-2`.
- A session of an agent with an AGENT.md `name` gets that name.
- The start `session_info_update` has the name.
- Update the tests that ^8pqam4g changed to expect `session` and `session-2`.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d199 #at-sessions