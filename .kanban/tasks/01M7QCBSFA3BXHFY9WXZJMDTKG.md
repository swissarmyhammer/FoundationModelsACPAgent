---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qm5apgh8sz7ecmaqe0vjff
  text: 'Skill text available (2026-11-18): the final text of the built-in `sessions` skill is on FoundationModelsMultitool origin/main, commit a5234d76 (main head 88ada32e), version 1.1.0. The path and API did not change: `BuiltinSkills.directory` → `sessions/SKILL.md`. The text names the address forms `@<id>`, `@<short id>`, `@<slug>`, the aliases, and the receipt words `delivered`, `queued`, `sent`, `started`, `refused`. A test in Multitool checks the skill against the tool. Compare the examples of this text with the real stack output. This task still waits for the Router D199 header and event work (^jf3j3v5).'
  timestamp: 2026-11-18T15:24:46.160294+00:00
- actor: claude-code
  id: 01m7qn7jt215p1ke21jnmn4pxt
  text: |-
    Skill text update (2026-11-18): the `sessions` skill 1.1.1 is on FoundationModelsMultitool origin/main, commit e76f7d2e (main head 288eae56). It shows the message headers as Router origin/main 709d82c5 writes them:
    - A user message with a source session: `From the user, in <title> (<folder>)`, a blank line, then the text. Unknown source: `From the user, in the session <id>`.
    - A message from a session: the Router header with the `agent name:` line and the fenced block `message from another agent`.
    - The old `[message from the user, ...]` form is gone.
    Use this version (or later) for the comparison. The Router D199 work is on main, so this task waits only for ^qa7btpc on this board.
  timestamp: 2026-11-18T15:43:28.578078+00:00
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