---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'bench: drive the long-lived acp server, to load the models one time'
---
## The problem

`bench/swebench_run.py` starts a new `acp-agent run` process for each instance.
The agent loads its local models again each time. The README of `bench/` says
this is minutes of each instance.

The SWE-bench Lite split holds 300 instances. About 179 of them can run on
this machine. Minutes of model loading, 179 times, is hours of the run.

## The work

The package already has a server: `acp-agent acp` serves ACP on standard input
and standard output. Drive that server instead, with one session for each
instance.

1. Start one `acp-agent acp` process for the full run.
2. Speak ACP JSON-RPC to it from the harness.
3. Open one session for each instance, with the cwd of the clone.
4. Send the problem statement, and wait for the turn to end.
5. Read the stop reason of the turn, and record it in the run record.
6. Start the process again if it stops, and go on with the next instance.

This also gives the harness the stop reason of each turn, which the one-shot
`run` command does not give it now.

## Before you start

Do the environment tasks first. This task changes how the harness speaks to
the agent, and it is of no value while a third of each instance goes to
building a Python environment.

## When it is complete

- One agent process serves a full run.
- The models load one time.
- The run record holds the stop reason of each turn.
- A measurement shows the time each instance saves.

Related: [[bench-write-a-machine-readable-record-of-each-instance]] #bench