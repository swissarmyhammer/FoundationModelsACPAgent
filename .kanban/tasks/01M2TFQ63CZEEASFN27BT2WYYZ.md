---
assignees:
- claude-code
position_column: done
position_ordinal: e180
title: 'Report upstream: Skills SSH marketplace fetch is unreachable, and CodeContext.start() waits for the full embedding pass'
---
Two faults are in sibling packages, and this repository only works around them:
- FoundationModelsSkills at `b902551`: `MarketplaceStore.start()` gives `unreachable` in 0.06 seconds for `git@github.com:swissarmyhammer/skills.git`, although `git push` over SSH works from the same shell. The HTTPS form works.
- FoundationModelsCodeContext: `CodeContext.start()` does not return until one full index pass is complete, with an embedding of each chunk. The pass embeds all chunks of one file in one batch. A host cannot get a started context for a large repository in a bounded time, and it cannot turn the embedding off.

Work: make one task or issue in each sibling repository with these facts. No code change in this repository. #upstream