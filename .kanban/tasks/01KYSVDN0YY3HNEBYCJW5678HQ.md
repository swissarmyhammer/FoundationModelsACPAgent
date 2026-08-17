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
Plan.md §7.2. Extend confinement from single-root to the full root set. **Upstream gate: the Multitool files capability's `939nnzx` (multi-root `PathGuard`) — in progress. Do not start this task until it lands; do not reimplement multi-root guarding here.**

- `session/new` and `session/resume` accept `additionalDirectories: [AbsolutePath]`; absolute required per item; the array has `x-deserialize-skip-invalid-items` — skip and log a bad entry, never refuse the session. The list is **ordered** and persists per session (SessionIndex).
- Roots extend confinement only — `cwd` stays singular for: relative-path base, config layer, AGENTS.md walk, transcript directory. A second root must never fork the transcript location.
- `PathGuard` gets the root set (cwd + roots). `ShellPolicy` accepts the roots as valid working directories. The shell remains NOT root-confined otherwise (§11.4).
- On resume the list is authoritative and replaceable (already enforced by the resume task — this task makes the multi-root half real).
- Advertise `capabilities.session.additionalDirectories: {}` (already in initialize — verify it is honest once this lands; §7.2's warning: accepting-but-ignoring is worse than not advertising).

- [ ] Multi-root ToolContext → PathGuard root set
- [ ] Skip-and-log invalid entries
- [ ] Ordered list persisted and reported via session/list
- [ ] ShellPolicy accepts roots as working directories

## Acceptance Criteria
- [ ] With an additional root R: `files` reads a file under R from the client end; a path outside cwd∪R still refuses
- [ ] A relative or garbage entry in the array is skipped with a log; the session still starts
- [ ] Transcripts stay under `<cwd>/.<name>/` even when R is supplied
- [ ] `session/list` reports the ordered list from the most recent activation

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MultiRootConfinementTests.swift` — harness; two temp roots
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.