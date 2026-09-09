---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21hywjhfs1c0pwm3kq9apve
  text: |-
    ### The upstream card is made

    `FoundationModelsExtras` card **`^gpfa1sy`** — "Doctorable module: D1 to D3". It is in `todo` and carries the full specification of this card, written from the Extras view.

    This card stays open until that one is done and merged to Extras `main`.
  timestamp: 2026-09-08T22:24:31.313365+00:00
- actor: claude-code
  id: 01m21vxba9fyvrte9bravbg3wc
  text: |-
    ### Verification of the upstream work

    This is a tracking card. The work is in `../FoundationModelsExtras`, and I read
    the code and the tests there. I made no change in that repository: its working
    tree stayed clean through this step.

    **The upstream commits.** The module is on Extras `main`, and `origin/main` and
    the local `main` are the same commit, `55d6b04`. The five commits that make it:

    - `b044d69` feat(doctor): add HealthStatus, HealthCheck, and Doctorable protocol
    - `aae3b89` feat(doctor): add DoctorRunner and DoctorReport with concurrent checks
    - `939b317` feat(doctor): add plain-text and JSON doctor renderer
    - `e814610` feat(extras-demo): add doctor subcommand for the Doctorable health-check surface
    - `f80146f` feat(doctor): add DoctorReport JSON support and plain renderer tests

    The module is `Sources/FoundationModelsExtras/Doctor/`, 507 lines over five
    files: `Doctorable.swift`, `HealthCheck.swift`, `DoctorReport.swift`,
    `DoctorRunner.swift`, `DoctorRenderer.swift`.

    **Each acceptance criterion, and what shows it.**

    1. *A type that states only `doctorName` and `doctorCategory` gives one `.ok`
       check.* `Doctorable` gives `isApplicable` and `runHealthChecks()` default
       implementations; the default returns one `.ok` built from the two names.
       Test: `aComponentThatStatesOnlyItsNameAndCategoryGivesOneOkCheck`. I also
       compiled such a type here (see the consumption note below).
    2. *`exitCode` gives 0, 1 and 5.* `DoctorReport.exitCode` switches on
       `worstStatus` over three named constants, `okExitCode` 0, `errorExitCode` 1
       and `warningExitCode` 5. Tests: `a report of only passing checks exits
       zero`, `a report holding an error exits one`, `a report holding only a
       warning exits five`, and `an error outranks a warning`.
    3. *N components that each wait 100 ms finish in well under N x 100 ms.*
       `DoctorRunner.run()` uses `withTaskGroup`. Test: `components that each wait
       finish in well under the sum of their waits` — 10 components, each waiting
       `componentDelay` of 100 ms, against a limit of the serial time divided by
       `serialTimeFraction`. A second test, `one slow component does not hold back
       the others`, makes a serial runner fail through a watchdog instead of
       hanging.
    4. *The report order is the registration order.* Each task carries its
       registration position home in `RegisteredFindings`, and `run()` sorts on
       that position before it flattens. The position is read before the
       applicability filter, so a skipped component does not shift the ones behind
       it. Tests: `the report keeps the registration order when the first component
       is slow`, and `a component that does not apply reports nothing and stays
       registered`.
    5. *The plain renderer holds no `ESC[` sequence, ever.*
       `PlainTextDoctorRenderer` builds each row from padded ASCII columns only.
       `PlainRendererTests` holds three tests for this rule: `the output of every
       status holds no ansi escape`, `no doctor source file spells the escape
       character` (which reads each source file of the module and rejects the
       escape byte and the three spellings `u{001b}`, `u{1b}` and `x1b`), and `no
       doctor source file imports a terminal or color library`.
    6. *No file of the module imports a terminal or a color library.* I grepped
       every import of the module. There is exactly one: `import Foundation` in
       `DoctorRenderer.swift`. The other four files import nothing.
    7. *The change is on Extras `main`.* Yes, at `55d6b04`, and pushed.

    **The JSON.** `DoctorReport` encodes as the single array of its checks through
    a `singleValueContainer`, and decodes back from it. `jsonData(prettyPrinted:)`
    sorts its keys. A `HealthCheck` whose `fix` is `nil` writes no `fix` key.
    Tests: `a report survives a json round trip`, `an encoded report is the array
    of its checks`, `a report decodes from its own json data`,
    `anOkCheckSurvivesAJSONRoundTrip`, `anErrorCheckSurvivesAJSONRoundTrip`,
    `anEncodedOkCheckHoldsNoFixKey`.

    **The upstream suite.** `swift test` in `../FoundationModelsExtras`: 264 tests
    in 24 suites, all passed.

    ### This repository can consume it

    The pin in `Package.resolved` was the older `8b4706d`, so the new module did
    not resolve. I ran `swift package update FoundationModelsExtras`, which moved
    the working copy to `main` at `55d6b04`. `Package.resolved` is in `.gitignore`
    here and is not tracked, so nothing was staged and nothing needs to be.

    `swift build` is clean. To show that the new types are reachable from a plain
    `import FoundationModelsExtras` in this repository, I type-checked a probe file
    in the scratchpad against the built module. It declares a `Doctorable` that
    states only its name and its category, and it touches `DoctorRunner`,
    `DoctorReport`, `HealthStatus`, `HealthCheck`, `PlainTextDoctorRenderer` and
    `jsonData()`. It type-checks. A negative control, with one name changed to a
    name that does not exist, fails as it must, so the check has teeth.

    `swift test` at the root: 497 tests in 52 suites passed, with 1 known issue at
    `HarnessSmokeTests.swift:239`. That is the baseline exactly.

    No source file of this repository changed. The card is now the only record that
    needed the update.
  timestamp: 2026-09-09T01:18:26.633993+00:00
- actor: claude-code
  id: 01m21vxg3v0cgrf441shgc83jm
  text: |-
    ### implement — changed
    - evidence: no source file changed here. The card description is ticked: 4 subtasks, 7 acceptance criteria, 7 test items. Upstream Extras `main` is at `55d6b04`, and this repository now resolves it (`swift package update FoundationModelsExtras`, an ignored and untracked `Package.resolved`). `swift build` clean; root `swift test` 497 tests in 52 suites, 1 known issue at `HarnessSmokeTests.swift:239`; Extras `swift test` 264 tests in 24 suites.
    - next: review.
  timestamp: 2026-09-09T01:18:31.547812+00:00
position_column: doing
position_ordinal: '80'
title: 'Extras: the Doctorable module, D1 to D3'
---
## What

Upstream work in `../FoundationModelsExtras`. The full specification is
that repository's `doctor-plan.md`, milestones **D1, D2 and D3**. All
three are here, because D3's plain renderer is what the piped `doctor`
output needs, and no other card owns it.

New module `Sources/FoundationModelsExtras/Doctor/`:

**D1 — the protocol and the values.**
- `HealthStatus`: `ok`, `warning`, `error`. `Sendable`, `Codable`.
- `HealthCheck`: `name`, `status`, `message`, `fix: String?`,
  `category`. `Sendable`, `Equatable`, `Codable`. Static makers where
  `warning` and `error` require a `fix`.
- `Doctorable`: `doctorName`, `doctorCategory`, `isApplicable` (default
  `true`), `func runHealthChecks() async -> [HealthCheck]` (default: one
  `.ok` built from the name and the category).

**D2 — the runner.**
- `DoctorReport`: `checks`, `worstStatus`, `exitCode` — 0 for all `.ok`,
  1 for any `.error`, 5 for warnings with no error.
- `DoctorRunner`: `init(components:)` and `run() async -> DoctorReport`.
  Concurrent in a task group, skipping non-applicable components, and
  keeping the registration order in the result.
- `runHealthChecks()` never throws. A check that cannot run reports
  `.error` with the reason, so one broken check cannot stop the others.

**D3 — the plain renderer and the JSON.**
- A plain-text renderer for `DoctorReport`: status, name, message, with
  the fix line under each `.warning` and `.error` row. **No ANSI escape,
  ever** — this is the renderer a piped `doctor` uses, and a decorated
  table is the CLI's own concern.
- `HealthCheck` and `DoctorReport` encode to JSON for the `--json` form.

**This module declares no terminal dependency.** Extras is a library
that also runs inside a Mac app.

- [x] D1: `HealthStatus`, `HealthCheck`, `Doctorable`
- [x] D2: `DoctorReport` and `DoctorRunner`
- [x] D3: the plain renderer, and the JSON encoding
- [x] Merge to `main` in the Extras repository

## Acceptance Criteria

- [x] A type declaring only `doctorName` and `doctorCategory` compiles
      and gives one `.ok` check.
- [x] `exitCode` gives 0, 1 and 5 for the three cases.
- [x] N components that each wait 100 ms finish in well under
      N × 100 ms.
- [x] The report order matches the registration order, whatever the
      finish order.
- [x] The plain renderer output holds no `ESC[` sequence, ever.
- [x] No file in the module imports a terminal or a color library.
- [x] The change is on Extras `main`.

## Tests

- [x] `DoctorableTests`: the default implementation gives exactly one
      `.ok` check, named and categorized from the protocol properties.
- [x] `isApplicable == false` contributes no checks, and the component
      stays in the runner's list.
- [x] `DoctorReportTests`: the exit code of each of the three cases.
- [x] `DoctorRunnerTests`: the concurrency timing assertion, and a
      stable order.
- [x] `PlainRendererTests`: the output holds no `ESC[`, and each
      `.warning` and `.error` row is followed by its fix line.
- [x] `HealthCheck` and `DoctorReport` round-trip through JSON.
- [x] `swift test` in `../FoundationModelsExtras` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.