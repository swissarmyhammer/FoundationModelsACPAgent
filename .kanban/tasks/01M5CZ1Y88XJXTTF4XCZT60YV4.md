---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'ACPA-16: one list of folders from the host for config, Instructions.md and skills'
---
## What
ACPA-16 and D98: ACPAgent makes all its stacks with `DotfolderStack` from one list of folders, at two levels above the built-in layer: the user level (a root settings folder that the constructor takes; in the app `<iCloud container>/Agents/`) and the session level (the cwd of each `session/new`, `session/resume` and launcher start). The session level wins. With a root from the host, ACPAgent reads no folder in `~` and no `XDG_CONFIG_HOME`. The CLI gives no root, so it keeps its XDG folders.

Now ACPAgent makes separate stacks from bare names:
- `config.yaml` and `Instructions.md`: `ConfigurationLoader` (`Configuration/ConfigurationLoader.swift:143-219`) with `DotfolderStack(name: "acp-agent", ...)`. The factory is `RoutedACPAgent.makeConfigurationLoader(workingDirectory:)` (`SessionSetup.swift:793`). `InstructionsAssembler` uses `context.loader.stack` (`SessionSetup.swift:893`).
- Skills: `ToolCatalog.makeSkillsSource` (`ToolCatalog.swift:552-568`) with `DotfolderStack(name: "skills", ...)`.
- Also `RuntimeDoctor.swift:132`, `TranscriptsDoctor`, `ConfigCommand.Path` (line 341) and `LayerFileWriter` build stacks.

Do this:
- Add a type `SettingsFolders` (in `Configuration/`) that gives the layers for one cwd: `func stack(for kind: Kind, workingDirectory: URL) -> DotfolderStack`, with `Kind` = `.configuration`, `.skills`, `.agents`, `.rules`. Use `DotfolderStack.init(layers:)` (Extras `DotfolderStack.swift:180`), lowest layer first: built-in, user, project.
- With a root from the host: the user layer of `.configuration` is `<root>/`, and the user layers of the other kinds are folders in `<root>` whose names are never a valid agent id. Use `<root>/_skills/` and `<root>/_rules/` (as `_rules/` and `_partials/`). Agents are `<root>/<id>/` (the next card). The project layers stay the project dotfolders of the cwd (`.acp-agent/`, `.skills/`, ...).
- With no root (the CLI): the layers are the same as now (XDG user folder, project dotfolder).
- Add `rootSettingsFolder: URL? = nil` to the `RoutedACPAgent` init (`RoutedACPAgent.swift:288-313`; it replaces the narrow `userDirectory`, keep the old parameter only if a caller still needs it) and to `ComposedAgent.compose`.
- Use `SettingsFolders` in each place above. Every stack in the library comes from it, so no code path reads `~` or `XDG_CONFIG_HOME` when the root is set.
- The rules kind: FoundationModelsRules has no code yet, so only define the kind and the folder name. Do not add a dependency.
- Document the folder names in README.md.

## Acceptance Criteria
- [ ] With a root, `config.yaml`, `Instructions.md` and the skills come from `<root>` and the cwd, and the cwd wins.
- [ ] With a root, no stack contains a folder in `~` or `XDG_CONFIG_HOME`, also when `HOME` and `XDG_CONFIG_HOME` point to folders with a `config.yaml`.
- [ ] With no root, the layers are the same as before.
- [ ] `doctor` and `config path` show the layers of `SettingsFolders`.

## Tests
- [ ] A test with a temporary root, a temporary cwd and a temporary `XDG_CONFIG_HOME`: a key set in all three has the cwd value; a key set only in XDG is not set.
- [ ] A test that a skill in `<root>/_skills/` and a skill with the same name in the cwd give the cwd skill.
- [ ] A test with no root keeps the old layer list.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16