---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bg46j405zfdnd6j3qy90tw
  text: |-
    ### acceptance — bench evidence
    - The commit of this task in this repo is f3d00bf "fix(agent): make the record of a cut prompt name the cause". The commit message names the task by a wrong short id (^1pw3j6m). It is this task (^dcmsxpw).
    - The Router part is done upstream: Router ^0dcsd3t and ^8eq31j0. Both are in the pin of this repo.
    - Acceptance "A bench run of django__django-13710 and django__django-13964 gives a non-empty patch" is met. In the run `bench/preds.code-context-1006.jsonl`, the two instances made patches, and the two instances are RESOLVED. Score: `bench/preds.code-context-1006.jsonl.score.score_20261006_143842.json`.
    - Commit 09b7295 (^1x5ksdv) later replaced the `context.fill` key of the cut record.
  timestamp: 2026-10-07T15:36:16.196810+00:00
- actor: claude-code
  id: 01m4bg48yw3rtdce3x7q1bp0a5
  text: |-
    ### review — findings
    - evidence: `review sha f3d00bf~1..f3d00bf`, 1 finding (1 confirmed, 1 refuted). Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift:611 `swift/doc-parameter-naming`. The line is the same in the current code (HEAD 09b7295 did not change it).
    - next: change the doc comment of `report(cut:metadata:changedFileCount:)` from `- metadata:` to `- cutMetadata:`, and remove the same cause from the whole file. Then run the review again.
  timestamp: 2026-10-07T15:36:18.652118+00:00
position_column: review
position_ordinal: '80'
title: 'bench: a prompt that stops at the reasoning limit gives an empty patch, and the stop report does not say why'
---
## Why

Found in the SWE-bench run `bench/preds.code-context.jsonl` of 2026-10-05 (16 django instances, model `mlx-community/Qwen3.8-27B-mxfp4`, 14 patches, 2 empty). Both empty patches come from prompts that stopped at the reasoning limit:

- `django__django-13710`: 1088 s, `tokens.in=144653 tokens.out=29046`, `prompt.stop_reason=_reasoning_limit` (`bench/run.code-context.log` line 2678). The transcript has no edit call.
- `django__django-13964`: 2058 s, `tokens.in=1233016 tokens.out=45956`, `prompt.stop_reason=_reasoning_limit` (`bench/run.code-context.log` line 8020). The transcript has 4 lines that name an edit, but the final patch is empty.

The log line of both is an `error` of `FoundationModelsACPAgent.PromptExecution`: "The last submission of the prompt did not end by itself." The line does not say how many recoveries ran, how many reasoning tokens the last pass made, or if the agent changed a file.

In 13964 the generation stalled many times. The longest gap is 434 s before seq 1476 (a `prompt` row). Other long gaps are before `instructions` rows (285 s before seq 1287, 257 s before seq 1561). Transcripts: `bench/preds.code-context.transcripts/django__django-13964/01M463CMSNG9DJXGSRDY2027CT/transcript.jsonl` and `bench/preds.code-context.transcripts/django__django-13710/01M460H04P6D49QAZ3GNRE65ZP/transcript.jsonl`.

## Where the code is

- The limit: `RepetitionDetection.defaultReasoningTokenLimit = 8_192` in the sibling repo FoundationModelsRouter, `Sources/FoundationModelsRouter/Session/RepetitionDetection.swift:53`. The recoveries: `defaultRecoveriesPerAnswer = 2` (same file, line 34). The check: `RepetitionDetector.swift:215`.
- The recovery: `RoutedSessionActorReasoningStop.swift:98-101` (`reasoningStopContinuationPrompt`, "Do not reason more. Act now") and `:152-182` (continue, or compact and continue). With no recovery left, the answer ends with `FinishReason.reasoningTokenLimit`.
- This repo, the config: `Sources/FoundationModelsACPAgent/Configuration/RepetitionConfiguration.swift:49-54` (`repetition.reasoningTokenLimit`, `null` gives no limit).
- This repo, the stop: `Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift:309-312` (a completed prompt whose last submission did not end by itself is cut), `:535-544` (`cutStop(for:)` maps `.reasoningTokenLimit` to `.reasoningLimit`), `:133` (`_reasoning_limit` wire value), `:609-615` (`report(cut:usage:)`, the log line).
- `Sources/acp-agent/ExitCode.swift:72`: `_reasoning_limit` exits 1.

## What to do

1. Read the two transcripts. For each reasoning stop, record the pass, the reasoning tokens, the recovery number, and if a compaction ran. Find out if the agent ever applied an edit in 13964, and why the patch is empty.
2. Find the cause of the long gaps before `prompt` and `instructions` rows (probable cause, not yet proven: a compaction or a recovery submission). Record it in this task.
3. Change the agent so that a long task makes progress before the limit. Options to measure (one each, with the bench): a higher `repetition.reasoningTokenLimit` in `bench/code-context.config.yaml`; more recoveries; a recovery prompt that tells the model to apply the edit it has. Keep the change that gives non-empty patches.
4. Make the stop report better: add to the log line of `report(cut:usage:)` the recovery count, the reasoning tokens of the last pass, and the number of files the prompt changed. If a Router change is necessary, record it as a task on the Router board, and name it here.

## Acceptance

- The cause of each empty patch is in this task, with evidence.
- A bench run of `django__django-13710` and `django__django-13964` gives a non-empty patch, or the task says why it cannot.
- The `_reasoning_limit` log line holds the new fields, and a test proves each field.
- `swift build` has no warnings, and `swift test` passes.

#bench #upstream
## Notes (2026-10-05)

### Root cause, from the two transcripts
- `django__django-13710`: the last three passes each hold about 8k reasoning tokens (34781, 32148 and 35617 characters, seq 393, 397 and 401). The first two passes stopped for repeated lines (two `repeatedPartRemoval` rows, and the recovery prompt "Your last output repeated lines ..." at seq 395 and 399). The third pass stopped at the reasoning token limit with no recovery left. The reasoning loops on one `__init__` block of `django/contrib/admin/options.py`. The transcript has no write, edit or patch call. Thus no tracked file changed, and the patch is empty.
- `django__django-13964`: the last three passes each hold about 8k reasoning tokens (31792, 32603 and 31971 characters, seq 1475, 1478 and 1481). The model deliberates about the fix ("Let me implement the fix. Actually, hold on ..."). The only writes are `tools.files.write` calls of reproduction scripts (`repro_issue.py`, seq 1444, 1460 and 1468). These files are untracked, and `git diff <base_commit>` in `bench/swebench_run.py` reports tracked files only. No edit of a source file occurred, and nothing was reverted. Thus the patch is empty.
- The stopped passes have no `generationCall` row in the transcripts.
- The bench log keeps only `warning` and above. The Router stop records of the agent (`EventProjection.reportRouterStop`) are `notice` records, so the log of the run holds no record of the five Router stops. The `error` record of `report(cut:usage:)` was the only record, and it did not name the cause.

### Done in this repo (commit f3d00bf; `swift test`: 742 tests in 83 suites pass)
- `EventProjection` counts the Router stops (repetition and reasoning) and the recoveries that followed them, keeps the last `ReasoningStop`, and records the distinct files of each `FileChangeSet`. `cutMetadata` gives these values.
- The `error` record of a cut prompt now has the keys `reasoning.tokens`, `reasoning.limit`, `router.stops`, `router.recoveries` and `files.changed`, and a message that names the cause, for example: "Router stopped the last pass of the prompt at the reasoning token limit, because it reasoned and did not act and no recovery was left. The files verbs of the prompt changed no file."
- Limit: `files.changed` counts the changes that the files verbs record. A shell command that writes a file records no change set.
- Tests: `EventProjectionTests.theReasoningLimitRecordNamesTheLimitTheTokensAndTheRecoveries` and `theReasoningLimitRecordCountsTheChangedFiles`.

### Remains for Router
- This task depends on Router task ^0dcsd3t for the real fix (a recovery with no thinking, a final pass with no thinking, no empty text after the last recovery). The bench acceptance item ("a bench run gives a non-empty patch") waits for ^0dcsd3t.
- `RoutedSessionActorReasoningStop.swift:98-101`: the recovery prompt only asks the model to act. It runs with thinking still on, so the model reasons for one more full pass.
- `RoutedSessionActorRepetitionWatch.swift:425-429` (`continueAfterWatchStop`): this is the path of a watch stop at the reasoning token limit. With no recovery left, it returns the response text of the stopped attempt, which is empty. With a recovery left, `runContinuation` sends the prompt of `:74` with the same generation options. `RoutedSessionActorReasoningStop.swift:174` does the same for a pass that ended inside its reasoning.
- `RepetitionDetection.swift:34` (`defaultRecoveriesPerAnswer = 2`) and `:53` (`defaultReasoningTokenLimit = 8_192`): the repetition stops and the reasoning stops use one recovery count, so in 13710 the two repetition stops used both recoveries before the reasoning stop.
- Router task ^3anq1yz: `context.fill=0.031` in both records is not the real fill (1233016 tokens in for 13964).

## Review Findings (2026-10-07 10:31)

> Scope: `review sha f3d00bf~1..f3d00bf` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 0 not reviewed.

- [ ] `Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift:611` `swift/doc-parameter-naming` — Doc comment uses the external parameter label `metadata` instead of the internal parameter name `cutMetadata`. Doc comments must name the internal (local) parameter, not the external argument label. Change `- metadata:` to `- cutMetadata:` to match the internal parameter name.
