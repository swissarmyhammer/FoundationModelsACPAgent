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
- actor: claude-code
  id: 01m5czs5zr851ayc9nav54hh1a
  text: |-
    ### review — stuck
    - evidence: review sha HEAD~1..HEAD (commit 83d0092). 6 findings (6 confirmed, 1 refuted): Sources/acp-agent/AgentComposition.swift:134, Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:66, :80, :85, :155, :177.
    - conflict: the finding at SecretStoreTests.swift:85 (test-integrity/no-test-cheating) tells you to remove the Test.cancel skip and let the Keychain test fail. The card Tests section tells you to skip that test with a clear reason when the host has no Keychain access. The two cannot both be correct.
    - next: a person decides the conflict (change the card or the rule). Then /implement the findings and /review again. The task stays in review.
  timestamp: 2026-10-20T15:44:48.632999+00:00
- actor: claude-code
  id: 01m5czsz7v26ksapqfb3b328f1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test, 1005 passed, 0 failed
    - commit: 83d0092
    - review: findings (reported stuck) — Sources/acp-agent/AgentComposition.swift:134, Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:66, :80, :85, :155, :177
    - conflict resolved by the planner: the card text "skipped, not failed" was a plan detail, not a rule. The card now puts the Keychain test in IntegrationTests/ and lets it fail. All 6 findings are open and in scope.
  timestamp: 2026-10-20T15:45:14.491647+00:00
- actor: claude-code
  id: 01m5d089p79950w74a6wyhx4z6
  text: |-
    Findings worked (TDD). All six findings are now `- [x]`.
    - AgentComposition.swift: the CLI gives no secret store. The library default (login Keychain, service `acp-agent`) is the store of the CLI. `AgentCompositionTests.theCompositionGivesTheLoginKeychainOfTheCLI` still proves it.
    - SecretStoreTests.swift: `dump` is gone. The text-form test reads `Mirror(reflecting:)` children, which is what `dump` reads. The Keychain round-trip test, the `Test.cancel` branch, the status set, and the query helpers are gone from the unit target. The file uses no Keychain now.
    - New IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/KeychainSecretStoreTests.swift: the round-trip test. It fails with the status when SecItemAdd fails. CI runs the IntegrationTests package (`integration-package-path` in .github/workflows/ci.yml).
    - KeychainSecretStore.swift: the new internal `itemQuery(account:)` holds the shared attributes. `lookupQuery` adds the limit and return keys. The integration test adds and deletes the item with `itemQuery`. RED: the integration test did not compile (no `itemQuery`). GREEN: it passed.
    - New Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift: the public `composeStubAgent(name:label:secretStore:)`. ComposedAgentTests and SecretStoreTests call it. Their private copies are gone.
    - Discovery: the IntegrationTests package had a stale ignored Package.resolved (FoundationModelsMultitool had no `SnapshotsCapability`). `swift package --package-path IntegrationTests update` corrected it. No family package source changed.
  timestamp: 2026-10-20T15:53:03.943457+00:00
- actor: claude-code
  id: 01m5d08dax648r5xz50a4eqkay
  text: |-
    ### implement — changed
    - evidence: 6 files. New: IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/KeychainSecretStoreTests.swift, Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift. Changed: Sources/FoundationModelsACPAgent/Configuration/KeychainSecretStore.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift, Tests/FoundationModelsACPAgentTests/ComposedAgentTests.swift. `swift test`: 1004 tests in 113 suites passed, 0 failed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests). `swift test --package-path IntegrationTests --filter KeychainSecretStoreTests`: 1 test passed. The one warning is the existing SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle.
    - next: /review
  timestamp: 2026-10-20T15:53:07.677344+00:00
- actor: claude-code
  id: 01m5d0cfcm2nve5gm836mh9ytz
  text: |-
    ### test — green
    - evidence: touched the 5 changed or new Swift files, then `swift test` — 1004 tests in 113 suites passed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests), 0 failures, 0 compiler warnings. `swift test --package-path IntegrationTests --filter KeychainSecretStoreTests` — 1 test in 1 suite passed, 0 compiler warnings. Only the accepted SwiftPM "missing creator for mutated node" warning on mlx-swift_Cmlx appears.
    - next: review
  timestamp: 2026-10-20T15:55:20.852533+00:00
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
- [ ] `KeychainSecretStore` with `synchronizable: false`: add an item with `SecItemAdd` under a unique test service, read it, then delete it. This test uses a real external system, so it goes in the `IntegrationTests/` nested package (`swift test --package-path IntegrationTests`), not in the hermetic suite. If `SecItemAdd` fails, the test fails. (Card changed after the review of 83d0092: the rules `test-partitioning` and `no-test-cheating` win over the old text "skipped, not failed".)
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18

## Review Findings (2026-10-20 10:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 34 not reviewed.

> 34 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 34 file(s)

- [x] `Sources/acp-agent/AgentComposition.swift:134` `reuse/reuse` — The CLI builds its own login Keychain store with KeychainSecretStore(service: dotfolderName, synchronizable: false). RoutedACPAgent.init already builds this same store as its default, under the service name.rawValue. The CLI therefore repeats the library default in a second place, and a change to the default would not reach the CLI. Pass no secretStore from the CLI, so the library default gives the same login Keychain store under the same service. If the explicit argument is kept for clarity, add a comment that says it matches the library default.
- [x] `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:66` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:80` `test-integrity/test-partitioning` — The unit target test `theLoginKeychainStoreReadsAnAddedItem` uses a real external system. It calls SecItemAdd and SecItemDelete on the user's login Keychain. A unit test must need no external system, so this test belongs in an integration target, not in the default unit run. Move the Keychain round-trip test into the `IntegrationTests/` nested package, selected with `swift test --package-path IntegrationTests`, and make sure a CI task runs that target. Keep the unit tests in this file on `InMemorySecretStore`, which needs no Keychain.
- [x] `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:85` `test-integrity/no-test-cheating` — The Keychain test `theLoginKeychainStoreReadsAnAddedItem` turns a failed SecItemAdd into a cancelled test when the status is in `noKeychainAccessStatuses`. A host that refuses Keychain access, such as a CI runner, then reports the test as skipped instead of failing. The test cannot fail on that host, so it proves nothing there. Remove the `Test.cancel` branch. Let the test fail with the status when SecItemAdd fails, and move the test to the integration target described in the earlier finding, where a host without Keychain access is a known precondition and not a silent pass.
- [x] `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:155` `reuse/reuse` — The new composeStubAgent helper rebuilds the stub composition that already exists in ComposedAgentTests. Both create the config home and workspace, build the environment, and call ComposedAgent.compose with the stub model. Two copies of the same setup will drift apart when the setup changes. Move the shared stub-composition helper into Tests/FoundationModelsACPAgentTestSupport and call it from both suites. The new helper should only add the secretStore argument, or pass it through the shared helper if that helper accepts one.
- [x] `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:177` `reuse/reuse` — loginKeychainItemQuery rebuilds the same query dictionary that KeychainSecretStore.lookupQuery already builds for the same service, account, synchronizable and data protection attributes. A change to the production query shape would not update this test helper. Make the shared attribute part of the query internal rather than private, for example a query for a given service and account without the return or limit keys. Then call it from both the store and the test helper. If the test must stay independent of the production code, leave it as is and add a comment that says why.

## Blocker: conflict between a review rule and this card (2026-10-20 10:42)

The finding at `Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift:85` (`test-integrity/no-test-cheating`) tells you to remove the `Test.cancel` branch and to let the Keychain test fail when the host has no Keychain access.

The Tests section of this card tells you the opposite: "If the test host has no Keychain access, the test is skipped with a clear reason, not failed."

The two requirements cannot both be correct. The agent did not resolve this conflict. A person must decide: change the card, or change the rule. Then start the work again.

**Resolved (2026-10-20):** the planner who wrote this card changed the Tests section. The skip was a plan detail, not a rule. The Keychain test goes to `IntegrationTests/` and fails when `SecItemAdd` fails. All six findings above are in scope.