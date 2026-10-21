---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: 'ACP-1 (in FoundationModelsACP): HTTP server transport with Acp-Connection-Id and the credential of each connection'
---
The work is in the repo /Users/wballard/github/swissarmyhammer/FoundationModelsACP, and not in this repo. The user gave the FoundationModelsACP work to this session. Do it after ACP-3. It unblocks ACPA-5b here.

Spec: TestudoApp features/packages/foundationmodels-acp.md, "ACP-1 HTTP server transport" (agreed; D10), plus the D120 notes from the coordinating session.

## Change (in FoundationModelsACP)
- An ACP v2 over HTTP server transport, behind the `ACPTransport` protocol. ACP over HTTP is not a standard yet, so it stays behind the protocol.
- It issues an `Acp-Connection-Id` at `initialize`, and requires that id on each later request. A request with a missing or unknown id is refused.
- It gives the agent that id and the bearer token of each connection (or a trust value), so the agent can set the trust of the connection (ACPA-5b: a token of a device of the user gives userDevice, any other token gives external).

## Done when
- A failing test first (TDD), in FoundationModelsACP: an HTTP `initialize` returns an `Acp-Connection-Id`. A later request with that id reaches the same connection. A request with no id or a wrong id is refused. The agent side can read the connection id and the bearer token.
- The full FoundationModelsACP `swift test` passes. Push to FoundationModelsACP main.
- Then in this repo, `swift package update FoundationModelsACP`, and the full `swift test` passes. #acp-1