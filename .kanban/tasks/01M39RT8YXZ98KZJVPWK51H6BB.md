---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39t4d8mxc7zxmgnavmec44t
  text: |-
    Scope added (from the Router session, 2026-09-24): Router card ^1hcwaqy, not committed yet, brings two more enum cases and a host option. Handle them in this card.

    ## Two more cases

    - `FinishReason.repeatedLines`: the call stopped because it repeated itself. Map it to a stop reason that says so (proposal: `_repeated`), beside `_truncated` and the value for `.endedInsideReasoning`, in `PromptTurn.stopReason(for:)` and in `ExitCode.swift`.
    - `SessionEvent.repetitionStopped(RepetitionStop)`: the detector stopped a call. `EventProjection` has an `@unknown default` arm, thus it compiles, but the event must not fall into it silently. Log it with its numbers, as the `_truncated` line does, and decide whether it reaches the wire.

    A `switch` with no default over either enum does not compile until it handles the new case. Check `Sources` and `Tests` when the Router commit lands.

    ## The host option

    `RepetitionDetection` (isEnabled, windowTokens, minimumLineLength, recoveriesPerTurn; defaults true, 2,048, 20, 2 — the owner approved these as configurable starting points). It passes through `SessionConfiguration.repetitionDetection`, or a new last parameter `repetitionDetection:` of `makeSession(...)`.

    Expose it in `config.yaml`, for example under `compaction:` or a new `repetition:` section, with the four keys and Router's defaults when absent, and pass it in `makeBudgetedSession`. Add it to `config show`, to the codec tests, and to the bench README.
  timestamp: 2026-09-24T13:36:58.132988+00:00
- actor: claude-code
  id: 01m39zhvfdec6c3x0aa8f5xqrw
  text: |-
    Scope added (from the Router session, 2026-09-24): Router cb631e6 and 94a5723 (^gg49g5e there) add the transcript event kind `repeatedPartRemoval`. A session that had a repetition stop writes it; a restore reads it, so that the repeated part stays out of the restored render.

    ## What it does here

    - `SessionResume.update(for:)` switches over `TranscriptEvent.Kind` with no default, thus the build breaks until it names the new case. It is bookkeeping, not a message: add it to the arm that returns `nil`, beside `.generationCall`, with a comment.
    - Check every other `switch` over `TranscriptEvent.Kind` in `Sources` and `Tests` (`TerminalStream`, `SessionResumeTests`) the same way.
    - Test: a session resumed from a journal that holds a `repeatedPartRemoval` line replays no message for it, and replays the messages around it.

    Decision of the owner (2026-09-24): no compatibility work. Journals from older builds are not a concern of this card.
  timestamp: 2026-09-24T15:11:41.549533+00:00
- actor: claude-code
  id: 01m3nhkvr14g0pkgv9hs9v61kz
  text: |-
    Blocker (2026-09-28): the pinned Router cannot supply the new case.

    - The local `Package.resolved` pins FoundationModelsRouter to bbad3ce. The current family main branches break the build here, thus the pin stays. The adoption of the newer Router API is card ^tz867gz, which is blocked.
    - In `.build/checkouts/FoundationModelsRouter` (HEAD bbad3ce), `FinishReason` has only `completed` and `maxTokens`. A search for `endedInsideReasoning` finds no match.
    - `git merge-base --is-ancestor b3b3d72 HEAD` returns 1: Router b3b3d72 is not in the pinned revision. The cases `repeatedLines`, `SessionEvent.repetitionStopped`, `RepetitionDetection` and the transcript kind `repeatedPartRemoval` from the added scope are also after the pin.

    No file changed. This card can continue when ^tz867gz moves the Router pin to a revision that holds b3b3d72.

    ### implement — stuck
    - evidence: pinned Router bbad3ce has no `FinishReason.endedInsideReasoning`; b3b3d72 is not an ancestor of bbad3ce. No file changed.
    - next: finish ^tz867gz (Router pin adoption), then do this card again.
  timestamp: 2026-09-29T02:59:00.481443+00:00
- actor: claude-code
  id: 01m3nhm8wkhvsy7te9t6h8qpe9
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The pinned Router bbad3ce has no FinishReason.endedInsideReasoning (it came in Router b3b3d72).
    - test, commit, review: not run
    - next: this task waits for ^tz867gz (adopt the newer Router).
  timestamp: 2026-09-29T02:59:13.939596+00:00
position_column: todo
position_ordinal: '8180'
title: Map Router's endedInsideReasoning finish reason to an honest ACP stop reason
---
## What changed in Router

Router b3b3d72 (card ^gfxd7av there) adds `FinishReason.endedInsideReasoning`: the output of a generate call ended inside the reasoning, below the ceiling. `.maxTokens` now means only that the call reached its ceiling. Router does not compact after the new case and does not send its ceiling continuation prompt.

## The gap here

`EventProjection.endedAtTokenCeiling` reads `lastFinishReason == .maxTokens`, and `PromptTurn` then ends a completed turn with `_truncated`. No `switch` over `FinishReason` exists, thus the build does not break. But a turn whose last call ends with `.endedInsideReasoning` now reports a plain `end_turn`: a cut turn reads as a finished one.

## What to do

1. Give the new case its own ACP stop reason. Proposal: a new extension value, `_ended_in_reasoning`, beside `_truncated`, so a client and the bench record can tell "reasoned until it stopped, with no answer" from "reached the output ceiling". Decide the name in the card.
2. Map it in `PromptTurn.stopReason(for:)`, and in the exit code table of `acp-agent` (`ExitCode.swift`), as `_truncated` is mapped.
3. Log it with the usage numbers, as the `_truncated` log line does.
4. Tests: a scripted turn whose last usage report carries `.endedInsideReasoning` ends with the new stop reason, and one with `.maxTokens` still ends with `_truncated`.
5. The bench README table of stop reasons names the new value.

Depends on Router b3b3d72 being on Router main.

#upstream