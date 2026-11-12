---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
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
- Use `/tdd`.