---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1f3m9kx21k9av0025bbxtbg
  text: |-
    ### research — the wire and client symbols, verified in the sibling sources

    - `Agent` (FoundationModelsACP/Connection/Agent.swift): `initialize`, `newSession`, `listSessions`, `resumeSession`, `closeSession`, `prompt`, `sessionCancel` have no default. `loginAuth`, `logoutAuth`, `deleteSession`, `setSessionConfigOption` default to `RequestError.methodNotFound(<wire name>)`, which is `-32601`.
    - `AgentSideConnection(stream:logger:requestTimeout:_ factory:)` is `async`. The connection maps a thrown `RequestError` to the wire as is, and each other error to `internalError`.
    - `InitializeRequest.capabilities` decodes with `forgivingDecode(... default: ClientCapabilities())`. A malformed `capabilities` value reaches the agent as an empty `ClientCapabilities`, so the agent reads it as "supports nothing".
    - `InitializeResponse(info:protocolVersion:authMethods:capabilities:meta:)`. `AgentCapabilities(auth:session:meta:)`. `SessionCapabilities(additionalDirectories:delete:mcp:prompt:meta:)`. `MCPCapabilities(http:stdio:)` with `MCPHTTPCapabilities()` and `MCPStdioCapabilities()`. `PromptCapabilities(audio:embeddedContext:image:)`. The generated `AgentCapabilities` has no permission field at all.
    - `ProtocolVersion.v2`, `.latest`, `init(rawValue: UInt16)`. `RequestError.invalidRequest` is `-32600`. `ErrorCode.wireValue` is public.
    - `ClientSideConnection.initialize` throws `ProtocolVersionMismatchError(sent:received:)` when the agent answers a different version. It does this only after a successful decode of the response. So a client that sends `1` and gets `2` sees a success response, then the client-side mismatch error.
    - `SwiftUIACPClient` is `@MainActor`. `connect(over:logger:)` returns `ClientSideConnection`. `ACPClient.supportedProtocolVersion == .v2`. `ACPClient.advertisedCapabilities` has `elicitation.form` and `elicitation.url`, no `auth`.
    - `InMemoryTransport.pair()` gives two ends. `NDJSONCodec.encode(_:)` frames one message. `NDJSONCodec.frames(from:logger:)` reads `NDJSONFrame.message(JSONValue)`.
    - Logging in this package uses `os.Logger(subsystem: "FoundationModelsACPAgent", category:)` (ConfigurationLoader).
    - `swift build --build-tests` completes from the cache in 2 s. No network is necessary.

    Plan: `RoutedACPAgent` is a `public actor` with `init(name: DotfolderName)`. `Agent/Initialization.swift` holds `initialize`, the implementation identity, the advertised capabilities, the negotiation and the client-capability reading. The session handlers apply the order rule, then throw `methodNotFound`. The auth methods keep the wire default, which is `-32601`.
  timestamp: 2026-09-01T18:27:44.381718+00:00
- actor: claude-code
  id: 01m1f3za2xy4xzg4by1nd6rzfc
  text: |-
    ### implementation landed

    - `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift`: `public actor RoutedACPAgent: Agent` with `init(name: DotfolderName)`, `negotiatedClientCapabilities`, the order rule `requireInitialized(before:)`, and one stub for each session request. Each stub applies the order rule, then throws `RequestError.methodNotFound`. `session/cancel` logs and ignores (plan.md §10.1). The auth methods keep the wire default, `-32601`.
    - `Sources/FoundationModelsACPAgent/Agent/Initialization.swift`: `NegotiatedClientCapabilities` (absent means unsupported), `RequestError.initializeRequired(before:)` (invalid request with `method` and `reason` in `data`), `RoutedACPAgent.implementation`, `buildVersion`, `latestProtocolVersion`, `supportedProtocolVersions`, `advertisedCapabilities`, `initialize`, and `negotiateProtocolVersion(requested:)`, which logs when it answers a different version.
    - `Tests/FoundationModelsACPAgentTests/InitializationTests.swift`: 11 tests (16 cases) over `InMemoryTransport.pair()` and `SwiftUIACPClient.connect(over:)`. One test writes a raw JSON-RPC line with `"capabilities": "not an object"` and reads the success response from the transport, because the typed client cannot send a malformed value.
    - `ImportSmokeTests`: the placeholder `RoutedACPAgentPackage` test now names `RoutedACPAgent`.

    Discoveries:
    - The wire's `ClientSideConnection.initialize` throws `ProtocolVersionMismatchError` after a successful decode, so the v1 test asserts `received == .v2` on that error. That proves the answer was a success response.
    - `AgentCapabilities` in the generated v2 schema has no permission field. The test pins the exact key set of the encoded capabilities (`session` only, with the four markers) so a future field cannot slip in.
    - The test target cannot reach the wire package's `WireRoundTrip` helper, so `InitializationTests.jsonTree(of:)` encodes through `JSONEncoder` and decodes as `JSONValue`.

    `swift test`: 33 tests in 4 suites passed. The one build warning is SwiftPM's pre-existing "missing creator for mutated node" about the mlx-swift bundle, not from this package's sources.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Agent/Initialization.swift, Tests/FoundationModelsACPAgentTests/InitializationTests.swift, Tests/FoundationModelsACPAgentTests/ImportSmokeTests.swift
    - next: /test, then /commit and /review
  timestamp: 2026-09-01T18:33:45.309760+00:00
depends_on:
- 01KYSV4RJGFQ3HYG7J5C3P8H6D
position_column: doing
position_ordinal: '80'
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

- [x] `RoutedACPAgent` type and the `Agent` conformance skeleton
- [x] `initialize` with info, capabilities and negotiation
- [x] Pre-initialize order enforcement
- [x] Auth methods refuse with `-32601`
- [x] No permission capability advertised

## Acceptance Criteria
- [x] `initialize(protocolVersion: 2)` echoes 2; `initialize(protocolVersion: 1)` returns 2 successfully
- [x] The response carries `info.name` and `info.version`, and the four session capability markers as `{}` objects
- [x] The response advertises no permission capability
- [x] `session/new` before `initialize` gives an invalid-request error
- [x] `auth/login` gives error code `-32601`

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/InitializationTests.swift` — drive the agent through `InMemoryTransport.pair()` and `SwiftUIACPClient.connect(over:)` from `FoundationModelsACPClient` (plan.md §20.1); assert negotiation, the capabilities shape, the order rule and the auth refusal. Send `ACPClient.supportedProtocolVersion` and `ACPClient.advertisedCapabilities` as the client's values.
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.