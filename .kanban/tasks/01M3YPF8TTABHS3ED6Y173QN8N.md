---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ypkvkxa20w1bja7m6ast93
  text: |-
    Research: the cause is in this repo, in the integration tests. Router is correct.

    Evidence:
    - Router computes the budget as `hostBudget() - admission.footprint.totalBytes` (Router.runAdmission). The pool is `ModelPool.shared`, one pool for the process. Each Router in the process shares it.
    - In the failed resolve the embedding is "0 bytes" and flash/standard are charged only their session KV (147456 / 65536 bytes at one token). Router charges that marginal cost only for a model that is RESIDENT in the pool. Thus the trio of an earlier resolve is still resident when ToolCallingTests resolves.
    - SkillTriggerTests runs just before ToolCallingTests in the same process (`swift test --package-path IntegrationTests --no-parallel`, alphabetical). Its agent lives in the global `skillTriggerHost`, which nothing releases. `RoutedACPAgent.residentProfile` keeps the holds of the three models for the life of the agent.
    - On the CI machine the native window (262144 tokens) does not fit, so JointFit sized the SkillTrigger window to the budget (the log shows `context.tokens=42199`). That left 176359 bytes. The second resolve needs a new session KV for standard and flash (212992 bytes at one token), so the trio is blocked. "unsized" is only the label for a candidate with no window that fits.
    - The budget is 176359 bytes in each red run since 394a277 (36593420743, 36878035587, 37029703913): deterministic. The red run of 2026-09-28 (36481357717) was a different cause, a compile error in ToolCatalog.swift, which is fixed.
    - This 512 GB machine fits the native window with space left, so the leak does not fail here by the budget. A test must look at the pool, not at the budget.

    Plan: SkillTriggerTests makes its subject in the test and releases it at the end (close the harness, drop the agent). A shared support check waits for `ModelPool.shared` to have no resident model after a live-model test releases its agent, and both live-model suites assert it. That assertion fails on every machine when a suite keeps its models.
  timestamp: 2026-10-02T16:19:33.117476+00:00
- actor: claude-code
  id: 01m3ywzn9dpcaf9w03rke5mb8q
  text: |-
    Implementation findings (the leak had four links, all in this repo):

    1. Test layer: SkillTriggerTests kept its agent in the global `skillTriggerHost`. Now the test makes the subject, closes it, and drops it (`SkillTriggerSubject.make()` / `close()`).
    2. Agent <-> connection cycle: `AgentSideConnection` keeps the agent its factory built; `RoutedACPAgent.bind(connection:)` kept the connection strongly. Now the agent keeps it weakly (`ConnectionReference`). The callers of `AgentSideConnection.init` (AgentComposition.serve, the harness) keep the connection.
    3. Command registry <-> builtin context cycle: the registry keeps the builtins, each builtin keeps `BuiltinCommandContext`, and the binding kept the registry and the session. Now `Binding.registry` is weak.
    4. Response hooks: `FoundationModelsACP` keeps the deferred work of a request in `ResponseHooks`, a task-local. Each `Task {}` that the handler starts inherits it, and the skills watcher that `session/new` starts lives on, so the hook closures live on after they ran. `leaks --traceTree` showed: CommandRegistry <- hook closure <- ResponseHooks <- task <- Skills EventBroadcaster continuation. The `publishAvailableCommands` hook and sink now keep the connection and the registry weakly.

    Dead ends: making the CommandRegistry subscription task `Task.detached` changed nothing (reverted). `leaks --traceTree` output has stale-pointer noise from the test task frame; the weak-reference probes were the reliable signal.

    Local environment note: `IntegrationTests/Package.resolved` (ignored by git) was stale (Router 79d5dac, no `awaitIdle`); `swift package --package-path IntegrationTests update` moved it to the root pins (Router c5ebd44).

    Evidence after the fix: `swift test --package-path IntegrationTests --no-parallel --filter "SkillTriggerTests|ToolCallingTests"` passes in one process (2 tests, 193 s), and the pool is empty after each suite.

    Upstream: the ResponseHooks retention is a FoundationModelsACP defect (runAll never clears the hooks, and child tasks inherit the task-local). Recorded as a separate card.
  timestamp: 2026-10-02T18:10:51.309074+00:00
- actor: claude-code
  id: 01m3yz94kh31xc9gha0k4cpm1y
  text: |-
    ### implement — changed
    - evidence: cause = a leaked agent from SkillTriggerTests kept its three models in the process-wide `ModelPool.shared`; Router subtracts resident bytes from the budget, so ToolCallingTests had 176359 bytes left. Leak links: global test host; agent <-> connection cycle; command registry <-> builtin context cycle; FoundationModelsACP ResponseHooks (task-local inherited by the skills watcher) kept the publish hook closure. Router is correct.
    - files: Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTests/AgentReleaseTests.swift (new), IntegrationTests/.../Support/ProcessModelPool.swift (new), IntegrationTests/.../Support/LiveAgent.swift (new), IntegrationTests/.../SkillTrigger/SkillTriggerTests.swift, IntegrationTests/.../SkillTrigger/SkillTriggerSubject.swift, IntegrationTests/.../ToolCallingTests.swift
    - tests: AgentReleaseTests RED (agent and Router session outlived the closed connection) then GREEN (3/3). SkillTriggerTests pool check RED (3 models resident) then GREEN. `swift build -c release`: no warnings. `swift test`: 710 tests pass (one earlier run crashed with SIGPIPE and two runs failed doctor timing ceilings at load average ~100; 4 later runs green; baseline main 4/4 green at load ~80 — load flakiness). `swift test --package-path IntegrationTests --no-parallel`: 29 tests in 11 suites pass. `--filter ToolCallingTests`: pass (201 s).
    - next: /review; after the commit and push, confirm the CI Integration job is green (card step 3). Upstream card ^w93shct records the FoundationModelsACP ResponseHooks change.
  timestamp: 2026-10-02T18:50:59.057742+00:00
- actor: claude-code
  id: 01m3z0wzrg8z3tmgj1z7xd030k
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (eb1893c); 3 findings, 3 confirmed, 0 refuted — SkillTriggerTests.swift:177, SkillTriggerTests.swift:179, Support/ProcessModelPool.swift:29
    - next: implement the 3 open items in the "Review Findings (2026-10-02 13:51)" section, then review again. Green CI after push is the last step of the card.
  timestamp: 2026-10-02T19:19:18.032838+00:00
- actor: claude-code
  id: 01m3z4xdbv1kq5cz13ta9d5ht8
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (fa650d1). 2 files reviewed, 7 validator runs, 0 findings, 0 failed. The 3 findings of 2026-10-02 13:51 are checked.
    - next: The task is in done. The orchestrator must push and make sure that the CI Integration job is green.
  timestamp: 2026-10-02T20:29:26.267158+00:00
position_column: done
position_ordinal: ff9080
title: 'CI is red: the ToolCallingTests integration gate cannot resolve the "coding" profile on the CI machine'
---
## Problem

The `ci / Integration (opt-in, real dependencies)` job fails on each push to main. The last green CI run is 079c662 (2026-09-23). `ci / Build & test` passes. In the runs of 2026-10-02 (37029703913, 36966015064, 36952052862) the one failing test is:

```
✘ Test "The shipped model writes a file and runs a shell command" recorded an issue at ToolCallingTests.swift:107:6:
Caught error: profile "coding" did not resolve: ResolutionFailure: profile "coding" cannot co-fit a budget of 176359 bytes.
embedding (remaining 176359 bytes, context 1 tokens): chose mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
standard (remaining 176359 bytes, context 1 tokens): no viable candidate
  - mlx-community/Qwen3.8-27B-mxfp4 — unsized: trio blocked by flash
      native window 262144 tokens, no window fits — 65536 bytes at one token: trio blocked by flash
flash (remaining 176359 bytes, context 1 tokens): chose mlx-community/Qwen3-4B-4bit
  - mlx-community/Qwen3-4B-4bit — 147456 bytes: chosen
```

29 tests in 11 suites ran, and only this one failed. The test (IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ToolCallingTests.swift, added in 394a277 on 2026-09-29) builds its Router the same way as SkillTriggerTests (`Router(recordingsDir:loader: LiveModelLoader(), samplingMode: .greedy)`), but its user config sets `profile: standard: [<shipped model>]`, and the 27B model is "unsized" in the budget. The budget of 176359 bytes is not a real memory size.

Earlier red runs (2026-09-23 to 2026-09-29) may have other causes; read one of them to confirm whether this is the only current cause.

## What to do

1. Find the cause: why the budget is 176359 bytes, why the 27B standard model is "unsized" there, and why SkillTriggerTests (same model) resolves and this test does not (for example, the order of the tests, a flash model in the profile, the profile name "coding", or the size data of an absent download).
2. Fix it in the correct place. If the cause is in Router's resolution or memory budget, record it as a Router card with the evidence and, if the CI log is the only evidence, reproduce it locally first. If the cause is in this test's configuration, fix the test.
3. Prove it: run the test locally (`swift test --package-path IntegrationTests --filter ToolCallingTests`), push, and confirm the CI Integration job is green. #tests

## Review Findings (2026-10-02 13:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SkillTrigger/SkillTriggerTests.swift:177` `swift/immutability` — Mutable accumulator `var rates` is filled via `append()` in a loop instead of using a functional approach with `map`/`compactMap`. This requires a reader to trace the entire loop body to understand the final value. Use async map/reduce with structured concurrency, such as `withThrowingTaskGroup`, or restructure to use a functional approach that clearly expresses the transformation intent.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SkillTrigger/SkillTriggerTests.swift:179` `swift/immutability` — Mutable accumulator `var runs` is filled via `append()` in a loop instead of using a functional approach with `map`/`compactMap`. Restructure to use a collection-building approach such as `withThrowingTaskGroup` or similar structured concurrency pattern that expresses the intent functionally.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessModelPool.swift:29` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
