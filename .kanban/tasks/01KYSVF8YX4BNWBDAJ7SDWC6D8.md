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
Plan.md §20.3, tier 4. Gated on Apple silicon + real models + network (env-var gate alongside the family's existing gating convention). Create `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIEvaluation.swift` on Apple's Evaluations framework (swift-testing native):

1. **Subject** — `subject(from sample:)`: fresh temp workspace as the session cwd and confinement root; recording to a temp location; the composed agent with real `files`+`shell` and the coding instructions; run to completion; return workspace path + transcript + run stats.
2. **Dataset** — an `ArrayLoader` of 20–30 hand-written `ModelSample` variants of "build a small Python CLI" (pyproject.toml, a third-party package like `click`, the CLI, pytest tests, project-local venv, pytest green, then run it); `expected` carries the fixed input/output pair.
3. **Evaluators — mechanical, verified outside the agent** (never trust the transcript's claims): `PytestGreen` (re-run pytest in the venv, exit 0), `CLIRuns` (run the CLI against `expected`, check output), `FilesPresent`, `ToolTraffic` (transcript contains files and shell calls).
4. **Aggregation** — `MetricsAggregator.computeMean` per metric; the `@Test` asserts mean pass rates against thresholds; turn/tool-call/token stats ride along keyed by the resolved model from `manifest.json`.
5. **Isolation** — venv inside the workspace; no system-Python change; no network beyond package install; delete the workspace after grading, keep transcripts of failed runs.

- [ ] Subject wiring
- [ ] 20–30 sample dataset
- [ ] Four mechanical evaluators
- [ ] Aggregation + thresholds
- [ ] Isolation + cleanup

## Acceptance Criteria
- [ ] Gated run executes at least one sample end to end on Apple silicon and produces per-metric means
- [ ] Ungated evaluator-honesty test: `PytestGreen` and `CLIRuns`, fed a fabricated transcript that claims success over a deliberately failing workspace, both grade FAIL (proving they grade from the filesystem/exit codes, not transcript text)
- [ ] Ungated `swift test` skips the gated suite and stays green

## Tests
- [ ] The gated suite; command documented in the file header (e.g. `ACP_EVAL=1 swift test --filter PythonCLIEvaluation`)
- [ ] `Tests/FoundationModelsACPAgentTests/Evaluations/EvaluatorHonestyTests.swift` — ungated, the lying-transcript case above
- [ ] Ungated `swift test` → green

## Workflow
- Use `/tdd` where applicable (subject/evaluator units are testable ungated with a scripted backend).