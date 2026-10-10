---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
title: 'IntegrationTests: replace the spawned acp-client binary with the FoundationModelsACPClient library over an in-memory transport'
---
## Problem

FoundationModelsACPClient 24643be (pushed 2026-10-10) is a library only. Its user decided this. The `AcpClientCore` library and the `acp-client` executable products are removed, and so are the client's own IntegrationTests package and its `cli-plan.md`. The client no longer exposes StopReason exit codes.

In this repo:
- `IntegrationTests/Package.swift` declares `clientExecutableName = "acp-client"`, and `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ClientInteropTests.swift` builds and runs that binary. The binary does not exist any more, so the suite fails when the IntegrationTests pins move to the client 24643be.
- `cli-plan.md` §6 and §17 describe `acp-client`, and the client side of the exit-code table in §9 is gone.

## Decision (the client's user, 2026-10-10)

Tests run in process, with no spawned client.

## Change

1. Move each check of `ClientInteropTests` to the FoundationModelsACPClient library over an in-memory transport (for example `InMemoryTransport.pair()` and the public `ComposedAgent` of ^h72a557). Remove a check that has no meaning without the binary, and record why.
2. Remove `clientExecutableName` and the `acp-client` product dependency from `IntegrationTests/Package.swift`.
3. Update `cli-plan.md` §6, §9 and §17: remove the `acp-client` binary and the client side of the exit-code table. State that a client is the library.
4. Check `Examples/acp-print`: it links the client library only. It must still build.

## Tests

- `swift test --package-path IntegrationTests --no-parallel` passes with the client pin at 24643be or later.
- The root suite passes.

#tests