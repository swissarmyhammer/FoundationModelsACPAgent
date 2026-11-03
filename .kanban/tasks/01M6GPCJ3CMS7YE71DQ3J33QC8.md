---
comments:
- actor: wballard
  id: 01m6grskpt87b6mkxavj58a3vp
  text: |-
    ### implement - stuck
    - Done: swift package update FoundationModelsACP moved the pin to c1b6d20 (it has 4e0667c as ancestor). Package.resolved is in .gitignore, so it shows no diff.
    - Blocker: swift build fails BEFORE it compiles this package. The dependency FoundationModelsACPClient (pinned 3d5c0dc) does not compile against the new wire package:
      - Model/ChunkCoalescer.swift: the switch over SessionUpdate in isCoalescible is not exhaustive (new SessionUpdate cases).
      - Model/Identifiable+Wire.swift: AvailableCommand.name is gone (AvailableCommand is now a union with a type discriminator; break 2).
      - PendingPermissionRequest.swift: .cancelled now needs a CancelledPermissionOutcome value (break 1).
    - The task forbids a change in any other package. The fix belongs on the FoundationModelsACPClient board. No source file of this package was changed. No test was written or run.
    - Next: a person decides. Needed: a card on the Client board to adopt alpha.13, done and pushed to main; then run this task again. The break list for this package cannot be checked until the Client builds.
  timestamp: 2026-11-03T13:15:22.202771+00:00
- actor: wballard
  id: 01m6gsw5rf8mrra7tkxd3geqcp
  text: |-
    WIRE CHANGE (ACP review fix b86bfc2, 2026-11-03, on top of c1b6d20 / ded0830 / 9f1bcd1 / 129fc9a): `ToolCallUpdate.capabilities` is now `PatchField<ToolCallCapabilities>` (was `ToolCallCapabilities?`), and `TerminalUpdate.capabilities` is now `PatchField<TerminalCapabilities>` (was `TerminalCapabilities?`). Rule: omitted leaves the value, `null` clears it, an object replaces the whole value. `AccumulatedTerminal` has `size: TerminalSize?` and `capabilities: PatchField<TerminalCapabilities>`, and replay keeps both. `ElicitationUrlMode.Scope` is now a typealias of `ElicitationFormMode.Scope`.
    EFFECT: this is break number 14 for the adoption task: fix every place that builds or reads these capabilities. It matters for the cancel task (a tool call advertises `cancel` in its capabilities; the agent must clear it with `null` when the call reaches a final status, and must not send capabilities again as a plain value on later updates).
  timestamp: 2026-11-03T13:34:14.799089+00:00
- actor: claude-code
  id: 01m6gywbvswsq9wpqe91538wen
  text: |-
    ### Breaks check (wire 71a3bde, client e9b15fd)
    TOUCHED this package:
    - 2 (AvailableCommand union): CommandRegistry.availableCommands now builds .command(Command(...)). Tests use a test-support helper (command, commandName). New test: the wire command has type "command".
    - 6 (ToolCallLocation.line is LineNumber?): ACPEventTranslator.locationsPatch converts the tool line with wireLine(of:). A line below 1 gives no line. New test: a zero line gives a location with no line.
    - SessionUpdate has 3 new cases (subagentUpdate, sessionMessage, sessionMessageChunk): the test-support SessionUpdateKind switch maps them.
    - Not a wire break, but a warning in this package: the Apple SDK Transcript.Entry has a new case .data. EchoModel.content(of:) handles it now.
    NOT touched (checked by grep and by the build):
    - 1 (cancelled outcome): the agent never builds RequestPermissionOutcome.
    - 3 (ElicitationSchema): ElicitationRelay decodes it from JSON that Extras encodes; the elicitation tests pass.
    - 4 (auth capabilities): Initialization does not read or send auth.
    - 5 (.paused): no switch over the wire ToolCallStatus in this package; the agent only produces statuses.
    - 7 (UsageUpdate.cost), 8 (Cost.currency): the agent never sends a cost.
    - 9 (cancelToolCall, cancelTerminal): the agent does not serve them; the default method-not-found stays. The cancel task decides later.
    - 10 (MethodSide.proxy), 11 (method table), 12 (null id), 13 (new types): no use in this package.
    - 14 (capabilities PatchField on ToolCallUpdate and TerminalUpdate): no code builds or reads these; TerminalStream and the translator leave capabilities at the default.
    No shim, no old overload added.
  timestamp: 2026-11-03T15:01:43.929400+00:00
- actor: claude-code
  id: 01m6gz2fkaw7ezehrpw2cm2xrk
  text: |-
    ### implement - changed
    - evidence: swift build has no error and no warning from this package (one toolchain line stays: "missing creator for mutated node" for the mlx bundle). Root swift test: 1293 tests, 142 suites, pass, 1 known issue (an intended withKnownIssue in HarnessSmokeTests). IntegrationTests: 36 tests, 2 fail. Both are in EmbeddingModelTests (theShippedDefaultCoreMLModelLoadsAndEmbeds, aConfiguredMLXQwenEmbeddingModelLoadsAndEmbeds) with: profile "coding" did not resolve: ResolutionFailure: profile "coding" cannot co-fit a budget of 78259 bytes. This is a memory-budget limit of this machine in the Router profile resolution, not a wire break. The other 34 pass.
    - Package.resolved (ignored by git): wire 71a3bde, client e9b15fd, in the root and in IntegrationTests.
    - Files: Sources/FoundationModelsACPAgent/Commands/CommandRegistry.swift, Agent/ACPEventTranslator.swift, Configuration/EchoModel.swift; tests ToolDisplayProjectionTests, CommandRegistryTests, CommandDispatchTests, SessionHistoryTests, SessionResumeTests; test support AssertionHelpers.
    - Note: the RED step was not run on its own, because the package did not compile before the fix. The two new tests were written before the production code, but the first run of them was the green run.
    - next: review.
  timestamp: 2026-11-03T15:05:04.362873+00:00
position_column: doing
position_ordinal: '80'
title: 'Adopt ACP schema alpha.13 in the agent: update the wire dependency and fix the breaks'
---
## What
The wire package FoundationModelsACP was re-vendored to ACP schema `schema-v2.0.0-alpha.13` (commit 4e0667c on main, ACP board card 01M6GJ8GX6C0YRHJW0W2ADAVTE). This package depends on the wire package as a remote dependency on its `main` branch, and `Package.resolved` pins one revision until `swift package update`. Move to the new revision and fix every break, in the same change (ARCHITECTURE.md: no backward compatibility, no shims, no deprecated aliases).

Breaks that the ACP session listed (comment on the ACP re-vendor card). Check each against this package; some may not touch it:
1. `RequestPermissionOutcome.cancelled` holds a value: `.cancelled(CancelledPermissionOutcome())`.
2. `AvailableCommand` is a union with a `type` discriminator: `AvailableCommand.command(Command(description:name:))`. A command with no `type` is skipped on decode. This touches the command list that the agent publishes (`publishAvailableCommands`, `ConfigOptions`, the slash commands).
3. `ElicitationSchema` needs `properties` and `type` (`.object`); the no-argument initializer is gone. This touches `ElicitationRelay` and the elicitation tests.
4. `ClientCapabilities.auth` has the type `ClientAuthCapabilities`; `AuthCapabilities` is gone; new `AgentAuthCapabilities`. This touches `Initialization.swift`.
5. `ToolCallStatus` has a new case `.paused` (not terminal). Every switch without a default must handle it (`ACPEventTranslator`, `TerminalStream`, the tool call tally).
6. `ToolCallLocation.line` is `LineNumber?` (1-based, `UInt32`); `0` on the wire gives `nil`.
7. `UsageUpdate.cost` is `PatchField<Cost>` (omitted = unchanged, `null` = clear, value = replace). This touches the usage updates of the agent and `PromptTally`.
8. `Cost.currency` accepts any string; the three upper-case letters send rule is gone.
9. The `Agent` protocol has two new requests with default implementations: `cancelToolCall` (`tool_call/cancel`) and `cancelTerminal` (`terminal/cancel`). Decide if the agent serves them; the default answers method-not-found. Note for later: the cancel task of this plan may use `tool_call/cancel`.
10. `MethodSide` has a new case `.proxy`. A switch over it must handle it.
11. The unstable method table changed (document/* and nes/* gone; auth/status, session/archive, session/unarchive, session/status, session/set_title, proxy/* added).
12. A request with `"id": null` gets an invalid-request error; an error response with a null id is dropped.
13. New generated types: `BackgroundWork` (terminal, toolCall), a scope union in `ElicitationFormMode`; the generated file shards changed.
Not in this task: JSON-RPC batching is removed from v2, but the wire package `Connection.swift` still reads batches. That is a card on the ACP board.

Do:
1. `swift package update` for the wire package only; build; fix every compile error and warning.
2. Run the unit tests and the IntegrationTests package; fix every failure.
3. Write in a task comment which of the 13 items touched this package, and which did not.
4. Do not change the wire package from this task. A needed change there is a card on the ACP board, discussed with the user first.

## Acceptance Criteria
- [ ] `Package.resolved` pins a wire revision that is at or after 4e0667c.
- [ ] `swift build` has no error and no warning.
- [ ] `swift test` passes at the root and in `IntegrationTests`.
- [ ] No compatibility shim or old overload is added.
- [ ] A task comment lists the touched breaks.

## Tests
- [ ] Update the tests that break; add a test for each behavior change that this package owns (the command union, the usage cost patch, the paused status in the tally).
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents