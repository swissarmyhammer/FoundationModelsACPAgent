---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gnv60xxtd6ksd46yd5xwym
  text: |-
    ## Cause

    The empty zero-token `response` events and the empty `end_turn` come from two different turns. The kept transcripts and the unified log show the chain.

    ### Evidence from the kept transcripts and the system log

    - Each defect session shows the same three events: `session` meta, the `instructions` entry, and a `response` event with no `entry`, no `text`, `tokensIn: 0`, `tokensOut: 0`, and `ms` 10128-52157. No `prompt` entry exists. Examples: sessions 01M1GHNNZKDG0FD5EQZDQQJGF9 (ms 19198), 01M1GG6VHH6D3ZAGYREHXJXXPC (ms 52157), 01M1GHBYXPD5JE79CVZWQRGDJ4 (ms 10128).
    - The stall watchdog log shows that these turns made zero fragments for their full life: "generation has produced no fragment in 30.0s (0 so far)" (unified log, category PromptTurn, 02:40-02:55 on 2026-09-02).
    - Five sessions then hold a `divergence` event 1.4 s to 30 s after the failed close.

    ### Cause A - the recorded zero-token empty response event

    A bodyless `.response` event has exactly one producer: `recordFailedTurn` in `.build/checkouts/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:365-385`. Thus the model call of turn 1 THREW after 10-52 s. The token counts are zero because the MLX bridge stamps usage only at the successful end of a generation (`.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift:2350-2359` and `2413-2418` - `emitUsage` runs after the loop). A throw in the middle of the decode leaves `LanguageModelSession.usage` unchanged, so Router's delta (`RoutedSessionActorRecording.swift:31,115-121`) is a true (0, 0). The failed close records NO error reason (`makePartialEvent(kind: .response)` with no text), so the transcript cannot tell "errored" from "generated nothing". The thrown error type is recorded nowhere - not in the transcript and not in the log. The turn made zero response fragments for its full life, which agrees with a throw on the tool-call path before any response text - the eval's own notes name `RejectedToolCallError` (a malformed tool call, common on small local models; throw sites `MLXLanguageModel.swift:2204,2422,2551,2603`) as the usual case. This turn DID report `_error` on the wire through `PromptTurn.classify`.

    ### Cause B - the empty end_turn on the wire

    The eval re-prompts after each stop that is not `end_turn` (`Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLISubject.swift:190-212`). The follow-up turn completes without a throw, in as little as 1.4 s. Its transcript diff hits the divergence guard: the backend rewrote the recorded entry at index 0 in place (`TranscriptDiffer.divergence`, `RoutedSessionActorRecording.swift:167-181`). That branch records only the divergence marker and moves `persistedEntryCount` past ALL of the turn's own entries - the turn's prompt, tool calls, and response are never recorded. On the wire, `PromptTurn.drive` (`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:119-145`) maps every stream completion to `.completed` -> `end_turn`, with no check that the turn produced anything. A turn that completes with no text, no tool call, and a zero-token usage report thus ends as a bare `end_turn`.

    ### Decision

    This package can satisfy criterion 2 in its own code (option 2a): `PromptTurn` sees every event of the turn, so it can detect a completed turn whose stream carried no text, no reasoning, and no tool call, and whose `turnEnded` usage reported zero output tokens, and report the honest `_no_output` extension stop reason instead of a bare `end_turn`. Plan.md §8.2 permits this: "The value is `_`-extensible." The zero-token stamping of a FAILED turn (cause A) and the diff swallow of a diverged turn (cause B, Router recording) stay upstream facts, but the wire honesty criterion is closed here.
  timestamp: 2026-09-02T09:05:18.877253+00:00
- actor: claude-code
  id: 01m1gp67nfe0kpqm0z9ys0fcqt
  text: |-
    Implementation of option 2a is complete, with TDD (red first, then green):

    - `TurnStop` gains the `noOutput` arm, and `PromptTurn.noOutputStopReasonValue` = `_no_output` (the §8.2 `_`-extension rule).
    - `EventProjection` now tracks `sawOutput` (text, reasoning, tool call, tool status, invocation record, run settlement), `sawUsageReport`, and shows `generatedNothing`.
    - `PromptTurn.drive` maps a completed turn with `generatedNothing` to `noOutput` -> wire `_no_output`, never a bare `end_turn`. A turn with output, or a turn with no usage report, keeps `end_turn` - the fix does not invent an error the events do not support.
    - A test-support overload `ScriptedTurnFixture.idleStopReason(in: [SessionUpdate])` mirrors the existing `idleCount` overload.
    - Six new tests: the mapping totality arm, the no-output synthetic turn, the text guard, the tool-call guard, the no-usage-report guard, and the wire-level scripted `[.endTurn]` turn that reproduces the live defect shape end to end.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift, Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift
    - next: test
  timestamp: 2026-09-02T09:11:21.007292+00:00
- actor: claude-code
  id: 01m1gp7t653vkcsba2ksmxeq1r
  text: |-
    ### test — green
    - evidence: swift test — 301 tests in 34 suites passed, 0 failed, 0 skipped; the 1 "known issue" is the deliberate withKnownIssue negative assertion in HarnessSmokeTests (a test-helper test, present before this change); the single build warning comes from the pinned mlx-swift dependency's bundle build phase, not from this package's sources, and was present before this change.
    - next: commit
  timestamp: 2026-09-02T09:12:12.741840+00:00
position_column: doing
position_ordinal: '80'
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