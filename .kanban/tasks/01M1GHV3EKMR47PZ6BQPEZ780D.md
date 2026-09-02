---
assignees:
- claude-code
position_column: todo
position_ordinal: a280
title: Investigate intermittent zero-token empty responses in live-model prompt turns
---
## What
The tier-4 gated eval (PythonCLIEvaluation, task ^sdwc6d8) found an intermittent live-model defect on 2026-09-02: a prompt turn completes with `end_turn`, but the recorded `response` event carries an EMPTY text, `tokensOut: 0`, and `tokensIn: 0`, after 19 to 52 seconds of generation time. No tool call and no `prompt` entry is recorded for such a turn.

## Evidence
- Observed on `mlx-community/Qwen2.5-14B-Instruct-4bit` and on `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, driven through `RoutedACPAgent` over the ACP wire in-process (`swift test`, `MetalLibraryTestBootstrap` applied).
- The same wiring, model, and session produce full tool-driven turns on other runs, so the defect is intermittent.
- Kept transcripts with the empty responses sit under `/private/tmp/PythonCLIEval-user-*/transcripts/` from the 2026-09-02 runs. Example: a `response` event with `ms: 19198`, `tokensOut: 0`, empty text.
- One kept transcript also holds a `divergence` event: "backend transcript rewrote the recorded entry at index 0 in place".

## Where to look
- The Router live generation path (`streamResponse`) and its usage stamping: a 19-second generation that reports zero tokens in AND out is not a plausible generation report.
- Whether an internal generation error is swallowed and surfaces as an empty completed stream.

## Acceptance Criteria
- [ ] The cause of the empty zero-token turn is named.
- [ ] A turn that generates nothing reports an honest reason (an error, a refusal, or real token counts), never an empty `end_turn`.