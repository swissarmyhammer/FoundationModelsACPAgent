---
assignees:
- claude-code
position_column: done
position_ordinal: fffff980
title: 'Marketplaces: implement resetSources() in SettingsMarketplaceSourceStorage'
---
Blocked until Extras has `MarketplaceSourceStorage.resetSources() -> [MarketplaceSource]` and `MarketplaceRegistry.reset()` on main (Skills adds `resetMarketplaces` and the `reset marketplace` op).

- `resetSources()` clears `tools.skills.marketplaces` at the USER level through the settings store (`clear`), and gives the effective list after that: the value with `cwd: nil` (defaults and builtin layers), else `SkillsToolOptions.defaultMarketplaces`.
- The registry of the agent has no working directory, so the project list does not apply to its answer. Each session still reads its merged list after the change (`MarketplaceMount.sources`).
- Tests (/tdd): a save then a reset removes the user key from the file, and the reset gives the default list; a session follows the reset.
- Push, and send the commit to testudoapp-75. #D190