---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fgp6a4xvzwya1jge2rthmj
  text: |-
    Research findings (verified in the upstream sources):
    - `MultiTool.Builder` is a final class with `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:)`, `withShell(storeDirectory:sandbox:outputChunkStream:) throws`, `withCapability(_:)`, `buildRegistry() throws`.
    - `Registry.makeSessionTools(librarian: RoutedLLM?, sampleGenerator: RoutedLLM? = nil) throws -> [any Tool]` vends `searchTools`, `runCode`, `wait` in that order. A `nil` librarian keeps the searcher in retrieval mode.
    - `Registry` has `public let surface: APISurface` and `public let tools: [String: any Tool]` keyed by entry path. `ToolInvoker.invoke(_:content:)` is public and can invoke a verb from a test through implicit existential opening.
    - A refused files path answers in band: `ReadResult.correction` is set and no error is thrown. The output erases to `any PromptRepresentable`; a test reads it through `ConvertibleToGeneratedContent.generatedContent.jsonString`.
    - `SkillsTool.make(registry:session:)` has a closure overload `session: @escaping @Sendable (String) -> any AgentSession`, `async throws`, returns `OperationTool<SkillsToolContext>` named `skills`. One `import FoundationModelsSkills` re-exports `AgentSession` and `DotfolderStack`.
    - Router's `RoutedSession` does not conform to `AgentSession`; Multitool holds an internal adapter. This package needs its own small adapter with the load-bearing `fork()` override.
    - `SkillsRegistry(stack:policy:watch:)` passes stack layers through unchanged; `commandUpdates` is non-nil only for `watch: true`.
    - `SandboxConfiguration.sandboxOptions(workingDirectory:additionalRoots:)` already builds `SeatbeltSandbox.Options` over the root set; `SeatbeltSandbox(options:)` is public.
    - Tests can resolve a real `LanguageModelProfile` through `Router(cacheDir:probe:metadataSource:loader:)` with stub loader, machine probe and metadata, in the pattern of Multitool's `StubRouterFixtures.swift`.
    - The roster for the README table check is enumerable as `ToolsConfiguration.CodingKeys.allCases` (files, shell, skills, mcp).
  timestamp: 2026-09-01T22:15:58.020697+00:00
- actor: claude-code
  id: 01m1fh1737ts039w6k5xwr09kt
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Tools/CatalogContext.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift, Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift, Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift, plus README.md § Tools
    - next: run the test step, then commit, then review

    TDD order was followed: the tests were written first and failed with "cannot find 'ToolCatalog' in scope"; then the three source files and the README section made them pass. All 9 catalog tests and the README table test are green. Full run: 95 tests in 12 suites, all pass, zero compiler warnings.
  timestamp: 2026-09-01T22:21:59.271246+00:00
- actor: claude-code
  id: 01m1fh407d9tjgec9f271wf0w5
  text: |-
    ### test — green
    - evidence: swift test — 95 passed, 0 failed, 0 skipped, in 12 suites. This package's targets compile with zero warnings (verified with a forced recompile of every changed file). The only warnings in a full clean rebuild come from the third-party mlx-swift dependency checkout (`constexpr if is a C++17 extension` in its Metal headers, and the build database's `missing creator` notice for its Cmlx bundle); both are present on clean main with this change stashed, and are not touchable from this repository.
    - next: commit
  timestamp: 2026-09-01T22:23:30.541737+00:00
- actor: claude-code
  id: 01m1fh4krv35x3kbhm10r2qq5j
  text: |-
    ### commit — changed
    - evidence: 29204ee feat(tools): compose the MultiTool session tools and append the skills tool (9 files, 701 insertions)
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-01T22:23:50.555369+00:00
- actor: claude-code
  id: 01m1fhh1na7a3gcyxpzwrv3t90
  text: |-
    ### review — findings
    - evidence: 3 findings — Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift:21, Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift:28 (two rules on that line)
    - next: implement works the unchecked findings, then test, commit, and review again
  timestamp: 2026-09-01T22:30:37.994372+00:00
- actor: claude-code
  id: 01m1fhhpmwss26dbvh78ecphrs
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (3 source files, 3 test files, README § Tools)
    - test: green (95 passed, 0 failed, 0 skipped, zero package warnings)
    - commit: 29204ee
    - review: findings (3 — SelectionAgentSession.swift:21 idioms; StubProfileFixtures.swift:28 concurrency and value-semantics)
  timestamp: 2026-09-01T22:30:59.484843+00:00
- actor: claude-code
  id: 01m1fhm5r3nh39m8807xfmx5f4
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift, Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift
    - next: test, then commit, then review

    How each finding was worked:
    - SelectionAgentSession.swift `swift/idioms`: the handwritten memberwise initializer and its doc comment were deleted. The stored property changed from `private let` to `let` (internal), because a private property would make the synthesized memberwise initializer private and unreachable from `ToolCatalog.swift`; with the internal property the synthesized initializer is identical to the deleted one.
    - StubProfileFixtures.swift `swift/concurrency`: the `@unchecked Sendable` assertion was removed. The class holds no stored state, so its `Sendable` conformance (required by `LanguageModelSessionBackend`) is now compiler-checked, exactly the second option the finding offered.
    - StubProfileFixtures.swift `swift/value-semantics`: the literal struct conversion cannot compile — `LanguageModelSessionBackend` is declared `public protocol LanguageModelSessionBackend: AnyObject, Sendable`, so a conformer must be a class. The class stays `final`, the `@unchecked` assertion is gone, and the doc comment now records why the reference type is required. This is the rule's own carve-out: a class is reserved for genuine reference-semantics needs, and a protocol with an `AnyObject` constraint is one.
  timestamp: 2026-09-01T22:32:20.483788+00:00
- actor: claude-code
  id: 01m1fhm9d8sz409vnpmc1gnjds
  text: |-
    ### test — green
    - evidence: swift test — 95 passed, 0 failed, 0 skipped, in 12 suites; package build with zero warnings after the finding fixes
    - next: commit
  timestamp: 2026-09-01T22:32:24.232134+00:00
- actor: claude-code
  id: 01m1fhmh71d9hrb7pjdssmmsek
  text: |-
    ### commit — changed
    - evidence: fb0504c refactor(tools): resolve the review findings on the catalog fixtures (4 files)
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-01T22:32:32.225172+00:00
- actor: claude-code
  id: 01m1fhrahh7x9hz3q05cf52yr5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings (counts: findings 0, confirmed 0, refuted 0); all 3 prior findings checked
    - next: task moved to done
  timestamp: 2026-09-01T22:34:36.465553+00:00
- actor: claude-code
  id: 01m1fhrfaafd0jpgdy6v5q8pvt
  text: |-
    ### finish iteration 2 — done
    - implement: changed (the 3 review findings worked in 2 files)
    - test: green (95 passed, 0 failed, 0 skipped, zero package warnings)
    - commit: fb0504c
    - review: clean (0 findings; all prior findings checked; task moved to done)
  timestamp: 2026-09-01T22:34:41.354947+00:00
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
position_column: done
position_ordinal: '8780'
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

- [x] `CatalogContext` value, carrying the profile
- [x] `ToolCatalog.sessionTools(context:)`, `async throws`, with the banner
- [x] The files capability is opted in and root-confined
- [x] The shell capability is opted in with a sandbox
- [x] The skills tool is appended, from a stack-built registry with `watch: true`
- [x] README § Tools table with a row per capability

## Acceptance Criteria
- [x] A default context yields tools named `searchTools`, `runCode`, `wait` and `skills`
- [x] `shell: false` config yields a registry with no shell namespace, asserted through the built `APISurface` entries
- [x] `tools.files.read` refuses a path outside the root set, asserted by invoking the verb
- [x] `tools.files.read` accepts a path in an additional root
- [x] The skills registry is built with `watch: true`, so its `commandUpdates` is non-nil
- [x] A test asserts that the README Tools table names every capability in the catalog

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift` — a construction matrix against temp-dir configs. Assert composition through `APISurface.entries` paths, because the per-verb argument and output structs are internal.
- [x] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — the README Tools-table row check
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-01 17:23)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift:21` `swift/idioms` — Internal memberwise initializer is written out identically to what the compiler would synthesize. The rule prohibits this except for public initializers; delete the init and let the compiler generate it. Delete lines 18–23 (the doc comment and init). The struct's compiler-synthesized memberwise initializer will be identical and requires no documentation.
- [x] `Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift:28` `swift/concurrency` — `EchoSessionBackend` is marked `@unchecked Sendable` but lacks a documented synchronization invariant. Per the concurrency rule, `@unchecked Sendable` requires a documented synchronization invariant explaining why the type is safe despite bypassing compiler checks. Either add a comment above the class explaining the synchronization invariant (e.g., "Stateless and therefore inherently thread-safe"), or remove `@unchecked` if the class should be implicitly `Sendable` without the assertion.
- [x] `Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift:28` `swift/value-semantics` — `EchoSessionBackend` is defined as a `final class` but should be a `struct`. The rule defaults to value types (`struct`/`enum`) and reserves `class` for genuine identity, reference semantics, or Obj-C interop. This class has no stored state, no identity requirements, and no reference-semantics need — it is a pure protocol-conforming test double with all-pure methods. Change `final class EchoSessionBackend` to `struct EchoSessionBackend` on line 28. Remove the `@unchecked Sendable` annotation and replace it with `: Sendable` (or omit it if the struct is implicitly `Sendable` due to stateless methods).