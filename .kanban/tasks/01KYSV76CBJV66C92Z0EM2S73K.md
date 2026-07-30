---
assignees:
- claude-code
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
position_column: todo
position_ordinal: '8680'
title: 'ToolCatalog and ToolContext: construct files and shell with confinement'
---
## What
Plan.md §11.1–§11.4 (files + shell; MCP is its own task). Create `Sources/FoundationModelsACPAgent/Tools/`:

- `ToolContext.swift` — carries the session working directory, the session's additional roots, the decoded per-tool config sections, and the `ShellDecisionStore` locations.
- `ToolCatalog.swift` — the one registration point, exactly the shape in §11.1 including the "ADD NEW TOOLS HERE" banner comment: `public enum ToolCatalog { public static func builtin(context:) -> [any FoundationModels.Tool] }`. Honors the enable/disable codec: a tool decoded as off is **not constructed** and never reaches the model.
- `files`: construct `FoundationModelsFileTool` with `PathGuard` confined to the root set (cwd + additional roots; cwd stays the base for relative paths, §11.4). Until FileTool's multi-root `939nnzx` lands, pass cwd as the single root — the multi-root task extends this.
- `shell`: construct `FoundationModelsShelltool` with the composed `ShellPolicy` value (from the codec task) and `ShellDecisionStore(userDecisionsURL:projectDecisionsURL:)` pointed at our dotfolder layers (or `nil` for no persistence); `.session` stays the default remembered-answer scope (§2.5). The shell is **not** root-confined — its confinement is policy rules (§11.4).
- Frontends can append their own tools; the merged array goes to `makeSession(tools:)` (wired in session/new).
- Catalog contract step 3 (§11.1): README.md gains a `## Tools` table with one row per roster entry (`files`, `shell`, MCP) — the row-per-entry rule the banner instructs future additions to follow.

- [ ] `ToolContext` value
- [ ] `ToolCatalog.builtin(context:)` with banner
- [ ] `files` constructed root-confined
- [ ] `shell` constructed with composed policy + decision store
- [ ] README § Tools table with a row per roster entry

## Acceptance Criteria
- [ ] Default (no config) context yields both `files` and `shell` in the array
- [ ] `shell: false` config yields an array without the shell tool
- [ ] The constructed files tool refuses a path outside the root set (asserted by calling the tool directly)
- [ ] The constructed shell policy still denies a builtin-denied command even when project config supplies its own rules
- [ ] A test asserts README's Tools table names every catalog roster entry

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` — construction matrix against temp-dir configs; direct tool invocations for the confinement assertions
- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — README Tools-table row check
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.