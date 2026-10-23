---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5mbk5fan2nnsa6xbhk7wf7q
  text: |-
    Research (probes in scratchpad, macOS 27 / Swift 6.4):
    - `security create-keychain -p <pw> <path>` does NOT add the keychain to the user search list here (list-keychains -d user unchanged before/after). `unlock-keychain -p`, `set-keychain-settings <path>` (no -u/-t => "no-timeout"), `delete-keychain <path>` all work on a file in a temp folder.
    - `kSecUseKeychain` and `kSecMatchSearchList` are NOT deprecated; only getting a SecKeychainRef is (`SecKeychainOpen` deprecated macOS 10.10).
    - Warning-free confinement: a protocol requirement whose witness is marked `@available(macOS, deprecated: 10.10)` calls `SecKeychainOpen` with no warning, and calling it through the protocol emits none (swiftc -swift-version 6, zero diagnostics).
    - One query dict carrying BOTH `kSecUseKeychain: ref` and `kSecMatchSearchList: [ref]` works for SecItemAdd, SecItemCopyMatching (hit and -25300 miss) and SecItemDelete; the item never shows in the default search list.
    - SecKeychainOpen gives status 0 for a path with no file; two opens of one path are CFEqual, different paths are not (usable in a unit test with no keychain file).
    - No gate env: ci.yml uses `integration-package-path: IntegrationTests` + `integration-no-parallel`, so the shared workflow runs plain `swift test --package-path IntegrationTests` (no-parallel).
  timestamp: 2026-10-23T12:25:55.434191+00:00
- actor: claude-code
  id: 01m5mc31r2jx1084qryzyz4gv4
  text: |-
    Implementation landed (uncommitted, per brief).
    - `KeychainSecretStore` gains `public enum Keychain { case login; case file(URL) }` and `init(service:synchronizable:keychain: = .login)`; `precondition` that a synchronizable store takes `.login` only. Default unchanged, so `loginKeychain(for:)`, RoutedACPAgent, SettingsStore, ConfigurationLoader and AgentCompositionTests equality all keep their behaviour.
    - `itemQuery(account:)` now `throws`; for `.file` it carries the same `SecKeychain` as `kSecUseKeychain` (add target) and as the single entry of `kSecMatchSearchList` (lookup/delete). `.login` adds neither key.
    - Deprecated `SecKeychainOpen` is confined: private protocol `KeychainFileOpening` (non-deprecated requirement) + private `SecKeychainFileOpener` whose witness is `@available(macOS, deprecated: 10.10)`; called through `any KeychainFileOpening`. Zero compiler warnings (verified: filtered unit build and a full fresh compile of the root module in the nested package both show no `warning:` from Swift files).
    - Integration test now uses `Support/TemporaryKeychain.swift`: `security create-keychain -p <random UUID>`, `unlock-keychain`, `set-keychain-settings` (no timeout, no lock on sleep) in a unique temp folder; `delete()` runs `security delete-keychain` and removes the folder. The test asserts `security list-keychains -d user` is the same before and after.
    - Gotcha: the nested IntegrationTests/Package.resolved (gitignored) was stale — FoundationModelsMultitool lacked `ShellStore`, so the nested build failed on SandboxComposition.swift/ShellStoreLease.swift. `swift package update` in IntegrationTests fixed it locally; CI resolves fresh so it is unaffected.
    - Not exercised: a real locked login keychain (did not lock the user's). The unit test proves the query names only the given keychain; the integration test never names the login keychain.
  timestamp: 2026-10-23T12:34:35.906138+00:00
- actor: claude-code
  id: 01m5mc3rdvzybqk45j7rj2nfd0
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Configuration/KeychainSecretStore.swift, Tests/FoundationModelsACPAgentTests/SecretStoreTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/KeychainSecretStoreTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TemporaryKeychain.swift (new). RED: `swift test --filter SecretStoreTests` failed to compile (no member `keychain` / `Keychain`). GREEN: same filter 8/8 passed. `cd IntegrationTests && swift test --no-parallel --filter KeychainSecretStoreTests` 1/1 passed (CI sets no gate env: ci.yml passes integration-package-path + integration-no-parallel only). Root `swift test` 1269 tests / 141 suites passed (1 known issue = pre-existing withKnownIssue in HarnessSmokeTests). Zero Swift compiler warnings; the only `warning:` line is SwiftPM's "missing creator for mutated node: mlx-swift_Cmlx.bundle", unrelated to these files.
    - next: /review; then commit.
  timestamp: 2026-10-23T12:34:59.131575+00:00
- actor: claude-code
  id: 01m5mc8p271f88pr1v3wkdp3qk
  text: |-
    ### test — green
    - evidence: swift test 1269 passed (141 suites, 1 deliberate known issue); IntegrationTests KeychainSecretStoreTests 1 passed; bench 265 OK; forced recompile of KeychainSecretStore.swift — 0 compiler warnings
    - next: commit, review
  timestamp: 2026-10-23T12:37:40.551374+00:00
position_column: doing
position_ordinal: '80'
title: KeychainSecretStore takes the keychain as a parameter; its integration test uses a temporary keychain
---
User decision 2026-10-23: make the keychain a parameter of `KeychainSecretStore`, and have the integration test create and use a temporary keychain.

## Why
CI on main has not passed since 2026-10-20 12:39. The only test failure: `IntegrationTests/.../KeychainSecretStoreTests.theLoginKeychainStoreReadsAnAddedItem` — `SecItemAdd gave status -25308` (errSecInteractionNotAllowed): the self-hosted runner's login keychain is locked. The user does not want to change the runner.

## Do
- [x] `KeychainSecretStore` gets a keychain parameter (default: the login keychain, as today, so `KeychainSecretStore.loginKeychain(for:)`, RoutedACPAgent.swift:411 and SettingsStore.swift:255 keep their behaviour). Its query targets that keychain (e.g. `kSecUseKeychain` for add / `kSecMatchSearchList` for read, or whatever works for a file keychain).
- [x] The integration test creates a temporary keychain (unique file in a temp folder, known throwaway password, unlocked, no auto-lock), adds its item there, reads through a store given that keychain, and deletes the keychain file at the end — never touching the login keychain or the user's keychain search list.
- [x] Zero warnings: the file-keychain APIs (`SecKeychainCreate`, `SecKeychainOpen`, ...) are deprecated. Find a way with no build warning (e.g. the `security` CLI for create/unlock/delete in the test, and a non-deprecated way for the store to target it; or confine any deprecated call so it produces no warning). If no warning-free way exists, stop and report it.

## Tests (first)
- The integration test passes on a machine whose login keychain is locked (simulate: it must not use the login keychain at all).
- A unit test: the store's queries carry the given keychain.
- Run the IntegrationTests package locally (`cd IntegrationTests && swift test --filter KeychainSecretStoreTests`, with whatever gate env the CI workflow sets). #ci