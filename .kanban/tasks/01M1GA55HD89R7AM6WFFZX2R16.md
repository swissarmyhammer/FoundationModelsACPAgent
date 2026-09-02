---
assignees:
- claude-code
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