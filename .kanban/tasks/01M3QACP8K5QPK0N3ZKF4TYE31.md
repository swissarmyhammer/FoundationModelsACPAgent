---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: Remove the obsolete `wait` tool from plan.md §4.7, §11, §11.1 and README.md
---
## Why

The model surface of Multitool is `searchTools` + `runCode`. There is no `wait` tool. A settled background run comes back to the session as mail and starts a new submission (plan.md §8.0). Some text still names `wait`, so a reader learns a wrong surface.

## What

Rewrite these places for the mail model. Write in ASD-STE100 Simplified Technical English.
- plan.md §4.7 (the text near "wait" in the `runCode` snippet section).
- plan.md §11 and §11.1 (for example "`wait` is mounted in both modes").
- README.md: "`searchTools`, `runCode` and `wait`".

## Acceptance Criteria

- [ ] `rg -n "\bwait\b" plan.md README.md` shows no line that names a `wait` tool.
- [ ] No code change.

Found by ^wqe0awe. #generation-queue