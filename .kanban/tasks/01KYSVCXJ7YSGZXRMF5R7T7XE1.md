---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
position_column: todo
position_ordinal: '9480'
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

- [ ] The select option built from the resident profile
- [ ] Announcement in the session/new response
- [ ] `set_config_option` full-state semantics
- [ ] Divergence push through `config_option_update`

## Acceptance Criteria
- [ ] The `session/new` response carries exactly one config option, kind select, with a `currentValue` default
- [ ] The option's labels show each slot's `chosen.stringValue`
- [ ] `set_config_option` to `flash` succeeds, the returned complete state shows `flash`, and later turns use the flash slot, asserted through the scripted loader
- [ ] A scripted resolution divergence produces one `config_option_update` carrying the full option list

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ConfigOptionsTests.swift` — harness-driven
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.