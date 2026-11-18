---
assignees:
- claude-code
depends_on:
- 01M7QCBBA8BX23JY4SFZX4K6R4
position_column: todo
position_ordinal: '8680'
title: 'D200: integration test that the sessions skill examples agree with the real stack output'
---
Decision D200 in `TestudoApp/features/decisions.md` (commit d1895ba). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-sessions-skill.md`, the integration test. Draft skill text: `sessions-skill-SKILL.md` in the same folder.

## Dependency

- ^zx4k6r4 (the built-in layer of the skills stack).
- The D199 Router change: the header of a user message with a source session (`router-brief-at-sessions.md`, Router task 01M7NQNGH4YGB2Y1SS0JF3J3V5 and the tasks before it). Do not start until it is available.

## Change

Add a test in `IntegrationTests` with the real in-process stack and the Router session directory:

1. Start two sessions in one folder.
2. Make sure that the instructions of the default session hold the body of the `sessions` skill.
3. Send a message from one session to the other with the `sessions` tool, and send a user message with a source session.
4. Compare the receipt lines and the message headers that the real stack writes (`[message from session <id>]` with the fact lines, and the header of a user message with a source session) with the examples in the skill text.

When they do not agree, change the skill text in FoundationModelsMultitool, not the stack. Tell the Multitool session through a message or a card on its board (`sah --cwd <repo> tool kanban task add`).

## Tests

- The test above passes with the shipped skill text.
- The test fails with a clear message that names the example that does not agree. #d200 #sessions-skill #d199