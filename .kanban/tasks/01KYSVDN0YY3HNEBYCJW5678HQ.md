---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSVB1ACAR7NDK06015S796H
position_column: todo
position_ordinal: '9680'
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