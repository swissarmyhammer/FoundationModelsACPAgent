---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m222vsqtjm4mba7n304xp8fx
  text: |-
    Research, then the design decisions that the code records.

    What is really in this repository, and what the checks read:
    - `SandboxConfiguration` has exactly one key, `extraWritePaths`, and
      `sandboxOptions(workingDirectory:additionalRoots:)` builds the
      `SeatbeltSandbox.Options`. That initializer puts every path through
      `realpath(3)`, so `options.writableRoots.first` is the resolved working
      directory the preflight needs.
    - `SeatbeltSandbox.preflight(workingDirectory:temporaryDirectory:)` IS the
      trivial confined command: it starts `/usr/bin/sandbox-exec` with the real
      profile against `/usr/bin/true`. So the real prober calls that, and does
      not invent a command of its own.
    - `MCPComposition.connectServers(section:clientServers:)` already does what
      the MCP probe must do: a stdio entry spawns its command and waits for
      `.ready`, and an http entry connects at its URL. The real prober calls it
      over a roster of one entry, then gives everything back. Its `shutDown`
      went from `private` to internal for that, and its documentation now names
      the second caller.
    - The shell store default is `<cwd>/.shell` (`ShellState.init()` through
      `ShellDotfolder.currentDirectory()`). The check resolves that against the
      directory `--cwd` names.

    The prober protocol has two calls, `startSandbox(options:)` and
    `startMCPServer(_:)`, and each answers `ProbeOutcome` — `answered`,
    `failed(reason:)` or `timedOut`. Nothing throws, so a refusal travels as a
    value and one broken tool cannot stop the report.

    The timeout: `ToolsDoctor.probeTimeoutSeconds` is 5.0 seconds, and the
    initializer takes an override so a test can prove the bound in 0.2 seconds
    instead of 5. `ProbeTimeout.run` races the probe against a timer in two
    unstructured tasks. A structured child would have to be awaited at the end
    of its scope, so a probe that ignores cancellation would still hold the
    whole run; the unstructured task is cancelled and left behind.

    What did NOT work, so the next agent does not repeat it: the stub prober
    first modelled "never answers" with a `withCheckedContinuation` that is
    never resumed. The suite then printed `SWIFT TASK CONTINUATION MISUSE:
    neverAnswer() leaked its continuation without resuming it`. That is a
    warning, and the rule is zero warnings. The stub now sleeps 60 seconds and
    then answers: far past any injected timeout, cancellable, and the late
    answer is dropped by the one-shot `FirstAnswer` box.

    One extraction the duplication rule made necessary: `TranscriptsDoctor` and
    the new shell-store check ask the same question of two directories — it
    exists and can be written, or the nearest directory above it can be
    written. That rule now lives one time in `WritableDirectoryCheck`, and each
    component states only its own name, subject and fix. `TranscriptsDoctor`
    keeps its messages word for word, and its tests did not change.

    Not in this card, on purpose: the `files:` and `skills:` sections. The
    skills stack is card ^sj5hyh, and the files capability reaches only the
    session root set, which the sandbox row already covers.
  timestamp: 2026-09-09T03:19:55.898035+00:00
- actor: claude-code
  id: 01m222w5tx9e9hybfahyqnf65t
  text: |-
    Correction to the comment above: the skills card is `^vsj5hyh`, not
    `^sj5hyh`.

    ### implement — changed
    - evidence: 5 new files and 4 changed files.
      New: `Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift`,
      `Sources/FoundationModelsACPAgent/Doctor/ToolsProber.swift`,
      `Sources/FoundationModelsACPAgent/Doctor/WritableDirectoryCheck.swift`,
      `Tests/FoundationModelsACPAgentTests/Doctor/ToolsDoctorTests.swift`,
      `Tests/FoundationModelsACPAgentTests/Support/StubToolsProber.swift`.
      Changed: `Sources/acp-agent/DoctorCommand.swift` (the third component and
      the injected prober), `Sources/FoundationModelsACPAgent/Doctor/TranscriptsDoctor.swift`
      (it now calls the shared writable-directory check),
      `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift` (`shutDown`
      is internal), `Tests/FoundationModelsACPAgentTests/Doctor/DoctorRegistryTests.swift`
      (three components, and a stub prober).
    - red first: `swift build --build-tests` refused the new test files with
      `cannot find type 'ToolsProber' in scope` and `cannot find type
      'ProbeOutcome' in scope`. Then the source landed and the 11 new tests
      passed.
    - green: root `swift test` gives 536 tests in 58 suites, 1 known issue at
      HarnessSmokeTests.swift:239. The baseline was 525 tests in 57 suites with
      that same known issue, so this card adds 11 tests and 1 suite. Zero
      failures and zero warnings; the timeout test takes 0.202 seconds.
    - next: `/review`.
  timestamp: 2026-09-09T03:20:08.285494+00:00
- actor: claude-code
  id: 01m224dyb00ya17secqvbtectv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (c019caa). 0 findings, 0 confirmed, 0 refuted. 7 validators ran on 9 files. 4 kanban files were not read, because an ignore rule excludes them.
    - next: none. The card is in the done column.
  timestamp: 2026-09-09T03:47:19.008378+00:00
- actor: claude-code
  id: 01m224ej53qd13ydv7cgzx5ked
  text: |-
    ### finish iteration — clean
    - implement: changed — 13 files. `ToolsDoctor` is the third component, category `tools`: rows for the seatbelt sandbox, each `sandbox.extraWritePaths` entry, the shell, and each configured MCP server. `ToolsProber` is the injected seam and nothing throws; `SystemToolsProber` reuses `SeatbeltSandbox.preflight` and `MCPComposition.connectServers`. No unit test spawns a process. `WritableDirectoryCheck` holds the directory rule that `TranscriptsDoctor` and the shell-store check share.
    - every prober call runs under a 5-second timeout that a test can override. `ProbeTimeout.run` races the probe against a timer in unstructured tasks, so a probe that ignores cancellation cannot hold the run.
    - dead end worth keeping: the stub prober first modelled "never answers" with a never-resumed `withCheckedContinuation`, and the suite printed `SWIFT TASK CONTINUATION MISUSE`. The stub now waits and answers late, which is cancellable and leaves no suspended task.
    - test-first: red with "cannot find type 'ToolsProber' in scope" and "cannot find type 'ProbeOutcome' in scope"
    - test: green — swift test after a clean build, 536 tests in 58 suites, 1 known issue at HarnessSmokeTests.swift:239. It was 525 in 57 before. The ToolsDoctor suite ran eight times with no flakiness and no continuation misuse.
    - commit: c019caa
    - review: clean — 0 findings, 7 validators, 9 files. The concurrency of the unstructured-task race, the continuation discipline and the `Sendable` conformances were in scope and drew no defect.
  timestamp: 2026-09-09T03:47:39.299418+00:00
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: done
position_ordinal: ca80
title: 'doctor checks: the sandbox, the tools and the MCP servers'
---
### What

cli-plan.md §5.12, the Sandbox and Tools rows. The Skills and Runtime
rows moved to their own card, because six checks across two components
was over the sizing limit.

`ToolsDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`tools`. It takes the resolved `AgentConfiguration` and an injected
prober, so no test needs a real subprocess or a real network.

- The seatbelt sandbox starts. Run one trivial confined command through
  the injected prober and report the result. A failure is an `.error`.
- Each `sandbox.extraWritePaths` entry exists. A missing path is a
  `.warning` naming it.
- The `tools.shell` store directory is writable. `nil` means the
  capability's own default location, and that is checked too.
- Each configured MCP server: a stdio server's command exists and
  starts; an http server's URL answers. A failure is an `.error` naming
  the server. `tools.mcp` disabled contributes nothing.
- Each disabled tool section reports `.ok` with the word "disabled", so
  a person sees why a tool is absent.

Every prober call carries a timeout. **Name it in seconds in the code**
— the acceptance criterion below asserts against that named value, not
against a vague "its timeout".

- [x] `ToolsDoctor`, with the injected prober
- [x] Sandbox, extra paths, shell store, MCP servers
- [x] A disabled section reports `.ok` and says "disabled"
- [x] Register it in the doctor component list

### Acceptance Criteria

- [x] With an injected prober that succeeds everywhere and a default
      roster, every row is `.ok`. **This uses the fixture, not the real
      machine** — the check must be reproducible in CI.
- [x] A missing `extraWritePaths` entry gives one `.warning` naming it.
- [x] An MCP server whose command the prober reports absent gives one
      `.error` naming the server and the command.
- [x] `tools.shell: false` gives one `.ok` row that says disabled, and
      no store-directory check runs.
- [x] A prober that never answers gives a `.warning` inside the named
      timeout, and the run does not hang.
- [x] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

- [x] `ToolsDoctorTests`: the all-succeed fixture, the missing extra
      path, the unwritable store directory, and a disabled section.
- [x] The MCP rows against an injected prober: found, missing and
      timeout.
- [x] A timeout test asserts the elapsed time is under the named bound.
- [x] A test walks every check and asserts no `.warning` or `.error` has
      a nil `fix`.
- [x] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
