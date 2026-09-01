---
assignees:
- claude-code
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
position_column: todo
position_ordinal: '8680'
title: 'ToolCatalog: build the MultiTool session tools and append the skills tool'
---
## What
Plan.md §11.1–§11.4 (files, shell and skills; mcp is its own task).

Create `Sources/FoundationModelsACPAgent/Tools/`:

- `CatalogContext.swift` — holds the session working directory, the session root set, the decoded config sections, and the resolved profile. The name is `CatalogContext` because Router owns the name `ToolContext`.
- `ToolCatalog.swift` — the one composition point. Give it the "ADD NEW CAPABILITIES HERE" banner comment.

```swift
public enum ToolCatalog {
    public static func sessionTools(context: CatalogContext) async throws -> [any FoundationModels.Tool]
}
```

It must be `async throws`, because `withMCP(servers:)` is `async throws`.

**These are the facts as of 2026-08-31:**

- **`findAPIs` does not exist. The discovery tool is `searchTools`** (`SearchToolsTool`, `Tool.name == "searchTools"`).
- **The result is not a pair. It is three tools.** `MultiTool.Registry.makeSessionTools(librarian:sampleGenerator:)` vends `searchTools`, `runCode` and `wait`, in that mount order. Direct mode vends `runCode` and `wait`. `wait` is mounted in both modes.
- **`makeSessionTools` needs a librarian model**: `makeSessionTools(librarian: RoutedLLM?, sampleGenerator: RoutedLLM? = nil) throws -> [any Tool]`. Pass `profile.flash`. This is why `CatalogContext` must carry the profile.
- **Hold the profile strongly.** Each `RoutedModel` holds its owning profile weakly, and `makeSession` calls `preconditionFailure` if it was released.
- The builder calls are:
  - `withFiles(root: URL, additionalRoots: Set<URL> = [], readOnly: Bool = false, allowSymlinks: Bool = false, recordsChanges: Bool = false) -> Self`
  - `withShell(storeDirectory: URL? = nil, sandbox: (any CommandSandbox)? = nil, outputChunkStream: ShellOutputChunkStream? = nil) throws -> Self`
  - `withCapability(_ capability: any Capability) -> Self` for frontend capabilities
  - `buildRegistry() throws -> MultiTool.Registry`
- **`PathGuard` is internal.** You cannot name it, and the per-verb argument and output structs are internal too. Reach multi-root confinement only through `withFiles(root:additionalRoots:)`. The root set is the cwd plus the session additional roots. The cwd stays the base for relative paths.
- **There is no shell policy and no permission layer.** `ShellPolicy`, `ShellSecurityConfig`, `ShellDecisionStore` and `builtinRules` were deleted upstream on 2026-08-24. The only gate is the sandbox. Pass a `SeatbeltSandbox` built from the root set. See the sandbox task.
- **The skills tool is stand-alone.** `SkillsTool.make(registry:session:)` is `async throws` and returns an `OperationTool<SkillsToolContext>` with the model-facing name `skills`. Append it to the returned array beside the Multitool tools. There is no `withSkills(...)` builder call.
- **There is no agents capability yet.** Do not write a `withCapability` line for agents, and do not decode an `agents:` section. Agents arrive in a later iteration as a Multitool capability behind `runCode`, mounted as a background run and collected with `wait` (plan.md §11.3). When it ships, it is one `withCapability(_:)` line here and nothing else.

**Build the skills registry from the stack, not from bare roots.** Use `SkillsRegistry(stack: DotfolderStack(name: "skills", workingDirectory: cwd, ...), watch: true)`. The reason is trust: `SkillsRegistry(roots:)` maps every root to `.project`, which Skills renders untrusted, so a trusted defaults layer would be downgraded. `init(stack:)` passes the layers through unchanged and keeps each layer's `source`. Note that a `DotfolderStack.Layer` carries only `source` and `root` and has **no trust tag**; Skills derives trust from `source` itself, with `.defaults` trusted and everything else untrusted. `watch: true` is what makes `commandUpdates` non-nil for the slash-command task.

Honor the enable and disable codec. A capability that decodes as off gets no `with…()` call and never reaches the model.

Catalog contract step 3 (§11.1): README.md gains a `## Tools` table with one row per capability (`files`, `shell`, `mcp`, `skills`).

- [ ] `CatalogContext` value, carrying the profile
- [ ] `ToolCatalog.sessionTools(context:)`, `async throws`, with the banner
- [ ] The files capability is opted in and root-confined
- [ ] The shell capability is opted in with a sandbox
- [ ] The skills tool is appended, from a stack-built registry with `watch: true`
- [ ] README § Tools table with a row per capability

## Acceptance Criteria
- [ ] A default context yields tools named `searchTools`, `runCode`, `wait` and `skills`
- [ ] `shell: false` config yields a registry with no shell namespace, asserted through the built `APISurface` entries
- [ ] `tools.files.read` refuses a path outside the root set, asserted by invoking the verb
- [ ] `tools.files.read` accepts a path in an additional root
- [ ] The skills registry is built with `watch: true`, so its `commandUpdates` is non-nil
- [ ] A test asserts that the README Tools table names every capability in the catalog

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` — a construction matrix against temp-dir configs. Assert composition through `APISurface.entries` paths, because the per-verb argument and output structs are internal.
- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — the README Tools-table row check
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.