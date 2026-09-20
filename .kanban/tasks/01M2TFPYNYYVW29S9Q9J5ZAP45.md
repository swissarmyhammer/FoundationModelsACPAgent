---
assignees:
- claude-code
position_column: done
position_ordinal: df80
title: The code context skills must name the Multitool verbs
---
The five skills of the `code-context` branch of `swissarmyhammer/skills` tell the model to call a `code_context` MCP tool with JSON such as `{"op": "get symbol", "query": "X"}`. In this agent the surface is code mode: `runCode` with `await tools.code_context.getSymbol({query: "X"})`. The 23 verbs are in the `tools.code_context` group.

Work, on the `code-context` branch only:
- Change each operation example in `code-context`, `explore`, `detected-projects`, `lsp` and `map` to the `tools.code_context.<verb>(...)` form, with the parameter names of the real verb schemas.
- Change the `compatibility` line of each skill.
- Remove the instruction to ask the user for permission in `lsp`; the agent installs a language server automatically.
- Generate the catalogs again, run the tests, and push.

Acceptance: `swift test` in the skills repository passes, and a fetch in this agent mounts the five skills. #code-context #skills