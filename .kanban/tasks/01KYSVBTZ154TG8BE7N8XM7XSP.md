---
assignees:
- claude-code
depends_on:
- 01KYSV611EWFQQRRPJWR5JQ4H5
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: todo
position_ordinal: '9180'
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

- [ ] Sandbox built from the root set and config
- [ ] Wired through `withShell(sandbox:)`
- [ ] Empty writable-root set fails loudly, never passed through
- [ ] Failed `async` preflight refuses the command with a reason
- [ ] No unconfined fallback path exists
- [ ] The stated limit is documented in the README

## Acceptance Criteria
- [ ] A shell command that writes inside the root set succeeds, proved by reading the file from disk
- [ ] A shell command that writes outside the root set fails, and the file does not exist afterwards
- [ ] Composing with an empty root set raises our own error and never constructs `Options`, which is the process-cwd regression test
- [ ] A command whose preflight throws never spawns, asserted with an injected sandbox whose `preflight` throws
- [ ] A writable root given through a symlinked temp path is confined correctly, which is the `/private` regression test
- [ ] No `session/request_permission` request reaches the client during a scripted tool turn
- [ ] A test asserts the README states the read and network limit

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SandboxCompositionTests.swift` — the write-in and write-out cases with filesystem truth, the empty-root-set case, the preflight refusal, and the symlink case
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.