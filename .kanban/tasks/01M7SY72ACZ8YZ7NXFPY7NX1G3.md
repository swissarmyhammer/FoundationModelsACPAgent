---
assignees:
- claude-code
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: todo
position_ordinal: '9180'
title: 'D207: persist the transcript search catalog with the registry, and measure 1,000 sessions'
---
Decision D207. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/search/acpa-brief.md`, change step 5 and the last test. Overview: `overview.md` ("Across launches").

## Dependencies

- ^jex3g34 (the TranscriptSearchIndex).
- FoundationModelsMetadataRegistry on `main` with the persistence of its catalog and vectors, the update of some items, and the cost gate at 100,000 items (`mdr-brief.md`). Not on this board, and the registry session is not running yet: wait for the sha.

## Change

1. Give the searcher the persistence option of the registry, with the folder `<AgentHome.local>/session-search/server/` (a new folder name constant on `AgentHome`, as `codeContextFolderName`) and the model id of the `embedding` slot. Keep no other search file. The app's instance uses `.../client/`.
2. Use the registry's update of some items in the update path (replace the full-list `update(items:)`).
3. After launch, the searcher starts from its stored catalog; the reconcile then gives only the changed items.

## Tests

- A new agent over the same folder searches with no embed.
- A change of the embedding model id rebuilds the vectors.
- Measure with a realistic history (for example 1,000 sessions): the time of a search and of a turn update. Report the numbers to the TestudoApp session (testudoapp-9a). Do not change the design; the limits are in `mdr-brief.md`. #d207 #search