---
depends_on:
- 01KY7EEGS0JJ5G6720FGSEBT3M
position_column: todo
position_ordinal: '8980'
title: 'Golden conformance tests: ReplayTransport + resume semantics'
---
Plan §9.1/§10-carryover. Drive the conformance over the wire package's ReplayTransport/InMemoryTransport with a scripted fake session backend: golden request/response transcripts for initialize/new/prompt/cancel; stable toolCallIds across two concurrent same-name tool calls; replay-from-full-history vs construct-from-checkpoint on resume; available_commands_update fires on registry change (streaming provider tick). Deterministic, no model. DEPENDS on the conformance task.