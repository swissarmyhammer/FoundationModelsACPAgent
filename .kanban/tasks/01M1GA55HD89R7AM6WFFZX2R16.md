---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gn05g6qwa7c8a1kh6ensax
  text: |-
    ## Verification against the pinned Multitool checkout

    I examined the pinned checkout at .build/checkouts/FoundationModelsMultitool (revision e8c91a602d8b094afdf8ba681f83c54945643d44, branch main). No public seam accepts a default working directory for the shell composition. The evidence:

    - `MultiTool.Builder.withShell(storeDirectory:sandbox:outputChunkStream:)` — Sources/FoundationModelsMultitool/Surface/MultiToolBuilder.swift:235-239. This is the only `withShell` overload in the package. It has no working-directory parameter.
    - `ShellCapability.init(storeDirectory:sandbox:outputChunkStream:)` — Sources/FoundationModelsMultitool/Capabilities/Shell/ShellCapability.swift:99. Public, but it has no working-directory parameter.
    - The execute verb and its options are internal: `struct ExecuteArguments` (Capabilities/Shell/Execute.swift:75) and `struct Execute: Tool` (Execute.swift:772). The field `workingDirectory: String?` (Execute.swift:93) goes to the runner with no change (Execute.swift:244).
    - `ShellRunner` is internal (`struct ShellRunner`, Capabilities/Shell/ShellRunner.swift:71). `Request.workingDirectory: String?` (ShellRunner.swift:185, default `nil` at :207). The fallback is `request.workingDirectory ?? FileManager.default.currentDirectoryPath` (ShellRunner.swift:485). The spawned `Configuration` gets `request.workingDirectory.map { FilePath($0) }` (ShellRunner.swift:458), thus a `nil` value makes the child run in the agent process directory.
    - `SeatbeltSandbox.Options.init(writableRoots:extraWritePaths:)` — Capabilities/Shell/SeatbeltSandbox.swift:146. It shapes the write grant only. It has no default run directory.
    - The `CommandSandbox` protocol (Capabilities/Shell/CommandSandbox.swift:113) cannot supply the default. `wrap` receives the directory after the runner resolves it (ShellRunner.swift:447) and returns only an executable and arguments; it cannot set the `Configuration.workingDirectory` (ShellRunner.swift:458).

    Conclusion: the task is blocked upstream. FoundationModelsMultitool must supply the seam. I will file the upstream ask.
  timestamp: 2026-09-02T08:50:33.606941+00:00
- actor: claude-code
  id: 01m1gn1038ts9f421cx1wvcp5s
  text: |-
    ## Upstream ask

    Filed as Ask 6 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md. Owning package: FoundationModelsMultitool.

    The ask: supply a default working directory for the shell composition — for example a `defaultWorkingDirectory` parameter on `withShell` and `ShellCapability.init`, or a field on a public shell options struct — so that a run that omits `workingDirectory` lands in that default instead of the process directory, which the sandbox refuses.

    The cause, at revision e8c91a6: the execute verb passes `workingDirectory: String?` to the runner with no change (Execute.swift:93, :244); `ShellRunner` falls back to `FileManager.default.currentDirectoryPath` for the sandbox directories (ShellRunner.swift:485) and the spawned `Configuration` gets `nil` (ShellRunner.swift:458), thus the child inherits the agent process directory. The process directory stands outside the session root set, thus the sandbox refuses each plain command in band.
  timestamp: 2026-09-02T08:51:00.840324+00:00
- actor: claude-code
  id: 01m1gn16g34vjg2kban0m04v1x
  text: |-
    ### finish — stuck
    - evidence: No public seam for a default working directory exists in the pinned Multitool checkout (revision e8c91a6). Proof: MultiToolBuilder.swift:235-239 (only `withShell` overload, no working-directory parameter); ShellCapability.swift:99 (public init, no working-directory parameter); Execute.swift:75, :93, :244, :772 (verb and arguments internal, `workingDirectory` passes through unchanged); ShellRunner.swift:71, :185, :458, :485 (internal runner, `nil` falls back to the process directory); SeatbeltSandbox.swift:146 (`Options` shapes the write grant only); CommandSandbox.swift:113 with ShellRunner.swift:447-458 (`wrap` cannot set the run directory). Upstream ask filed as Ask 6 in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/UPSTREAM_ASKS.md, owner FoundationModelsMultitool. No code change, no commit. The card stays in todo until the upstream seam lands.
    - next: When FoundationModelsMultitool supplies the seam, wire the session cwd through SandboxComposition.composeShell and drop the explicit workingDirectory from tier-2 proof 7.
  timestamp: 2026-09-02T08:51:07.395557+00:00
position_column: todo
position_ordinal: a180
title: Default the shell run working directory to the session root
---
## What
The tier-2 streamed-shell proof (task ^qg1rfct) found this gap: a `tools.shell.execute` call that omits `workingDirectory` runs in the agent PROCESS current directory, not in the session `cwd`. The shell verb's own description says "Omit it to run in the current directory", and `ShellRunner` falls back to `FileManager.default.currentDirectoryPath`. The sandbox then refuses the run in band — the process directory stands outside the session root set — and the command does not run.

## Why
The agent process's current directory has no relation to the session working directory. A model that follows the verb description gets a refused run on every plain command. The session root is the only sensible default.

## How
- Check whether Multitool's shell composition accepts a default working directory (for example on `withShell` or the execute verb options). If not, record the upstream ask.
- Wire the session `cwd` as the default through `SandboxComposition.composeShell` when the seam exists.
- Then drop the explicit `workingDirectory` from the tier-2 proof 7 snippet in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`.

## Acceptance Criteria
- [ ] A `tools.shell.execute` with no `workingDirectory` runs in the session `cwd`
- [ ] Tier-2 proof 7 passes without an explicit `workingDirectory`