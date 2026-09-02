---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g4nyfvqj9sdp5vmmbt3ydt
  text: |-
    Research and implementation notes (TDD: the failing tests came first, then the code).

    Discoveries:
    - `RoutedSession` binds to one slot at `makeSession` and has no mid-session model switch. Thus the slot switch replaces the entry's Router session with one vended from the selected slot's resident handle. The replacement records under the ACP session's own transcript directory, so the lineage stays on disk the way §4.2 states it for a fork's nesting. The replaced session is closed when idle.
    - Value ids are the stable slot names ("standard" / "flash"); the labels show each slot's `chosen.stringValue`, per the card. `SessionConfigSelectOptions` is a deferred union (raw JSON) in the wire package; the flat list is encoded through the generated `SessionConfigSelectOption` coder so the wire shape cannot drift.
    - The divergence push: each session stores the announced option state (`announcedConfigOptions`). `turnFinished` reconciles the truth against it and pushes ONE `config_option_update` with the full list on a difference. The test scripts a divergence through `recordAnnouncedConfigOptions`, the same production seam `session/new` and `set_config_option` use.
    - Test support: `StubModelLoader.makeLLMContainer` now receives the `ModelSlot`, so a per-slot scripted loader proves which slot generated a turn.

    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift, Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/ConfigOptionsTests.swift (new), Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift, Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift (+ AssertionHelpers, ScriptedModel, BuiltinCommandsTests, TranscriptRecordingFixtures call-site updates)
    - next: run the full test suite
    task: ^r7t7xe1
  timestamp: 2026-09-02T04:05:21.531613+00:00
- actor: claude-code
  id: 01m1g4q406y05rtqkvwznhwgme
  text: |-
    ### test — green
    - evidence: swift test — 235 passed in 25 suites, 0 failed, 0 skipped; swift build --build-tests — 0 warnings. The 1 "known issue" is pre-existing and deliberate: HarnessSmokeTests proves the ordered-subsequence helper can fail through `withKnownIssue`.
    - next: commit
  timestamp: 2026-09-02T04:05:59.942436+00:00
- actor: claude-code
  id: 01m1g4x14f9cq8t9rxdmwr34gc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1dbac50) — 0 findings, 13 files reviewed, 7 validator runs, 0 failed. Task moved to done; the subtask and acceptance boxes are checked with the tests as evidence.
    - next: none
  timestamp: 2026-09-02T04:09:13.615767+00:00
- actor: claude-code
  id: 01m1g4x5bytzv60gtjc36xnrw3
  text: |-
    ### finish iteration 1 — done
    - implement: changed (TDD — the 6 failing tests came first; ConfigOptions.swift and the session-table wiring made them pass)
    - test: green (swift test — 235 passed, 0 failed, 0 skipped; 0 warnings)
    - commit: 1dbac50
    - review: clean (review sha HEAD~1..HEAD — 0 findings); task moved to done
  timestamp: 2026-09-02T04:09:17.950928+00:00
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
position_column: done
position_ordinal: '9280'
title: 'Session config options: model slot select over standard/flash'
---
## What
Plan.md §15. Create `Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift`.

- One real option on day one: a `select`, category `model`, over the resident profile's `standard` and `flash` slots. Both are already resident, so a switch loads nothing and blocks on nothing. The `description` says it selects among the profile's slots, so a user does not expect a full candidate list.
- This task owns the option construction, the `session/new` announcement that replaces the placeholder, `set_config_option`, and the divergence push. The `session/resume` response announcement is the resume task's wiring job and consumes the same construction exposed here. No ordering edge is needed; whichever lands second connects it.
- Announcement: a priority-ordered array. Every option MUST have a default.
- `session/set_config_option` applies the slot switch. The response and any push carry the complete state, with `configOptions` required. Never send a delta.
- `config_option_update` is load-bearing. When Router's joint-fit resolution lands on a different model than the option shows, push the update so `currentValue` is the truth (§15).

**Facts that shape the option:**
- `LanguageModelProfile` exposes `definitionName`, `standard`, `flash`, `embedding` and `release()`. The slots are `RoutedLLM` values, so the option switches which handle the next session uses.
- Each `RoutedModel` exposes `chosen: ModelRef` and `footprintBytes`. Show `chosen.stringValue` as the option label, because `ModelRef`'s `repo` and `revision` are internal and `stringValue` is the only public read.
- **Hold the profile strongly.** `RoutedModel` holds its owning profile weakly, and `makeSession` traps if the profile was released.
- `ModelSlot` is `standard`, `flash` and `embedding`. Offer only `standard` and `flash`. Embedding is not a chat slot.
- It does not need pooled residency. That matters only for a profile switch.

- Intentionally absent: `mode`, `thought_level` (Router shows no reasoning-level knob), and a `model_config` context size. No groups.

- [x] The select option built from the resident profile
- [x] Announcement in the session/new response
- [x] `set_config_option` full-state semantics
- [x] Divergence push through `config_option_update`

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/set_config_option` with an unknown `sessionId` gives JSON-RPC invalid params (`-32602`) with the id in `data`. A known but closed session gives `-32602` with the reason "closed; resume it first".

## Acceptance Criteria
- [x] `session/set_config_option` on an unknown or closed id gives `-32602` and pushes no `config_option_update`
- [x] The `session/new` response carries exactly one config option, kind select, with a `currentValue` default
- [x] The option's labels show each slot's `chosen.stringValue`
- [x] `set_config_option` to `flash` succeeds, the returned complete state shows `flash`, and later turns use the flash slot, asserted through the scripted loader
- [x] A scripted resolution divergence produces one `config_option_update` carrying the full option list

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ConfigOptionsTests.swift` — harness-driven
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.