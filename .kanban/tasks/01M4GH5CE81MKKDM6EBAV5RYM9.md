---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Remove plan.md and the references to it
---
## Goal

The user says that the plan is old. Delete `plan.md`. Remove or change each reference to it, the direct references and the indirect references, so that each comment stands alone.

## Known references (counted on 2026-10-09)

- Direct: `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` gives 581 lines. The files with the most lines are `Agent/SessionSetup.swift` (50), `Agent/PromptExecution.swift` (31), `RoutedACPAgent.swift` (23), `Package.swift` (16), `Agent/SessionLifecycle.swift` (15), `Tools/ToolCatalog.swift` (14), `Commands/CommandRegistry.swift` (14) and `Agent/EventProjection.swift` (14).
- Indirect, section marks: 304 lines in 176 files have a `§` section number and no document name on the same line. Most are the second line of a wrapped `plan.md` reference, or a bare section number of the plan. Examples:
  - `Commands/CommandDispatch.swift:7` (`§14.3`)
  - `Commands/BuiltinCommands.swift:8` (`§14.1`) and `:407` (`§2.2`)
  - `Tools/CatalogContext.swift:38` (`§4.3`)
  - `Doctor/ProfileDoctor.swift:366` (`§7.1`)
  - `RoutedACPAgent.swift:31` (`§5`) and `:172` (`§2.2`)
  - `Package.swift:419` (`§12`)
  Find them with `rg -n '§\s?[0-9]' --glob '!.kanban/**' --glob '!*.md'`.
- Indirect, words: about 590 lines say "the plan", "plan §" or "(plan". Find them with `rg -n -i '\bthe plan\b|plan §|\(plan\b' --glob '!.kanban/**' --glob '!*.md'`. Some of these are not about `plan.md`. Read each one.
- Milestone ids such as `M6`: none found in the Swift sources.
- A `§` that names another document (for example `generation-queue.md §5.5` of FoundationModelsRouter, or the ACP specification) is not a reference to `plan.md`. Keep it.

## Keep `cli-plan.md`

`cli-plan.md` exists, and the user did not say to delete it. Keep it, and keep its references (`RoutedACPAgent.swift`, `Sources/acp-agent/AcpAgentCommand.swift`). It also matches `rg "plan\.md"`, so the acceptance check below excludes it.

## What to change

1. Change each direct and each indirect reference. A comment must give the reason directly. It must not point to a deleted file or to a section number of it.
2. Keep each important recorded decision as short text, in the README or in the code comment at the applicable location. For example, keep the sandbox-only permission decision (`plan.md:1912-1956`).
3. Delete `plan.md`.

## Acceptance

- [ ] `plan.md` does not exist. `cli-plan.md` still exists.
- [ ] `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` finds nothing.
- [ ] No comment has a bare `§` section number of the plan, and no comment says "the plan" for `plan.md`.
- [ ] The sandbox-only permission decision, and each other decision that the code depends on, is in the README or in a code comment.
- [ ] `DocumentationSyncTests` and the full test suite pass.