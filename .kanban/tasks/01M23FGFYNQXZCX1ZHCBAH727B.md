---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m23mwjnngyraq7ackqkd093h
  text: |-
    Research for the third box: how CI selects the tier-3 suites.

    What I read:
    - `.github/workflows/ci.yml` in this repository. It has one job, `ci`,
      with no steps of its own. It delegates to
      `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` and it
      gives two inputs: `integration-package-path: IntegrationTests` and
      `integration-no-parallel: true`.
    - The shared workflow itself, at
      `/Users/wballard/github/swissarmyhammer/workflows/.github/workflows/swift-ci.yaml`.

    What the shared workflow does with that one input:
    - The `integration` job starts when `integration-package-path` is not
      empty. It runs on `[self-hosted, macOS]`, not on a hosted runner. The
      32 GB floor of the tier-4 evaluation is thus met, and the job runs the
      whole nested package: `rm -rf IntegrationTests/.build`, then
      `swift build --package-path IntegrationTests --build-tests`, then
      `swift test --package-path IntegrationTests`.
    - The `test` (unit) job also builds the nested package on every run, with
      the same `rm -rf` and `swift build --build-tests`. The header comment of
      `ci.yml` states this, and it is correct.
    - The shared workflow offers `integration-filter` and `integration-skip`,
      which pass `--filter` and `--skip` to that one nested run. This
      repository gives neither, so no suite is held out.

    The mechanism card ^m0jrd7v adopted is thus already in place, and the
    selection it chose is the package boundary itself. No suite reads an
    environment variable.

    Proof that the tier-3 suites really run: GitHub Actions run `34226397374`
    (commit `c92e1fc`, 2026-09-08) reports, inside the integration job,
    `Suite CLIProcessTests passed after 1.400 seconds` and
    `Suite StdioContractTests passed after 5.323 seconds`.

    Why the two faults of this card were invisible, then:
    1. `origin/main` is `c92e1fc`, and local `main` is 35 commits in front of
       it. Commit `8cf7170`, which implemented `doctor` and deleted
       `Sources/acp-agent/NotImplementedError.swift`, is inside that unpushed
       run. At `c92e1fc` the string "is not implemented yet" was still in the
       sources, so the old case
       `aStubSubcommandExitsOneAndSaysSoOnStderr()` passed in CI, correctly.
       CI has never been given the code that breaks it.
    2. The integration job is red on every run since 2026-09-03, on the
       tier-4 `PythonCLIEvaluationTests` quality floor. A job that always
       fails cannot show a new tier-3 failure. I opened card ^gwnczy6 for
       that.

    I did not change `.github/workflows/ci.yml`. The selection it states is
    correct and it already runs the tier-3 suites.

    One hazard I found and did not act on, because the fix is in the family
    sibling `swissarmyhammer/workflows`: the integration job removes
    `.build` and `IntegrationTests/.build`, but it removes no `Package.resolved`.
    Both resolved files are git-ignored, so `actions/checkout` leaves them in
    place on the persistent self-hosted workspace. A branch-tracked dependency
    such as FoundationModelsRouter therefore stays at the revision the last run
    pinned. That is exactly the stale-pin failure this card names, and it can
    happen on the runner too. It needs its own card on the workflows board and
    a decision first.
  timestamp: 2026-09-09T17:54:10.229306+00:00
- actor: claude-code
  id: 01m23mwstmjr8qvg2yj4gcd1cq
  text: |-
    ### implement — changed
    - evidence: no source file changed. Commits `af356a8` and `8482d76`
      already did the first two boxes, and I verified both by reading
      `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/CLIProcessTests.swift`
      and by running
      `swift test --package-path IntegrationTests --filter CLIProcessTests`,
      which gives "Test run with 6 tests in 1 suite passed after 0.267
      seconds". The third box is answered in the description: CI runs the
      tier-3 package already, through `integration-package-path:
      IntegrationTests` in `.github/workflows/ci.yml`. The two changed files
      are this card's description and the new card ^gwnczy6.
    - what I could not verify: I ran no CI job, so the CI facts come from the
      workflow files and from the log of GitHub Actions run `34226397374`, not
      from a new run. I ran no tier-4 suite and no whole-package run.
    - next: review.
  timestamp: 2026-09-09T17:54:17.556828+00:00
position_column: doing
position_ordinal: '80'
title: CLIProcessTests still expects doctor to be a stub, and the tier-3 pin lags the root package
---
## The defect

Two faults stand in the tier-3 package. Both were invisible, because the
package did not build.

### 1. The build

`swift test --package-path IntegrationTests` failed to compile:

```
Sources/acp-agent/ProgressReporter.swift:87:34: error: cannot find type 'SlotProgress' in scope
```

`IntegrationTests/Package.resolved` pinned FoundationModelsRouter at
`bd8b6ff0`, and the root `Package.resolved` pins `d469aa0a`. The newer
revision carries the public `SlotProgress` type that card ^mnww4p1 added.
A local `swift package --package-path IntegrationTests update
foundationmodelsrouter` fixed the build. The pin file is ignored by git, so
CI resolves fresh and does not show this. A developer with an old checkout
does.

### 2. The stale test

With the package building again, one case fails:

```
CLIProcessTests.aStubSubcommandExitsOneAndSaysSoOnStderr
  expected exit 1, got the doctor report
  expected stderr to contain "is not implemented yet"
```

`Self.stubSubcommand` is `"doctor"`. The `doctor` subcommand was
implemented by card ^p3h7ncn, and it now runs its checks and writes its
report. No `acp-agent` subcommand is a stub any more, so the case measures
nothing.

The file has not changed since commit `9c51ba1`, which is before the doctor
card landed. That is the proof the suite has not run since.

## The fix

- [x] Delete `aStubSubcommandExitsOneAndSaysSoOnStderr`, and the
      `stubSubcommand` and `notImplementedMarker` constants it alone
      reads. There is no stub subcommand left to measure.
      DONE by commit `af356a8`. The case was not deleted; it was rewritten
      as `aMalformedProfileReferenceMakesDoctorExitOneWithTheFailureOnStderr`.
      The constants `stubSubcommand` and `notImplementedMarker` are gone.
      `NotImplementedError.swift` is gone from `Sources/acp-agent` too.
- [x] Decide whether a tier-3 case for `acp-agent doctor` belongs in that
      suite instead, and add it when it does.
      DONE by commit `af356a8`. The decision is yes, and the case is the
      rewritten one above: a malformed profile reference makes `doctor`
      exit 1 with the reason on stderr and nothing on stdout. The case
      needs no model and no network, so it stays a tier-3 case.
- [x] Find out why the tier-3 package is not run. Run it in CI, or say on
      the card why it is not run.
      DONE. See "Why the suite did not catch these two faults" below.
      The tier-3 package IS run in CI, and always was. No change to
      `.github/workflows/ci.yml` is necessary.

## Why the suite did not catch these two faults

The premise of the third box is wrong. CI runs the tier-3 package on every
push and every pull request.

- `.github/workflows/ci.yml` gives the shared workflow
  `integration-package-path: IntegrationTests`.
- In the shared workflow `swissarmyhammer/workflows`, that input alone
  starts the `integration` job. The job removes `IntegrationTests/.build`,
  builds the nested package, and runs `swift test --package-path
  IntegrationTests`. It runs on the `[self-hosted, macOS]` pool, so the
  32 GB floor of the tier-4 evaluation is satisfied and the whole package
  runs, tier-3 and tier-4 together.
- The same input also makes the unit job build the nested package on every
  run, so a compile error in the package cannot stay unseen.
- Evidence: run `34226397374` (commit `c92e1fc`, 2026-09-08) reports
  `Suite CLIProcessTests passed after 1.400 seconds`, with
  `aStubSubcommandExitsOneAndSaysSoOnStderr()` among its six cases.

There are two real reasons the two faults stayed invisible, and neither is
the selection.

1. **CI has not seen the code.** `origin/main` is `c92e1fc`. Local `main`
   is 35 commits in front of it. Every commit that made the two faults —
   the doctor implementation `8cf7170`, which deleted
   `NotImplementedError.swift`, and the Router revision that added
   `SlotProgress` — is in that unpushed run. A suite cannot fail on code
   that CI was never given. At `c92e1fc`, `doctor` really was a stub, and
   the old case was correct.
2. **The integration job is already red.** Every CI run since 2026-09-03
   failed. The last one failed in the tier-4
   `PythonCLIEvaluationTests`, on `mean >= pythonCLIEvalMeanFloor`, with
   4 issues. A job that always fails hides a new tier-3 failure inside
   it. That hazard is real and it is separate from this card, so it has
   its own card.

## Done when

- [x] `swift test --package-path IntegrationTests` builds from a clean
      checkout.
      The two pin files now agree on FoundationModelsRouter `d469aa0a`,
      and the filtered run below built and passed.
- [x] Every case of `CLIProcessTests` passes.
      `swift test --package-path IntegrationTests --filter CLIProcessTests`
      gives "Test run with 6 tests in 1 suite passed after 0.267 seconds".
