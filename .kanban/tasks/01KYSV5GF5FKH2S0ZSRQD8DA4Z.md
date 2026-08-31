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
Plan.md §5–§6. Replace the placeholder in `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift` with the real type conforming to the wire package's `Agent` protocol. Add `Sources/FoundationModelsACPAgent/Agent/Initialization.swift`.

- `initialize`: respond with `protocolVersion` and the required `info`. `Implementation.name` is the package or product identifier, never the dotfolder name. `title` is the display name. `version` is the build version.
- Version negotiation is behavior. The client sends its latest. If we support it, echo the same integer. Otherwise reply with our latest (`2`) in a normal successful response. A client sending `1` gets `2` back, not an error. Log it.
- Capabilities: `capabilities.session` with `prompt`, `mcp: {stdio: {}, http: {}}`, `delete: {}` and `additionalDirectories: {}`. Use objects, not booleans (§5).
- **`additionalDirectories` is honest now.** Multitool's multi-root support shipped, and `withFiles(root:additionalRoots:)` carries the root set. Keep advertising it, and let the multi-root task prove it end to end.
- **Do not advertise any permission capability, and never send `session/request_permission`.** Multitool deleted its permission layer on 2026-08-24 and the sandbox is the only gate. See the sandbox task.
- Read the client capabilities with "absent means unsupported". Malformed capabilities degrade to supports-nothing and must not fail initialize.
- Order rule: any `session/*` before `initialize` gives a JSON-RPC invalid-request error.
- Auth: `auth/login` and `auth/logout` give JSON-RPC `-32601`. Never raise `-32000`. Omit `capabilities.auth` and `authMethods` entirely (§6).

Session handlers land in later tasks. Stub them here to throw method-not-available so the conformance compiles.

- [ ] `RoutedACPAgent` type and the `Agent` conformance skeleton
- [ ] `initialize` with info, capabilities and negotiation
- [ ] Pre-initialize order enforcement
- [ ] Auth methods refuse with `-32601`
- [ ] No permission capability advertised

## Acceptance Criteria
- [ ] `initialize(protocolVersion: 2)` echoes 2; `initialize(protocolVersion: 1)` returns 2 successfully
- [ ] The response carries `info.name` and `info.version`, and the four session capability markers as `{}` objects
- [ ] The response advertises no permission capability
- [ ] `session/new` before `initialize` gives an invalid-request error
- [ ] `auth/login` gives error code `-32601`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InitializationTests.swift` — drive the agent through `InMemoryTransport.pair()` and `ClientSideConnection`; assert negotiation, the capabilities shape, the order rule and the auth refusal
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.