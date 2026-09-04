---
assignees:
- claude-code
depends_on:
- 01M1MP6PBZ3X4FAA6CVCFKR6VW
position_column: todo
position_ordinal: '9780'
title: 'acp-client N6: --timeout, the interrupt, and the reaping proofs'
---
### What

Upstream work in `../FoundationModelsACPClient`, milestone **N6** of its
`cli-plan.md` §11.

- `--timeout <seconds>`: end the run if the turn does not stop in time,
  and exit 124, the `timeout(1)` convention.
- `Ctrl-C`: send `session/cancel`, wait for the `cancelled` stop reason,
  print the text that arrived, reap the agent, exit 4. A second `Ctrl-C`
  ends the run at once, and it still reaps the agent.
- Use a `DispatchSourceSignal`, and do the work on a normal task. The
  handler body only sets a flag, because a signal handler must be
  async-signal-safe.

**The obligation this card exists for: no agent process outlives the
run.** This holds after success, after a failure, after a timeout, and
after an interrupt. `AgentProcess` already spawns the agent in its own
process group; this card proves the reaping.

A leaked agent holds gigabytes of model weights, so each exit path gets
its own test.

- [ ] `--timeout`, and exit 124
- [ ] The first and the second `Ctrl-C`
- [ ] Reap the agent in every exit path

### Acceptance Criteria

- [ ] A turn that runs past `--timeout` exits 124.
- [ ] A `SIGINT` during a turn exits 4, and the partial text is on
      stdout.
- [ ] A second `SIGINT` ends the run inside a short, named time limit.
- [ ] After each of success, failure, timeout and interrupt, no process
      in the agent's process group is alive.
- [ ] The `DispatchSourceSignal` handler body only sets a flag.

### Tests

- [ ] A timeout test against a stub that never finishes: exit 124.
- [ ] An interrupt test: exit 4, and the recording client shows a
      `session/cancel` reached the agent before the exit.
- [ ] A second-interrupt test with a time bound.
- [ ] One reaping test per exit path: after the run, the agent's process
      group holds no live process.
- [ ] A source-level test that the signal handler body sets a flag and
      calls nothing else.
- [ ] `swift test` in `../FoundationModelsACPClient` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.