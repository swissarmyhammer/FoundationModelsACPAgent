---
assignees:
- claude-code
depends_on:
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
position_column: todo
position_ordinal: 8a80
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

- [ ] `RecordingClient` and the collector
- [ ] Scripted `ModelLoader` and backend, reusing Router test support where it fits
- [ ] Wiring convenience and assertion helpers
- [ ] InitializationTests moved onto the harness

## Acceptance Criteria
- [ ] The convenience builds the pair and completes an `initialize` round trip observed from the client end
- [ ] The scripted backend, driven directly with no session/prompt yet, emits its scripted sequence of deltas, tool call and turn end
- [ ] The harness runs on any CI host, with no model download, no GPU and no network

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift` — construction, the initialize round trip, and a direct scripted-backend sequence assertion
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.