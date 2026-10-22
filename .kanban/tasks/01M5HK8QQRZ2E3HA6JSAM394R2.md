---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'ROUTER-3: stop the ACPAgent append to sessions.jsonl when Router writes the line (waits on a Router API for title and additionalDirectories)'
---
From the Router session: Router main 98a8ec95 (ed7b7c27, ROUTER-3 ^2cc8d3f). RouterSessionDirectory appends a line to the sessions.jsonl of the recording root when a new root session registers. Roots come from `directory.useRecordingRoots(_:)`. Forks, subagents and restored roots append nothing. If ACPAgent also appends, each new root gets two lines (the last line wins, so nothing breaks, but the file grows twice as fast).

## Why ACPAgent cannot stop yet
`PromptExecution.makeFirstActivity` (PromptExecution.swift:1040-1053) writes the line at the FIRST PROMPT, with:
- `title` from the first prompt;
- `additionalDirectories`, which session/list returns (SessionList.swift:135);
- `cwd` and `updatedAt`.
A session with zero prompts is not listed. Router writes at register, with no title and empty additionalDirectories.

## Waits on
The Router answer, as asked 2026-10-22:
- (a) An API to give the title and additionalDirectories, and to write at the first prompt; or
- (b) A switch to turn off the Router write.

## Change, when the Router API is in
- Give Router the recording roots (`useRecordingRoots`).
- Hand it the title and the extra roots at the first prompt.
- Remove the ACPAgent append (`makeFirstActivity` / the FirstActivity write).
- Keep the delete path (SessionLifecycle.swift:339) consistent with whoever owns the file.

## Done when
- A failing test first (TDD): a new session with one prompt has exactly one sessions.jsonl line, with its title and additionalDirectories, and a session with no prompt has no line (unless the Router answer changes that rule; then write it down here).
- The full `swift test` passes. #router-3 #blocked-upstream