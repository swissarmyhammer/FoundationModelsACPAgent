---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77t52g2gzvqd1r178empd8c
  text: 'Decision of testudoapp-75 (2026-11-12): step1. A run must get the same filter as the root session (^b013mv9): its runCode registry has only the capabilities that its agent''s `tools:` / `disallowedTools:` allow, so what its body says matches what it can do. Prefer the ACPAgent-only change (give each run a filtered registry). Ask foundationmodelsagents-d7 for a hook only if the run''s selection is not reachable from ACPAgent; then stop and report the exact hook. Tests: a run with `disallowedTools: [shell]` has no shell in runCode; a run with no limits keeps it. The always-kept tools stay (files, runCode, searchTools, the endpoint tools). Order: after the push of ^enh25yn and ^vshf002.'
  timestamp: 2026-11-12T12:01:38.306858+00:00
- actor: claude-code
  id: 01m77tejtgyryd6hhcx7050fc8
  text: |-
    Research (FoundationModelsAgents pin a8a2153):
    - The run catalog of this host is `AgentsComposition.makeRunTools`. It registers `searchTools` and `runCode` only. Each factory is `ToolCatalog.Factory = @Sendable () -> any Tool`. The factory gets no argument, thus it does not know the agent of the run.
    - `AgentSessionMaker.resolveSetup(for:family:)` serves a new run and a restored run. It calls `ToolResolver.resolve(tools:disallowed:catalog:agentsTool:)`. The resolver selects from `catalog.names` only, then calls `catalog.makeTool(named:)` for each selected name. `ToolCatalog.makeTool(named:)` is internal.
    - The only host closure that gets the definition of a run is `AgentEnvironment.RunTemplateContext` `(AgentDefinition, [String]) -> [String: TemplateValue]`. It runs after the tools are made, and it gets the names, not the instances. A link between a factory call and this call is not safe: two runs can resolve at the same time, and the resolve awaits the `agents` tool factory between the two calls.
    - `tools: [web]`: `web` is not a catalog name, thus the resolver gives an unknown-name warning and selects no `runCode`. A host factory that knows the definition is not sufficient for this case: the resolver must also always make `runCode`/`searchTools` (the always-kept tools of the session, `ToolCatalog.alwaysOnToolNames`) and must accept the capability names (web, shell, `mcp__<server>__<tool>`) as names of the vocabulary.
    - Rejected ACPAgent-only ideas: (1) one catalog entry for each capability name. A factory gives one tool, thus `tools: [web, shell]` or `disallowedTools: [shell]` gives many tools with the name `runCode`. (2) A deferred `runCode` that the `runTemplateContext` call sets later. Not safe for two concurrent runs, and it fights the contract of that closure.
    Conclusion: the selection of a run is not reachable from ACPAgent. No production code and no test was written, as the decision of testudoapp-75 says (stop before building around it).
  timestamp: 2026-11-12T12:06:49.936733+00:00
- actor: claude-code
  id: 01m77tf0smtjvbnrh44tep2k8x
  text: |-
    Blocker: the needed FoundationModelsAgents hook (for foundationmodelsagents-d7).

    Add a kept catalog entry whose factory gets the definition of the run:

    ```swift
    extension ToolCatalog {
      /// Makes one new instance of a kept tool for the run of `definition`.
      public typealias KeptFactory = @Sendable (_ definition: AgentDefinition) -> any Tool

      /// Adds a tool that each run gets, whatever its `tools` and `disallowedTools` say.
      /// - name: the name of the tool (`runCode`, `searchTools`).
      /// - vocabulary: the further names that the keys can name (the capability names
      ///   inside the tool: `web`, `shell`, `mcp__<server>__<tool>`). Read at each resolve.
      /// - factory: makes the tool for one run; the host applies the keys inside the tool.
      public mutating func registerKept(
        _ name: String, vocabulary: @escaping @Sendable () -> [String],
        _ factory: @escaping KeptFactory)
    }
    ```

    Behavior:
    1. `ToolResolver.resolve` (thus a new run and a restored run, through `AgentSessionMaker.resolveSetup`) calls each kept factory one time with `request.definition`, and adds the tool to the resolved tools. `tools:` and `disallowedTools:` never remove a kept tool.
    2. The names of each `vocabulary` join `ToolVocabulary`. Thus `tools: [web]` and `disallowedTools: [shell]` give no unknown-name warning, in the resolve and in `runner.catalog()` (`ToolResolver.diagnostics`). The MCP prefix rule applies to these names too.
    3. The names of the kept tools are in the `toolNames` that `RunTemplateContext` gets.

    With this hook, ACPAgent registers `runCode` and `searchTools` as kept, with the vocabulary of the capability names of the registry, and each factory applies `RegistrySelection(definition:topLevelNames:mcpServerNames:).applied(to:)` before `makeSessionTools`. That gives the same filter as the root session (^b013mv9). The tests of this card (disallowedTools [shell], no tools:, tools [web], restored run) then become possible.

    I did not write a card on the FoundationModelsAgents board: the order says not to edit sibling repositories.
  timestamp: 2026-11-12T12:07:04.244235+00:00
- actor: claude-code
  id: 01m77tf3kpwx9r5g7c9ybhwn6h
  text: |-
    ### implement — stuck
    - evidence: no files changed. `ToolCatalog.Factory` of FoundationModelsAgents (pin a8a2153) is `@Sendable () -> any Tool`, and `ToolResolver.resolve` selects from catalog names only. The definition of a run does not reach a host tool factory. The needed hook is `ToolCatalog.registerKept(_:vocabulary:_:)` with `KeptFactory = @Sendable (AgentDefinition) -> any Tool` (see the blocker comment).
    - next: a person asks foundationmodelsagents-d7 for the hook, then this card continues with the four tests first.
  timestamp: 2026-11-12T12:07:07.126105+00:00
- actor: claude-code
  id: 01m77tfxg3jbbv8y5hptv7dm0f
  text: |-
    ### finish iteration 1 — stuck (orchestrator, 2026-11-12)
    - No source change. A run tool factory gets no argument, and ToolResolver selects only from catalog names, so the run selection is not reachable from ACPAgent.
    - Request sent to foundationmodelsagents-d7: `ToolCatalog.registerKept(_:vocabulary:_:)` with `KeptFactory = @Sendable (AgentDefinition) -> any Tool` (called with the run definition for new and restored runs; never removed by tools: / disallowedTools:; vocabulary names join ToolVocabulary with the mcp__ rule; kept names in the RunTemplateContext toolNames).
    - next: when it is pushed, bump the Agents pin (and Skills if needed), register runCode and searchTools as kept tools, filter each run registry with the root session rule, and write the four tests first.
  timestamp: 2026-11-12T12:07:33.635944+00:00
- actor: claude-code
  id: 01m77thc5f2e3jpbmf2afjx4pw
  text: 'Agents card ^tjp89s3 (step1), accepted plan: `ToolCatalog.KeptFactory = @Sendable (_ definition: AgentDefinition) -> any Tool` and `registerKept(_:vocabulary:_:)`. A kept name is not also a plain catalog name. The resolver calls each kept factory one time per run (new and restored, through resolveSetup); kept tools come after the catalog tools and before the agents tool. The vocabulary names and the kept name are known names for tools: and disallowedTools:, also for the MCP patterns, in the resolve and in runner.catalog(); a vocabulary name makes no tool, and no entry removes a kept tool. RunTemplateContext toolNames get the kept names. `AgentDefinition.toolSelection(over:hasAgentsTool:)` does not change: the ACPAgent factory calls it on `definition` with the capability names (the root session rule).'
  timestamp: 2026-11-12T12:08:21.423749+00:00
- actor: claude-code
  id: 01m78hkt3xtf9pb5c58k8hsj47
  text: |-
    Agents ^tjp89s3 is pushed (FoundationModelsAgents origin/main 02d5f0f; code 2a03044, 6ae65f6, b3e7650; 977 tests pass; review clean). Same Skills pin (55aa12c or later). This card is no longer blocked.
    API on ToolCatalog: `public typealias KeptFactory = @Sendable (_ definition: AgentDefinition) -> any Tool`; `public typealias Vocabulary = @Sendable () -> [String]`; `public mutating func registerKept(_ name: String, vocabulary: @escaping Vocabulary, _ factory: @escaping KeptFactory)`; `public var keptNames: [String]` (sorted); `names` gives only the plain names.
    Behavior: each run (new and restored) calls each kept factory one time with its definition. Kept tools come after the catalog tools and before the agents tool. tools: and disallowedTools: never remove a kept tool. The kept name and each vocabulary name are known names, also for the mcp__ patterns; such a name makes no tool. The kept names are in the toolNames of runTemplateContext. A kept name must not also be a plain name (precondition). The vocabulary closure is called at each resolve.
    Next run: bump only the Agents pin to 02d5f0f or later; in AgentsComposition.makeRunTools register runCode and searchTools with registerKept (not register); the runCode factory filters the registry with `definition.toolSelection(over:hasAgentsTool:)` and the root session rule (^b013mv9; always-kept files, runCode, searchTools and the endpoint tools); the vocabulary gives the capability names and the mcp__ names. Write the four tests first.
  timestamp: 2026-11-12T18:51:38.493030+00:00
- actor: claude-code
  id: 01m78j50t5m8k6xa77d812h7av
  text: |-
    Research (implement, Agents pin 02d5f0f):
    - `swift package update FoundationModelsAgents` in the root and in IntegrationTests moved only FoundationModelsAgents (a8a2153 -> 02d5f0f). Skills stays at 55aa12c. Package.resolved is in .gitignore, thus the pins are local.
    - `ToolResolver.resolve` calls `catalog.makeKeptTools(for: definition)` after the plain tools. A new run and a restored run both come through `AgentSessionMaker.resolveSetup`, thus one kept factory serves both.
    - The root rule is `RegistrySelection(definition:topLevelNames:mcpServerNames:).applied(to:)` (SessionAgentTools.swift). Its `capabilityNames(of:)` gives the nouns and the `mcp__<server>__<tool>` names; that is the vocabulary. The MCP server names come from the actors of the servers (async), thus `sessionSurface` reads them before it makes the run catalog.
    - The runCode description in discovery mode does not list the nouns. A test reads the nouns from `MultiTool.currentRegistry`. The restored child session is a `RoutedSessionActor` (testable Router) whose `tools` holds its runCode; `ResumeNestedSessionsTests.recordShutDownChain()` gives the recorded chain.
    - The existing test `theRunToolsBuildNoPairOfSessionToolsAtTheMount` reads `runTools.names`; with kept tools the names move to `keptNames`.
  timestamp: 2026-11-12T19:01:02.405820+00:00
- actor: claude-code
  id: 01m78k2dxgvjrngxy0ggkjc9ks
  text: |-
    Implementation notes:
    - `AgentsComposition.makeRunTools` now has the argument `mcpServerNames` and registers `searchTools` and `runCode` with `registerKept`. Each factory applies `RegistrySelection(definition:topLevelNames:mcpServerNames:).applied(to:)` (the root rule, thus `toolSelection(over:hasAgentsTool:)` and the always-on names) and then builds the pair over the filtered registry. The vocabulary is `RegistrySelection.capabilityNames(of:mcpServerNames:)`, a new static form of the existing method. `RegistrySelection.serverNames(of:)` reads the server names; `SessionSurface.mcpServerNames()` and `sessionSurface` both call it.
    - The fallback of `freshSessionTool` (a failed pair build, a defect that asserts and logs) is still the mounted tool, which reads the full registry. The doc tells this.
    - Two existing tests changed because runCode is now a kept tool: `theRunsGetTheSkillsToolOfTheOneRegistryAndTheSessionTools` reads `keptNames + names`, and `aRestoredChildFollowsTheCurrentDisallowedTools` denies `skills` in place of `runCode` (the keys cannot remove a kept tool). `theRunToolsBuildNoPairOfSessionToolsAtTheMount` reads `keptNames`.
    - A restored child session wraps its tools; the test reads `RoutedSessionActor.originalTools` to find the MultiTool. `tools` gives the wrapped tools, which are not `MultiTool`.
    - RED evidence: before the change, 6 of 7 new tests failed (no runCode for `tools: [web]`; shell present for `disallowedTools: [shell]`). The restore test also failed with a factory that ignored the definition (shell present), then passed with the filter.
  timestamp: 2026-11-12T19:17:06.096977+00:00
- actor: claude-code
  id: 01m78k2j4g3x4zk70cebqt5z3k
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift, Sources/FoundationModelsACPAgent/Tools/SessionAgentTools.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/RunToolSelectionTests.swift (new, 7 tests), Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift, Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift. `swift build --build-tests`: no compiler warnings. `swift test`: 2021 tests in 221 suites pass, 0 failures, 1 known issue (the existing withKnownIssue smoke test). `swift build --build-tests --package-path IntegrationTests`: complete. Pins: FoundationModelsAgents 02d5f0f (root and IntegrationTests), FoundationModelsSkills 55aa12c (no change). No commit.
    - next: /review.
  timestamp: 2026-11-12T19:17:10.416136+00:00
position_column: doing
position_ordinal: '80'
title: 'An agent run with a tools: key gets the registry selection of its agent'
---
## What
In this host, the run catalog has only `searchTools`, `runCode`, `skills` and `agents` (`AgentsComposition.makeRunTools`). Each tool group (web, shell, git, ...) is a noun of the registry of `runCode`. A run keeps the full registry ("The agent runs keep the tools of the full registry", `SessionSurface.applying(agent:)`).

Thus:
- A run of an agent with `tools: [web]` resolves no tool. It has no `runCode`, thus no web tool. The `tools:` entry `web` gives an unknown-tool warning.
- A run of an agent with `disallowedTools: [shell]` keeps the shell noun in its `runCode`.

Since ^vshf002, the template values of a run follow the keys of its agent with the rules of the session (`ToolCatalog.runTemplateContext`). The body of such a run thus tells `tools.web.enabled` as `true`, but the run has no web tool.

## Acceptance Criteria
- [ ] A run of an agent with `tools: [web]` gets `runCode` with the web noun and the endpoint nouns only (the same selection as `RegistrySelection` of a session).
- [ ] A run of an agent with `disallowedTools: [shell]` gets `runCode` with no shell noun.
- [ ] A run of an agent with no `tools:` key keeps the full registry.

## Tests
- [ ] A unit test for each criterion.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd`. #step1