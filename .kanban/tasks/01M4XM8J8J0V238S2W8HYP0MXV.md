---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xms4wn1psgjx8k0vh9mx37
  text: 'Done in the working tree (commit with the final T6 run). ACP_AGENT_STUB_CHUNK_DELAY_MS is replaced by ACP_AGENT_STUB_CHUNK_GATE: the path of a named pipe. The stub (GatedStubModel.swift) reads one byte before each chunk on a serial queue (a blocking kernel read); at the end of the pipe each later chunk goes at once. ComposedAgent.compose(stubChunkDelay:) becomes compose(stubChunkGate:) (public API; only the CLI calls it; no demo used the delay). SignalledExecutableRun(chunkGate:) lets the first chunk go, waits for the first output and atFirstOutput, then: no signal → close the gate; signals → send them while the prompt is held, close after the exit. InterruptTests and OutOfProcessTests: 4 tests pass in one filtered run.'
  timestamp: 2026-10-14T16:43:56.693300+00:00
position_column: todo
position_ordinal: '8980'
title: 'T6: replace the stub chunk delay of the interrupt tests with a hold'
---
The spawned stub model of acp-agent paces its chunks with a real delay (ACP_AGENT_STUB_CHUNK_DELAY, 180 ms in IntegrationTests InterruptTests and OutOfProcessTests). The interrupt tests depend on it: the signal must land before the chunks end. That is a time dependency.

Do: the stub waits on a kernel event (a pipe) before each chunk, and the test lets it go on after the signal landed. Then the signal always lands before the chunks end, with no clock. If the delay is also used outside tests (a demo), keep it as an option for that use only.

Decision of the step lead, 2026-10-14. #mail-step-4