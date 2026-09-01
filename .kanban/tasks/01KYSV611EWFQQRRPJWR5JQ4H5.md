---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fd5r676m8fh03zaxchcxf5
  text: |-
    Research done. Discoveries:

    - `AgentConfiguration.swift` holds placeholder `ToolsConfiguration` and `SandboxConfiguration` types that accept each body without a read. The loader marks the two sections `.open` in `sectionSchemas`. This task replaces the two placeholders and removes the `.open` schema case when no section uses it.
    - The loader checks keys before the decode: `ConfigurationLoader.schemaWarnings(in:)` walks the merged `YAMLValue` tree against `AgentConfiguration.sectionSchemas`. The tool bodies get their key checks in that same walk, so the pattern stays one pattern.
    - `YAMLValue.decoded(as:)` decodes through Yams' standard `Codable` decoder, so a `singleValueContainer` bool probe before an options decode gives the scalar-false-then-body order.
    - `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)` is in `FoundationModelsMultitool`, which the library target already links. Its initializer maps `resolvedPath` over both lists, and an empty `writableRoots` becomes the process cwd — so the section API takes a required working directory and can not send an empty list.
    - MCP config server shapes come from plan.md §7.3 and §11.5: stdio needs `name` + `command` (absolute), http needs `name` + `url`; `args`, `env`, `headers` are optional.
    - The test `toolsAndSandboxBodiesAreAcceptedWithoutKeyChecks` pins the placeholder behavior and says so in its comment. The codec work replaces that test with the real assertions.

    Plan: write `ToolSectionCodec.swift` (generic `ToolSection<Options>`, `FilesToolOptions`, `ShellToolOptions`, `SkillsToolOptions`, `MCPToolSection`, `MCPServerConfiguration`, real `ToolsConfiguration`, and the tools-body schema walk) and `SandboxConfig.swift` (`SandboxConfiguration` with `extraWritePaths` plus `sandboxOptions(workingDirectory:additionalRoots:)` building `SeatbeltSandbox.Options`). TDD: the two new test files come first.
  timestamp: 2026-09-01T21:14:33.543669+00:00
- actor: claude-code
  id: 01m1fdq66gp1sv6y7zvbj4mk5g
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift (new), Sources/FoundationModelsACPAgent/Configuration/SandboxConfig.swift (new), Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift, Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift, Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift (new), Tests/FoundationModelsACPAgentTests/SandboxConfigTests.swift (new); plus the fixture helper and the placeholder-test replacement in Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift
    - notes: TDD order held — the two new test suites failed first for the missing API, then the codec and the sandbox section made them pass. The `mcp:` entry decodes into `MCPToolSection` with a `Transport` enum per server, so a server can not hold both `command` and `url`. The loader's schema walk now checks tool bodies (error) and reports unknown tool keys (warning) through the new `.toolRoster` schema case; the `.open` case is deleted because no section uses it.
    - next: test

    ### test — green
    - evidence: swift test — 52 tests in 6 suites passed, 0 failed, 0 skipped; swift build --build-tests shows 0 warnings
    - next: commit
  timestamp: 2026-09-01T21:24:04.944691+00:00
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
position_column: doing
position_ordinal: '80'
title: 'Configuration: tool-section codec and the sandbox config section'
---
## What
Plan.md §2.5, §11.2. Work in `Sources/FoundationModelsACPAgent/Configuration/`.

**This task lost its shell-policy half.** Multitool deleted its shell permission layer on 2026-08-24. `ShellPolicy`, `ShellPolicy.builtinRules`, `.merged(with:)`, `ShellSecurityConfig`, `ShellDecisionStore` and `decisions.yaml` no longer exist. The upstream reasoning: a denylist over command text can be avoided, but the sandbox is a kernel boundary and does not care how a command is spelled. There is also no `permissions:` config section any more. Do not write a denial-union rule and do not write a `PermissionsConfig` type.

Write these instead:

- `ToolSectionCodec.swift` — the enable and disable rule for `tools:`. Per tool key: absent, `{}`, null or `true` gives on with defaults. A scalar `false` gives off, checked before the body decode. A mapping body decodes as that capability's own option type, and an unknown key in a body is an error. There is no `tools: false` global switch and no `only:` allowlist. `mcp:` is the one list-bodied entry: omitted gives on with no servers, `mcp: [...]` gives those servers, and `mcp: false` gives fully off, including refusing client-supplied servers. The MCP task enforces that refusal.
- `SandboxConfig.swift` — the replacement for the deleted policy section. Decode a `sandbox:` section into `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)`. Default the writable roots to the session root set (cwd plus additional roots). Let config add `extraWritePaths`.

**Obey the resolved-path precondition.** Every directory given to the sandbox must already be `realpath(3)`-resolved. `URL.resolvingSymlinksInPath()` does NOT satisfy this on macOS, because it strips `/private` and gives exactly the form Seatbelt cannot match. `SeatbeltSandbox.Options.init` runs `resolvedPath` over both lists, so build the options through that initializer and never hand-roll the strings.

Record the stated limit in a doc comment: the sandbox bounds writing and deleting only. Reads are free and the network is open, so exfiltration is not bounded.

- [ ] Per-tool scalar-false-then-body codec
- [ ] `mcp:` list decoding with the three states
- [ ] `sandbox:` section decoded into `SeatbeltSandbox.Options`
- [ ] The root set defaults the writable roots
- [ ] The exfiltration limit is documented

## Acceptance Criteria
- [ ] The five shapes of §11.2's table each decode to the documented meaning
- [ ] An unknown key inside a `tools.shell:` body gives an error; an unknown top-level tool section gives a warning only
- [ ] With no `sandbox:` section, the writable roots equal the session root set
- [ ] A `sandbox.extraWritePaths` entry reaches the built options
- [ ] A writable root given as a `/tmp` symlink path arrives resolved, with the `/private` prefix kept

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift` — the §11.2 five-shape matrix, the mcp tri-state, and the unknown-key error
- [ ] `Tests/FoundationModelsACPAgentTests/SandboxConfigTests.swift` — the root-set default, the extra paths, and the symlink resolution case
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.