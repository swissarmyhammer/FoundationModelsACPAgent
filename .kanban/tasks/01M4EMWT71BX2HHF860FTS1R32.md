---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4g8ystry17zep0bqa0ef1kr
  text: 'Upstream task (2026-10-09): ^8fd3kgk (01M4G8YDTF9YEDZVZ958FD3KGK) on the FoundationModelsMultitool board holds both defects with the repro. It is in todo. The session foundationmodelsmultitool-1b will send the commit when the fix is on Multitool origin/main. Then move the Multitool pin here, check both verbs on a detached-HEAD clone, and close this task. Until then, /finish skips this task.'
  timestamp: 2026-10-09T12:07:11.448410+00:00
- actor: claude-code
  id: 01m4gdq5kapbqm8440p5vgr88z
  text: |-
    Upstream fix is on Multitool origin/main (2026-10-09): commit ea0d60f (task ^8fd3kgk); main is at 360d6d0.
    1. `tools.git.changes` on a detached HEAD: with no `branch` argument it reads HEAD, and the result `branch` is `HEAD`. A `range` (for example `HEAD`, `HEAD~1..HEAD`, `HEAD~2`) also works. The correction stays only for a repository with no commit.
    2. `tools.git.diff`: each changed run of lines that no entity holds is now one change with `entityType` "lines" and a name such as "lines 12-14", for each language and data format.

    To close this task: task ^8n8sfpv moves the Multitool pin to 360d6d0 or later. Then check both verbs on a detached-HEAD clone (for example with the bench verb-check method of ^exkkyyr). No other code change is expected in this repo.
  timestamp: 2026-10-09T13:30:24.234193+00:00
position_column: todo
position_ordinal: '8580'
title: 'Upstream Multitool: tools.git.changes fails on a detached HEAD, and tools.git.diff misses a change against HEAD'
---
## Status

These are defects in FoundationModelsMultitool. Do not fix them in this repo. Send them to a Multitool session, which makes the task on the Multitool board. Then write its task id here. This task is done when the Multitool fix is on Multitool `origin/main` and this agent pins it.

## Defects

Found on 2026-10-08 in task ^exkkyyr. Multitool checkout 24f65ed. The repository is a SWE-bench django clone with a detached HEAD at base commit 0456d3e427.

1. **`tools.git.changes` cannot work on a detached HEAD.** `tools.git.changes({})` and `tools.git.changes({range: "HEAD"})` both give the correction: "HEAD names no branch: HEAD is detached, or the git repository has no commit. Give branch to name the local branch to read." The branch check comes before the range is read. Thus, a range cannot work on a detached HEAD, and on a SWE-bench clone the agent cannot get its change list from `changes`. Also, `branch: "main"` reads the later upstream history.
   - Expected: with a detached HEAD, `changes` uses HEAD (or the given `range`) and does not need a branch name.
2. **`tools.git.diff` misses a change against HEAD.** `tools.git.diff({left: "django/contrib/admin/sites.py@HEAD", right: "django/contrib/admin/sites.py"})` gave 0 changes for a comment line that was added at the end of the file. `git diff <base>` shows that change.
   - Expected: the diff shows each changed line, including a comment line at the end of the file.

## Not in this task

The `.acp-agent/` files in `status` and `diff` are a bench clone problem. Task ^exkkyyr fixes them with `.git/info/exclude`.

#tools #upstream