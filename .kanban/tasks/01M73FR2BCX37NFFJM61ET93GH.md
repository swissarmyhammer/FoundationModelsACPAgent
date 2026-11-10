---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: The skills template values follow the tool selection of the session agent
---
## What
`ToolCatalog.skillsTemplateContext` gives each skill render the values `tools.<group>.enabled`. It reads only the configuration and the tool mode. Since ^b013mv9 (ACPA-1b), the `tools:` and `disallowedTools:` keys of the session agent can remove a capability from the root session (`SessionSurface.applying(agent:)`). The template values do not follow that selection. A skill then gives the steps of a tool, for example `{% if tools.shell.enabled %}`, that the session does not have.

The values are made in `ToolCatalog.makeSkillsSource(context:)` and `AgentsComposition.makeAgentRegistry`, before the session agent is known. The instructions of the session agent and its `skills:` preload are rendered in `composeSessionAgent`, also before the selection.

## Acceptance Criteria
- [ ] A session agent with `disallowedTools: [shell]` renders a skill with `tools.shell.enabled` as `false`.
- [ ] A session agent with no `tools:` key renders the same values as today.

## Tests
- [ ] A unit test for each criterion.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd`.