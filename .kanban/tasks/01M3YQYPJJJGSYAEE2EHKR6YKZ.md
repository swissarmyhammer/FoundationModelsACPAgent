---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yqzy9tkjhkpsgqf7wc5q4w
  text: 'Upstream plan (FoundationModelsACP session, 2026-10-02): four tasks on its board, in this order: alpha.7 bump (^g2mkx79), session-update buffer (^1heg5df), merge engine (^2npy0da), messageId helper (^rpc6wrp). The helper waits for the engine: it also puts the echoed user message into an engine with the same ID. Thus the engine can be our retained history for session/resume; the engine task has a test that a replay of the transcript gives the same state with the same IDs. Implementation has not started (the owner has not said when). That session sends the head commit and the final helper name and signature when pushed. Start this card only then.'
  timestamp: 2026-10-02T16:43:37.658624+00:00
- actor: claude-code
  id: 01m3yv2e657qxnpez8gejezvm9
  text: |-
    Unblocked in part (FoundationModelsACP session, 2026-10-02): alpha.7 is on main at 63f0462.
    - `PromptResponse(messageId: MessageId)` is required; a missing or null `messageId` fails to decode.
    - `ToolCallUpdate.name` is `PatchField<String>` (omitted = `.unchanged`, null = `.cleared`, string = `.value`).
    - `NewSessionResponse.availableCommands` and `ResumeSessionResponse.availableCommands` are `[AvailableCommand]?`.
    - Pattern to copy: `acp-test-agent` makes a new `MessageId` for each prompt, returns it in the response, then echoes the prompt as a `user_message` update with the same ID.
    NOT on main yet: the helper (^rpc6wrp) and the merge engine (^2npy0da). Do changes 1 to 3 now with our own ID code, as acp-test-agent does. Leave change 4 (ID-stable replay from the engine) and the move to the helper for a later card when they are pushed.
  timestamp: 2026-10-02T17:37:25.189045+00:00
position_column: todo
position_ordinal: '80'
title: 'Adopt ACP schema-v2.0.0-alpha.7: PromptResponse.messageId (required), ToolCallUpdate.name, availableCommands in new/resume, ID-stable replay'
---
## Why

The FoundationModelsACP session (2026-10-02) moves the package to ACP schema-v2.0.0-alpha.7. The work is planned and NOT released yet. That session tells us when it is pushed. Do not start before then, and do not use a local override: move the pin with `swift package update` after the push.

## Changes

1. **REQUIRED (breaking).** `PromptResponse()` does not compile. For each prompt the agent:
   - makes a `MessageId` for the user message that it adds to the conversation;
   - sends a `user_message` session/update with that ID (before or after the response);
   - returns the same ID in `PromptResponse(messageId:)`.

   FoundationModelsACP supplies a helper that does "add, echo, return the ID" as one step. Use it. The current message echo is in the prompt acceptance path (`PromptExecution.acceptPrompt` / `scheduleModelPrompt`, plan.md §8.1). Slash commands (`CommandDispatch`) also return a `PromptResponse`: they need an ID too.
2. **OPTIONAL: `ToolCallUpdate.name`.** The program name of the tool (for example `runCode`, `skills`), with patch semantics: omitted means no change, null clears it. `title` stays the label for a person. Set `name` on the first update of each tool call (`EventProjection`).
3. **OPTIONAL: `availableCommands` in `NewSessionResponse` and `ResumeSessionResponse`.** Send the first command list there. A later `available_commands_update` replaces it.
4. **Resume: replay is the "retained history".** The agent can drop messages, but a message that it keeps and replays must keep its ID. FoundationModelsACP supplies a Sendable merge engine (it replaces `SessionUpdateAggregator`) that keeps an ordered transcript. Read whether the agent can use it as the retained history for `session/resume` (`SessionResume.swift`), or whether the Router journal must store the message IDs. The user message ID of change 1 must be stable across a resume.
5. **No change:** the extension stop reasons (`_truncated`, `_ended_in_reasoning`, `_repeated`, `_reasoning_limit`, `_stalled`, `_no_output`, `_error`) stay. Clients keep them raw through `StopReason.unknown(String)`, and AgentViewKit shows a banner for each one.

## Also check

- acp-client and the bench harness (`bench/swebench_acp.py`) read `PromptResponse`. The harness reads the stop reason from the idle update, but check that a new required field does not break its JSON reading.
- The tier-3 interop tests and `Examples/`.

## Tests

- Each prompt response holds a `messageId`, and a `user_message` update with the same ID reaches the client.
- A slash command response holds a `messageId`.
- The first update of a tool call holds `name`.
- `session/new` and `session/resume` responses hold `availableCommands`.
- A resumed session replays the kept messages with their original IDs. #upstream