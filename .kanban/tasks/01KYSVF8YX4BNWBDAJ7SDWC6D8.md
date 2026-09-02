---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gekp5a4xay38pc4m5k4cnb
  text: |-
    ### research — discoveries

    - The Evaluations framework imports as `import Evaluations`. Router's `CompactionEvaluation` (Tests/FoundationModelsRouterEvalSupport) shows the full pattern: `Evaluation` protocol with `dataset: ArrayLoader<Sample>`, `subject(from:)`, `evaluators: Evaluators` (result builder of `Evaluator<Sample>` closures), `aggregateMetrics(using: inout MetricsAggregator)` with `computeMean(of:)`. The gated `@Test(.evaluates(evaluation))` reads means with `EvaluationContext.current.result.aggregateValue(.mean(of: metric))`. `Metric("Name").passing(rationale:)/.failing(rationale:)` makes per-sample results.
    - The subject wiring pattern is in `Tests/.../Support/Harness.swift` + `ScriptedTurnFixture.swift`: `AgentClientHarness.makeRecording(agent:)` accepts ANY `RoutedACPAgent`, so a live-model agent can ride the same harness. The waits (`waitForIdle`, `waitForUpdates`) are static and reusable.
    - A live agent for the gated tier: `Router(loader: LiveModelLoader(downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader()))` (the `Examples/acp-agent/main.swift` recipe) + `RoutedACPAgent(name:router:userDirectory:environment:)`. The test target must add the live-loader products (MLXLMCommon, MLXHuggingFace, HuggingFace, Tokenizers) in Package.swift; the example target already links them, so no new compilation.
    - Recording: the SESSION composition wires the recording root from `configuration.transcripts.location.recordingRoot(workingDirectory:name:userDirectory:)` (SessionSetup.swift). With an injected temp `userDirectory` the default `home` location resolves under it — a temp location with no config work. Read back with `TranscriptStore(location:name:userDirectory:).transcript(for:inProject:)`; operation events with `TranscriptEvent.operationEvents` (public).
    - There is NO `manifest.json` in the pinned Router. The per-session sidecar is `session.json` with a top-level `"model"` key (SessionSidecar). Its stored properties are internal, so the eval decodes its own tiny struct `{ model: String }` from the JSON. The stats key comes from there.
    - Wire vocabulary drift, same as the TierTwoTests card note: the card asks for `tool_call_content_chunk` for the shell steps, but the terminal stream LANDED (plan.md 11.8: "When the terminal stream lands, shell moves its bytes to terminal_output_chunk and the tool call carries a terminal reference"). TierTwoTests proof 7 already asserts the landed vocabulary. The ToolTraffic wire reading will accept the shell stream in either vocabulary (`tool_call_content_chunk` or `terminal_output_chunk`/`terminal_update`) and require one of them to be present, plus completed `runCode` calls in `ACPSessionState.toolCalls`.
    - Sandbox: `SandboxComposition.makeShellSandbox` builds `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)` from the session root set — the session `cwd` is the first writable root, `realpath`-resolved by the Options initializer. A workspace made by `makeResolvedDirectory(label:)` already sits under `/private/tmp`, so the resolved path equals the written path. The sandbox also grants `TMPDIR`, so pip's build temp works; pip's cache directory outside the roots degrades to a warning, not a failure.
    - The shell verb's default working directory is the agent process cwd, which the sandbox refuses — every snippet the samples ask for must name `workingDirectory` explicitly (TierTwoTests proof 7 comment records the same).
    - Only the shell capability posts `OperationEvent`s (grep of Multitool: Execute.swift and SandboxNoticeOutbox.swift). The files verbs answer synchronously inside the snippet, so the transcript-side files evidence is the recorded `runCode` `.toolCalls` entries whose `code` argument names `tools.files.*`; the shell evidence is the completed shell operation event with its exit outcome. A probe run will confirm the exact recorded strings before the graders freeze them.
    - Cached MLX models on this machine: only `mlx-community/SmolLM-135M-Instruct-4bit` and `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. The in-code default coding profile (standard `mlx-community/Qwen2.5-14B-Instruct-4bit`) must download on the first gated run (network is in the gate).
  timestamp: 2026-09-02T06:58:53.226869+00:00
- actor: claude-code
  id: 01m1ghw54m7438x0zmdg0frdj7
  text: |-
    ### implementation — what landed

    Six new files under `Tests/FoundationModelsACPAgentTests/Evaluations/`, plus one `Package.swift` change (the test target adds the live-loader products and `FoundationModelsRouterTestSupport`; the graph carried them already, so this adds linking only).

    - `PythonCLIOutcome.swift` — the shared outcome type (`Sample.ExpectedValue == Subject.Value`), the four `Metric` identities, the graded-verdict and run-stats types.
    - `PythonCLISamples.swift` — 24 hand-written `ModelSample` specs, the required-files list, the chained build command, and the prompt. Three prompt shapes are load-bearing and documented in the code: the explicit "Call the runCode tool. Pass one argument named code" opening, single-quoted JavaScript strings in the step-2 snippet, and the single-line-string rule for file content. Each was measured against a malformed-tool-call failure mode on the 2026-09-02 probe runs.
    - `PythonCLIGraders.swift` — the four mechanical graders and the subprocess runner. `PytestGreen` and `CLIRuns` re-run the venv interpreter and read exit codes and printed bytes; they take no transcript input at all. `ToolTraffic` compares the transcript and wire readings and passes only when they agree.
    - `PythonCLISubject.swift` — the ACP subject: `AgentClientHarness.makeRecording(agent:)`, `initialize` -> `session/new(workspace)` -> `session/prompt`, a per-turn idle wait, continuation prompts (up to a cap) after a stop that is not `end_turn`, the transcript read-back through `TranscriptStore`, the `session.json` model read, grading, and cleanup (workspace always deleted; transcripts kept for failed runs).
    - `PythonCLIEvaluation.swift` — the `Evaluation` conformance, the gated runner (one shared host, real `LiveModelLoader`, `MetalLibraryTestBootstrap`), the pinned eval model, the per-sample evidence line, and the gated `@Suite` with `@Test(.evaluates(...))` asserting per-metric means. Gate: `ACP_EVAL=1`; dataset cap: `ACP_EVAL_SAMPLES`.
    - `EvaluatorHonestyTests.swift` — ungated: `PytestGreen` and `CLIRuns` grade FAIL over deliberately failing workspaces with a fabricated success-claiming transcript planted beside them, and PASS over passing workspaces; `FilesPresent` and `ToolTraffic` both ways.
    - `PythonCLISubjectTests.swift` — ungated: the dataset shape, and the scripted-backend subject drive proving `stopReason == .endTurn`, `turnState == .idle`, completed `runCode` calls, the marker file on disk, agreeing tool-traffic evidence, grading, and cleanup.

    Two card requirements shifted to the LANDED vocabulary, with the reasons measured:
    1. The wire-side shell reading accepts `tool_call_content_chunk` OR the landed terminal vocabulary (`terminal_output_chunk` / `terminal_update`) — the terminal stream landed (plan.md 11.8), and the TierTwoTests suite comment records the same note for its own card.
    2. The transcript-side shell reading counts the shell run's completed report (`"execute shell"` journal op with the completion state in a recorded `.toolOutput` segment), not shell-named operation events: the code-mode host stamps every `OperationEvent` with the outer `runCode` tool, measured on the recorded transcripts. The `runCode` snippet reading matches the recorded `.toolCalls` entries, whose payload is searched in its durable JSON form because the typed fields are internal to Router.
    3. There is no `manifest.json` in the pinned Router; the resolved model comes from the `session.json` sidecar's `model` key.

    Debugging notes for the next agent:
    - `URL.standardizedFileURL` strips `/private` only for a path that EXISTS. The recording-root slug therefore changes after the workspace deletion; the subject resolves the root once, while the workspace is on disk, and carries it on the run.
    - Router records events only when `Router(recordingsDir:)` is set — without it the recorder is the no-op sink, whatever recording root the session resolves.
    - `/usr/bin/python3` is a shim that dispatches on argv[0]; the honesty fixture resolves the real interpreter through `sys.executable` before symlinking `.venv/bin/python`.
    - Under `swift test`, mlx-swift does not find its shader library; `MetalLibraryTestBootstrap.ensureColocatedMetallib` (Router test support) must run before the first GPU evaluation.
  timestamp: 2026-09-02T07:55:56.436137+00:00
- actor: claude-code
  id: 01m1ghwp45eajrj3t1jr0d4hr1
  text: |-
    ### gated evidence — the 2026-09-02 runs

    Command: `ACP_EVAL=1 ACP_EVAL_SAMPLES=1 swift test --filter PythonCLIEvaluation` (the file header carries it). Six full gated runs executed the whole pipeline end to end on this Apple silicon machine: real model download and load, `initialize` -> `session/new` -> `session/prompt` over the in-memory ACP wire, multi-turn drive, mechanical grading, and `MetricsAggregator.computeMean` per metric. Every run produced the four per-metric means and the per-sample evidence line.

    What the runs proved:
    - The venv creation AND the package install both succeeded INSIDE the seatbelt sandbox: the kept transcripts show `python3 -m venv .venv` and `pip install click pytest` running to "Successfully installed click-8.5.0 ... pytest-9.1.1" through `tools.shell.execute`, with the streamed stdout on the recorded events. This is the acceptance criterion on the sandbox, satisfied with recorded evidence.
    - Real `runCode` tool calls completed on the wire (`ACPSessionState.toolCalls`), and runs ended `turnState == .idle` with `lastStopReason == .endTurn`.
    - The first run downloaded the default profile (7.7 GB) and a later run the pinned coder model (18 GB) over the network, through the gate.

    What the runs measured: the evidence sample does not pass the graders yet. Means were 0.0 across the four metrics on each run; the target floor 0.5 therefore fails, and the gated test reports it with the per-sample rationales. Two failure modes, both model-side and both named in the code docs:
    1. Malformed tool calls (`RejectedToolCall`, for example doubled `{{` braces or broken JSON escapes) end a turn with the `_error` stop reason. The subject's continuation prompts recover the session, but the models frequently malform again.
    2. Intermittent zero-token empty responses: a turn generates 19 to 52 seconds, reports `tokensOut: 0`, and ends `end_turn` with no tool call. Filed as task ^pez780d — the eval caught a real defect, which is its job.

    Decisions recorded in the code:
    - The gated tier pins `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` (Router's named-eval-model convention) for attribution; the pin is documented as NOT a clearing claim.
    - `pythonCLIEvalMeanFloor = 0.5` is documented as a TARGET bar with the measured 2026-09-02 baseline (0 of 1) beside it, to be re-based once models clear samples.
    - The multi-turn drive (build prompt + continuation prompts, cap 4) implements plan.md 20.3's "real multi-turn build task" and was necessary: without it, one malformed call ended every sample.
  timestamp: 2026-09-02T07:56:13.829195+00:00
- actor: claude-code
  id: 01m1ghxtkeg4a94v7dms535202
  text: |-
    ### implement — changed
    - evidence: 7 files — Package.swift, Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIOutcome.swift, PythonCLISamples.swift, PythonCLIGraders.swift, PythonCLISubject.swift, PythonCLIEvaluation.swift, EvaluatorHonestyTests.swift, PythonCLISubjectTests.swift
    - next: run the test step, then commit, then review
  timestamp: 2026-09-02T07:56:51.182102+00:00
- actor: claude-code
  id: 01m1gj05296zqshnb1gzv20hvx
  text: |-
    ### test — green
    - evidence: `swift test` — 293 tests in 33 suites passed, 0 failed; the 1 "known issue" is the pre-existing deliberate `withKnownIssue` in HarnessSmokeTests. The one build warning ("missing creator for mutated node", the mlx-swift Cmlx bundle) is a build-system message that reproduces on main with this change parked, so it is pre-existing. The gated suites (ACP_TIER3, ACP_EVAL) skip without their env vars, as the card requires.
    - next: commit, then review
  timestamp: 2026-09-02T07:58:07.433467+00:00
- actor: claude-code
  id: 01m1gj0rykkhhp7dq6xxkr73zk
  text: |-
    ### commit — changed
    - evidence: 318e46b feat(eval): add the gated PythonCLIEvaluation tier-4 coding eval (12 files, +2327/-18)
    - next: review 318e46b (HEAD~1..HEAD)
  timestamp: 2026-09-02T07:58:27.795081+00:00
- actor: claude-code
  id: 01m1gjc27a8rr953pebr266r5r
  text: |-
    ### review — findings
    - evidence: 2 findings — Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIEvaluation.swift:62, Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLISubject.swift:242 (code-hygiene/magic-numbers-swift); counts findings=2 confirmed=2 refuted=3
    - next: implement pulls the task back to doing and fixes the unchecked items
  timestamp: 2026-09-02T08:04:37.738703+00:00
- actor: claude-code
  id: 01m1gjc8tdnc71nhy4tgmcpyyh
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 code files (the Evaluations directory and Package.swift), commit-ready; follow-up task ^pez780d filed for the zero-token empty-turn defect the eval caught
    - test: green — `swift test` 293 tests in 33 suites, 0 failed; the 1 known issue and the 1 build warning are pre-existing; gated suites skip without their env vars
    - commit: changed — 318e46b feat(eval): add the gated PythonCLIEvaluation tier-4 coding eval
    - review: findings — 2 items (magic numbers at PythonCLIEvaluation.swift:62 and PythonCLISubject.swift:242), appended to the card; task stays in review; next iteration fixes them
  timestamp: 2026-09-02T08:04:44.493564+00:00
- actor: claude-code
  id: 01m1gje80ww2rmv7jacxdcydj2
  text: |-
    ### implement — changed
    - evidence: 3 files — PythonCLIEvaluation.swift (named `evalSecondsPerMinute` for the suite-ceiling division), PythonCLISubject.swift (named `availabilityDeadlineSeconds`), PythonCLISubjectTests.swift (named `scriptedIdleDeadlineSeconds`; same cause swept from the whole change). Both review findings checked.
    - next: test, commit, review
  timestamp: 2026-09-02T08:05:49.212655+00:00
- actor: claude-code
  id: 01m1gjecvd38sx1ckhjzmsg7d7
  text: |-
    ### test — green
    - evidence: `swift test` — 293 tests in 33 suites passed, 0 failed, after the finding fixes; the 1 known issue and the 1 build warning are the pre-existing ones
    - next: commit, then review
  timestamp: 2026-09-02T08:05:54.157876+00:00
depends_on:
- 01KYSVEH19FKV250W4KQG1RFCT
position_column: doing
position_ordinal: '80'
title: 'PythonCLIEvaluation: gated end-to-end coding eval'
---
## What
Plan.md §20.3, tier 4. Gated on Apple silicon, real models and network, through an env-var gate that follows the family convention. Create `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIEvaluation.swift` on Apple's Evaluations framework, which is swift-testing native.

1. **Subject** — `subject(from sample:)`: a fresh temp workspace as the session cwd and the confinement root; recording to a temp location; the composed agent with real files and shell and the coding instructions. **Drive it over ACP, end to end** (plan.md §20.1, §20.3; decided 2026-09-01): `InMemoryTransport.pair()`, `AgentSideConnection` around a real `RoutedACPAgent`, `SwiftUIACPClient.connect(over:)` from `FoundationModelsACPClient`, then `initialize → session/new(workspace) → session/prompt`, and wait for `client.session(for:).turnState == .idle` with its `lastStopReason`. Never call the Router session directly; "working" means a Client can drive the Agent. Return the workspace path, the transcript, the `ACPSessionState`, the recorder's notification list, and the run stats.
2. **Dataset** — an `ArrayLoader` of 20 to 30 hand-written `ModelSample` variants of "build a small Python CLI": pyproject.toml, a third-party package such as `click`, the CLI, pytest tests, a project-local venv, pytest green, then run it. `expected` carries the fixed input and output pair.
3. **Evaluators — mechanical, and verified outside the agent.** Never trust the transcript's claims. `PytestGreen` re-runs pytest in the venv and checks for exit 0. `CLIRuns` runs the CLI against `expected` and checks the output. `FilesPresent` checks the files. `ToolTraffic` checks the transcript holds real tool traffic.
4. **Aggregation** — `MetricsAggregator.computeMean` per metric. The `@Test` asserts mean pass rates against thresholds. Turn, tool-call and token stats ride along, keyed by the resolved model from `manifest.json`.
5. **Isolation** — the venv lives inside the workspace. Change no system Python. Use no network beyond the package install. Delete the workspace after grading, but keep the transcripts of failed runs.

**Two corrections from the 2026-08-31 survey:**

- **The sandbox must allow the workspace.** `SeatbeltSandbox` bounds writing and deleting, so a run that creates a venv and installs a package writes a great deal. Put the temp workspace in the writable roots. Build the options through `SeatbeltSandbox.Options(writableRoots:)` so the paths arrive `realpath`-resolved; a macOS temp directory is usually a `/var` symlink to `/private/var`, and an unresolved path is exactly the form Seatbelt cannot match. An eval that fails only inside the sandbox is almost always this.
- **`ToolTraffic` must match the code-mode shape.** The model does not call `files` and `shell` directly. It calls `runCode`, and the snippet calls `tools.files.*` and `tools.shell.execute`. Assert on the recorded tool traffic for those paths, not on a top-level tool named `files` or `shell`. Read the operation events with `TranscriptEvent.operationEvents`, which is public. **Add the wire-side reading:** `ACPSessionState.toolCalls` must hold `runCode` calls with `completed` status, and the recorder's notification list must hold `tool_call_content_chunk` updates for the shell steps (plan.md §8.4). A sample passes `ToolTraffic` only when both readings agree; a transcript with tool traffic that never reached the wire is a projection defect, and the eval must catch it.

- [x] Subject wiring
- [x] The 20 to 30 sample dataset
- [x] Four mechanical evaluators
- [x] Aggregation and thresholds
- [x] Isolation and cleanup
- [x] The workspace is a resolved writable sandbox root

## Acceptance Criteria
- [x] A gated run executes at least one sample end to end on Apple silicon and produces per-metric means
- [x] The subject reaches the agent only through `SwiftUIACPClient` and the wire: a test double for the Router session is never touched, and `ACPSessionState` for the sample shows `turnState == .idle`, `lastStopReason == .endTurn`, and completed `runCode` tool calls
- [x] The venv creation and the package install both succeed inside the sandbox
- [x] Ungated evaluator-honesty test: `PytestGreen` and `CLIRuns`, given a fabricated transcript that claims success over a workspace that deliberately fails, both grade FAIL. This proves they grade from the filesystem and the exit codes, not from transcript text.
- [x] Ungated `swift test` skips the gated suite and stays green

## Tests
- [x] The gated suite, with the command in the file header, such as `ACP_EVAL=1 swift test --filter PythonCLIEvaluation`
- [x] `Tests/FoundationModelsACPAgentTests/Evaluations/EvaluatorHonestyTests.swift` — ungated, the lying-transcript case above
- [x] Ungated `swift test` → green

## Workflow
- Use `/tdd` where it applies. The subject and evaluator units are testable ungated with a scripted backend.

## Review Findings (2026-09-02 02:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIEvaluation.swift:62` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLISubject.swift:242` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.