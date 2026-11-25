---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: 'Rules folders: follow D63 (<cwd>/.agents/rules/, the user rules folders)'
---
## Problem

TestudoApp decision D63 (features/decisions.md): rules are the package FoundationModelsRules, with four layers:
- built-in (in the package);
- user (`<iCloud container>/Rules/` and `~/.config/agents/rules/`);
- agent (`<agent folder>/_rules/`);
- project (`<working folder>/.agents/rules/`).

There is no session layer. `SettingsFolders` of ACPAgent gives other folders for `Kind.rules`: `<cwd>/.rules/`, `<synced>/_rules/` and `~/.config/rules/`. The plan of FoundationModelsRules says not to use `.rules`, because Zed has a `.rules` file.

## Work

- Change `SettingsFolders` for `.rules` to the folders of D63. This is before the release, so there is no migration.
- Update the docs and the tests of the folders.
- No reader of rules exists yet, so no other code changes.