---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5cz7z94krenp7smz7qjyyxs
  text: |-
    Research done.
    - `ConfiguredSecret` (Configuration/ConfiguredSecret.swift) already redacts a value in each form. The new store follows the same rule: no description, mirror or error shows a value.
    - `ComposedAgent.compose` builds `RoutedACPAgent`. The agent keeps host inputs as `nonisolated let` (`environment`, `userDirectory`). The store goes there too, as `secretStore`, for the next card.
    - The CLI composes in `Sources/acp-agent/AgentComposition.swift`; `AgentCompositionTests` reaches it with `@testable import acp_agent`.
    - Toolchain is Swift 6.4, so `Test.cancel(_:)` gives the skip of the Keychain test when the host has no Keychain access.
    - No ARCHITECTURE.md in the repository.
  timestamp: 2026-10-20T15:35:24.708539+00:00
- actor: claude-code
  id: 01m5czgpwz1qd97q0pxyqc380a
  text: |-
    Implementation done (TDD). RED: the new tests did not compile (`KeychainSecretStore` and `RoutedACPAgent.secretStore` did not exist). GREEN: 8 new tests pass. The Keychain round-trip test ran on this host and was not skipped.
    - The new file `Configuration/SecretStore.swift` holds `SecretStore`, `SecretStoreError` (each case names only the reference) and `InMemorySecretStore` (its description, debugDescription and mirror show the reference names only).
    - The new file `Configuration/KeychainSecretStore.swift` reads a generic password item. With `synchronizable: true` the query sets `kSecAttrSynchronizable = true`. With `false` it sets `kSecAttrSynchronizable = false` and `kSecUseDataProtectionKeychain = false`. The status errSecItemNotFound gives nil. Each other status throws `keychainFailure(reference:status:)`.
    - `RoutedACPAgent.init(secretStore:)` keeps the store in `nonisolated let secretStore` for the next card. When the value is nil, the agent uses `KeychainSecretStore(service: name.rawValue, synchronizable: false)`. `ComposedAgent.compose(secretStore:)` gives the store to the agent.
    - The CLI gives `KeychainSecretStore(service: "acp-agent", synchronizable: false)`.
    - The Keychain test skips with `Test.cancel` when SecItemAdd gives a status that means "no Keychain access" (missing entitlement, interaction not allowed, not available, no such keychain, auth failed).
    - Full `swift test`: 1005 tests in 113 suites passed, 0 failures, 1 known issue (an existing `withKnownIssue` in HarnessSmokeTests). The one warning is the SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle. It existed before this change, and many earlier cards record it.
  timestamp: 2026-10-20T15:40:11.039697+00:00
- actor: claude-code
  id: 01m5czgt0rvk2n9p2jfa6gtcvj
  text: |-
    ### implement — changed
    - evidence: 8 files. New: Sources/FoundationModelsACPAgent/Configuration/SecretStore.swift, Sources/FoundationModelsACPAgent/Configuration/KeychainSecretStore.swift, Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift. Changed: Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Configuration/GatedStubModel.swift (a doc link only), Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift. `swift test`: 1005 tests passed, 0 failed.
    - next: /review
  timestamp: 2026-10-20T15:40:14.232952+00:00
- actor: claude-code
  id: 01m5czkwtsjw1zcdek0wq10hgm
  text: |-
    ### test — green
    - evidence: swift test — 1005 tests in 113 suites passed, 0 failed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests). swift build --build-tests after touch of the Configuration sources and tests: no compiler warning.
    - warning left: the SwiftPM "missing creator for mutated node" warning on mlx-swift_Cmlx bundle. It is accepted and comes from a dependency.
    - next: review.
  timestamp: 2026-10-20T15:41:55.417427+00:00
position_column: doing
position_ordinal: '80'
title: 'ACPA-18: a SecretStore port and a Keychain implementation'
---
## What
ACPA-18 and D101: a secret in `config.yaml` is a reference `keychain:<name>`. ACPAgent looks up the value in the Keychain. The app gives the synchronizable items of iCloud Keychain. The CLI uses the login Keychain. Now there is no Keychain code in ACPAgent or in the family packages.

Add a port and one implementation in `Sources/FoundationModelsACPAgent/Configuration/`:
- `public protocol SecretStore: Sendable { func value(forReference name: String) throws -> String? }`. It returns nil when no item exists. It throws for other Keychain errors.
- `public struct KeychainSecretStore: SecretStore` with `init(service: String, synchronizable: Bool)`. It reads a generic password item (`kSecClassGenericPassword`, `kSecAttrService` = service, `kSecAttrAccount` = name). With `synchronizable: true` it reads the iCloud Keychain items (`kSecAttrSynchronizable = true`), else the login Keychain (`kSecAttrSynchronizable = false` and `kSecUseDataProtectionKeychain` off).
- `public struct InMemorySecretStore: SecretStore` for tests and for hosts with no Keychain.
- Add `secretStore: (any SecretStore)? = nil` to `ComposedAgent.compose(...)` and to the `RoutedACPAgent` init, and keep it for the configuration load (the next card uses it). With nil, use `KeychainSecretStore(service: <name>, synchronizable: false)`.
- The CLI (`Sources/acp-agent/AgentComposition.swift`) gives the login Keychain, `service: "acp-agent"`.
- A value never goes into a log, a `description` or an error message. The errors name only the reference.

This card does not change how `config.yaml` is read. The next card does that.

## Acceptance Criteria
- [ ] `SecretStore`, `KeychainSecretStore` and `InMemorySecretStore` exist and are public.
- [ ] `compose` and the `RoutedACPAgent` init take a `SecretStore`.
- [ ] No error, log or description contains a secret value.

## Tests
- [ ] `InMemorySecretStore` gives the value of a known name and nil for an unknown name.
- [ ] `KeychainSecretStore` with `synchronizable: false`: add an item with `SecItemAdd` under a unique test service, read it, then delete it. If the test host has no Keychain access, the test is skipped with a clear reason, not failed.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18