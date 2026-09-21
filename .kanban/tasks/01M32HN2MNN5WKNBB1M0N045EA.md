---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A rejected tool call ends the whole turn instead of going back to the model
---
## What happens

When the model writes a tool call that MLX cannot parse, `MLXLanguageModel` throws `RejectedToolCallError` out of the generation. The error goes up through Router, and `PromptTurn` ends the turn with the stop reason `_error`. The model never sees the error, and it never gets a second try.

## Evidence

Measured on 2026-09-21 in `SkillTriggerTests` with `mlx-community/Qwen3-4B-Instruct-2507-4bit` and greedy decoding. The samples `release-notes` and `who-calls` end after 9 to 12 seconds with `_error`, no text and no tool call on the wire, in every run. The log line (added in this repo on the same day) names the cause:

```
failed: RejectedToolCallError(rejection: RejectedToolCall(reason: invalidArguments, format: json, ...
  rawTextPreview: "<tool_call>\n{\"name\": \"runCode\", \"arguments\": \"{ \\\"code\\\": \\\"async function getReleaseNotes() ...
```

The `arguments` value is a JSON string, which the parser accepts, but the JSON inside it has escapes that are not valid (a regular expression in JavaScript code, inside a JSON string, inside JSON).

The shipped model `mlx-community/Qwen3.8-27B-mxfp4` did not hit this in the same samples. A smaller or a different model does, and any model can.

## What must change

A rejected tool call must go back to the model as a tool error that says why the call was rejected, and the turn must continue, so the model can write the call again. Other agents do this.

The throw is in the `stable` branch of `swissarmyhammer/mlx-swift-lm`, `Libraries/MLXFoundationModels/MLXLanguageModel.swift` (the `.rejectedToolCall` cases). The fix belongs there, or in the Router turn loop. This repo cannot fix it.

## Acceptance

- With `mlx-community/Qwen3-4B-Instruct-2507-4bit`, `ACP_AGENT_SKILL_TRIGGER_SAMPLES=release-notes swift test --package-path IntegrationTests --filter SkillTriggerTests` no longer ends with `_error`.
- A test in the repo that owns the fix proves that a rejected call reaches the model as a tool error and that the turn continues.

#upstream #skills