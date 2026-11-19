---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: 'AgentTranscriptSearcherTests is flaky: the background search updates of the fixture agent change the index between two reads'
---
Found during ^w0dheny (2026-11-19). The flake is there on HEAD 7ba6a38 with no change of the search code.

Evidence: `swift test --skip-build --filter AgentTranscriptSearcherTests --maximum-repetitions 30` on HEAD gave 10 failed expectations in 30 runs: `theAfterCursorOfTheFieldGivesTheNextPage` (first.nextCursor is nil; first.results + second.results != whole.results), `theSearchSessionsFieldGivesTheSessionsAndHitsOfTheTool` (results.count, snippets), `theSessionsToolSearchesWithTheSearcherOfTheAgent` (answer has no "lives on an island.").

Cause (from the failure output): the fixture indexes its chunks with `indexWord` directly in `agent.transcriptSearchIndex`, but the agent of the fixture also runs `TranscriptSearchUpdates` in the background. A directory event of a new session (the name "default-2" from D199 naming, the history of the prompt) replaces the items of the session in the index while the test reads its pages. Thus two reads of the same query can see two states of the index: a session item with the snippet "default-2" comes in one page and not in the other, and the indexed chunk "The quokka lives on an island." can be replaced by the history of the session.

Fix direction: the test waits until the background updates of the fixture are idle before it indexes its chunks and reads its pages, or it indexes into an index that no background update writes. Do not weaken the assertions. #test #flaky #search