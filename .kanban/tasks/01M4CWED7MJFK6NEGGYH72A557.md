---
comments:
- actor: claude-code
  id: 01m4g8yn9pghbwn9929at2fnba
  text: |-
    ### API shape from AgentViewKit (session agentviewkit-1c, 2026-10-09)

    No session works on this task now. The kit task ^808vyvy waits for it.

    - `InProcessAgent.makeConnection(serving:)` in AgentViewKit takes `@Sendable (AgentSideConnection) -> any Agent`. The kit calls this closure one time with the in-process `AgentSideConnection`.
    - Thus, the public helper gives `any Agent` (the composed `RoutedACPAgent`) for an `AgentSideConnection`. The agent is bound to that connection. The helper must NOT start its own transport or serve loop.
    - A host then writes `InProcessAgent.makeConnection { connection in compose(..., connection: connection) }`.
    - The kit closure is sync and does not throw. If `compose` must throw or must be async, tell the kit session, because the kit then needs a small change. Prefer a form that the sync closure can call.
    - Keep `serve(...)` for the stdio path of the executable. The kit does not need it.
    - When the change is pushed, send the commit sha to agentviewkit-1c. The kit then changes its README in-process quick start (`InProcessQuickStart.start(cwd:serving:)`) to use the public helper.
  timestamp: 2026-10-09T12:07:06.806024+00:00
- actor: claude-code
  id: 01m4hewa33x9jkrf7dwtddxhgy
  text: |-
    ### Research and implementation

    - The new public type is `ComposedAgent` in `Sources/FoundationModelsACPAgent/ComposedAgent.swift`. The name is not `AgentComposition`, because the executable keeps an `AgentComposition` enum for its CLI choices.
    - Split: `ComposedAgent.compose(name:workingDirectory:environment:modelSource:stubChunkDelay:reporting:)` is `async throws` and is called one time. `agent(boundTo:) -> any Agent` is sync and does not throw. The AgentViewKit closure calls it directly. `serve(over:logger:)` calls `agent(boundTo:)` in the factory closure, so there is one bind path.
    - The environment switch `ACP_AGENT_STUB_MODEL` stays in the executable. The library takes `ModelSource` as a parameter, so production library code reads no test-mode variable (test-partitioning rule).
    - `PacedStubModel.swift` moved to the library (`Configuration/`), because the stub path of `compose` uses it.
    - The `run` and `acp` files of the CLI do not import the library (cli-plan.md §4). Thus `AgentComposition.Composed` is now a `typealias` of `ComposedAgent`. A first try changed those files to name `ComposedAgent`, and the build failed with "cannot find type". I reverted that.
    - README quick start now uses `ComposedAgent.compose` and `serve(over:logger:)`, and shows the factory-closure form. The old README pointed at `Sources/acp-agent/AgentComposition.swift`, which no longer holds the composition.
    - TDD: `ComposedAgentTests` failed first with "cannot find type 'ComposedAgent' in scope". After the change, the 2 tests passed.
  timestamp: 2026-10-09T23:09:55.683786+00:00
- actor: claude-code
  id: 01m4hfa86be0m0v1pd4a11x38n
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/ComposedAgent.swift (new), Sources/FoundationModelsACPAgent/Configuration/PacedStubModel.swift (moved from Sources/acp-agent/), Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/ComposedAgentTests.swift (new), Tests/FoundationModelsACPAgentTests/RunCommandTests.swift (doc comment), README.md. `swift test`: 830 tests in 89 suites passed (1 known issue, the intended negative case in HarnessSmokeTests), 0 warnings. `swift test --package-path IntegrationTests --no-parallel`: 30 tests in 11 suites passed.
    - API for AgentViewKit: `let composed = try await ComposedAgent.compose(name: try DotfolderName("<name>"), workingDirectory: <url>)` one time (async, throws), then `InProcessAgent.makeConnection { connection in composed.agent(boundTo: connection) }` (sync, does not throw, returns `any Agent`, no transport and no serve loop).
    - next: /review. Not committed. The sha goes to agentviewkit-1c after the push.
  timestamp: 2026-10-09T23:17:32.491012+00:00
- actor: claude-code
  id: 01m4hfbh9h94my4hv29wct29jg
  text: |-
    AgentViewKit accepts the shape (2026-10-09). Two requirements that a later change must keep:
    - `ComposedAgent.agent(boundTo:)` returns `any Agent` (or a type that conforms to `Agent`). It is sync, does not throw and starts no transport.
    - `ComposedAgent` stays `Sendable`, because the kit captures it in a `@Sendable` closure.
    After the push, send the commit sha to agentviewkit-1c. That session then starts its task ^808vyvy.
  timestamp: 2026-10-09T23:18:14.577744+00:00
- actor: claude-code
  id: 01m4hfnn76367rw5qmqab2wee1
  text: |-
    ### test — green
    - evidence: swift test (root) — 830 tests in 89 suites passed, 0 failed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests); swift test --package-path IntegrationTests --no-parallel — 30 tests in 11 suites passed, 0 failed. No compiler warnings in package files. The only warning is the mlx-swift_Cmlx.bundle build-system line from a dependency.
    - next: none. No file changed. No commit made.
  timestamp: 2026-10-09T23:23:46.278817+00:00
- actor: claude-code
  id: 01m4hfph5n7yyr492esvj6mx77
  text: |-
    ### commit — changed
    - evidence: 25787f4 feat(library): make the agent composition public as ComposedAgent, and let the executable call it (^h72a557)
    - next: review HEAD~1..HEAD
  timestamp: 2026-10-09T23:24:14.901644+00:00
- actor: claude-code
  id: 01m4hgvrwypcyp0mzgzzfw6rhb
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (25787f4) — 0 findings, 0 confirmed, 3 refuted, 7 attempted, 0 failed. 6 files reviewed. Not reviewed: README.md (no validator matches it) and 2 .kanban files (.reviewignore). Five code-hygiene Swift tool rules declined only the old path Sources/acp-agent/PacedStubModel.swift. The commit moved that file to the library, so the old path has no file. No prior Review Findings section.
    - next: none. Task moved to done. Send the commit sha 25787f4 to agentviewkit-1c after the push.
  timestamp: 2026-10-09T23:44:35.230973+00:00
- actor: claude-code
  id: 01m4hgw7xjx7jv9fk5w29wcddn
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files
    - test: green — swift test 830 (1 known issue, HarnessSmokeTests); IntegrationTests 30
    - commit: 25787f4
    - review: clean — 0 findings
  timestamp: 2026-10-09T23:44:50.610475+00:00
position_column: done
position_ordinal: ffb080
title: Make the serve and compose helper of the agent public in the library target
---
## What
Request from AgentViewKit (task ^808vyvy there). The helper that serves and composes the agent (`serve(...)` and `compose(...)` in `Sources/acp-agent/AgentComposition.swift`) is in the `acp-agent` executable target only. A host that runs the agent in its own process (for example with `InProcessAgent.makeConnection(serving:)` of AgentViewKit) must build the `RoutedACPAgent` itself.

- [x] Move the serve and compose helper into the `FoundationModelsACPAgent` library target.
- [x] Make it public, with a doc comment that tells a host how to serve the composed agent over a transport.
- [x] Change the `acp-agent` executable to call the public helper, so that there is one copy.

## Acceptance Criteria
- [x] A package that depends on the `FoundationModelsACPAgent` library can compose and serve the agent with one public call.
- [x] The `acp-agent` executable has no copy of the helper.

## Tests
- [x] A test in the library test target composes the agent with the public helper and serves it over an in-memory transport, and an `initialize` request gets an answer.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.