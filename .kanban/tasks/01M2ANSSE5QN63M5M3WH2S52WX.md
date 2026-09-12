---
assignees:
- claude-code
depends_on:
- 01M2ANS2RQV9D4E4MPXM3FDCVH
- 01M2ANQZRKDTF7DQZ99N1BW41E
position_column: todo
position_ordinal: '8780'
title: 'bench: measure the instance limit again, after the environment work'
---
## The problem

`DEFAULT_TIMEOUT_S = 3600` in `bench/swebench_run.py`. That one hour was set
against a harness that gives the agent no Python environment.

The run of 2026-09-11 shows the limit is measuring the wrong thing. The full
run spent 7.5 hours, and 5.5 hours of that was inside the model. Of 707
`runCode` calls, 219 were about building an environment. The two instances that
went past the limit were both building an environment when they were stopped.

After the environment work, the limit must be set against the work that is
left: read the code, find the bug, and make the change.

## The work

1. Do a run of 10 instances with the environment prepared, with a large limit
   (for example 7200 s), so no instance is stopped.
2. Read the durations from the run record.
3. Set `DEFAULT_TIMEOUT_S` above the 95th percentile of that measurement.
4. Write the measurement in `bench/README.md`, with the date and the machine,
   in place of the sentence that says one hour.
5. Write the new figure in the "What to expect" part of the README.

## When it is complete

- The new limit comes from a measurement, and the README names it.
- A run of 10 instances stops none of them at the limit.
- The README no longer says an hour without a reason.

Related: [[bench-prepare-the-instance-environment-in-the-driver]] and
[[bench-write-a-machine-readable-record-of-each-instance]] #bench