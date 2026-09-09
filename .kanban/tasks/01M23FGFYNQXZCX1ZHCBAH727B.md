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
    1. `origin/main` is `c92e1fc`, and local `main` is 36 commits in front of
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
- actor: claude-code
  id: 01m23n2qzx8d5jh6emhwb36ewy
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` on commit `ca850a7` gives 0 findings,
      0 confirmed, 0 refuted. The engine reviewed 0 files: all 6 files of the
      commit are `.kanban/` files, which `.reviewignore` excludes. The commit
      changes no source file and no workflow file.
    - what I examined in the record, because the record is the deliverable:
      (1) each ticked box and the evidence it names; (2) each CI statement and
      its source; (3) the count of the unpushed commits; (4) the new card
      ^gwnczy6; (5) the `Package.resolved` hazard on the self-hosted runner.
    - what passed: the first two boxes of "The fix" name commit `af356a8`.
      The third box points to the section that names `.github/workflows/ci.yml`,
      the shared workflow, and run `34226397374`. No statement says that a CI
      run was made for this card; comment `01m23mwstmjr8qvg2yj4gcd1cq` says
      "I ran no CI job" and names the two written sources. Card ^gwnczy6 gives
      the failing tier-4 assertion `mean >= pythonCLIEvalMeanFloor` at
      `PythonCLIEvaluation.swift:336:13` with 4 issues, and it proposes three
      ways to decide instead of an unverified fix. Comment
      `01m23mwjnngyraq7ackqkd093h` marks the `Package.resolved` hazard as found
      and not acted on, and says the fix belongs to the sibling repository
      `swissarmyhammer/workflows` and needs its own card there.
    - what failed: two faults, in the "Review Findings (2026-09-09 12:55)"
      section. The commit count is 36 at `ca850a7`, not 35. The "clean checkout"
      box names no clean checkout and no commit or CI run.
    - next: correct the two items, then review again.
  timestamp: 2026-09-09T17:57:32.285450+00:00
- actor: claude-code
  id: 01m23n4bv67hnck7stmxnntp1e
  text: |
    ### Amendment, 2026-09-09

    Two corrections to the record, each one answering a review finding.

    **1. The unpushed commit count.** The card and the comment
    `01m23mwjnngyraq7ackqkd093h` said 35. The number is **36**, measured with
    `git rev-list --count origin/main..main` at commit `ca850a7`. The card now
    gives the command and the commit, because each new commit makes the number
    larger. This comment replaces the number 35 wherever the earlier comment
    gives it.

    **2. The "clean checkout" box is UNTICKED.** It said `swift test
    --package-path IntegrationTests` builds from a clean checkout, and it gave
    as evidence the agreement of the two pin files plus a filtered run. That is
    not the same thing. No clean checkout was made. `.gitignore:6` ignores
    `Package.resolved` and `IntegrationTests/Package.resolved`, so no commit can
    hold the agreement of the two files: it lives on this disk only. The first
    thing that can prove that box is a CI run of the 36 unpushed commits.
  timestamp: 2026-09-09T17:58:25.382094+00:00
position_column: review
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
   is 36 commits in front of it, measured with
   `git rev-list --count origin/main..main` at commit `ca850a7`. The
   number gets larger with each new commit, so it is true only at the
   commit named. Every commit that made the two faults —
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

- [ ] `swift test --package-path IntegrationTests` builds from a clean
      checkout.
      NOT PROVED, and it cannot be proved from this repository. The two
      pin files agree on FoundationModelsRouter `d469aa0a` on this disk
      only: `.gitignore:6` ignores `Package.resolved` and
      `IntegrationTests/Package.resolved`, so no commit can hold that
      agreement. The evidence below is a filtered run in the workspace
      that was already there, and no clean checkout was made. A CI run
      of the 36 unpushed commits is the first thing that can prove this
      box.
- [x] Every case of `CLIProcessTests` passes.
      `swift test --package-path IntegrationTests --filter CLIProcessTests`
      gives "Test run with 6 tests in 1 suite passed after 0.267 seconds".

## Review Findings (2026-09-09 12:55)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 0 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> Every file in scope was excluded — 6 of 6 file(s) — so nothing was left to review. The exclusions above are deliberate: this is a clean review, not an empty scope, a failed run, or a size-cap skip.

The engine found no code in the commit `ca850a7`. The commit changes only
kanban cards. The record is the deliverable of this card, so the record was
examined. Two faults are below.

- [x] `.kanban/tasks/01M23FGFYNQXZCX1ZHCBAH727B.md` `record/evidence` — The card says local `main` is 35 commits in front of `origin/main`. At commit `ca850a7`, `git rev-list --count origin/main..main` gives 36. The comment `01m23mwjnngyraq7ackqkd093h` says 35 also. Write the number that the command gives, and write the commit at which you counted it, because each new commit makes the number larger.
- [x] `.kanban/tasks/01M23FGFYNQXZCX1ZHCBAH727B.md` `record/evidence` — The "Done when" box "`swift test --package-path IntegrationTests` builds from a clean checkout" is ticked, but no clean checkout was made. The evidence that the box gives is a filtered run in the workspace that was already there, and `Package.resolved` is ignored by git (`.gitignore:6`), so no commit can hold the agreement of the two pin files. Name the commit or the CI run that shows a build from a clean checkout, or write on the box that it rests on a local run in the existing workspace and that no clean checkout was made.
