"""
swebench_record.py -- the machine-readable record of one instance of a run.

`swebench_run.py` writes a prediction row for each instance, and that row holds
the patch alone. The duration, the exit code and the shape of the patch go to
standard output, so a run keeps them only if you add `| tee`.

The run of 2026-09-11 kept no log. To find why the instances were slow, all of
the time data had to be built again from the transcripts in
`bench/preds.transcripts/`. That work is not necessary if the harness records
it.

So a run writes a second file beside the predictions, `<stem>.runs.jsonl`, with
one row for each instance:

| Field | What it is |
|---|---|
| `instance_id` | the instance |
| `seconds` | the wall time of the instance |
| `clone_seconds` | the time of the clone and the checkout |
| `agent_seconds` | the time of the turn of the agent |
| `exit_code` | the exit code of an agent process that ENDED in this instance |
| `stop_reason` | why the agent stopped the turn |
| `timed_out` | whether the watchdog stopped it |
| `patch_bytes` | the size of the patch |
| `patch_files` | the count of files in the patch |
| `transcript_path` | where the transcripts are |
| `env_status` | what the environment step did: built, failed or unsupported |
| `env_python` | the Python version of the environment |
| `env_seconds` | the time of the environment step |
| `env_exit_code` | the exit code of the build command that failed |
| `env_reason` | why the instance did not run |

The five `env_` names hold the step that `swebench_venv.py` does. That step is
the largest cost of an instance after the agent, and it is the step that
decides whether the agent starts at all. A run that leaves 121 instances of
the Lite split out must say why it left each one out, and `env_reason` is
where it says so.

`stop_reason` and `exit_code` are a pair, and the long-lived agent of
`swebench_acp.py` is the reason they are two names. ONE agent process serves
the whole run, so an instance that ended with that process alive has no exit
code of its own: `exit_code` holds the code of a process that ENDED in this
instance, and `null` in every other condition. `stop_reason` is the word of
the protocol for how the turn ended -- `end_turn`, `max_tokens`,
`max_turn_requests`, `refusal`, `cancelled`, or an extension that begins with
`_`. It is a free string, and the record keeps whatever the agent said.

Each row carries all fifteen names, in all conditions. A step that did not run
gives `null`, and not a name that is absent, so a reader of the file can use
`[]` on each row. `append_row` flushes each row, so a run that stops in the
middle keeps the rows of the instances that are complete.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import json

# The word that starts the header of each file of a unified diff. `git diff`
# writes it in lower case, in all conditions, so the match reads the case. A
# line of a body starts with a space, a `+` or a `-`, so a header is the only
# line that starts with this word.
FILE_HEADER = "diff --git "
# The encoding of the patch on disk. The predictions file is JSON, and JSON
# is UTF-8, so a byte of this encoding is a byte of that file.
PATCH_ENCODING = "utf-8"
# How many digits of a second the record keeps. A clock gives more digits
# than a reader of a run can use, and three digits are one millisecond.
SECONDS_DIGITS = 3
# The name of the record file, below the stem of the predictions file:
# `preds.jsonl` -> `preds.runs.jsonl`. The `.gitignore` of the bench
# directory keeps `*.runs.jsonl` out of git.
RUNS_SUFFIX = ".runs.jsonl"


def runs_path(outpath):
    """The file that holds the record of each instance of a run.

    - outpath: the predictions file of the run.

    It stands beside the predictions file, with the same stem, exactly as
    the transcripts of a run do. A reader thus learns one rule and finds
    every result of a run.
    """
    return outpath.parent / f"{outpath.stem}{RUNS_SUFFIX}"


def patch_file_count(patch):
    """The count of files in a unified diff.

    - patch: the diff, from `git diff <base_commit>`.

    This counts the header that `git diff` writes in front of each file.
    """
    return sum(1 for line in patch.splitlines() if line.startswith(FILE_HEADER))


def seconds_of(duration):
    """One duration, in the form the record keeps.

    - duration: the duration in seconds, or None when the step did not run.

    A step that did not run gives None, and the row then holds `null`.
    """
    if duration is None:
        return None
    return round(duration, SECONDS_DIGITS)


def run_record(
    instance_id,
    *,
    seconds,
    clone_seconds,
    agent_seconds,
    exit_code,
    stop_reason,
    timed_out,
    patch,
    transcript_path,
    env_status,
    env_python,
    env_seconds,
    env_exit_code,
    env_reason,
):
    """The record of one instance of a run.

    - instance_id: the id of the SWE-bench instance.
    - seconds: the wall time of the whole instance.
    - clone_seconds: the time of the clone and the checkout, or None.
    - agent_seconds: the time of the turn of the agent, or None.
    - exit_code: the exit code of an agent process that ENDED in this
      instance, or None. One process serves the whole run, so an instance
      that ended with the agent alive has no exit code of its own.
    - stop_reason: why the agent stopped the turn, or None when the turn
      never reached an idle update.
    - timed_out: True when the watchdog stopped the agent at the time limit.
    - patch: the diff of the agent. The record measures it, and keeps the
      diff itself out: the prediction row holds that.
    - transcript_path: where the transcripts of the instance are, or None.
    - env_status: what the environment step did, or None when it did not run.
    - env_python: the Python version of the environment, or None.
    - env_seconds: the time of the environment step, or None.
    - env_exit_code: the exit code of the build command that failed, or None.
    - env_reason: why the instance did not run, or None when it ran.

    The record carries all fifteen names in all conditions, so that a reader
    can use `[]` on each row of the file.
    """
    return {
        "instance_id": instance_id,
        "seconds": seconds_of(seconds),
        "clone_seconds": seconds_of(clone_seconds),
        "agent_seconds": seconds_of(agent_seconds),
        "exit_code": exit_code,
        "stop_reason": stop_reason,
        "timed_out": timed_out,
        "patch_bytes": len(patch.encode(PATCH_ENCODING)),
        "patch_files": patch_file_count(patch),
        "transcript_path": None if transcript_path is None else str(transcript_path),
        "env_status": env_status,
        "env_python": env_python,
        "env_seconds": seconds_of(env_seconds),
        "env_exit_code": env_exit_code,
        "env_reason": env_reason,
    }


def append_row(stream, row):
    """Write one row to a JSON Lines file, and put it on the disk.

    - stream: the open file, in append mode.
    - row: the record to write.

    The flush is the point. A run of many hours can stop at any instance,
    and the rows of the instances that are complete must survive that.
    """
    stream.write(json.dumps(row) + "\n")
    stream.flush()
