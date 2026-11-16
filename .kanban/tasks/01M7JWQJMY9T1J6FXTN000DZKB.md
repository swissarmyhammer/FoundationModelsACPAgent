---
position_column: done
position_ordinal: fffff880
title: Mount the marketplace registry of Extras over tools.skills.marketplaces
---
testudoapp asks for the marketplace mount (D190).

- `SettingsMarketplaceSourceStorage`: the Extras `MarketplaceSourceStorage` over `tools.skills.marketplaces` at the USER level. With no key, the list is the default list.
- `RoutedACPAgent.marketplaceRegistry`: one `MarketplaceRegistry` for the agent.
- `SessionMarketplaces`: the marketplace layers of a session. On each registry change, it makes a new `MarketplaceStore` from the merged list of the session, starts it, swaps it in, stops the old store, and tells the skills and agent registries to read the layers again.
- The skills tool and `SkillsGraph` get the registry when Skills (`SkillsTool.make(..., marketplaces:)`) and Agents (card 01M7JWNG on its board) have the parameter.