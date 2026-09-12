---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'bench: write a machine-readable record of each instance'
---
## The problem

`bench/swebench_run.py` writes three fields for each instance: `instance_id`,
`model_name_or_path` and `model_patch`. The duration, the exit code and the
count of rounds go to standard output only, and a run keeps them only if you
add `| tee`.

The run of 2026-09-11 kept no log. To find why instances were slow, all of the
time data had to be built again from the transcripts in
`bench/preds.transcripts/`. That work is not necessary if the harness records
it.

## The work

Write a second file beside the predictions, `<stem>.runs.jsonl`, with one row
for each instance. Each row holds:

| Field | What it is |
|---|---|
| `instance_id` | the instance |
| `seconds` | the wall time of the instance |
| `clone_seconds` | the time of the clone and the checkout |
| `agent_seconds` | the time of the agent process |
| `exit_code` | the exit code of the agent |
| `timed_out` | whether the watchdog stopped it |
| `patch_bytes` | the size of the patch |
| `patch_files` | the count of files in the patch |
| `transcript_path` | where the transcripts are |

Write each row when its instance ends, and flush. A run that stops in the
middle must keep the rows of the instances that are complete.

## When it is complete

- A run of two instances writes two rows.
- The rows hold the correct durations.
- The file is in the `.gitignore` of `bench/`. #bench