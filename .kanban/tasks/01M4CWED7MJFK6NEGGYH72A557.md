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
position_column: todo
position_ordinal: '80'
title: Make the serve and compose helper of the agent public in the library target
---
## What
Request from AgentViewKit (task ^808vyvy there). The helper that serves and composes the agent (`serve(...)` and `compose(...)` in `Sources/acp-agent/AgentComposition.swift`) is in the `acp-agent` executable target only. A host that runs the agent in its own process (for example with `InProcessAgent.makeConnection(serving:)` of AgentViewKit) must build the `RoutedACPAgent` itself.

- [ ] Move the serve and compose helper into the `FoundationModelsACPAgent` library target.
- [ ] Make it public, with a doc comment that tells a host how to serve the composed agent over a transport.
- [ ] Change the `acp-agent` executable to call the public helper, so that there is one copy.

## Acceptance Criteria
- [ ] A package that depends on the `FoundationModelsACPAgent` library can compose and serve the agent with one public call.
- [ ] The `acp-agent` executable has no copy of the helper.

## Tests
- [ ] A test in the library test target composes the agent with the public helper and serves it over an in-memory transport, and an `initialize` request gets an answer.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.