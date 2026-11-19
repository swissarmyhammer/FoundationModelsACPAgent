---
assignees:
- claude-code
depends_on:
- 01M7RWC0Q3R664RM3W2AGKNBVR
position_column: todo
position_ordinal: 8d80
title: 'D205: a tool fork copies the history up to its tool call also when the record of that call is late'
---
Found during ^agknbvr (2026-11-18).

## Current behavior

The launcher of this agent (`Agent/SessionForkLaunch.swift`) copies the retained ACP history of a tool fork (`fork session` with no id, cut `.callingToolCall`) when the Router asks it to build the fork. The copy ends before the tool call that forked, and the agent reads that call from its own retained history of the source. The Router sends the event of that call before the tool runs, but the agent records events asynchronously. If that record is late, the agent does not find the call, and the fork gets an EMPTY copy, not the turns before the call. No test makes the record late.

## Change

1. Before the copy, wait (with a time limit) until the retained history of the source holds the tool call of the fork. Use the Router fork request (`forkedAtHistoryOrdinal`, the source id) or the tool call id to know which call.
2. If the wait times out, fail the fork with a clear error, so the Router removes the fork folder. Do not make a fork with a wrong history.

## Tests

- A tool fork where the record of the calling tool call is held back until after the launcher starts: the fork has the turns before the call.
- A tool fork where the record never comes: the fork call fails with the clear error, and no fork is registered. #d205 #fork