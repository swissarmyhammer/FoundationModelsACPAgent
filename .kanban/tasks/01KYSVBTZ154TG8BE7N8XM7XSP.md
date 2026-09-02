---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fq9ndfd6fg5ejwpq1e77s4
  text: |-
    Research notes:
    - Upstream shapes confirmed in ../FoundationModelsMultitool. `CommandSandbox` declares `wrap(shellPath:shellArguments:workingDirectory:temporaryDirectory:) throws -> SandboxedInvocation` and `preflight(workingDirectory:temporaryDirectory:) async throws` with a no-op default. `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)` maps `resolvedPath` (realpath) over both lists, and an empty `writableRoots` silently becomes the process working directory.
    - `MultiTool.Builder.withShell(storeDirectory:sandbox:outputChunkStream:) throws` is the one door for the shell capability.
    - The upstream `Execute` verb calls `sandbox.preflight` before the run. A thrown `SeatbeltSandboxError` becomes an in-band `correction` that says "The command was NOT run." A failed preflight never spawns.
    - `ToolCatalog.makeRegistry` already wires an inline `SeatbeltSandbox` through `SandboxConfiguration.sandboxOptions(workingDirectory:additionalRoots:)`. The plan: move that wiring into `Tools/SandboxComposition.swift` with (1) `makeShellSandbox(rootSet:configuration:)` that throws our own error on an empty root set before `Options` is constructed, and (2) a `composeShell(into:options:sandbox:)` seam that the injected throwing-preflight test drives.
    - `session/prompt` is not implemented on `RoutedACPAgent` yet, so the scripted tool turn runs through the `ScriptedSessionBackend` + `ToolInvoker` path (the Support/ScriptedModel.swift seam) with the recording harness connected; the test asserts the collector saw no update and `pendingPermissionRequests` stays empty.
    - The README-limit test follows the `DocumentationSyncTests` pattern: a public constant carries the stated limit text and the test asserts the README contains it verbatim.
  timestamp: 2026-09-02T00:11:27.535944+00:00
- actor: claude-code
  id: 01m1fqp3xsrc4m0nneq33vbb8s
  text: |
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Tools/SandboxComposition.swift (new), Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift (shell branch now goes through SandboxComposition.composeShell), README.md (§ The sandbox limit), Tests/FoundationModelsACPAgentTests/SandboxCompositionTests.swift (new, 8 tests), Tests/FoundationModelsACPAgentTests/Support/ResolvedTemporaryDirectory.swift (new shared fixture), Tests/FoundationModelsACPAgentTests/SandboxConfigTests.swift (uses the shared fixture; its own copy is deleted)
    - TDD: the suite was written first and failed with "cannot find 'SandboxComposition' in scope"; the implementation then made all 8 tests pass. `swift test --filter 'SandboxCompositionTests|SandboxConfigTests'` → 12 tests, 2 suites, all passed.
    - design: `SandboxComposition.makeShellSandbox(rootSet:configuration:)` throws `SandboxCompositionError.emptyRootSet` before any `Options` value exists; `composeShell(into:options:sandbox:)` is the one seam every shell mount goes through, so the injected throwing-preflight test drives the same wiring production uses. Options build only through `SandboxConfiguration.sandboxOptions`, so every path is realpath-resolved. `SandboxComposition.statedLimit` carries the README limit sentence verbatim and a test pins the two together.
    - next: run the full test suite
  timestamp: 2026-09-02T00:18:15.609915+00:00
- actor: claude-code
  id: 01m1fqqex0wf7ycn6spxcrd971
  text: |-
    ### test — green
    - evidence: `swift test` — 144 tests in 16 suites passed, 0 failures, 0 skipped. Zero compiler warnings from source files. The one build log warning ("missing creator for mutated node" for the mlx-swift Cmlx bundle) is a pre-existing build-system note about a dependency artifact, present before this change. The "1 known issue" is the pre-existing deliberate `withKnownIssue` self-test of the assertion helper in HarnessSmokeTests, not a skip.
    - next: commit
  timestamp: 2026-09-02T00:18:59.616335+00:00
- actor: claude-code
  id: 01m1fqr1n1vdaa7v2j2fcey275
  text: |-
    ### commit — changed
    - evidence: 724ff7b feat(tools): confine the shell with SandboxComposition over the session root set — 8 files changed, 474 insertions(+), 31 deletions(-)
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-02T00:19:18.817980+00:00
- actor: claude-code
  id: 01m1fqxmrhbfchzxkfjcmfdd0t
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — counts: 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. Skipped by rule: .kanban/ (reviewignore), README.md (no validator matches).
    - next: task moves to done
  timestamp: 2026-09-02T00:22:22.225439+00:00
- actor: claude-code
  id: 01m1fqxwbmh5hekmqtbv702zz2
  text: |-
    ### finish iteration 1 — done
    - implement: changed (SandboxComposition.swift, ToolCatalog.swift, README.md, SandboxCompositionTests.swift, ResolvedTemporaryDirectory.swift, SandboxConfigTests.swift)
    - test: green (swift test — 144 tests in 16 suites, 0 failures, 0 skipped, 0 source warnings)
    - commit: 724ff7b
    - review: clean (review sha HEAD~1..HEAD — 0 findings)
  timestamp: 2026-09-02T00:22:30.004464+00:00
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: done
position_ordinal: 8a80
title: 'Sandbox confinement: SeatbeltSandbox over the session root set'
---
## What
Plan.md §11.7, rewritten.

**This task replaced the permission-broker task.** The old task built ACP permission modes (`"*"` / `policy` / `ask`), `session/request_permission`, and `allow_always` persistence through a `ShellDecisionStore`. Every type it named was deleted upstream on 2026-08-24, and the user chose the sandbox-only path on 2026-08-31. Do not restore that design.

The decision and its reason: a denylist over command text can be avoided by respelling the command. The seatbelt sandbox is a kernel boundary and does not care how a command is spelled. So the sandbox is the only gate.

Create `Sources/FoundationModelsACPAgent/Tools/SandboxComposition.swift`:

- Build a `SeatbeltSandbox` from the session root set and the decoded `sandbox:` config section. Give it to `MultiTool.Builder.withShell(sandbox:)`.
- `SeatbeltSandbox` conforms to `CommandSandbox`, which declares `wrap(...) throws -> SandboxedInvocation` and **`preflight(workingDirectory:temporaryDirectory:) async throws`**, with a no-op default. Note `preflight` is `async throws`, not plain `throws`.
- **The preflight is the proof.** It runs a canary before any command starts. A failed preflight means the command does not run. There is no path from a failed preflight to an unconfined spawn. Surface a failed preflight as a tool-call failure with the reason, and never fall back to running unconfined.

**Never hand `SeatbeltSandbox.Options` an empty `writableRoots`.** The initializer replaces an empty list with the process working directory before it resolves the paths:
```swift
let roots = writableRoots.isEmpty
    ? [FileManager.default.currentDirectoryPath] : writableRoots
```
So an empty array does not mean "write nothing". It silently means "write wherever this process is running", which is the widest grant the type can give and the opposite of the intent. Always pass the session root set, and fail loudly if it computes to empty rather than passing an empty array through.

**Every directory must be `realpath(3)`-resolved.** Build the options only through `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)`, which maps `resolvedPath` over both lists. Never pass `URL.resolvingSymlinksInPath()` output, which strips `/private` on macOS and gives the one form Seatbelt cannot match.

Do not advertise ACP `session/request_permission`, and do not send one. The initialize task must not list a permission capability. Say plainly in the README and in a doc comment what the sandbox does and does not do: it bounds writing and deleting; reads are free and the network is open, so exfiltration is not bounded.

- [x] Sandbox built from the root set and config
- [x] Wired through `withShell(sandbox:)`
- [x] Empty writable-root set fails loudly, never passed through
- [x] Failed `async` preflight refuses the command with a reason
- [x] No unconfined fallback path exists
- [x] The stated limit is documented in the README

## Acceptance Criteria
- [x] A shell command that writes inside the root set succeeds, proved by reading the file from disk
- [x] A shell command that writes outside the root set fails, and the file does not exist afterwards
- [x] Composing with an empty root set raises our own error and never constructs `Options`, which is the process-cwd regression test
- [x] A command whose preflight throws never spawns, asserted with an injected sandbox whose `preflight` throws
- [x] A writable root given through a symlinked temp path is confined correctly, which is the `/private` regression test
- [x] No `session/request_permission` request reaches the client during a scripted tool turn
- [x] A test asserts the README states the read and network limit

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SandboxCompositionTests.swift` — the write-in and write-out cases with filesystem truth, the empty-root-set case, the preflight refusal, and the symlink case
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.