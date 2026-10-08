---
assignees:
- claude-code
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