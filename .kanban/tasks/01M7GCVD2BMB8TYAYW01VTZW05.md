---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Let the host give the agent a name (agentName)
---
From TestudoApp (testudoapp-75). The user wants "what is your name" to answer "Testudo".

- Add `agentName: String? = nil` to `ComposedAgent.compose(...)`; pass it through RoutedACPAgent to SessionSetup, as `openTestudoDownloadURL`.
- `InstructionsAssembler.assemble`: when not nil, a section right after `StyleInstructions.text` that an Instructions.md cannot replace, from new `Instructions/AgentNameInstructions.swift`: "# Name\n\n- Your name is <name>.\n- When the user asks your name, say that your name is <name>."
- Optional: the sub-agent preamble in `Tools/AgentsComposition.swift`.

Tests: the section is present with a name, absent with nil, present when an Instructions.md replaces the base.