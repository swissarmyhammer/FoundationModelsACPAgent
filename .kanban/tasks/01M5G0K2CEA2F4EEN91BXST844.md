---
assignees:
- claude-code
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
position_column: todo
position_ordinal: '8480'
title: 'ACPA-5b: the trust of a connection comes from its credential, never from the client'
---
Spec: ACPA-5 (D120 b), TestudoApp foundationmodels-acpagent.md.

## Change
- The bearer token of the connection gives its trust. The in-process UI and a token of a device of the user give `userDevice`. Any other token gives `external`.
- What the client says at `initialize` does not change the trust.
- The trust goes in the `RoutedACPConnection` row (^ACPA-5a).

## Find out first
- Where the HTTP transport (FoundationModelsACP, ACP-1) exposes the credential of a connection, and how the host gives the list of user-device tokens. If the transport does not expose it, stop and report what FoundationModelsACP would need. Do not edit that repo.

## Done when
- A failing test first (TDD): a connection with a user-device token is `userDevice`, a connection with another token is `external`, and an `initialize` that claims more does not change it. An in-process (InMemoryTransport) connection is `userDevice`.
- The full `swift test` passes. #acpa-5