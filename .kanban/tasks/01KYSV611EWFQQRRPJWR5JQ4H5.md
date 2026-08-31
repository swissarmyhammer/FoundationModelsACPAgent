---
assignees:
- claude-code
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
position_column: todo
position_ordinal: '8380'
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