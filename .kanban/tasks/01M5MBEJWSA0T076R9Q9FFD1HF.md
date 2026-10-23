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
- actor: claude-code
  id: 01m5mcc4jxv0q1nza6db114ejg
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (43c8811) — 1 finding (1 confirmed, 0 refuted): IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TemporaryKeychain.swift:112 reuse/reuse
    - next: implement the unchecked item in `## Review Findings (2026-10-23 07:37)`; task stays in review
  timestamp: 2026-10-23T12:39:33.725830+00:00
- actor: claude-code
  id: 01m5mcchytayczdbgdvddfa38x
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files (KeychainSecretStore.swift, SecretStoreTests.swift, KeychainSecretStoreTests.swift, TemporaryKeychain.swift new)
    - test: green — swift test 1269 passed; integration keychain test passed; bench 265 OK; 0 compiler warnings
    - commit: 43c8811
    - review: findings — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TemporaryKeychain.swift:112 (reuse: runSecurity duplicates process launch helpers)
  timestamp: 2026-10-23T12:39:47.418493+00:00
- actor: claude-code
  id: 01m5mcjk3n0t96j8qt17y0d5ne
  text: |-
    Research for finding TemporaryKeychain.swift:112 reuse/reuse:
    - SignalledExecutableRun does not fit: it streams stdout to detect the first byte, signals the child, and drives a chunk gate. SpawnedACPAgent streams too (PipeReader). Neither returns "run to the end, give status + output".
    - The same launch-and-capture block (Process, close-on-exec Pipe, run, readToEnd before the wait, wait, status) stands THREE times in Support: TemporaryKeychain.runSecurity (stdout+stderr merged), ProcessCensus.identifiers (pgrep, stdout only, stderr inherited), and BuiltExecutableRun.run (separate stdout/stderr pipes from PipedChildProcess, async wait through a terminationHandler continuation set AFTER run(), which can double-resume if the child exits between the handler set and the isRunning check).
    - Plan: one shared async helper CapturedProcessRun (Support/CapturedProcessRun.swift) that starts a configured Process, reads its pipes to their ends (async let), and waits on ProcessExitEvent (handler set before run). A second entry runs a system tool by absolute path with stderr merged or inherited. BuiltExecutableRun, ProcessCensus.identifiers and TemporaryKeychain.runSecurity all call it; runSecurity keeps only the SecurityFailure mapping. Async ripples to ProcessCensus (agentsServingACP, orphanedAgentsServingACP, expectNoAgentOutlivedItsRun), OutOfProcessTests.ObservedAgents.record, ClientServerTests call sites, TemporaryKeychain make/delete/userSearchList and KeychainSecretStoreTests.
  timestamp: 2026-10-23T12:43:05.205615+00:00
- actor: claude-code
  id: 01m5mcxy80thrpat7c9qgq4nc6
  text: |-
    Finding TemporaryKeychain.swift:112 reuse/reuse implemented (uncommitted, per brief).
    - SignalledExecutableRun did not fit (it streams stdout for the first byte, signals, drives the chunk gate), so the shared launch-and-capture moved into one new helper, Support/CapturedProcessRun.swift: `run(_:standardOutput:standardError:)` (marks the pipes close-on-exec, waits on ProcessExitEvent set before run(), reads each pipe to the end with async let) and `run(toolAt:arguments:errorOutput:)` for a system tool, stderr `.mergedIntoOutput` or `.inherited`.
    - All three former copies call it: BuiltExecutableRun.run, ProcessCensus.identifiers (pgrep, stderr inherited as before), TemporaryKeychain.runSecurity (stderr merged as before; keeps only the SecurityFailure mapping).
    - Side effect: BuiltExecutableRun no longer sets terminationHandler after run() (that continuation could resume twice if the child exited between the handler set and the isRunning check).
    - Async ripple: ProcessCensus.identifiers/agentsServingACP/orphanedAgentsServingACP/expectNoAgentOutlivedItsRun, OutOfProcessTests ObservedAgents.record, ClientServerTests + OutOfProcessTests call sites, TemporaryKeychain make/userSearchList/delete, KeychainSecretStoreTests (an async `defer { await ... }` compiles on Swift 6.4).
    - Not folded in: SignalledExecutableRun.drain and SpawnedACPAgent's PipeReader stream output as it comes (first-byte wait, transport byte stream), so they are a different shape, not a copy of run-to-end capture.
    - Gotcha: `files edit` with replace_all replaced only the first match in OutOfProcessTests and ClientServerTests; the second sites were fixed by hand.
    - TDD: new CapturedProcessRunTests (4 tests) RED on `cannot find 'CapturedProcessRun' in scope`, then GREEN 4/4.
  timestamp: 2026-10-23T12:49:17.056004+00:00
- actor: claude-code
  id: 01m5mcy1nwfer88gf2m3s3b702
  text: |-
    ### implement — changed
    - evidence: 9 files — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/CapturedProcessRun.swift (new), CapturedProcessRunTests.swift (new), Support/BuiltExecutableRun.swift, Support/ProcessCensus.swift, Support/TemporaryKeychain.swift, KeychainSecretStoreTests.swift, OutOfProcessTests.swift, ClientServerTests.swift (all under IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/), plus the card. `cd IntegrationTests && swift test --no-parallel --filter 'KeychainSecretStoreTests|CapturedProcessRunTests|ProcessCensusTests'` 8/8 passed; whole `cd IntegrationTests && swift test --no-parallel` 31 tests / 14 suites passed, 0 skipped; root `swift test` 1269 tests / 141 suites passed (1 known issue = pre-existing withKnownIssue). Zero Swift compiler warnings; the only `warning:` is SwiftPM's pre-existing "missing creator for mutated node: mlx-swift_Cmlx.bundle". Finding flipped to [x].
    - next: /review
  timestamp: 2026-10-23T12:49:20.572735+00:00
- actor: claude-code
  id: 01m5md3xfm83nrfg6b5xeszydn
  text: |-
    ### test — green
    - evidence: swift test 1269 passed (141 suites, 1 deliberate known issue); IntegrationTests swift test --no-parallel 31 passed (14 suites); bench 265 OK; no compiler warnings
    - next: commit, review
  timestamp: 2026-10-23T12:52:32.884408+00:00
- actor: claude-code
  id: 01m5md7qab325eqtvvqmjb5bt6
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (fd38edd) — 2 findings (2 confirmed, 0 refuted) — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessCensus.swift:48 (completeness/public-output-contract), ProcessCensus.swift:48 (test-integrity/no-test-cheating). Prior TemporaryKeychain.swift:112 reuse finding checked.
    - next: implement — ProcessCensus accepts only pgrep exit 0 (matches) and 1 (no match); any other status throws with status and stderr.
  timestamp: 2026-10-23T12:54:37.643470+00:00
- actor: claude-code
  id: 01m5md89av97n27xgm5hfajrg8
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 8 files (CapturedProcessRun.swift new, CapturedProcessRunTests.swift new, BuiltExecutableRun, ProcessCensus, TemporaryKeychain, 3 test files)
    - test: green — swift test 1269 passed; integration 31 passed; bench 265 OK
    - commit: fd38edd
    - review: findings — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessCensus.swift:48 (x2: pgrep exit 2/3 treated as an empty match)
  timestamp: 2026-10-23T12:54:56.091499+00:00
- actor: claude-code
  id: 01m5mdmka691e2hh2rv3w5538n
  text: |-
    Findings ProcessCensus.swift:48 (completeness/public-output-contract, test-integrity/no-test-cheating) implemented (uncommitted, per brief).
    - `ProcessCensus.identifiers(selectedBy:)` now switches on the pgrep status: 0 -> parse stdout, 1 -> [], any other -> throws `CapturedProcessRun.Failure(command: "pgrep", status:, output: <pgrep stderr>)`. So `expectNoAgentOutlivedItsRun()` (and agentsServingACP / orphanedAgentsServingACP) fail loudly when the census cannot read the process table.
    - pgrep's stderr was inherited (left on the test log); `CapturedProcessRun.ErrorOutput` gained `.captured` (own stderr pipe, returned in `standardError`), and the census uses it.
    - Same cause, whole support code: the only other tool run that maps a non-zero exit is TemporaryKeychain.runSecurity, which already threw. Its `SecurityFailure` moved to the shared `CapturedProcessRun.Failure` (command "security <subcommand>", password still left out; description text unchanged), so the two tool-failure errors are one type. BuiltExecutableRun / SignalledExecutableRun / SpawnedACPAgent return the status to tests that assert on it, so nothing there swallows.
    - Probe: `/usr/bin/pgrep -f '('` exits 2 with "pgrep: Cannot compile regular expression ..." on stderr; a bad option also exits 2; no match exits 1.
    - TDD: new `ProcessCensusExitStatusTests.aCensusWhosePgrepFailsThrowsItsStatusAndItsErrorOutput` RED ("an error was expected but none was thrown and \"[]\" was returned"), then GREEN. Also added a no-match -> [] test and `CapturedProcessRunTests.aToolWithCapturedErrorOutputGivesBackEachStreamApart`.
    - Gotcha again: `files edit` replace_all replaced only the first of three doc lines; fixed by hand.
  timestamp: 2026-10-23T13:01:39.526373+00:00
- actor: claude-code
  id: 01m5mdmr0myqwrb53bbsf5nja1
  text: |-
    ### implement — changed
    - evidence: 5 files under IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ — Support/ProcessCensus.swift, Support/CapturedProcessRun.swift, Support/TemporaryKeychain.swift, ProcessCensusTests.swift, CapturedProcessRunTests.swift (plus the card). RED: `swift test --no-parallel --filter ProcessCensusExitStatusTests` failed (census returned [] for pgrep exit 2). GREEN: `--filter 'ProcessCensusExitStatusTests|CapturedProcessRunTests'` 7/7 passed. Whole `cd IntegrationTests && swift test --no-parallel` 34 tests / 15 suites passed, 0 failed, 0 skipped. Root `swift build` complete. Zero Swift compiler warnings; only `warning:` is SwiftPM's pre-existing "missing creator for mutated node: mlx-swift_Cmlx.bundle". Both 07:52 findings flipped to [x].
    - next: /review
  timestamp: 2026-10-23T13:01:44.340014+00:00
- actor: claude-code
  id: 01m5mdt9egz1a3a7pe9ftnzkwa
  text: |-
    ### test — green
    - evidence: swift test 1269 passed (141 suites, 1 deliberate known issue); IntegrationTests --no-parallel 34 passed (15 suites); bench 265 OK; no compiler warnings
    - next: commit, review
  timestamp: 2026-10-23T13:04:46.032108+00:00
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

## Review Findings (2026-10-23 07:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TemporaryKeychain.swift:112` `reuse/reuse` — `runSecurity` reimplements the process launch, pipe capture, wait, and status check that existing integration-test helpers already do. Keeping a second copy means two places to fix when the process-running logic changes. Check whether `SignalledExecutableRun` (or a small shared helper it can expose) can run `security` and return its output and termination status. If it can, call it from `runSecurity` and keep only the `SecurityFailure` mapping here. If the existing helpers don't fit (for example, they signal or stream output), extract the shared launch-and-capture code into one helper that all of them call.

## Review Findings (2026-10-23 07:52)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessCensus.swift:48` `completeness/public-output-contract` — The guard treats every exit status other than 1 (no match) as a successful run and parses stdout. pgrep exits 2 for a syntax error and 3 for a fatal error, both with empty stdout, so `identifiers(selectedBy:)` returns `[]` for them. That makes the no-orphan proof in `expectNoAgentOutlivedItsRun()` pass vacuously when pgrep itself fails. The error is silenced where it should be surfaced, the way the run error already is. Treat only exit 0 and exit 1 as normal. For any other status, throw an error that carries the status and stderr, so `expectNoAgentOutlivedItsRun()` fails loudly instead of reporting no orphans.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessCensus.swift:48` `test-integrity/no-test-cheating` — The guard treats every non-1 pgrep exit as a successful empty match. A pgrep failure (exit 2 for a bad pattern, exit 3 for a fatal error) with empty stdout returns [], so `expectNoAgentOutlivedItsRun` passes without having checked the process table. The reap proof can pass vacuously, which is a swallowed failure. Accept only exit 0 as matches and exit 1 as no match. Throw on any other status, for example with the `SecurityFailure`-style error carrying the status and stderr, so a failed census fails the test instead of passing it.
