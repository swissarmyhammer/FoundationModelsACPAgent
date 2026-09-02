---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fpk94tys1q0js79zs8k5wp
  text: |-
    ### research — discoveries (restored after an accidental `git checkout` of the .kanban files)

    - Client driver verified in ../FoundationModelsACPClient: `SwiftUIACPClient` is `@MainActor @Observable`, `init(coalescingCadence:clock:)` accepts `any Clock<Duration>`. `connect(over:logger:)` returns `ClientSideConnection` and binds the client itself. `ACPSessionState.flushPendingChunks()` and `pendingPermissionRequests` are public.
    - The wire `Client` protocol has four required members with no default: `sessionUpdate`, `requestPermission`, `createElicitation`, `elicitationComplete`. The `RecordingClient` forwards all four.
    - `FoundationModelsRouterTestSupport` (Tests/FoundationModelsRouterTestSupport in ../FoundationModelsRouter) vends gate traits, redaction scans, and transcript normalizers only. It vends NO injectable scripted backend; Router's `ScriptedOverflowBackend` is private to its own test target. Thus the scripted backend is written here, as an extension of the local `StubProfileFixtures.swift` pattern, and `StubModelLoader.makeLLMContainer` is the reused injection seam.
    - `LanguageModelSessionBackend` required members verified against Router's source. The container default `makeSession(instructions:tools:)` DROPS tools, so `ScriptedLLMContainer` writes all four factories.
    - `ToolInvoker.invoke(_:content:)` in FoundationModelsMultitool is public; the scripted backend uses it with `GeneratedContent(json:)` for the fixed-argument tool call. No new type-erasure code.
    - `SessionUpdate` (wire) has 17 cases with an `unknown` catch-all; `updates(ofKind:)` switches exhaustively. No code in this task switches on Router's `SessionEvent`, so no `default` arm was necessary anywhere.
    - The client package's `ManualClock` is not exported; a small `HoldingClock` (never fires; tests call the flush helper) lives in Harness.swift.
  timestamp: 2026-09-01T23:59:14.074565+00:00
- actor: claude-code
  id: 01m1fpm3cc8k4m5tccy9naawkg
  text: |-
    ### implement — changed
    - evidence: 6 files — Tests/FoundationModelsACPAgentTests/Support/Harness.swift (AgentClientHarness, HoldingClock, HoldingInstant), Support/RecordingClient.swift (UpdateCollector, RecordingClient), Support/ScriptedModel.swift (ScriptedTurnStep, ScriptedModelError, ScriptedSessionBackend, ScriptedLLMContainer, makeScriptedModelLoader over the reused StubModelLoader), Support/AssertionHelpers.swift (SessionUpdateKind, updates(ofKind:), expectOrderedSubsequence, textOnDisk), Support/HarnessSmokeTests.swift (9 tests), InitializationTests.swift (moved onto AgentClientHarness; the local InitializationHarness struct is deleted)
    - TDD: the smoke tests were written first and failed to compile (the RED state for a new API); the Support files then made them pass.
    - swift test: 136 tests, 15 suites, all pass, 1 known issue (the deliberate negative case of the ordered-subsequence helper). Zero warnings from the changed files; the one "missing creator" build-system warning about the mlx bundle exists on the pristine tree too.
    - next: test step, then commit, then review.
  timestamp: 2026-09-01T23:59:40.940331+00:00
- actor: claude-code
  id: 01m1fpn931m706g3awqcd5amyt
  text: |-
    ### test — green
    - evidence: swift test — 136 tests in 15 suites, all pass, 0 failures, 0 skipped. The 1 "known issue" is the deliberate withKnownIssue negative case that proves expectOrderedSubsequence can fail. Zero warnings from this repository's sources; the one remaining build warning ("missing creator for mutated node" on the mlx-swift Cmlx bundle) is emitted by the SwiftPM build system for the upstream mlx-swift artifact and is present on the pristine tree before this change.
    - next: commit.
  timestamp: 2026-09-02T00:00:19.553468+00:00
depends_on:
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
position_column: doing
position_ordinal: '80'
title: 'Test harness: RecordingClient sink and scripted model backend fixture'
---
## What
Plan.md §20.1. The shared fixture every tier-1 and tier-2 test uses. Build it against the agent skeleton only. Sessions and prompt turns do not exist yet; the end-to-end scripted-turn proof lives in the prompt-turn task.

Create `Tests/FoundationModelsACPAgentTests/Support/`:

- **The client driver is `FoundationModelsACPClient`. Do not write a test client.** The sibling package shipped (its board shows M0–M7 done). `SwiftUIACPClient` is the `Client` conformance, `@MainActor` and `@Observable`, with no SwiftUI import. `connect(over:logger:)` takes any `ACPTransport` and returns the `ClientSideConnection`. `client.session(for:)` gives the `ACPSessionState` projection: `entries`, `toolCalls`, `turnState`, `lastStopReason`, `availableCommands`, `configOptions`, `title`, `usage`. That state is the primary assertion surface, because it is what the Mac app binds to.

- `Harness.swift` — the wiring convenience: `InMemoryTransport.pair()`, `AgentSideConnection` around a `RoutedACPAgent`, `SwiftUIACPClient(coalescingCadence:clock:)` with an injected test clock, then `client.connect(over: clientEnd)`. Return the client, the connection and the agent. Add a `flush` helper that calls `flushPendingChunks()`; a test never sleeps for coalescing.

- `RecordingClient.swift` — the ten-line forwarding recorder for order proofs. The container is a projection and keeps no history, so a turn-order, cancellation or replay proof needs the raw sequence. An `UpdateCollector` actor appends every `UpdateSessionNotification` in arrival order, then the recorder forwards it to `SwiftUIACPClient.sessionUpdate(_:)`. Wire that path with `ClientSideConnection(stream: clientEnd) { _ in recorder }`, because `connect(over:)` binds the client itself. Forward `requestPermission` to the client too. **Drop the configurable `requestPermission` answer.** We no longer send permission requests; the sandbox is the only gate, and a test asserts `pendingPermissionRequests` stays empty.

- `ScriptedModel.swift` — an injectable `ModelLoader`. The seam is real and public:
  - `ModelLoader.loadLLM(ref:slot:context:reporting:) async throws -> any LoadedLLMContainer`
  - `LoadedLLMContainer.makeSession(instructions:)` and `makeSession(transcript:)` are required; the `tools:` overloads have defaults
  - `LanguageModelSessionBackend` required members: `respond(to:maxTokens:)`, `streamResponse(to:maxTokens:)`, `respond(to:following:maxTokens:)`, `makeFork()`, `transcriptEntries()`, `usageTokenCounts()`
  
  Emit a scripted sequence: text deltas, a known tool call with fixed arguments, and a turn end. No MLX, no download, no Apple-silicon gate. It runs in CI at every commit.
  
  Router also ships test-support products — `FoundationModelsRouterTestSupport`, `FoundationModelsRouterRealModelSupport` and `FoundationModelsRouterEvalSupport`. Check `FoundationModelsRouterTestSupport` first and reuse a scripted backend from it rather than writing one, if a suitable one is vended.

**Know what you cannot construct.** These have no public init, so a fake cannot build one: `TurnOutcome`, `ToolCallEntry`, `BackgroundRun`, `ToolContext`, `TranscriptEvent`, `TranscriptEvent.Partial`, `SessionSidecar`. No shipped `TranscriptRecorder` is reachable either, because `.jsonl`, `.inMemory` and `.none` are internal. So a recording fixture must come from driving a real recorded session, not from assembling events by hand. Design the helpers around that limit.

**Write a `default` arm anywhere you switch on `SessionEvent`.** It has thirteen cases and no library evolution, and upstream tells consumers to absorb new cases.

- Assertion helpers: `collector.updates(ofKind:)`, an ordered-subsequence assertion for turn-order checks, and a filesystem-truth helper that reads the file from disk. Never trust a `tool_call_update` claim.
- Move the InitializationTests wiring onto this harness.

- [x] `RecordingClient` and the collector
- [x] Scripted `ModelLoader` and backend, reusing Router test support where it fits
- [x] Wiring convenience and assertion helpers
- [x] InitializationTests moved onto the harness

## Acceptance Criteria
- [x] The convenience builds the pair and completes an `initialize` round trip observed from the client end
- [x] The scripted backend, driven directly with no session/prompt yet, emits its scripted sequence of deltas, tool call and turn end
- [x] The harness runs on any CI host, with no model download, no GPU and no network

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift` — construction, the initialize round trip, and a direct scripted-backend sequence assertion
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.