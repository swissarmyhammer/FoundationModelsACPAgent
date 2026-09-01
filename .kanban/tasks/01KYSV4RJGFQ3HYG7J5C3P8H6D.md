---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1f25rpfffwj5wpw507j05w1
  text: |-
    ### implement — research
    - The five family products and the client product resolve over SSH (`git@github.com:swissarmyhammer/<Name>.git`, branch `main`). `ssh -T git@github.com` authenticates on this machine.
    - `FoundationModelsACP` declares tools-version 6.4 and `.macOS(.v27)`. It resolves under our tools-version 6.2 manifest with the Swift 6.4 toolchain.
    - The resolved graph holds one `swift-sdk` only: `https://github.com/swissarmyhammer/swift-sdk.git` at `main (168bf40)`. Multitool brings it. This package does not declare it.
    - Public types named in the smoke test: `Agent` (protocol, ACP), `Router` (actor, Router), `DotfolderStack` (struct, Extras), `MultiTool.Builder` (final class, Multitool), `SkillsRegistry` (struct, Skills), `SwiftUIACPClient` (final class, ACPClient).
    - No sibling package commits `Package.resolved`.
    - `swift build --build-tests` and `swift test` pass. The only warnings come from the `mlx-swift` C++ checkout (`-Wc++17-extensions`) and one SwiftPM build-system node warning. None comes from this package.
  timestamp: 2026-09-01T18:02:19.727919+00:00
- actor: claude-code
  id: 01m1f2a3zy1503rjmkygsbxwgp
  text: |-
    ### implement — changed
    - evidence: 3 files — Package.swift (five family packages + the client on the test target only, platform `.macOS("27.0")`, test target `FoundationModelsACPAgentTests`), Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift (7 tests, one public type per module), .gitignore (`Package.resolved`, as each sibling ignores it). `swift build --build-tests` and `swift test` pass: 7 tests in 1 suite, 0 failures. `Package.resolved` holds one `swift-sdk`.
    - next: /test, then /commit, then /review
  timestamp: 2026-09-01T18:04:42.366330+00:00
- actor: claude-code
  id: 01m1f2etg6zfeb044tn3hewxch
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed. Package.swift and Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift reviewed. No prior `## Review Findings` section is open.
    - next: move to done
  timestamp: 2026-09-01T18:07:16.486313+00:00
- actor: claude-code
  id: 01m1f2ezcssvq99xrx1a7qzdss
  text: |-
    ### finish iteration 1 — review clean, task done
    - implement: changed — Package.swift, Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift, .gitignore
    - test: green — swift test: 7 passed, 0 failed, 0 skipped; swift build --build-tests: no diagnostic from this package's sources
    - commit: f9ca898
    - review: clean — review sha HEAD~1..HEAD: 0 findings
  timestamp: 2026-09-01T18:07:21.497242+00:00
position_column: done
position_ordinal: '8180'
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

**Agents are not implemented yet.** A later iteration adds them as a Multitool capability. The model will reach them through code mode (`runCode` → `tools.agents.*`), as a long-running background tool that hands back a `completionToken` and is collected with `wait` (plan.md §11.3). Do not add `FoundationModelsAgents` to the manifest.

Obey these facts. They come from a survey of the packages on 2026-08-31:

- **Use `branch: "main"` for Multitool.** Multitool has no semver tags. It has only two milestone tags. A `from:` requirement does not resolve.
- **Set the platform to `.macOS("27.0")`.** Use the string form. Router, Multitool and Skills all declare `.macOS("27.0")`. The current `.macOS(.v26)` is a placeholder. It does not resolve against these dependencies. Keep swift-tools-version 6.2.
- **Multitool has no `@_exported import`.** You must declare Router and Extras yourself to name their types. This is why both are in the list above.
- **Declare swift-sdk only if you name MCP types.** Multitool uses the organization fork `https://github.com/swissarmyhammer/swift-sdk`, branch `main`. Do not add `modelcontextprotocol/swift-sdk`. Two different URLs for the same package identity make the resolve fail.

Add the products to the `FoundationModelsACPAgent` target. Add a `FoundationModelsACPAgentTests` test target.

**Add `FoundationModelsACPClient` to the test target only.** It is the client driver for every integration tier (plan.md §20.1) and, later, for `Examples/acp-print`. The library target never imports it. The client depends on the wire and Extras only, so there is no cycle. Use the same `.package(url:branch: "main")` form.

- [x] The five family dependencies are declared
- [x] `FoundationModelsACPClient` is declared, on the test target only
- [x] The platform is `.macOS("27.0")`
- [x] The test target `Tests/FoundationModelsACPAgentTests/` is added
- [x] The import smoke test is added

## Acceptance Criteria
- [x] `swift build` completes
- [x] `swift test` completes (the smoke suite)
- [x] The library target can import all five dependency modules
- [x] The resolved graph holds only one swift-sdk

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift`: import FoundationModelsACP, FoundationModelsRouter, FoundationModelsExtras, FoundationModelsMultitool and FoundationModelsSkills. Name one public type from each. Use `Router`, `MultiTool.Builder`, `DotfolderStack`, `SkillsRegistry` and the wire's `Agent` protocol.
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.