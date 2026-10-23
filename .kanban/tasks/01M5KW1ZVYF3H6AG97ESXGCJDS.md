---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5kwe114723em6r69vwngvjt
  text: |-
    ### CodeContext cf1552b (2026-10-23) — use it in this card
    - Update the CodeContext pin to cf1552b.
    - One process-wide `CodeContextManager(embedder:autoInstall:eventSource:indexDirectory:)`. Each session: `acquire(root: cwd)` at start, `release(root: cwd)` at shutdown, in place of its own `CodeContext(...)` + start()/stop(). The last release stops. `close`/`shutdown` still stop at once (use only at host exit).
    - A root inside an open root leases the context of that open root (a session in a subfolder shares the parent's index) — test it.
    - Key: `CodeContextManager.rootKey(for:)` = standardized + resolvingSymlinksInPath. Use the same normalization for the cwd key of ^w53xmhk / AgentHome.projectKey.
    - Embedder: one per manager; acquire takes none. Sessions whose profiles give different embedders (or semanticSearch off = nil) need different managers: keep one manager per embedder identity.
    - indexDirectory closure gets the rootKey: return `<local home>/projects/<sha256 of rootKey>/code-context`. nil keeps `<root>/.code-context`.
  timestamp: 2026-10-23T08:00:58.404406+00:00
- actor: claude-code
  id: 01m5m316mqp6w6hczxxv365k81
  text: |-
    Research (implement pickup):
    - Pin moved: Package.resolved FoundationModelsCodeContext b0c8aba -> cf1552b (= origin/main tip); `swift package resolve` changed no other pin.
    - CodeContextManager.acquire throws `CodeContextError.overlappingRoot` when the new root is an ANCESTOR of an open root (session in /repo after a session in /repo/sub). Today that session gets its own context; with a bare acquire session/new would fail. Plan: on overlappingRoot the session falls back to its own unshared CodeContext (index still under home.local), released by its stop.
    - Embedder identity = `ObjectIdentifier(profile.embedding)` (RoutedModel is a final class; residentProfile is per agent). Manager key also carries the LspAutoInstall policy and home.local, because a manager has one autoInstall and one index-directory rule.
    - The registry drops a manager at its last lease, so no manager retains an old profile's embedder after its sessions close.
    - All resume paths (restore failure, releaseReplacedSession) and session/close go through SessionSurface.shutdown(), so the release there covers them.
    - SessionSetup/SessionResume docs name `<cwd>/.code-context` as the example of a mount that makes the cwd; they need a fix too.
  timestamp: 2026-10-23T09:56:18.199411+00:00
- actor: claude-code
  id: 01m5m3k8eh0c2rz3gx9ac06b38
  text: |-
    Implementation landed (not committed, per brief):
    - New `Tools/CodeContextLease.swift`: `CodeContextLease {context, release}` and actor `CodeContextLeases.shared`, one `CodeContextManager` per `ManagerKey` = (ObjectIdentifier of the profile embedding handle or nil when semanticSearch is off, LspAutoInstall, home.local). Manager's indexDirectory closure = `home.codeContextIndexDirectory(of: rootKey)`. Lease count per manager is counted up before the first await; the manager entry is dropped at its last lease (no profile embedder is kept alive after its sessions close).
    - `overlappingRoot` (a session in a PARENT of an open root) falls back to an unshared CodeContext with the same home index folder, stopped at its release; without this, session/new would throw where it worked before.
    - `AgentHome.codeContextIndexDirectory(of:)` = `projectStateDirectory(of:)/code-context`; AgentHome doc fixed.
    - `SessionSurface.codeContextStop` (public) replaced by internal `codeContextLease`; `shutdown()` releases. BuiltRegistry carries the lease; `codeContextFirstIndexPass` gone (tests use `lease.context.waitForFirstIndexPass()`). session/close, resume restore failure and releaseReplacedSession all go through `shutdown()`.
    - Doc fixes: SessionSetup.requireExistingDirectories, SessionResume (composeResumedSession, the release-before-compose comment), SessionResumeTests codeContextOnYAML doc.
    - Pins: root Package.resolved CodeContext b0c8aba -> cf1552b; IntegrationTests/Package.resolved CodeContext f0ed4ce -> cf1552b (only that pin; the integration package pins are otherwise stale vs root and were not touched).
    - Discovery: `URL.resolvingSymlinksInPath()` maps `/private/tmp/x` to `/tmp/x`, so the manager's `rootDirectory` differs from a `/private/tmp` cwd path; tests compare both sides resolved.
    - TDD: CodeContextSharingTests RED first (4 failing: share, keep-running, subfolder, index-under-home), GREEN after. Full suite: 1250 tests / 138 suites passed (1 known issue is a `withKnownIssue` by design), build has no warnings.
    - ARCHITECTURE.md does not describe the code context, so no update needed.
  timestamp: 2026-10-23T10:06:09.873021+00:00
- actor: claude-code
  id: 01m5m3kba3vm35jzgrrrvrk3ke
  text: |-
    ### implement — changed
    - evidence: `swift test` 1250 tests in 138 suites passed (0 failures; 1 known issue by design), `swift build --build-tests` no warnings; CodeContextSharingTests 7/7 (4 RED before the change). Files: Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift (new), Tools/ToolCatalog.swift, Configuration/AgentHome.swift, Agent/SessionSetup.swift, Agent/SessionResume.swift, Tests/.../CodeContextSharingTests.swift (new), Tests/.../Support/NeverAnsweringEmbeddingContainer.swift (new), ToolCatalogTests.swift, AcpCommandTests.swift, Support/HarnessSmokeTests.swift, SessionResumeTests.swift; Package.resolved + IntegrationTests/Package.resolved (gitignored) CodeContext pin -> cf1552b.
    - next: /review
  timestamp: 2026-10-23T10:06:12.803534+00:00
- actor: claude-code
  id: 01m5m3ns8pwspq02w8nsze34ey
  text: |-
    ### test — green
    - evidence: swift test — 1250 tests in 138 suites passed, 0 failures, 1 known issue (deliberate withKnownIssue in HarnessSmokeTests), 0 skipped; only build warning is the known SwiftPM mlx "missing creator" line. Bench: uv run --no-project --python 3.12 --with swebench==5.0.2 python -m unittest — 265 tests OK.
    - next: none; no files changed, nothing committed.
  timestamp: 2026-10-23T10:07:32.630642+00:00
- actor: claude-code
  id: 01m5m41wz23cwkdyq6ty8s9a84
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0c33a88) — 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift:74
    - next: implement the unchecked item in Review Findings (2026-10-23 05:08), then re-review
  timestamp: 2026-10-23T10:14:09.634268+00:00
- actor: claude-code
  id: 01m5m42811s102be67qrc9vj4s
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 source/test files (CodeContextLease.swift new, CodeContextSharingTests.swift new)
    - test: green — swift test 1250 passed; bench 265 OK
    - commit: 0c33a88
    - review: findings — Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift:74 (autoInstall is assignOnlyProperty)
  timestamp: 2026-10-23T10:14:20.961871+00:00
- actor: claude-code
  id: 01m5m49f8qcnwes89e7900yvmd
  text: |-
    Finding `CodeContextLease.swift:74` dead-code-swift (`autoInstall` assignOnlyProperty) fixed:
    - Cause: `ManagerKey` had a hand-written `hash(into:)` and a synthesized `==`. The synthesized `==` reads `autoInstall`, but periphery cannot see synthesized reads, so it reported the property as assign-only. The property is not dead: a manager has one LspAutoInstall, so it must stay in the key.
    - Fix: an explicit, documented `static func ==` on `ManagerKey` that compares embedder, autoInstall and localRoot; it pairs with the explicit hash. No property removed (the rule says not to delete a property whose only reader is synthesized), no `periphery:ignore` marker needed because the read is now visible.
    - Rest of the file checked: every other stored property (ManagerSettings.embedder/autoInstall/home, ManagerKey.embedder/localRoot, Entry.manager/leaseCount, CodeContextLease.context/release) has a visible reader.
    - Guard test `settingsThatDifferOnlyInTheLanguageServerInstallGiveTwoManagerKeys` (CodeContextSharingTests) added first; it passed before the change too, as expected for a behavior-keeping refactor (the synthesized `==` already compared autoInstall). It fails if autoInstall is dropped from `==`.
    - Verified with periphery 3.x (`--skip-build --index-store-path .build/out --retain-public`): pre-fix tree (stashed) reports `CodeContextLease.swift:74:13 Assign-only property 'autoInstall'`; fixed tree reports nothing in CodeContextLease.swift.
    - Note: the rules dump for .swift is 754K chars (embedded probe output) and could not be read whole; the dead-code-swift section was read in full.
  timestamp: 2026-10-23T10:18:17.751324+00:00
- actor: claude-code
  id: 01m5m49hb90x5x22tsqm5qc8r9
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift (explicit ManagerKey ==), Tests/FoundationModelsACPAgentTests/CodeContextSharingTests.swift (new key test). `swift test`: 1251 tests in 138 suites passed, 0 failures, 1 known issue (by design); `swift build --build-tests` only the known SwiftPM mlx "missing creator" line. periphery: no finding in CodeContextLease.swift. Finding flipped to [x]. Not committed (per brief).
    - next: /review
  timestamp: 2026-10-23T10:18:19.881271+00:00
- actor: claude-code
  id: 01m5m4bn0qypdwkzxtw11dyke2
  text: |-
    ### test — green
    - evidence: swift test — 1251 tests in 138 suites passed, 0 failed, 0 skipped, 1 known issue (deliberate withKnownIssue in HarnessSmokeTests); only build warning is the known SwiftPM mlx "missing creator" line. bench: uv run --no-project --python 3.12 --with swebench==5.0.2 python -m unittest — 265 tests OK.
    - next: none; no source change was needed, nothing committed.
  timestamp: 2026-10-23T10:19:29.175010+00:00
- actor: claude-code
  id: 01m5m4fcphqcffpx5v8we91x3f
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4f7f78f) — 0 findings, 0 confirmed, 0 refuted (7 attempted, 0 failed); 2 files reviewed, 2 .kanban files skipped by .reviewignore; prior finding CodeContextLease.swift:74 checked
    - next: none — moved to done
  timestamp: 2026-10-23T10:21:31.729871+00:00
- actor: claude-code
  id: 01m5m4fqyy7weew36cms9qr330
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — CodeContextLease.swift (explicit ManagerKey ==), CodeContextSharingTests.swift
    - test: green — swift test 1251 passed; bench 265 OK
    - commit: 4f7f78f
    - review: clean — 0 findings
  timestamp: 2026-10-23T10:21:43.262186+00:00
depends_on:
- 01M5KW1TKC9N9DGCZG5W53XMHK
position_column: done
position_ordinal: ffff9180
title: Sessions in one cwd share one CodeContext (ref-counted), and its index lives under the local home
---
User design 2026-10-23: one code index per cwd, shared by every session of that cwd in the process.

## Today
- Each session makes `CodeContext(rootDirectory:embedder:autoInstall:)` + start() (ToolCatalog.swift:523-548) and SessionSurface.shutdown() stops it (ToolCatalog.swift:192-195; SessionLifecycle.swift:256; SessionResume.swift:391,436). N sessions = N watchers, index loops, LSP fleets and DatabasePools on one `<cwd>/.code-context/kit.db`.
- AgentHome.swift:199-202 says the index lives under `<local>/projects/<key>/`; it does not.

## Waits on
CodeContext session (asked 2026-10-23): ref-counted acquire/release in CodeContextManager, and an index folder parameter. Update the pin to its sha.

## Do
- [x] One process-wide CodeContextManager; composeCodeContext acquires for the session's cwd (same cwd key as the snapshot card); shutdown releases; the last release stops.
- [x] Pass the index folder `<local home>/projects/<cwd key>/code-context`, so an iCloud project folder does not sync kit.db. Fix the AgentHome doc to match.
- [x] Embedder: follow the package's documented rule for a second acquire with another embedder.

## Tests (first)
- Two sessions in one cwd get the same CodeContext; closing one keeps it running; closing the last stops it.
- Two cwds get two contexts.
- With a custom home, no `.code-context` folder appears in the cwd; the index is under home.local. #share-per-cwd #home

## Review Findings (2026-10-23 05:08)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Tools/CodeContextLease.swift:74` `code-hygiene/dead-code-swift` — var.instance `autoInstall` is assignOnlyProperty.
