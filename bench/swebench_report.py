"""
swebench_report.py -- the report that a score run writes beside the patches.

`swebench_score.py` writes the table of a run to standard output, and it
writes this report to a file. The table is for a person, and the report is the
durable record: a person quotes the number in it weeks later.

So the report follows two rules.

  * **The score is resolved / EVALUATED.** An instance that did not run,
    because docker could not build its image, stays out of the divisor. A
    memory failure of the machine is not a failure of the agent. That instance
    is reported alone, by its id.
  * **A run that evaluated nothing writes no report.** The run of 2026-09-11
    wrote `"submitted": 16, "evaluated": 0, "resolved": 0` when docker was not
    running at all. A reader of that file sees a failure of the agent, and the
    file says nothing about the true cause. No file is better than a false
    one, so `write_report` gives None and writes nothing.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""
import json

# The name of the report, below the name of the predictions file:
# `preds.jsonl` -> `preds.jsonl.score.<run id>.json`. The run id is part of
# the name, because you can score one predictions file many times. The
# `.gitignore` of the bench directory keeps `*.score.*.json` out of git.
REPORT_SUFFIX = ".score.{run_id}.json"
# How many spaces one level of the JSON gets. A person reads this file.
REPORT_INDENT = 2
# A part of one hundred is a percent.
PERCENT = 100
# The percentage of a run with nothing in the divisor. Zero of zero is not a
# number, and a report must hold a number.
NO_PERCENT = 0.0


def report_path(predictions, run_id):
    """The file that holds the report of one score run.

    - predictions: the predictions file that the run scored.
    - run_id: the run id of the harness.

    It stands beside the predictions file, exactly as the record and the
    transcripts of a run do. A reader thus learns one rule and finds every
    result of a run.
    """
    suffix = predictions.suffix + REPORT_SUFFIX.format(run_id=run_id)
    return predictions.with_suffix(suffix)


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

    The report holds the counts and the ids of each group, so that a reader
    can find the instances again. The first percentage is the honest score:
    an instance that did not run is not in its divisor.
    """
    unresolved_ids = sorted(set(evaluated) - set(resolved))
    resolved_ids = sorted(resolved)
    errored_ids = list(errored)
    return {
        "run_id": run_id,
        "predictions": str(predictions),
        "submitted": submitted,
        "evaluated": len(set(evaluated)),
        "resolved": len(resolved_ids),
        "unresolved": len(unresolved_ids),
        "errored": errored_ids,
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
    """
    if not report["evaluated"]:
        return None
    path = report_path(predictions, report["run_id"])
    path.write_text(json.dumps(report, indent=REPORT_INDENT) + "\n")
    return path
