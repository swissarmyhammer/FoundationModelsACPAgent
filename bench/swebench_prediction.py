"""
swebench_prediction.py -- the row that a run writes for one instance.

`swebench_run.py` writes one JSON row for each instance, and that file is the
durable record of a run. `swebench_score.py` reads the file again, as many
times as you must. A row that holds the work is thus better than a row that
holds nothing.

The old harness did not keep the work. It removed the patch of an instance
that went past the time limit, because a half-written tree is not an answer.
But a stopped tree can hold the correct answer. In the run of 2026-09-11 the
watchdog stopped `astropy__astropy-14182` at the limit of one hour, and the
tree held the two correct files for that issue:

    M astropy/io/ascii/rst.py
    M astropy/io/ascii/tests/test_rst.py

The harness recorded an empty patch, and that work was lost.

So the row keeps the patch in all conditions, and it carries `truncated` when
the watchdog stopped the agent. The run step keeps the work, and the score
step decides what to do with it.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block
of a module that the script imports. This module needs the standard library
only.
"""

# The three names that the official SWE-bench harness reads from each row. Do
# not change them: the harness finds the instance, the report name and the
# diff with these, and nothing else.
INSTANCE_KEY = "instance_id"
MODEL_KEY = "model_name_or_path"
PATCH_KEY = "model_patch"
# The name that says the watchdog stopped the agent before it finished. The
# harness does not read it, and the score step decides what to do with it. A
# row of an earlier run does not have it, so a reader uses `get`.
TRUNCATED_KEY = "truncated"


def prediction_row(instance_id, model_name, patch, *, truncated):
    """The prediction row of one instance.

    - instance_id: the id of the SWE-bench instance.
    - model_name: the name that the score report gives to this run.
    - patch: the diff of the agent, from `git diff <base_commit>`.
    - truncated: True when the watchdog stopped the agent at the time limit.

    The row keeps the patch in all conditions. A stopped agent gets the
    `truncated` name as well, and a finished agent gets the three names of
    the harness alone. A finished row is thus the same as the row of an
    earlier run, and a file of many runs keeps one shape.
    """
    row = {
        INSTANCE_KEY: instance_id,
        MODEL_KEY: model_name,
        PATCH_KEY: patch,
    }
    if truncated:
        row[TRUNCATED_KEY] = True
    return row
