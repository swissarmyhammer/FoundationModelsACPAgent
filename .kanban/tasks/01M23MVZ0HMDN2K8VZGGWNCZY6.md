---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m23nnv9rteg334vnx1gsp35k
  text: |
    ### finish — stuck, a person must decide

    This card says "Pick one way and write down why". Each of the three ways
    needs a decision that is not mine to make.

    - **Way 1, two runs in one job.** It needs a new input in the shared
      workflow `swissarmyhammer/workflows`. That is a family sibling package.
      A change there needs its own card on that board, and a decision first.
    - **Way 2, hold the tier-4 evaluation out of CI.** I can make this change
      here in one line. But it changes what CI measures: after it, no CI run
      ever gives a verdict on the quality of the model answers. That is a
      policy decision about the value of the signal, and the owner makes it.
    - **Way 3, raise the model quality until the floor holds.** To know if the
      floor is reachable I must run the tier-4 evaluation. That loads three
      MLX models, it needs about one hour, and it takes the whole GPU. A
      SWE-bench run was using this machine today, and the two competed. I did
      not run it.

    So the card stays in `review` with this comment, and it is not forced to
    `done`.

    **What I recommend, if you want one.** Way 2 now, and Way 1 later. Way 2
    gives the tier-3 contract a verdict of its own today, which is the fault
    this card names. Way 1 gives both tiers a verdict, which is better, but it
    waits on a sibling change. Way 3 answers a different question — is the
    model good enough — and it should not gate the contract.

    **What I need from you:** the way, and whether a change on the
    `swissarmyhammer/workflows` board is wanted.
  timestamp: 2026-09-09T18:07:58.264402+00:00
- actor: claude-code
  id: 01m276avr4rsbxv5fgbjtgfgqf
  text: |
    ### Research — the tier-4 evidence run started

    This pass does not pick a way. It collects the one measurement that can
    answer Way 3: does the tier-4 quality floor hold on the build of today?

    **What the suite measures.** `PythonCLIEvaluationTests` drives the whole
    24-sample `PythonCLIDataset` over ACP with the real models. It aggregates
    a mean pass rate for four metrics — `pytestGreen`, `cliRuns`,
    `filesPresent`, `toolTraffic` — and it asserts each mean against
    `pythonCLIEvalMeanFloor`, which is 0.5. The floor is a target bar, not a
    measured baseline; no whole-dataset run stands behind it yet. The pinned
    model is `mlx-community/Qwen3.8-27B-mxfp4`, the shipped standard default.
    Each sample gets at most 4 turns and a 3600 s idle ceiling, so a full
    drive can take many hours.

    **A pin fault found first.** `IntegrationTests/Package.resolved` lagged
    the root `Package.resolved`, so a run of the integration package would
    have measured older family packages, not the build the card asks about.
    This is the same class of fault card ^bah727b names. The pins are now
    equal to the root for every family package:

    - FoundationModelsRanker 2f0bd16
    - FoundationModelsMultitool d9edb5e
    - FoundationModelsMetadataRegistry 9a8f6c4
    - FoundationModelsExtras 55d6b04
    - mlx-swift-lm 1988c3f
    - FoundationModelsRouter d469aa0

    **One pin stays ahead of the root, and it must.**
    FoundationModelsACPClient stays at `144b168`, its branch head, not the
    root pin `3f30444`. The root pin has no `acp-client` product, and the
    integration target links that product, so the root pin makes the resolve
    fail with:

        product 'acp-client' required by package 'integrationtests' target
        'FoundationModelsACPAgentIntegrationTests' not found in package
        'FoundationModelsACPClient'

    The root package does not link that product, so the root pin can lag
    there with no effect on the root build.

    Command under way:

        swift test --package-path IntegrationTests --filter PythonCLIEvaluationTests
  timestamp: 2026-09-11T02:56:47.364286+00:00
- actor: claude-code
  id: 01m27jm15ngghsrgbtc5yfqwg6
  text: |
    ### The tier-4 measurement — the floor holds on this machine

    Command:

        swift test --package-path IntegrationTests --filter PythonCLIEvaluationTests

    The suite drove all 24 samples of `PythonCLIDataset` and PASSED in
    12414 s (3 h 27 m).

    | Metric | Passed | Mean | Floor | Assertion |
    |---|---|---|---|---|
    | `pytestGreen` | 22 of 24 | 0.9167 | 0.5 | passes |
    | `cliRuns` | 23 of 24 | 0.9583 | 0.5 | passes |
    | `filesPresent` | 23 of 24 | 0.9583 | 0.5 | passes |
    | `toolTraffic` | 23 of 24 | 0.9583 | 0.5 | passes |

    Every mean is above the floor of 0.5. The assertion near the end of
    `PythonCLIEvaluation.swift` passes for all four metrics.

    **The two samples that did not pass.**

    - `celsius` — `pytestGreen` only. The CLI and the files are correct, but
      one test of the four failed: `test_negative_40_celsius_is_40_fahrenheit`
      got exit code 2. The other three graders passed.
    - `join` — all four. The turn ended with `endTurn` after 398 s and 0 tool
      calls and only 10683 tokens. The model wrote no file and made no tool
      call. The transcript of this failure is kept at
      `/private/tmp/PythonCLIEval-user-E345DFC0-AA11-449F-B0BB-3A959C129C0F/transcripts/-tmp-PythonCLIEval-join-092BDCE7-967F-4535-8C1C-8E168312EB02`.

    **The build the numbers came from.** The model is
    `mlx-community/Qwen3.8-27B-mxfp4`, the shipped standard default. The
    package revisions:

    - FoundationModelsRanker 2f0bd16
    - FoundationModelsMultitool d9edb5e
    - FoundationModelsMetadataRegistry 9a8f6c4
    - mlx-swift-lm 1988c3f
    - FoundationModelsRouter d469aa0
    - FoundationModelsExtras 55d6b04
    - FoundationModelsACPClient 144b168

    **A correction to the comment above.** Both `Package.resolved` files are
    in `.gitignore` and no repository tracks them. The lag I aligned was a
    lag in this workspace only, not in the repository. CI resolves the
    packages again on each run, so CI always gets the branch heads. The
    finding stays true for a local run: a local `Package.resolved` can hold
    an old revision and make a local run measure a build that is not the
    build of today.

    **One pin is an exception.** The integration target links the
    `acp-client` product. The root pin `3f30444` of FoundationModelsACPClient
    has no such product, and the resolve fails with it. The head `144b168`
    has the product. This matters only to a person who aligns the local
    revisions by hand.
  timestamp: 2026-09-11T06:31:30.741818+00:00
- actor: claude-code
  id: 01m27jmq5pqp7wbdvxmm48cc0h
  text: |
    ### The judgement — Way 3 holds locally, but it does not make CI green

    **Way 3 holds on the evidence, for a machine that has the models.** The
    card said "the floor may already be reachable". It is reachable. All four
    means are 0.92 or better against a floor of 0.5. The margin is large, not
    marginal, so a normal run-to-run change cannot make the floor fail.

    **But one number in the card's own defect report contradicts Way 3 as a
    cure for CI.** The CI log says:

        Suite PythonCLIEvaluationTests FAILED after 12.875 seconds with 4 issues

    This run of the same suite took 12414 seconds. A drive of 24 live samples
    cannot finish in 12.9 seconds. So the CI job never drove a sample. Every
    metric mean was 0 because the subject work failed immediately, not
    because the answers were bad. The CI redness is therefore not a quality
    failure. Raising model quality cannot correct it, because CI never
    measures the quality.

    I did not read the CI log myself, so the cause of the fast failure is not
    proved. The most probable cause is the environment: a GitHub runner has
    no Apple silicon GPU and no 27 B model, and the model load fails at once.
    A person must read one CI log of that job to name the cause.

    **The three "Done when" boxes.** I check none of them.

    1. *The tier-3 suites report a verdict that a tier-4 score cannot make
       red.* NOT satisfied. Nothing in this pass separates the two verdicts.
       One `swift test` run still carries both tiers and gives one exit code.
    2. *`.github/workflows/ci.yml` states the chosen way in its header, and
       `CIWorkflowTests` pins whatever new input the way needs.* NOT
       satisfied. I made no change to the workflow, as instructed.
    3. *One CI run on `main` is green, or the red mark names only the tier-4
       quality floor and the card says that is accepted.* NOT satisfied. This
       was a local run, not a CI run. The 12.9-second CI failure says a CI
       run will stay red even with the floor reachable.

    **What the numbers mean for each of the three ways.**

    - **Way 1, two runs in one job.** Unchanged, and still the best answer for
      the contract. The evidence adds nothing for or against it. It still
      needs a card and a decision on the `swissarmyhammer/workflows` board.
    - **Way 2, hold the tier-4 evaluation out of CI.** The evidence makes
      this stronger, not weaker. A CI job that cannot drive the models gives
      no verdict on quality at all, so holding the suite out of CI gives up
      nothing that CI really measures. The quality verdict comes from a run
      on a machine with the GPU, as this run was.
    - **Way 3, raise the model quality.** Done, as far as the floor goes, and
      no more work is needed on quality for this card. But it does not close
      the card, because the CI job fails before any sample runs.

    **So the decision still belongs to the owner.** The card stays stuck. The
    one thing the evidence removes is Way 3 from the list of ways that can
    make CI green.

    ### implement — stuck

    - evidence: `swift test --package-path IntegrationTests --filter
      PythonCLIEvaluationTests` passed in 12414 s over 24 samples.
      `pytestGreen` 0.9167, `cliRuns` 0.9583, `filesPresent` 0.9583,
      `toolTraffic` 0.9583, all above the floor 0.5. No tracked file changed;
      both `Package.resolved` files are in `.gitignore`.
    - next: a person picks Way 1 or Way 2. Way 3 is answered and it is not
      enough. A person should also read one CI log of the integration job to
      name the cause of the 12.9-second failure.
  timestamp: 2026-09-11T06:31:53.270807+00:00
- actor: claude-code
  id: 01m27jnq61kzscdhp7w76zk0cp
  text: |
    ### finish iteration 1 — stuck

    - implement: stuck — the tier-4 evidence run is complete, but no tracked file changed
    - test: not run — the implement step stopped at the decision
    - commit: not run — there is nothing to commit
    - review: not run
    - evidence: `swift test --package-path IntegrationTests --filter PythonCLIEvaluationTests` passed in 12414 s over 24 samples. `pytestGreen` 0.9167, `cliRuns` 0.9583, `filesPresent` 0.9583, `toolTraffic` 0.9583, all above the floor 0.5.
    - next: a person picks Way 1 or Way 2. Way 3 is answered: the quality floor is reachable, but the CI job fails in 12.9 s before it drives a sample, so more model quality cannot make CI green.
  timestamp: 2026-09-11T06:32:26.049720+00:00
- actor: claude-code
  id: 01m28xtw9sq3h08dasgj7eg2jv
  text: |
    ### The decision — a fourth way: three test levels, one package each

    The owner did not pick Way 1, Way 2 or Way 3. The owner named a better
    way, and this card records it.

    **The three ways all kept two verdicts in one job.** Way 1 put two runs
    in one job. Way 2 held the evaluation out with a filter. Way 3 kept one
    run and raised the quality. Each of them argued about the selector. The
    fault is not the selector. The fault is that an evaluation is not a kind
    of integration test, so it must not sit behind the integration exit code.

    **What is done.** Commit `5fa5a2f`. Three test levels, one SwiftPM
    package each, so the boundary is structural and no environment variable
    selects a test.

    | Level | Package | Runs | Time |
    |---|---|---|---|
    | Unit | the root package | CI, every commit | 561 tests, 3.7 s |
    | Integration | `IntegrationTests` | CI, every commit | 17 tests, 86 s |
    | Evaluation | `EvaluationTests` | on demand only | 24 samples, about 3.5 h |

    - The seven evaluation files moved to a new `EvaluationTests` package.
    - `.github/workflows/evaluation.yml` drives that package on
      `workflow_dispatch` alone. It takes an optional filter, it holds one
      run at a time, and its ceiling is 600 minutes.
    - `ci.yml` names neither the package nor the workflow.
    - `IntegrationTests` lost the model stack it no longer uses: mlx-swift-lm,
      swift-huggingface, swift-transformers, and Router with its test
      support. No suite that stays behind references any of them.
    - The package name is `EvaluationTests`, not `Evaluations`, because
      Apple's evaluation framework already gives a module that name and the
      sources import it.
    - `plan.md` §20.1 is rewritten. The five tiers are gone. Tiers 0, 1 and 2
      differed only in how much was faked, which is a note about one test and
      not a category. The numbering also made tiers 3 and 4 look one rung
      apart, and that is what put them in one package under one exit code.

    **Two new cases in `CIWorkflowTests` hold the split from both sides.**
    One fails if `evaluation.yml` grows a push or a pull-request trigger, or
    stops driving its own package. The other fails if `ci.yml` names the
    evaluation package or its workflow outside a comment.

    ### A correction to the record above

    The comment of 2026-09-11 06:31 says the CI job "never drove a sample"
    and that the cause was probably the environment. Both statements are
    wrong, and the cause is simpler.

    `origin/main` was 43 commits behind the local branch. CI measured
    week-old code for a week. The run that failed in 12.875 seconds was on
    commit `c92e1fc`, and at that commit the evaluation pinned
    `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, the stale model this
    package does not ship. The mean of -1.0 in that log is the sentinel for
    "no value recorded", not a score of zero: 12.875 s over 24 samples is
    about 0.54 s each, so every sample threw before it could be graded.

    The runner is also not the problem. The log shows
    `/Users/service/actions-runner/`, which is the self-hosted macOS pool,
    not a GitHub-hosted machine with no graphics processor.

    The evaluation framework swallows the per-sample error and the job
    uploads no artifact, so the error text never reaches the log. That gap is
    worth its own card: it turned a five-minute diagnosis into a card that
    sat stuck for two days.
  timestamp: 2026-09-11T19:06:43.897931+00:00
position_column: done
position_ordinal: d280
title: The CI integration job is red on every run, so a tier-3 failure has nowhere to show
---
## The defect

Every CI run since 2026-09-03 failed. The newest one on `origin/main`,
run `34226397374` at commit `c92e1fc`, shows the shape:

```
ci / Build & test                            passed in 4m19s
ci / Integration (opt-in, real dependencies) FAILED in 4m16s
  Run the selected integration tests
    Suite CLIProcessTests passed after 1.400 seconds
    Suite StdioContractTests passed after 5.323 seconds
    Suite PythonCLIEvaluationTests FAILED after 12.875 seconds with 4 issues
      PythonCLIEvaluation.swift:336:13:
        Expectation failed: mean >= pythonCLIEvalMeanFloor   (x4)
    Test run with 33 tests in 10 suites failed
```

The unit job is green. The integration suites in the integration job are
green. The evaluation is the only failure, and it fails on the quality
floor of the model answers, not on a contract.

One `swift test --package-path IntegrationTests` run carried both, so one
score below the floor made the whole job red. The job then stayed red for
every later run, and a person who looked at the red mark learned nothing
new from it. A contract regression that landed next landed inside a job
that already failed, so nobody saw it. Card ^bah727b shows what that
cost: two faults sat in the integration package and no red mark named
them.

## The answer

Three test levels, one SwiftPM package each. The boundary is structural,
and no environment variable selects a test.

| Level | Package | Runs | Time |
|---|---|---|---|
| Unit | the root package | CI, every commit | 561 tests, 3.7 s |
| Integration | `IntegrationTests` | CI, every commit | 17 tests, 86 s |
| Evaluation | `EvaluationTests` | on demand only | 24 samples, about 3.5 h |

The first two levels assert. They are fast, they are deterministic, and a
red mark is a defect, so CI runs them on every commit. The third scores a
real model over hours, and a mean below the floor can be a model question
rather than a code defect, so a person asks for it.

The card offered three ways, and each kept the two verdicts in one job.
The owner named a fourth way, which is the one above: an evaluation is
not a kind of integration test, so it does not sit behind the integration
exit code. See the comments for the work and for a correction to the
first diagnosis.

## Done when

- [x] The integration suites report a verdict that an evaluation score
      cannot make red.
- [x] `.github/workflows/ci.yml` states the chosen way in its header, and
      `CIWorkflowTests` pins it from both sides.
- [x] One CI run on `main` is green.
