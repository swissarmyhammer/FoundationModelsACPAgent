---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: 'OutOfProcessTests: the pgrep pattern finds no child process when the build folder is under /private/tmp'
---
## Problem

Found on 2026-10-10 in task ^c4a6mwy. `OutOfProcessTests.noProcessOfTheChildsGroupOutlivesTheRun` fails each time when the build folder is under `/private/tmp`, and passes when the build folder is under `$HOME`.

Cause: Foundation `Process` removes the `/private` prefix, so the child process runs as `/tmp/.../acp-agent acp`. The `pgrep` pattern in `ProcessCensus` keeps `/private/tmp/...`, so it matches no process. Thus, the test cannot see a child process that outlives the run, and it fails for a reason that is not the behavior under test.

## Change

- Make the `ProcessCensus` pattern match both path forms: resolve the binary path with symlinks resolved, and also match the form with `/private` removed. The other way is to match by process group in place of by path.
- Do not weaken the check: a child process that outlives the run must still make the test fail.

## Tests

- Run the suite with a build folder under `/private/tmp` and under `$HOME`. Both pass.
- A test of `ProcessCensus` itself: a pattern made from `/private/tmp/x/acp-agent` matches a process whose command line is `/tmp/x/acp-agent acp`.

#tests