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
position_column: todo
position_ordinal: '80'
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

The unit job is green. The tier-3 suites in the integration job are green.
The tier-4 `PythonCLIEvaluationTests` is the only failure, and it fails on
the quality floor of the model answers, not on a contract.

One `swift test --package-path IntegrationTests` run carries both tiers, so
one tier-4 score below the floor makes the whole job red. The job then
stays red for every later run, and a person who looks at the red mark
learns nothing new from it. A tier-3 regression that lands next lands
inside a job that already fails, so nobody sees it. Card ^bah727b shows
what that costs: two faults sat in the tier-3 package and no red mark named
them.

## What to decide

The two tiers answer different questions and they must not share one
verdict.

- Tier 3 measures a contract. It is fast, it is deterministic, and a
  failure is a defect.
- Tier 4 measures the quality of a real model's answers. It is slow, it
  varies from run to run, and a failure below the floor may be a model
  question, not a code defect.

Pick one way and write down why.

1. **Two runs in one job.** The shared workflow gives
   `integration-filter` and `integration-skip`, and both apply to the
   nested package run. Only one such run happens per job today, so this
   way needs an input the shared workflow does not have yet.
2. **Hold the tier-4 evaluation out of CI**, with
   `integration-skip: PythonCLIEvaluationTests`, and run it by hand or on
   a schedule. CI then measures the contract only.
3. **Raise the model quality until the floor holds**, and keep one run.
   Card ^15sywcv and card ^181jx7j both touched the model quality, so the
   floor may already be reachable.

Way 1 needs a change in `swissarmyhammer/workflows`. That is a family
sibling package, so it needs its own card there and a decision first.

## Done when

- [ ] The tier-3 suites report a verdict that a tier-4 score cannot make
      red.
- [ ] `.github/workflows/ci.yml` states the chosen way in its header, and
      `CIWorkflowTests` pins whatever new input the way needs.
- [ ] One CI run on `main` is green, or the red mark names only the
      tier-4 quality floor and the card says that is accepted.
#stuck