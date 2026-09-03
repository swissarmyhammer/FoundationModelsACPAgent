---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1jmvjs1zr7jktvg1mv79qa6
  text: |-
    Research results (iteration 1):

    What is already in place:
    - `ToolCatalog.makeRegistry` sends the root set to `withFiles(root:additionalRoots:)` and to `SandboxComposition.composeShell(rootSet:)`. `ToolCatalogTests` show the read verb accepts a path in an additional root and refuses a path outside the root set, at the registry level.
    - `SessionResume.recordResumedRootSet` writes the replaced list to `sessions.jsonl`. `PromptTurn.makeFirstActivity` writes the list at the first prompt. `SessionResumeTests` show the root-set replacement on resume.
    - `SessionList` reports the ordered list and drops a damaged non-absolute record entry. `SessionListTests` show the wire report from fixture-written records.
    - `InitializationTests` show the `additionalDirectories: {}` capability advertisement.

    What is missing (the gaps this task closes):
    - No `MultiRootConfinementTests.swift`. The client-end proofs from one `session/new` activation do not exist: read under R through the session surface, refusal outside the union, shell write into R shown from disk, transcripts kept under the cwd dotfolder, and `session/list` after a live first prompt.
    - The skip-and-log rule of plan.md section 7.2. The wire decode (`forgivingDecodeArrayIfPresent` in FoundationModelsACP) drops an invalid array item with no log. `AbsolutePath` cannot hold a relative value, so `newSession` and `resumeSession` map entries with no guard of their own. The fix: one `SessionSetup` helper converts the wire list to root URLs, skips a non-absolute entry with a log, and both call points use it. A raw-wire ndJSON test proves a relative entry does not refuse the session.

    Other facts found:
    - `withFiles` does not throw and does not examine the roots at construction. A root that does not exist is safe: `SeatbeltSandbox.Options` keeps an unresolvable path as it is, by documented design.
    - The ndJSON framing is public (`NDJSONFramer`), and `InMemoryTransport` carries raw bytes, so a test can drive the agent with raw JSON-RPC frames.
  timestamp: 2026-09-03T03:26:32.225193+00:00
- actor: claude-code
  id: 01m1jn0teavm1x1r2yp9rhej93
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift (new `SessionSetup.additionalRoots(fromPaths:)` skip-and-log converter, one logger, `newSession` rewired), Sources/FoundationModelsACPAgent/Agent/SessionResume.swift (`resumeSession` rewired to the same converter), Tests/FoundationModelsACPAgentTests/MultiRootConfinementTests.swift (new suite, 7 tests: client-end read under R, refusal outside the union, skip-and-log unit proof, raw ndJSON wire proof that a relative entry does not refuse the session, real sandboxed shell write into R read back from disk, transcript location held under the cwd dotfolder, ordered session/list report from the activation).
    - TDD: the suite failed first with "type 'SessionSetup' has no member 'additionalRoots'"; the helper made it green.
    - tests: `swift test` — 339 tests in 38 suites passed, 1 known issue (the pre-existing HarnessSmokeTests withKnownIssue). Baseline was 332 in 37.
    - next: run the test step, then commit and review.
  timestamp: 2026-09-03T03:29:23.914912+00:00
- actor: claude-code
  id: 01m1jn1v28k3jes5d7gx52mxjd
  text: |-
    ### test — green
    - evidence: `swift test` — 339 tests in 38 suites passed, 0 failures, 1 known issue (the pre-existing HarnessSmokeTests withKnownIssue). `swift build --build-tests` — 0 warnings, 0 errors. The tier-3 and tier-4 suites stay gated, as in the baseline.
    - next: commit, then review.
  timestamp: 2026-09-03T03:29:57.320431+00:00
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSVB1ACAR7NDK06015S796H
position_column: doing
position_ordinal: '80'
title: 'additionalDirectories: multi-root confinement end to end'
---
## What
Plan.md §7.2. Extend confinement from a single root to the full root set.

**The upstream gate is CLEARED.** The old task blocked on Multitool card `939nnzx` for a multi-root `PathGuard`. That work shipped. `FilesCapability` and `Builder.withFiles` both take `additionalRoots: Set<URL>` today. Start this task.

**`PathGuard` is internal.** You cannot name it, and the files capability's argument and output structs are internal too. Reach multi-root confinement only through `withFiles(root:additionalRoots:)`, and assert behavior by invoking the verbs.

- `session/new` and `session/resume` accept `additionalDirectories: [AbsolutePath]`. Each item must be absolute. The array carries `x-deserialize-skip-invalid-items`, so skip and log a bad entry and never refuse the session. The list is ordered and persists per session in the SessionIndex.
- Roots extend confinement only. `cwd` stays singular for the relative-path base, the config layer, the AGENTS.md walk and the transcript directory. A second root must never fork the transcript location.
- Pass the root set as `withFiles(root: cwd, additionalRoots: Set(additionalDirectories))`.
- The shell is not root-confined by the files capability. Its bound is the sandbox. Give the same root set to `SeatbeltSandbox.Options(writableRoots:)` so a shell write is allowed in an additional root. See the sandbox task.
- On resume the list is authoritative and replaceable. The resume task enforces that; this task makes the multi-root half real.
- `capabilities.session.additionalDirectories: {}` is already advertised at initialize. Verify it is honest now that this lands. Accepting and ignoring is worse than not advertising.

- [ ] Root set reaches `withFiles(root:additionalRoots:)`
- [ ] Invalid entries skipped and logged
- [ ] Ordered list persisted and reported through session/list
- [ ] Sandbox writable roots include the additional roots

## Acceptance Criteria
- [ ] With an additional root R, `tools.files.read` reads a file under R from the client end
- [ ] A path outside the union of cwd and R is still refused
- [ ] A relative or invalid entry in the array is skipped with a log, and the session still starts
- [ ] A shell command writes into R and succeeds, proved by reading the file from disk
- [ ] Transcripts stay under `<cwd>/.<name>/` even when R is supplied
- [ ] `session/list` reports the ordered list from the most recent activation

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MultiRootConfinementTests.swift` — harness, two temp roots
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.