---
assignees:
- claude-code
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
position_column: todo
position_ordinal: '8680'
title: 'ToolCatalog: build the MultiTool with the files and shell capabilities, with confinement'
---
## What
Plan.md §11.1–§11.4 (files + shell; MCP is its own task). The model-facing surface is Multitool's `runCode` + `findAPIs` pair. Create `Sources/FoundationModelsACPAgent/Tools/`:

- `CatalogContext.swift` — carries the session working directory, the session's additional roots, the decoded per-capability config sections, and the `ShellDecisionStore` locations. (The name is `CatalogContext` because Router's `Hosting/` substrate owns the name `ToolContext`.)
- `ToolCatalog.swift` — the one composition point, exactly the shape in §11.1 with the "ADD NEW CAPABILITIES HERE" banner comment: `public enum ToolCatalog { public static func multitool(context:) throws -> [any FoundationModels.Tool] }`. It builds one `MultiTool` through Multitool's `Builder` and returns the `runCode` + `findAPIs` pair. It honors the enable/disable codec: a capability decoded as off gets **no** `with…()` call and never reaches the model.
- `files`: opt in with `withFiles(...)`, with `PathGuard` confined to the root set (cwd + additional roots; cwd stays the base for relative paths, §11.4). Until the files capability's multi-root `939nnzx` lands, pass cwd as the single root — the multi-root task extends this.
- `shell`: opt in with `withShell(...)`, with the composed `ShellPolicy` value (from the codec task) and `ShellDecisionStore(userDecisionsURL:projectDecisionsURL:)` pointed at our dotfolder layers (or `nil` for no persistence); `.session` stays the default remembered-answer scope (§2.5). The shell is **not** root-confined — its confinement is policy rules (§11.4).
- Frontends can register their own capabilities through `withCapability(_:)` before the build; the composed pair goes to `makeSession(tools:)` (wired in session/new).
- Catalog contract step 3 (§11.1): README.md gains a `## Tools` table with one row per capability (`files`, `shell`, `mcp`) — the row-per-entry rule the banner instructs future additions to follow.

- [ ] `CatalogContext` value
- [ ] `ToolCatalog.multitool(context:)` with banner
- [ ] `files` capability opted in, root-confined
- [ ] `shell` capability opted in with composed policy + decision store
- [ ] README § Tools table with a row per capability

## Acceptance Criteria
- [ ] Default (no config) context yields a MultiTool whose registry contains the `files` and `shell` capabilities (assert through the registry surface or through `findAPIs`)
- [ ] `shell: false` config yields a registry without the shell capability
- [ ] The files capability refuses a path outside the root set (asserted by invoking the capability directly)
- [ ] The composed shell policy still denies a builtin-denied command even when project config supplies its own rules
- [ ] A test asserts README's Tools table names every capability in the catalog

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` — construction matrix against temp-dir configs; direct capability invocations for the confinement assertions
- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — README Tools-table row check
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.