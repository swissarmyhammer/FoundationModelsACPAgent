---
assignees:
- claude-code
depends_on:
- 01KYSV4RJGFQ3HYG7J5C3P8H6D
position_column: todo
position_ordinal: '8280'
title: 'RoutedACPAgent skeleton: initialize, version negotiation, no-auth surface'
---
## What
Plan.md §5–§6. Replace the placeholder in `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift` with the real type conforming to the wire package's `Agent` protocol, plus `Sources/FoundationModelsACPAgent/Agent/Initialization.swift`:

- `initialize`: respond with `protocolVersion` and required `info` (`Implementation.name` = the package/product identifier, never the dotfolder name; `title` = display name; `version` = build version).
- Version negotiation is behavior: client sends its latest; if we support it, echo the same integer; else reply with our latest (`2`) in a **normal successful response** — a client sending `1` gets `2` back, not an error. Log it.
- Capabilities: `capabilities.session` with `prompt`, `mcp: {stdio: {}, http: {}}`, `delete: {}`, `additionalDirectories: {}` — objects-not-booleans (§5). Omit `capabilities.auth` and `authMethods` entirely (§6).
- Read client capabilities with "absent means unsupported"; malformed capabilities degrade to supports-nothing, do not fail initialize.
- Order rule: any `session/*` before `initialize` → JSON-RPC invalid-request error.
- Auth: `auth/login` / `auth/logout` → JSON-RPC `-32601`. Never raise `-32000`.

Session handlers land in later tasks; this task stubs them to throw method-not-available so the conformance compiles.

- [ ] `RoutedACPAgent` type + `Agent` conformance skeleton
- [ ] `initialize` with info, capabilities, negotiation
- [ ] Pre-initialize order enforcement
- [ ] Auth methods refuse with `-32601`

## Acceptance Criteria
- [ ] `initialize(protocolVersion: 2)` echoes 2; `initialize(protocolVersion: 1)` returns 2 successfully
- [ ] Response carries `info.name`/`info.version` and the four session capability markers as `{}` objects
- [ ] `session/new` before `initialize` → invalid-request error
- [ ] `auth/login` → error code `-32601`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InitializationTests.swift` — drive the agent through `InMemoryTransport.pair()` + `ClientSideConnection`; assert negotiation, capabilities shape, order rule, auth refusal
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.