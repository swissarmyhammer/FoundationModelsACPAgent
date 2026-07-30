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
Plan.md §20.1. The shared fixture every tier-1/2 test uses. Built against the agent skeleton only — sessions and prompt turns do not exist yet; the end-to-end scripted-turn proof lives in the prompt-turn task. Create `Tests/FoundationModelsACPAgentTests/Support/`:

- `RecordingClient.swift` — the ten-line `Client` conformance from §20.1: an `UpdateCollector` actor that appends every `session/update` notification in arrival order, and a configurable `requestPermission` answer (default `selected("allow")`). Plus a convenience that wires `InMemoryTransport.pair()` + `ClientSideConnection` + a `RoutedACPAgent` and returns (client connection, collector, agent).
- `ScriptedModel.swift` — an injectable `ModelLoader` whose `LoadedLLMContainer.makeSession` returns a `LanguageModelSessionBackend` that emits a scripted sequence (text deltas, a known tool call with fixed arguments, turn end). Follow Router's `ScriptedOverflowBackend` pattern — no MLX, no download, no Apple-silicon gate; runs in CI at every commit.
- Assertion helpers: `collector.updates(ofKind:)`, ordered-subsequence assertion for turn-order checks, and a filesystem-truth helper (read the file from disk — never trust a `tool_call_update` claim, §20.1).
- Migrate the InitializationTests wiring onto this harness.

- [ ] `RecordingClient` + collector
- [ ] Scripted `ModelLoader`/backend
- [ ] Wiring convenience + assertion helpers
- [ ] InitializationTests migrated onto the harness

## Acceptance Criteria
- [ ] The convenience constructs the pair and completes an `initialize` round trip observed from the client end
- [ ] The scripted backend, driven directly (no session/prompt yet), emits its scripted sequence of deltas + tool call + turn end
- [ ] The harness runs on any CI host (no model download, no GPU, no network)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift` — construction + initialize round trip; direct scripted-backend sequence assertion
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.