"""
swebench_report.py -- the report that a score run writes beside the patches.

`swebench_score.py` writes the table of a run to standard output, and it
writes this report to a file. The table is for a person, and the report is the
durable record: a person quotes the number in it weeks later.

So the report follows four rules.

  * **The score is resolved / EVALUATED.** An instance that did not run,
    because docker could not build its image, stays out of the divisor. A
    memory failure of the machine is not a failure of the agent. That instance
    is reported alone, by its id.
  * **A run that evaluated nothing writes no report.** The run of 2026-09-11
    wrote `"submitted": 16, "evaluated": 0, "resolved": 0` when docker was not
    running at all. A reader of that file sees a failure of the agent, and the
    file says nothing about the true cause. No file is better than a false
    one, so `write_report` gives None and writes nothing.
  * **The report stands beside the predictions, and nowhere else.** The run id
    comes from the command line, and it becomes part of the name of the report
    file. A run id such as `../../etc/hostname` would put that file outside
    the directory of the predictions. So `checked_run_id` refuses a run id
    that is not a NAME, and each function that takes a run id calls it.
  * **Each group gives a count, and the ids stand in the `_ids` names.** The
    report gave a LIST at `errored` before 2026-09-12, and a count at each of
    the three groups beside it. A reader who took `errored` for a count, as
    `unresolved` beside it is a count, got a list. So `errored` is the count
    of the instances that did not run, and `errored_ids` holds their ids
    alone. A report of an older run still holds a list at `errored`, and
    `bench/README.md` says so.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import json
import re

# The name of the report, below the name of the predictions file:
# `preds.jsonl` -> `preds.jsonl.score.<run id>.json`. The run id is part of
# the name, because you can score one predictions file many times. The
# `.gitignore` of the bench directory keeps `*.score.*.json` out of git.
REPORT_SUFFIX = ".score.{run_id}.json"
# The shape of a run id that this module accepts: a letter or a digit, and
# then letters, digits, dot, dash and underline. A name of this shape holds
# no separator of a path, it is not `.` and it is not `..`, and it is not
# empty. So it can name a file in a directory, and it can name NOTHING
# outside that directory. The run id that the score step makes has this
# shape: `score_20260912_090000`.
RUN_ID_SHAPE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# What a person reads when the run id is not a name.
RUN_ID_REFUSED = (
    "the run id {run_id!r} is not a name. A run id begins with a letter or a "
    "digit, and after that it holds letters, digits, dot, dash and underline "
    "only, because it becomes part of the path of the report."
)
# How many spaces one level of the JSON gets. A person reads this file.
REPORT_INDENT = 2
# A part of one hundred is a percent.
PERCENT = 100
# The percentage of a run with nothing in the divisor. Zero of zero is not a
# number, and a report must hold a number.
NO_PERCENT = 0.0


class RunIdError(ValueError):
    """A run id that cannot become part of the path of the report.

    This error has a name of its own, so that a caller can catch this
    condition alone and say what a person must do. It is a `ValueError`,
    because a run id that is not a name is a bad VALUE of an argument, and a
    caller that knows only the errors of the standard library still works.
    """


def checked_run_id(run_id):
    """The run id, when it is a name. A `RunIdError`, when it is not.

    - run_id: the run id of the harness.

    This is the one gate of the module. The run id comes from `--run-id` on
    the command line, and it then becomes part of a path: the name of the
    report file here, and the directory of the logs in the harness. A run id
    such as `../../etc/hostname` is thus a way to write outside the directory
    of the predictions, and `RUN_ID_SHAPE` is the shape that cannot do it.

    Each function of this module that takes a run id calls this one, because
    a gate that one door of three holds is not a gate.
    """
    if isinstance(run_id, str) and RUN_ID_SHAPE.fullmatch(run_id):
        return run_id
    raise RunIdError(RUN_ID_REFUSED.format(run_id=run_id))


def report_path(predictions, run_id):
    """The file that holds the report of one score run.

    - predictions: the predictions file that the run scored.
    - run_id: the run id of the harness.

    It stands beside the predictions file, exactly as the record and the
    transcripts of a run do. A reader thus learns one rule and finds every
    result of a run. A run id that is not a name is refused, because the
    report must stand there and nowhere else.
    """
    name = REPORT_SUFFIX.format(run_id=checked_run_id(run_id))
    return predictions.with_suffix(predictions.suffix + name)


def part_of(count, total):
    """The part that one count is of a total, as a percentage.

    - count: the instances that resolved.
    - total: the instances in the divisor.

    A total of zero gives `NO_PERCENT`, because zero of zero is not a number.
    """
    if not total:
        return NO_PERCENT
    return PERCENT * count / total


def score_report(run_id, *, predictions, submitted, evaluated, resolved,
                 errored, minutes):
    """The report of one score run.

    - run_id: the run id of the harness.
    - predictions: the predictions file that the run scored.
    - submitted: how many instances the run sent to the harness.
    - evaluated: the ids of the instances that ran.
    - resolved: the ids of the instances whose tests passed.
    - errored: the ids of the instances that did not run.
    - minutes: the wall time of the run.

    Each group gives a COUNT at its own name -- `evaluated`, `resolved`,
    `unresolved`, `errored` -- and the ids of a group stand in the `_ids`
    name of that group. A reader thus reads each group the same way, and
    can still find the instances again. The first percentage is the honest
    score: an instance that did not run is not in its divisor.

    A run id that is not a name is refused here too, because `write_report`
    reads the run id back out of the report to make the path of the file.
    """
    unresolved_ids = sorted(set(evaluated) - set(resolved))
    resolved_ids = sorted(resolved)
    errored_ids = list(errored)
    return {
        "run_id": checked_run_id(run_id),
        "predictions": str(predictions),
        "submitted": submitted,
        "evaluated": len(set(evaluated)),
        "resolved": len(resolved_ids),
        "unresolved": len(unresolved_ids),
        "errored": len(errored_ids),
        "resolved_ids": resolved_ids,
        "unresolved_ids": unresolved_ids,
        "errored_ids": errored_ids,
        "resolved_pct_of_evaluated": part_of(
            len(resolved_ids), len(set(evaluated))
        ),
        "resolved_pct_of_submitted": part_of(len(resolved_ids), submitted),
        "wall_minutes": minutes,
    }


def write_report(predictions, report):
    """Write the report beside the predictions, and give the path.

    - predictions: the predictions file that the run scored.
    - report: the report that `score_report` made.

    Gives None, and writes NOTHING, when the run evaluated no instance. Such
    a report says `"resolved": 0`, and a reader takes that for a failure of
    the agent. Docker is the cause of an empty run, and the caller says so on
    the console.

    Raises a `RunIdError`, and writes nothing, when the run id of the report
    is not a name. A report can come from a file, and a file holds anything.
    """
    if not report["evaluated"]:
        return None
    path = report_path(predictions, report["run_id"])
    path.write_text(json.dumps(report, indent=REPORT_INDENT) + "\n")
    return path
