---
assignees:
- claude-code
depends_on:
- 01M5CZ1Y88XJXTTF4XCZT60YV4
position_column: todo
position_ordinal: '8880'
title: 'ACPA-17: a settings object in memory for each level, flushed to config.yaml and reloaded on outside change'
---
## What
ACPA-17 and D100(f): ACPAgent keeps one settings object in memory for each level that it has read (the user level, and the session level of each cwd). A change goes to the object of its level, then ACPAgent flushes that object to the `config.yaml` of that level. The sessions read the merged settings from the objects in memory. When the file changes from outside (for example iCloud brings a change from another device), ACPAgent reads it again into the object.

Now the configuration is loaded fresh for each session request (`RoutedACPAgent.makeConfigurationLoader`, `SessionSetup.swift:793`; `loadSessionContext`, line 810). The merge is at the YAML level (`LayeredYAMLDocument` and `builtinRoot.layered(under:)`), and `sources` keeps the layer of each key. There is no config watcher. `DotfolderWatcher(roots:|stack:, onChange:)` exists in Extras. `LayerFileWriter` writes layer files.

Do this:
- Add an actor `SettingsStore` (in `Configuration/`). It holds one YAML document for each level: `.user` and `.session(cwd)`. Use `SettingsFolders` of card ^zt60yv4 for the paths.
- API: `merged(for cwd:) -> (AgentConfiguration, sources)`, `value(at keyPath:, cwd:) -> (value, level)`, `set(_ value:, at keyPath:, level:)`, `clear(at keyPath:, level:)`, and `changes() -> AsyncStream<SettingsChange>`.
- A `set` or `clear` checks the result with `schemaWarnings` and refuses a change that does not decode. Then it writes the document of the level to its `config.yaml` with an atomic write. Comments of the file may go; document this.
- A `DotfolderWatcher` on each `config.yaml` that the store has read. When the file changes and the content is not the last content that the store wrote, the store reads it again and sends a change.
- `loadSessionContext` and the session start paths use `SettingsStore.merged(for:)` and not a fresh load.
- The secret rule of ACPA-18 for the flush is a separate card. This card must keep each `ConfiguredSecret` as it is in the file.

## Acceptance Criteria
- [ ] A `set` on the user level changes the merged value for all cwds that do not set the key, and writes `<user>/config.yaml`.
- [ ] A `set` on a session level wins over the user level for that cwd only, and writes `<cwd>/.acp-agent/config.yaml` (or the folder that `SettingsFolders` gives).
- [ ] A `clear` on the session level makes the user value apply again.
- [ ] An outside write to a `config.yaml` updates the merged value and sends one change.
- [ ] A change that does not decode is refused, and the file does not change.

## Tests
- [ ] Unit tests of `SettingsStore` with temporary folders for each criterion.
- [ ] A watcher test that writes the file from outside and waits for the change (with a timeout, no sleep loop).
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17