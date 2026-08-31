---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Declare package dependencies, targets, and test target in Package.swift
---
## What
Make the real manifest from the dependency-free one (plan.md §1).

Declare these dependencies in `Package.swift`. Use the family convention `.package(url: "git@github.com:swissarmyhammer/<Name>.git", branch: "main")`:

- `FoundationModelsACP` — the wire.
- `FoundationModelsRouter` — the runtime.
- `FoundationModelsExtras` — the dotfolder stack, the template engine, and the operation-event vocabulary.
- `FoundationModelsMultitool` — the consolidated tool surface. It holds the files, shell and mcp capabilities.
- `FoundationModelsSkills` — a stand-alone package. It gives a plain `FoundationModels.Tool`. It is NOT a Multitool capability. See the roster task.

Do not add FileTool, Shelltool, or MCP packages. Those three dissolved into Multitool. The agents capability is plan-only upstream.

Obey these facts. They come from a survey of the packages on 2026-08-31:

- **Use `branch: "main"` for Multitool.** Multitool has no semver tags. It has only two milestone tags. A `from:` requirement does not resolve.
- **Set the platform to `.macOS("27.0")`.** Use the string form. Router, Multitool and Skills all declare `.macOS("27.0")`. The current `.macOS(.v26)` is a placeholder. It does not resolve against these dependencies. Keep swift-tools-version 6.2.
- **Multitool has no `@_exported import`.** You must declare Router and Extras yourself to name their types. This is why both are in the list above.
- **Declare swift-sdk only if you name MCP types.** Multitool uses the organization fork `https://github.com/swissarmyhammer/swift-sdk`, branch `main`. Do not add `modelcontextprotocol/swift-sdk`. Two different URLs for the same package identity make the resolve fail.

Add the products to the `FoundationModelsACPAgent` target. Add a `FoundationModelsACPAgentTests` test target.

- [ ] The five family dependencies are declared
- [ ] The platform is `.macOS("27.0")`
- [ ] The test target `Tests/FoundationModelsACPAgentTests/` is added
- [ ] The import smoke test is added

## Acceptance Criteria
- [ ] `swift build` completes
- [ ] `swift test` completes (the smoke suite)
- [ ] The library target can import all five dependency modules
- [ ] The resolved graph holds only one swift-sdk

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift`: import FoundationModelsACP, FoundationModelsRouter, FoundationModelsExtras, FoundationModelsMultitool and FoundationModelsSkills. Name one public type from each. Use `Router`, `MultiTool.Builder`, `DotfolderStack`, `SkillsRegistry` and the wire's `Agent` protocol.
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.