---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g033kfs05e3rx1r352twx8
  text: |-
    Research complete. Facts found:

    - `SlashCommandProviding` (Extras) has exactly the two requirements on the card. `SlashCommand.Body` has the three cases. `SlashCommand.Invocation` carries `arguments: String` (raw text) and `workingDirectory: URL`.
    - `SkillsRegistry` conforms to `SlashCommandProviding` in `SkillsRegistry+SlashCommands.swift`. Each skill command carries `.prompt(template:)` with the raw body. `commandUpdates` is nil for `watch: false`.
    - `SkillsRegistry.call(id:arguments:)` is synchronous, throws, and takes `arguments: [String]`. The `$N` tokens are 0-based (`ArgumentSubstitution.swift`). The dispatcher must split the raw argument text into words.
    - ACP wire types: `SessionUpdate.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands:))`, `AvailableCommand(description:name:input:)`, `AvailableCommandInput.text(TextCommandInput(hint:))`.
    - The echo stub model (`EchoSessionBackend`) streams the model prompt back. A dispatch test can read the `agent_message_chunk` text to prove what text reached the model.
    - `ToolCatalog.makeSkillsRegistry(context:)` already builds the session registry with `watch: true` over `DotfolderStack(name: "skills", workingDirectory:)`. The project layer is `<cwd>/.skills/`.
    - `prompt()` in `PromptTurn.swift` is the dispatch point. It already validates order, session id, availability, and bound connection before it schedules a turn.
    - Test seam: the agent gets an internal provider registration method, because no catalog tool conforms to `SlashCommandProviding` today.

    Plan: `Commands/CommandRegistry.swift` (actor registry, merge with reserved builtins, near-miss search, skills `.rendered` wrap marked temporary, `AvailableCommand` mapping, update subscriptions) and `Commands/CommandDispatch.swift` (leading-slash parse, template expansion, action turn, refusal errors, dispatch extension on the agent). `SessionSetup` composes the registry; `newSession` publishes `available_commands_update` after the response and on each registry change.
  timestamp: 2026-09-02T02:45:09.871765+00:00
- actor: claude-code
  id: 01m1g13kwdy0anzn5pycrranym
  text: |-
    Implementation landed. TDD order: the two test files were written first, the build failed on the missing API (RED), then the implementation made them pass (GREEN).

    What was built:
    - `Sources/FoundationModelsACPAgent/Commands/CommandRegistry.swift` — the `CommandRegistry` actor: precedence merge (builtins reserved, later source wins with a logged win), `commandUpdates` follower tasks that replace one provider's set wholesale and republish, near-miss search (Levenshtein, max distance 3, max 3 suggestions), the `AvailableCommand` mapping with the argument-hint passthrough, and `SkillCommandSource` — the TEMPORARY wrap that turns each skill `.prompt` body into a `.rendered` body that runs `registry.call(id:arguments:)`. The removal condition is written on the type: Skills emitting `.rendered` (the pass-through arm already forwards it).
    - `Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift` — the leading-slash parse, the untrusted template expansion with the raw arguments under the `arguments` key, the model-prompt assembly that carries attached text blocks, `ActionCommandTurn` (echo, running, streamed chunks, one idle; no model turn), the three refusal errors, and `dispatchCommand` on the agent.
    - `PromptTurn.swift` — `prompt()` dispatches a leading `/name` before anything touches the session; `PromptTurn` gained a `modelPrompt` override; `beginTurn`/`scheduleModelTurn` are the shared busy-marking and scheduling helpers. The `.rendered` path marks the session busy before the async render, so a concurrent prompt gets the busy refusal.
    - `SessionSetup.swift` — one watched `SkillsRegistry` per session now serves both the preload assembly and the command source; `ActiveSession`/`SessionComposition` carry the registry; `newSession` publishes `available_commands_update` after the response and re-publishes on each registry change. Builtins list is empty with `TODO(^4fz1sd1)`.
    - `RoutedACPAgent.swift` — `registerCommandProviders(_:)`, the seam for linked conformers (the test harness stubs it; no catalog tool conforms today).

    Behavior-change fallout: three pre-existing suites asserted exact update sequences or empty collectors. The new mandated `available_commands_update` rides the same stream, so `AssertionHelpers.turnUpdates(in:)` filters it, and the affected assertions in `PromptTurnTests` and `CancellationTests` now assert over the turn updates.

    `swift test`: 217 tests, all pass, 1 pre-existing known issue, zero compiler warnings (the mlx bundle node notice predates this change).

    ### implement — changed
    - evidence: 9 files — Sources/.../Commands/CommandRegistry.swift, Sources/.../Commands/CommandDispatch.swift, Sources/.../Agent/PromptTurn.swift, Sources/.../Agent/SessionSetup.swift, Sources/.../RoutedACPAgent.swift, Tests/.../CommandRegistryTests.swift, Tests/.../CommandDispatchTests.swift, Tests/.../Support/CommandTestSupport.swift, Tests/.../Support/AssertionHelpers.swift (+ PromptTurnTests.swift, CancellationTests.swift assertion updates)
    - next: test, commit, review
  timestamp: 2026-09-02T03:02:55.117276+00:00
- actor: claude-code
  id: 01m1g14e5z6xtjv6yctemkkbm6
  text: |-
    ### test — green
    - evidence: swift test — 217 tests in 23 suites, all passed, 0 failed, 0 skipped; 1 pre-existing known issue (the deliberate negative proof in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps); swift build --build-tests — 0 compiler warnings in Swift sources
    - next: commit
  timestamp: 2026-09-02T03:03:22.047345+00:00
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: doing
position_ordinal: '80'
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

- [x] Registry merge with precedence and reserved builtins
- [x] All three `Body` cases dispatched, with `.rendered` preferred
- [x] Skills wired through the real `SlashCommandProviding` conformance
- [x] Skill dispatch routed through `registry.call(id:arguments:)`, marked temporary
- [x] Dispatch before the session in `prompt()`
- [x] Unknown-command near-miss error
- [x] Attachments carried for prompt and rendered, refused for `.action`
- [x] `available_commands_update` publication

## Acceptance Criteria
- [x] A `/nosuchcmd` prompt gives an error naming the nearest command and no model turn, so the scripted backend is never invoked
- [x] A provider command that collides with a builtin name loses, and the builtin still dispatches
- [x] A stub provider offering a `.rendered` body has that closure called, and its output reaches the model turn
- [x] A real skill with a `$1` placeholder, invoked with an argument, reaches the model with the argument substituted, which proves the `registry.call` path
- [x] An `.action` command with an attached resource_link gives a refusal with a reason and no model turn
- [x] The collector receives `available_commands_update` after session/new, and again after a skill file changes on disk with `watch: true`

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/CommandRegistryTests.swift` and `CommandDispatchTests.swift` — harness with stub `SlashCommandProviding` conformers covering all three body kinds, plus one real `SkillsRegistry` over a temp skills directory
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.