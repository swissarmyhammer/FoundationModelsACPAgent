---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77t52g2gzvqd1r178empd8c
  text: 'Decision of testudoapp-75 (2026-11-12): step1. A run must get the same filter as the root session (^b013mv9): its runCode registry has only the capabilities that its agent''s `tools:` / `disallowedTools:` allow, so what its body says matches what it can do. Prefer the ACPAgent-only change (give each run a filtered registry). Ask foundationmodelsagents-d7 for a hook only if the run''s selection is not reachable from ACPAgent; then stop and report the exact hook. Tests: a run with `disallowedTools: [shell]` has no shell in runCode; a run with no limits keeps it. The always-kept tools stay (files, runCode, searchTools, the endpoint tools). Order: after the push of ^enh25yn and ^vshf002.'
  timestamp: 2026-11-12T12:01:38.306858+00:00
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
- Use `/tdd`. #step1