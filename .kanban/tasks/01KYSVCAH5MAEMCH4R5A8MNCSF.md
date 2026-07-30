---
assignees:
- claude-code
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: todo
position_ordinal: '9280'
title: 'Slash commands: registry, precedence, dispatch at the prompt owner'
---
## What
Plan.md §14 (registry + dispatch mechanics; builtins are the next task). Create `Sources/FoundationModelsACPAgent/Commands/CommandRegistry.swift` + `CommandDispatch.swift`:

- Per-session registry assembled at session creation from the precedence order (§14.1): builtins → linked `SlashCommandProviding` conformers from catalog entries (§11.1) → skills (source 3 — NOT wired yet; Skills is plan-only upstream; leave the seam and a marked TODO). Later source wins at a name collision (logged) EXCEPT builtin names, which are reserved.
- Dispatch in the `prompt()` handler **before anything touches the session** (§14.3): a leading `/name` never reaches the model as a prompt. `.prompt(template:)` bodies expand (template + arguments) into a normal recorded model turn; `.action` bodies run code and stream text — no model turn, no transcript entries beyond what the action records.
- Unknown `/name` → error with near-miss suggestions; never a model turn. A literal leading slash is the frontend's escaping problem, not ours.
- Attachments rule (§14.3): extra content blocks accompany `.prompt`-style commands **into the expanded turn**; for `.action` commands, attachments → refuse the invocation with a reason.
- ACP surface (§14.4): publish `available_commands_update` at session start and on every registry change (`commandUpdates` streams feed it). `AvailableCommand{name, description}` + optional text input whose `hint` passes the provider's argument-hint string verbatim.

- [ ] Registry merge with precedence + reserved builtins
- [ ] Dispatch-before-session in `prompt()`
- [ ] Unknown-command near-miss error
- [ ] Attachments: carry for prompt-kind, refuse for `.action`
- [ ] `available_commands_update` publication

## Acceptance Criteria
- [ ] A `/nosuchcmd` prompt yields an error mentioning the nearest name and no model turn (scripted backend never invoked)
- [ ] A provider command colliding with a builtin name loses; the builtin still dispatches
- [ ] `.action` command with an attached resource_link → refusal with reason, no model turn
- [ ] The collector receives `available_commands_update` after session/new, and again after a `commandUpdates` push

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/CommandRegistryTests.swift` and `CommandDispatchTests.swift` — harness with stub `SlashCommandProviding` conformers
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.