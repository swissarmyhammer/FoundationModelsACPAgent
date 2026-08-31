---
assignees:
- claude-code
depends_on:
- 01KYSVEH19FKV250W4KQG1RFCT
position_column: todo
position_ordinal: 9a80
title: 'PythonCLIEvaluation: gated end-to-end coding eval'
---
## What
Plan.md §20.3, tier 4. Gated on Apple silicon, real models and network, through an env-var gate that follows the family convention. Create `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIEvaluation.swift` on Apple's Evaluations framework, which is swift-testing native.

1. **Subject** — `subject(from sample:)`: a fresh temp workspace as the session cwd and the confinement root; recording to a temp location; the composed agent with real files and shell and the coding instructions; run to completion; return the workspace path, the transcript and the run stats.
2. **Dataset** — an `ArrayLoader` of 20 to 30 hand-written `ModelSample` variants of "build a small Python CLI": pyproject.toml, a third-party package such as `click`, the CLI, pytest tests, a project-local venv, pytest green, then run it. `expected` carries the fixed input and output pair.
3. **Evaluators — mechanical, and verified outside the agent.** Never trust the transcript's claims. `PytestGreen` re-runs pytest in the venv and checks for exit 0. `CLIRuns` runs the CLI against `expected` and checks the output. `FilesPresent` checks the files. `ToolTraffic` checks the transcript holds real tool traffic.
4. **Aggregation** — `MetricsAggregator.computeMean` per metric. The `@Test` asserts mean pass rates against thresholds. Turn, tool-call and token stats ride along, keyed by the resolved model from `manifest.json`.
5. **Isolation** — the venv lives inside the workspace. Change no system Python. Use no network beyond the package install. Delete the workspace after grading, but keep the transcripts of failed runs.

**Two corrections from the 2026-08-31 survey:**

- **The sandbox must allow the workspace.** `SeatbeltSandbox` bounds writing and deleting, so a run that creates a venv and installs a package writes a great deal. Put the temp workspace in the writable roots. Build the options through `SeatbeltSandbox.Options(writableRoots:)` so the paths arrive `realpath`-resolved; a macOS temp directory is usually a `/var` symlink to `/private/var`, and an unresolved path is exactly the form Seatbelt cannot match. An eval that fails only inside the sandbox is almost always this.
- **`ToolTraffic` must match the code-mode shape.** The model does not call `files` and `shell` directly. It calls `runCode`, and the snippet calls `tools.files.*` and `tools.shell.execute`. Assert on the recorded tool traffic for those paths, not on a top-level tool named `files` or `shell`. Read the operation events with `TranscriptEvent.operationEvents`, which is public.

- [ ] Subject wiring
- [ ] The 20 to 30 sample dataset
- [ ] Four mechanical evaluators
- [ ] Aggregation and thresholds
- [ ] Isolation and cleanup
- [ ] The workspace is a resolved writable sandbox root

## Acceptance Criteria
- [ ] A gated run executes at least one sample end to end on Apple silicon and produces per-metric means
- [ ] The venv creation and the package install both succeed inside the sandbox
- [ ] Ungated evaluator-honesty test: `PytestGreen` and `CLIRuns`, given a fabricated transcript that claims success over a workspace that deliberately fails, both grade FAIL. This proves they grade from the filesystem and the exit codes, not from transcript text.
- [ ] Ungated `swift test` skips the gated suite and stays green

## Tests
- [ ] The gated suite, with the command in the file header, such as `ACP_EVAL=1 swift test --filter PythonCLIEvaluation`
- [ ] `Tests/FoundationModelsACPAgentTests/Evaluations/EvaluatorHonestyTests.swift` — ungated, the lying-transcript case above
- [ ] Ungated `swift test` → green

## Workflow
- Use `/tdd` where it applies. The subject and evaluator units are testable ungated with a scripted backend.