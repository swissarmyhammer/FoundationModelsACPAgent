---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Full root swift test: MCP stdio connect tests and AgentCatalogWatchTests fail in the full run, pass alone'
---
Found on 2026-11-21 during ^f4z8wj9. The failures are also on the base commit a844424 without the changes of ^f4z8wj9 (same dependencies, Router e221cbd).

## Facts

- In a full root `swift test` (load average 4 to 24 on the Mac), these tests fail: `ToolModeTests.theOpenModeConnectsAStdioServer` (result `connectFailed`), `MCPCompositionTests.theOutcomesListConfigServersFirstThenClientServers`, `MCPCompositionTests.configNounsMountFirstThenClientNounsAndNoPathCarriesAnMCPSegment`, `MCPCompositionTests.aConfigStdioServerThatExitsBeforeItAnswersFailsAndTheNextServerConnects`, and `AgentCatalogWatchTests` (time limit of 60 s exceeded). One run also had `SettingsGraphTests.theEndpointConforms` (a subscription probe gave no response in 10 s).
- Alone (`--filter`), each suite passes; `AgentCatalogWatchTests` passes in 0.8 s.
- On 2026-11-20 a full run passed (2738 tests) before the pins of Extras (49c6965), Multitool (d8863fb) and Router moved.

## Work

- [ ] Find the cause: the load of the full run (a connect or watcher timeout), or a change in a dependency pin.
- [ ] Make the tests deterministic in the full run.

## Tests

- [ ] Two full root `swift test` runs pass with zero failures. #flaky