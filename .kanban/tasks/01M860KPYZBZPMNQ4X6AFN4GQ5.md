---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: A discarded prompt ends its owner, so the close of the session does not wait for ever
---
Source: Testudo ^7w2b5nn, brief .briefs/FoundationModelsACPAgent-continue-resume-hang-2026-11-23.md.

When the connection closes while the agent handles `session/prompt`, FoundationModelsACP discards the deferred work and calls `onDiscard`. `scheduleModelPrompt` (PromptExecution.swift) and the `.action` arm of CommandDispatch.swift give no `onDiscard`. Thus the `PromptStateOwner` stays in `openPrompts`, and `cancelOpenPrompts` waits for ever in `waitForPromptEnd()`. The telemetry hook of the prompt is discarded too, so the prompt span does not end.

## Fix
- [x] Give an `onDiscard` at the two sites. It ends the owner as `cancelled` and runs `promptFinished`.
- [x] Give an `onDiscard` to the telemetry hook, so the span and the measurement end.
- [x] `waitForPromptEnd()` ends when its task is cancelled.

## Tests
- [x] A `.rendered` command holds the handler until the connection cancels it. The wire drops. Then `awaitPromptsFinished` and `closeOpenSessions()` end, and `openPrompts` is empty.
- [x] A cancelled wait of `waitForPromptEnd()` ends. #bug
## Result
- A rendered command held the handler. Before the fix, the test waited for ever in `awaitPromptsFinished`, and the cancelled wait waited in `waitForPromptEnd`. After the fix, the two tests pass.
- The full suite: 2849 tests pass, with 1 known issue.
