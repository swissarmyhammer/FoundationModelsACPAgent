---
assignees:
- claude-code
depends_on:
- 01M4E2A5G4FC38X7WG4P28XJZ6
position_column: todo
position_ordinal: '8380'
title: Ship the builtin configuration as a YAML file that names each tool, with each tool on by default
---
## Problem

The builtin configuration (layer 1) is Swift code, not a file. `AgentConfiguration` property defaults and the `init()` of each `*ToolOptions` in `Configuration/ToolSectionCodec.swift` hold the defaults (`ConfigurationLayerName.swift:6`: "the builtin layer is code, not a file"). `ConfigurationYAML` can generate the text of the defaults (`config init`, `config show`, `/config export`), but no YAML file in the repo shows the tools and their defaults. A person must read Swift code to learn which tools exist and which are on.

## Decision

1. Add one YAML file to the library target as a resource: `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`. Declare it in `Package.swift` with `.copy` or `.process`.
2. The file names each tool group under `tools:`: `files`, `shell`, `skills`, `codeContext`, `web`, `git` (from task ^p28xjz6), and `mcp`. Each group that can be off has `enabled: true`. Each option has its default value, and a short comment in ASD-STE100 Simplified Technical English.
3. The loader reads this file as layer 1, under the dotfolder layers. Thus, the file is the builtin configuration.
4. The Swift defaults stay as the decode fallback for a key that a layer does not set. A test makes sure that the file and the code cannot be different:
   - The file decodes to exactly `AgentConfiguration()`.
   - The file names each key of `ToolSectionCodec.optionKeys`. Thus, a new tool group or a new option fails the test until the file names it.
5. `config init` writes the same tool defaults as the file. Keep the existing round-trip rule of `ConfigurationYAML`: the written file reads back to the builtin configuration.
6. A secret (`ConfiguredSecret`, for example a web API key) is never in the file.

## Tests

- The resource loads from the bundle in the unit tests and in the built `acp-agent` binary.
- The file decodes to `AgentConfiguration()`.
- Each key in `ToolSectionCodec.optionKeys` is in the file.
- A user layer that sets `web: false` over the builtin file turns web off, and the other tools stay on.
- `config show --source` names the builtin layer for each key that no layer sets.

## Order

After ^p28xjz6, because the file must name `tools.git`.

#config #tools