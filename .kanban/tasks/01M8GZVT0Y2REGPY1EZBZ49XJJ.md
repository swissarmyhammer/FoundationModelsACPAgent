---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8gzx4ccfk11ksfbbh8ctejd
  text: '2026-11-28, testudoapp-4f: a new FoundationModelsAgents session will do the reserved-ids change. This session does not commit to that repository. Keep this card blocked until testudoapp-4f sends the sha of that change. Then update the FoundationModelsAgents dependency, do this card and run the full tests.'
  timestamp: 2026-11-28T11:51:01.260369+00:00
position_column: todo
position_ordinal: '8180'
title: The user skills folder is `skills`, not `_skills` (D219)
---
## Source

Brief from the Testudo coordinator (testudoapp-4f), decision D219: `/Users/wballard/github/swissarmyhammer/.briefs/settings-folders/FoundationModelsACPAgent-skills-folder-name.md`.

## Dependency

FoundationModelsAgents must reserve the ids `skills` and `profiles` first (brief `.briefs/settings-folders/FoundationModelsAgents-reserved-ids.md`). On 2026-11-28, `AgentDefinitionRules.isValidID` (`FoundationModelsAgents/Sources/FoundationModelsAgents/Definition/AgentDefinitionRules.swift:77`) does not reserve them, and that package has no live session. Land this card together with that change or after it. If this card lands first, the agent catalog reads `<synced>/skills/` as an agent, and `withARootTheSettingsFoldersOfTheRootAreNotAgents` fails.

## What to do

1. `SettingsFolders.skillsFolderName` (`Sources/FoundationModelsACPAgent/Configuration/SettingsFolders.swift:61`) becomes `"skills"`.
2. Change the docs and comments that name `_skills`:
   - `Configuration/SettingsFolders.swift:20`
   - `Configuration/AgentHome.swift:41`
   - `Tools/AgentsComposition.swift:269`
   - `Tools/ToolCatalog.swift:282` and `:988`
   - `Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift:504`, `:562`, `:581`, `:705`
   - `Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift:44`
   - `README.md` and the `docs/` folder, if they name `_skills`.
3. The profiles folder stays `profiles` (`ProfileFile.folderName`).
4. No migration (the product is not shipped).

## Acceptance criteria

- [ ] With a custom home, the user layer of the skills stack is `<synced>/skills/`.
- [ ] A skill written with `layer: user` goes to `<synced>/skills/<name>/SKILL.md`.
- [ ] With a root, `<root>/skills/` and `<root>/_rules/` are not agents and give no diagnostic (the test at `SettingsFoldersTests.swift:705` passes with the new name).
- [ ] No text `_skills` stays in Sources, Tests or docs.

## Coordination

Before builds or tests, obey the holds from testudoapp-4f. Ask for a CPU slot and send START and END lines to testudoapp-4f. #feature #blocked-external