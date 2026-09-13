---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2b522jajtmcd0yh1nr0cr0h
  text: |-
    ### finish — this task is not done, and the loop did not start it

    A `/finish` batch reached this card and left it in `todo` on purpose.

    **Why.** Each of the five steps of this card needs the measurement of step 1 first: "a run of 10 instances with a large limit (for example 7200 s), so no instance is stopped." That run holds the machine for many hours, and it uses the GPU for all of that time. An automatic loop must not start work of that size on the machine of a person who did not ask for it in that moment.

    **Everything this card needs is now in place.** The seven cards before it are done and committed:

    - The driver builds the Python environment of each instance, so the hours no longer go to that work.
    - One agent process serves the whole run, so the models load one time. The run reports `load_seconds`.
    - The run writes `bench/preds.runs.jsonl`, with `seconds`, `clone_seconds`, `agent_seconds` and `env_seconds` for each instance. Step 2 of this card reads that file.
    - `--sample 10 --seed S` gives ten instances that this machine can build, in the ratio of the repositories.

    **The command to give.** Build the release first, because a debug build is much slower for MLX:

    ```bash
    swift build -c release
    uv run bench/swebench_run.py bench/preds.jsonl --sample 10 --seed 1 --timeout 7200 | tee bench/run.log
    ```

    Then read `bench/preds.runs.jsonl`, take the 95th percentile of `seconds`, set `DEFAULT_TIMEOUT_S` above it, and write the measurement with its date and its machine in `bench/README.md`.

    **One condition of [[bench-drive-the-long-lived-acp-server-to-load-the-models-one-time]] waits here too**: "a measurement shows the time each instance saves." The `load_seconds` of that same run answers it.
  timestamp: 2026-09-12T15:51:28.586523+00:00
- actor: claude-code
  id: 01m2dsrgmtywgcg9z2tkc3rwfz
  text: |-
    ### complete — the limit is changed, and the measurement came from the run we had

    The person who owns this work decided not to do a run of many hours only to
    measure. The measurement came from the 16 transcripts of the run of
    2026-09-11 instead.

    | Group | Instances | The longest of the group |
    |---|---|---|
    | Finished on their own | 14 | 2628 s |
    | Stopped by the watchdog at 3600 s | 2 | 3600 s |

    Both of the stopped instances were building a Python environment when the
    watchdog stopped them. The driver builds that environment before the turn of
    the agent starts now, so that work is no longer in this budget.

    `DEFAULT_TIMEOUT_S` is 3000 s. It is above every instance that finished, and
    below the hour that the environment work made necessary.

    **What changed** (commit `3ace4b1`, local and not pushed):

    - `bench/swebench_run.py` — the constant, with the measurement and its
      conditions in the comment beside it.
    - `bench/README.md` — the option table, the "What to expect" bullet, and a new
      part, "Where the limit comes from".

    Tests: 196 Python tests pass, and `ruff check bench` is clean. No Swift source
    changed.

    **Steps 1 to 5 of the description are not done as they were written, and they
    will not be.** A figure that one run of one machine writes into prose goes
    stale in silence, and nothing can detect that. The durable answer was already
    in place before this card: each run writes `seconds` for each instance in
    `bench/preds.runs.jsonl`, and the summary counts the instances that reached
    the limit on its `too slow` line. So the evidence comes back with every run,
    and no person must do a run only to measure. The README says to read the run
    and not the sentence.

    One condition of [[bench-drive-the-long-lived-acp-server-to-load-the-models-one-time]]
    asked for the time each instance saves. `load_seconds` of any run answers it,
    and that card is in done already.
  timestamp: 2026-09-13T16:31:44.282359+00:00
depends_on:
- 01M2ANS2RQV9D4E4MPXM3FDCVH
- 01M2ANQZRKDTF7DQZ99N1BW41E
position_column: done
position_ordinal: dd80
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