---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qpfn39k9gwpjf9kctjsgyn
  text: |-
    Research:
    - Router takes the first facts of a new session from `SessionConfiguration.agentID` and `SessionConfiguration.agentName`. `RoutedLLM.makeBudgetedSession` (Agent/SessionSetup.swift) makes the configuration of each `session/new` session and sets neither field. That is the one site to change.
    - The resolved agent is in `SessionComposition.agent` (`ComposedSessionAgent`, built in `composeSessionAgent`). `choice.id` is the catalog id (`default` for the root agent, D71). `AgentDefinition.name` is the `name` key of the AGENT.md.
    - The builtin floor (no default AGENT.md) has no definition. For the default agent with no `name` key, the name is the host name `RoutedACPAgent.agentName` (for example `Testudo`), the name that the instructions give the model.
    - Item 3 (a session that this agent starts for another agent): `AgentSessionLauncher.launchRootSession(for:)` throws `noLauncher` (ACPA-9 Step 7 is not done). No path of this agent makes its own facts for such a session. Router `complete(facts:with:)` does not fill the agent fields, so ACPA-9 Step 7 must set them when it makes that launcher.
    - Restore reads the facts from `index.md`, so a resume keeps the name.
  timestamp: 2026-11-18T16:05:21.641385+00:00
- actor: claude-code
  id: 01m7qpwwyd6zzrvdvvjc8eye28
  text: |-
    Implementation landed (TDD: the 6 new tests failed first with the names `session` / `session-2`, then passed).
    - `ComposedSessionAgent.name` (Agent/SessionSetup.swift): the `name` key of the AGENT.md of the agent. The default agent with no `name` key, and the builtin floor, get the host name (`RoutedACPAgent.agentName`, for example `Testudo` -> `testudo`). With no host name, Router uses the id `default`.
    - `RoutedLLM.makeBudgetedSession` takes `agentID` and `agentName` and gives them to `SessionConfiguration`. `session/new` gives `composition.agent?.choice.id` and `composition.agent?.name`.
    - `announceName(of:sessionId:)` reads `session.facts.title`, so the start `session_info_update` sends the agent name with no change.
    - Item 3: no path of this agent makes facts for a session that it starts for another agent. `AgentSessionLauncher.launchRootSession(for:)` throws `noLauncher` (ACPA-9 Step 7). Router `complete(facts:with:)` does not fill the agent fields, so ACPA-9 Step 7 must give them.
    - Tests: new `SessionDefaultNameTests` (default agent name, `<name>-2`, AGENT.md name, host name, floor id) and `PromptExecutionTests.aNewSessionSendsTheNameOfItsAgentBeforeTheFirstPrompt`. `SessionFolderTests` and `SessionSetupTests` now expect `default` / `default-2` (the harness has no host name and no default AGENT.md). `TranscriptStoreTests` keeps `session`: its session is a raw Router session with no agent, not a `session/new` session.
  timestamp: 2026-11-18T16:12:35.661517+00:00
- actor: claude-code
  id: 01m7qpwzze9x6jf6k88xjxx8m3
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Agent/SessionAgentComposition.swift, Tests/FoundationModelsACPAgentTests/SessionDefaultNameTests.swift (new), Tests/FoundationModelsACPAgentTests/PromptExecutionTests.swift, Tests/FoundationModelsACPAgentTests/SessionFolderTests.swift, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift
    - next: review

    ### test — green
    - evidence: `swift build --build-tests` -> "Build complete!", 0 compiler warnings (1 SwiftPM "missing creator for mutated node" note for the mlx bundle, not from the compiler); `swift test --skip-build` -> 2315 tests in 246 suites passed, 0 failed, 0 skipped, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests)
    - next: review
  timestamp: 2026-11-18T16:12:38.766244+00:00
position_column: doing
position_ordinal: '8180'
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