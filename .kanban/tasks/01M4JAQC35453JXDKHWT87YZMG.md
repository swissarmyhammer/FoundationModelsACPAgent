---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
title: Read the skills marketplace from swissarmyhammer/skills main, in the builtin default and in the bench config
---
## Goal

The user decided on 2026-10-10: the agent gets its skills (and its marketplace agents) from `swissarmyhammer/skills` on the `main` branch, from now on.

## State now

- `bench/code-context.config.yaml` names the marketplace `https://github.com/swissarmyhammer/skills.git` with `ref: code-context`. That branch has only 7 skills (code-context, commit, detected-projects, explore, lsp, map, tdd). `main` has 23 skills and the agents.
- `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` has `marketplaces: []`. Thus, by default, the agent reads only the local dotfolder stack.
- The doc comment at `Configuration/ToolSectionCodec.swift:205` shows `ref: code-context` as the example.

## Change

1. **Builtin default.** In `builtin.config.yaml`, set `tools.skills.marketplaces` to one item: `url: https://github.com/swissarmyhammer/skills.git`, `ref: main`. Use the HTTPS URL only (the user decided on 2026-09-18 that a marketplace is HTTPS only). Write an STE comment. Change the Swift default of `SkillsToolOptions` the same way, so that the test "the builtin file decodes to exactly `AgentConfiguration()`" still passes.
2. **Bench config.** In `bench/code-context.config.yaml`, change `ref: code-context` to `ref: main`, and correct the comment that says the branch holds only the five code-context skills.
3. **Doc example.** Change the example at `ToolSectionCodec.swift:205` to `ref: main`.
4. **README.** State the default marketplace, and how to set it to an empty list.
5. **Tests.** A test checks the default marketplace (URL and `ref: main`). A user layer that sets `marketplaces: []` gives no marketplace. A test that uses the network must not run by default: use a local git repository as the marketplace in the tests.
6. **Doctor.** If `ToolsDoctor` states the skills marketplaces, check that it shows the new default.

## Notes

- The marketplace agents of `main` are still in the old layout `agents/<name>.md`. FoundationModelsAgents reads only `agents/<name>/AGENT.md` now. The skills session moves them; this task does not depend on that move.
- Run after ^c4a6mwy, because both tasks change the configuration files.

#config #tools