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
Plan.md §15. Create `Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift`:

- One real option, day one: a `select`, category `model`, over the resident profile's `standard`/`flash` slots (both already resident — a switch loads nothing and blocks on nothing). The `description` says it selects among the profile's slots, so users don't expect a full candidate list.
- This task owns the option construction, the `session/new` announcement (replacing the placeholder), `set_config_option`, and the divergence push. **The `session/resume` response announcement is the resume task's wiring job — it consumes the same construction exposed here** (no ordering edge needed; whichever lands second connects it).
- Announcement: priority-ordered array; every option MUST have a default.
- `session/set_config_option`: apply the slot switch; response and any push carry **the complete state** (`configOptions` required), never a delta.
- `config_option_update` is load-bearing: when Router's joint-fit resolution lands on a different model than the option shows, push the update so `currentValue` is the truth (§15).
- Intentionally absent: `mode`, `thought_level`, `model_config` context size (each decided in its own plan section). No groups.

- [ ] The select option constructed from the resident profile
- [ ] Announcement in the session/new response
- [ ] `set_config_option` full-state semantics
- [ ] Divergence push via `config_option_update`

## Acceptance Criteria
- [ ] `session/new` response carries exactly one config option, kind select, with a `currentValue` default
- [ ] `set_config_option` to `flash` succeeds and the returned complete state shows `flash`; subsequent turns use the flash slot (assert via scripted loader)
- [ ] A scripted resolution divergence produces one `config_option_update` carrying the full option list

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ConfigOptionsTests.swift` — harness-driven
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.