---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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

- [ ] D1: `HealthStatus`, `HealthCheck`, `Doctorable`
- [ ] D2: `DoctorReport` and `DoctorRunner`
- [ ] D3: the plain renderer, and the JSON encoding
- [ ] Merge to `main` in the Extras repository

## Acceptance Criteria

- [ ] A type declaring only `doctorName` and `doctorCategory` compiles
      and gives one `.ok` check.
- [ ] `exitCode` gives 0, 1 and 5 for the three cases.
- [ ] N components that each wait 100 ms finish in well under
      N × 100 ms.
- [ ] The report order matches the registration order, whatever the
      finish order.
- [ ] The plain renderer output holds no `ESC[` sequence, ever.
- [ ] No file in the module imports a terminal or a color library.
- [ ] The change is on Extras `main`.

## Tests

- [ ] `DoctorableTests`: the default implementation gives exactly one
      `.ok` check, named and categorized from the protocol properties.
- [ ] `isApplicable == false` contributes no checks, and the component
      stays in the runner's list.
- [ ] `DoctorReportTests`: the exit code of each of the three cases.
- [ ] `DoctorRunnerTests`: the concurrency timing assertion, and a
      stable order.
- [ ] `PlainRendererTests`: the output holds no `ESC[`, and each
      `.warning` and `.error` row is followed by its fix line.
- [ ] `HealthCheck` and `DoctorReport` round-trip through JSON.
- [ ] `swift test` in `../FoundationModelsExtras` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.