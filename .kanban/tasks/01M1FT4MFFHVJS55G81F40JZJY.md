---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gm04pmrt7c19kxd03sp4hn
  text: |-
    Verification of the pinned Router checkout (.build/checkouts/FoundationModelsRouter, commit 87c660b6a16c2e9375219a1052ad68c2c846d41e):

    No public door shows the resolved standard-slot context in tokens at session-construction time.

    - `RoutedModel.resolution` has `package` access — Sources/FoundationModelsRouter/LanguageModelProfile.swift:28.
    - `SlotResolution` is a `package struct` — Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:89. Its `contextTokens` has `package` access — Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:104.
    - `RoutedModel` shows only `chosen` (LanguageModelProfile.swift:22) and `footprintBytes` (LanguageModelProfile.swift:25) publicly.
    - `ProfileDefinition.context` (Core/ProfileDefinition.swift:44) is public, but it is the requested value, not the resolved value. The resolution ladder can select a smaller context (Resolution/JointFit.swift:548).
    - `RestoredSession.ContextMismatch.resolved` (Recording/SessionRestoration.swift:26) is public, but only a restore that finds a mismatch supplies it. It is not a read for a new session.
    - `TurnOutcome.contextFill` (Session/TurnOutcome.swift:21) and `SessionEvent` usage (Session/SessionEvent.swift:97) give fractions after a turn, not a token limit before `makeSession`.
    - `ResolutionProgress` (Resolution/ResolutionProgress.swift:72) reports only phase transitions, not the resolved context.

    Also noted: `RoutedSessionActorCompaction.swift:280` shows `budget ?? TokenBudget(limit: contextTokens)`, but this default applies only inside a fold. Automatic compaction stays off unless `makeSession` receives a non-nil `budget` (RoutedLLM.swift:49-50, "budget: The auto-compaction opt-in, or `nil` for manual compaction only").
  timestamp: 2026-09-02T08:33:04.212972+00:00
- actor: claude-code
  id: 01m1gm09gzvd7vg3csnw1wet9q
  text: |-
    ## Upstream ask for FoundationModelsRouter

    Please supply a public read of the resolved standard-slot context in tokens. Examples: a public `RoutedModel.contextTokens`, or a public `SlotResolution.contextTokens` together with a public `RoutedModel.resolution`.

    Motivation: FoundationModelsACPAgent must build `TokenBudget(limit:)` at `session/new`. The config `compaction:` section carries only fractions (`trigger`, `target`, `hardCeiling`) and `toolOutputLimit`. The limit must come from the model's resolution. Today `budget:` stays `nil` in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` and automatic compaction is off (card ^f40jzjy).

    Filed as Ask 3 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md.
  timestamp: 2026-09-02T08:33:09.151948+00:00
- actor: claude-code
  id: 01m1gm0f6nt846w2tch17ks535
  text: |-
    ### finish — stuck
    - evidence: The task is blocked upstream. The seam is missing in the pinned Router checkout (commit 87c660b): `RoutedModel.resolution` is `package` (Sources/FoundationModelsRouter/LanguageModelProfile.swift:28) and `SlotResolution.contextTokens` is `package` (Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:104). No public member of `RoutedModel`, `Router`, or a resolution report shows the resolved standard-slot context in tokens. The ask is filed as Ask 3 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md and as a comment on this card.
    - next: Wait for FoundationModelsRouter to land the public read. Then build `TokenBudget(limit: <resolved context>)` from `CompactionConfiguration` in SessionSetup, pass it as `budget:`, remove the TODO, and add the test. No code change and no commit were made in FoundationModelsACPAgent. The card stays in todo.
  timestamp: 2026-09-02T08:33:14.965921+00:00
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
position_column: todo
position_ordinal: '9e80'
title: Wire the compaction TokenBudget into session/new when Router shows the resolved context
---
## What
`session/new` (^63bbyr8) passes `budget: nil` to `profile.standard.makeSession(...)`, so automatic compaction is off.

Cause: `TokenBudget` requires a `limit` in tokens. Router does not show the resolved working context through its public API. `SlotResolution.contextTokens` and `RoutedModel.resolution` have `package` access. The config `compaction:` section carries only fractions (`trigger`, `target`, `hardCeiling`) and `toolOutputLimit` (plan.md §2.4: the context comes from the model).

## Steps
- [ ] Add a public read of the resolved standard-slot context to FoundationModelsRouter (for example `RoutedModel.contextTokens`), or use an equivalent public door when one lands.
- [ ] In `SessionSetup`, build `TokenBudget(limit: <resolved context>, trigger:, target:, hardCeiling:, toolOutputLimit:)` from `CompactionConfiguration` and pass it as `budget:`.
- [ ] Remove the marked TODO in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`.
- [ ] Test: a session made with a config `compaction:` section carries the derived budget (asserted through visible behavior or a recorded sidecar field).

## Acceptance Criteria
- [ ] `session/new` passes a non-nil `budget` derived from the compaction config and the model's resolved context.
- [ ] `swift test` green.