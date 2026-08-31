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
Plan.md §14 (the registry and the dispatch mechanics; the builtins are the next task). Create `Sources/FoundationModelsACPAgent/Commands/CommandRegistry.swift` and `CommandDispatch.swift`.

Assemble a per-session registry at session creation, in this precedence order (§14.1): builtins, then linked `SlashCommandProviding` conformers from catalog entries, then skills. A later source wins a name collision, and the win is logged, except that builtin names are reserved.

**`SlashCommandProviding` has exactly two requirements**, in `FoundationModelsExtras`:
```swift
func commands(workingDirectory: URL) async -> [SlashCommand]
var commandUpdates: AsyncStream<[SlashCommand]>? { get }
```

**Skills is source 3 and it is LIVE.** An earlier draft said it was plan-only and told you to leave a seam. That is stale. `SkillsRegistry` already conforms to `SlashCommandProviding`. Wire it for real. `commandUpdates` is nil when the registry was built with `watch: false`, so build the session's `SkillsRegistry` with `watch: true` for live pushes. One user-invocable skill gives one `/id` command.

**`SlashCommand.Body` has THREE cases, not two.** This corrects the plan's central claim about the skills gap:
```swift
public enum Body: Sendable {
  case prompt(template: String)
  case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)
  case rendered(@Sendable (Invocation) async throws -> String)
}
```
`.rendered` already ships in Extras. It is documented as the escape hatch for exactly this problem: a provider whose substitution model does not match the Stencil engine. **Do not file or wait on an upstream ask for it.**

Dispatch by body kind:
- `.prompt(template:)` — expand through the harness template engine into a normal recorded model turn.
- `.rendered(_:)` — call it, then feed the returned string into a normal recorded model turn. Prefer this whenever a provider offers it.
- `.action(_:)` — run the closure and stream its text. No model turn, and no transcript entries beyond what the action records.

**The skills special case, and why it is still needed.** Skills' own conformance still emits `.prompt(template:)` carrying the skill's raw, unrendered body. A host that runs that template through the harness engine gets only that engine's rendering, so Skills' own argument substitution and shell-injection passes never run, and `$0`, `$ARGUMENTS` and backtick-shell syntax pass through inert. Until Skills adopts `.rendered`, route skill commands through `registry.call(id:arguments:)`, which runs all three render passes and returns the finished string. Mark it as a temporary special case and name the condition for removing it: Skills emitting `.rendered`.

Note `registry.call(id:arguments:)` is synchronous and `throws`; it is not `async`.

Dispatch in the `prompt()` handler before anything touches the session (§14.3). A leading `/name` never reaches the model as a prompt.

An unknown `/name` gives an error with near-miss suggestions and never a model turn. A literal leading slash is the frontend's escaping problem.

Attachments (§14.3): extra content blocks accompany prompt-style and `.rendered` commands into the expanded turn. For an `.action` command, refuse the invocation with a reason.

ACP surface (§14.4): publish `available_commands_update` at session start and on every registry change, fed by the `commandUpdates` streams. `AvailableCommand {name, description}` plus an optional text input whose `hint` passes the provider's argument-hint string unchanged.

- [ ] Registry merge with precedence and reserved builtins
- [ ] All three `Body` cases dispatched, with `.rendered` preferred
- [ ] Skills wired through the real `SlashCommandProviding` conformance
- [ ] Skill dispatch routed through `registry.call(id:arguments:)`, marked temporary
- [ ] Dispatch before the session in `prompt()`
- [ ] Unknown-command near-miss error
- [ ] Attachments carried for prompt and rendered, refused for `.action`
- [ ] `available_commands_update` publication

## Acceptance Criteria
- [ ] A `/nosuchcmd` prompt gives an error naming the nearest command and no model turn, so the scripted backend is never invoked
- [ ] A provider command that collides with a builtin name loses, and the builtin still dispatches
- [ ] A stub provider offering a `.rendered` body has that closure called, and its output reaches the model turn
- [ ] A real skill with a `$1` placeholder, invoked with an argument, reaches the model with the argument substituted, which proves the `registry.call` path
- [ ] An `.action` command with an attached resource_link gives a refusal with a reason and no model turn
- [ ] The collector receives `available_commands_update` after session/new, and again after a skill file changes on disk with `watch: true`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/CommandRegistryTests.swift` and `CommandDispatchTests.swift` — harness with stub `SlashCommandProviding` conformers covering all three body kinds, plus one real `SkillsRegistry` over a temp skills directory
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.