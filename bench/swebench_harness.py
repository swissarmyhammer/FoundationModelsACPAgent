"""
swebench_harness.py -- the call of the SWE-bench harness, and the kind of its errors.

`swebench_score.py` calls `swebench.harness.run_evaluation.main`. Two rules
hold for that call, and this file holds both:

  * The call agrees with the pinned harness. The keyword names come from
    `HARNESS_PARAMETERS`, and that tuple is the signature of `main` in
    swebench==5.0.2. A name that the harness does not know makes a
    TypeError before docker starts.

  * Only a docker failure goes on to the tally. A docker failure (a pull, a
    container, exit 137) is a machine condition, and a second try can
    correct it. Any other error, for example that TypeError, is a defect of
    the score script. A second try cannot correct it, and it is NOT a memory
    failure. So `call_harness` raises `HarnessCallError` for it, and the
    script stops with a message that names the error.

This file uses only the standard library. The tests of the harness thus
prove it without swebench and without docker.
"""

# The parameters of `swebench.harness.run_evaluation.main` in swebench==5.0.2,
# in their order. The pin in swebench_score.py and this tuple change together.
# When swebench is installed, a test compares this tuple with the real
# signature.
HARNESS_PARAMETERS = (
    "dataset_name",
    "split",
    "instance_ids",
    "predictions_path",
    "max_workers",
    "open_file_limit",
    "run_id",
    "timeout",
    "rewrite_reports",
    "modal",
    "report_dir",
    "task_repo",
)
# The limit of open files for the harness. The harness sets it on Linux only.
OPEN_FILE_LIMIT = 4096
# Where the harness writes its own run report. The score report of this
# script goes beside the predictions, and not here.
REPORT_DIR = "."
# A class from these modules is a docker failure. The docker library raises
# from `docker.errors` (APIError, ImageNotFound, BuildError, ContainerError).
DOCKER_ERROR_MODULE = "docker."
# The harness raises this class when it cannot get the image of an instance.
HARNESS_IMAGE_ERROR = "swebench.harness.utils.EvaluationError"
# The platform of the published SWE-bench images. They have no arm64 manifest.
# The harness pulls an image with no platform, so on Apple Silicon docker asks
# for linux/arm64 and the pull fails with "no matching manifest" (a 404). So
# the score script pulls each image for this platform before the harness starts.
IMAGE_PLATFORM = "linux/amd64"
# The text of a docker failure that says docker stopped a container for memory.
MEMORY_MARKS = ("137", "oom", "out of memory")


class HarnessCallError(Exception):
    """The harness raised an error that is not a docker failure.

    - cause: the error that the harness raised.

    This is a defect of the score script, and not of the agent or of docker.
    The message names the type and the text of the cause.
    """

    def __init__(self, cause):
        self.cause = cause
        super().__init__(
            "the harness call failed with an error that is not a docker "
            f"failure: {type(cause).__name__}: {cause}. This is a defect of "
            "bench/swebench_score.py, and not of the agent or of docker. "
            "This script does no second try, and there is no score."
        )


def harness_arguments(
    *,
    dataset_name,
    split,
    instance_ids,
    predictions_path,
    max_workers,
    run_id,
    timeout,
):
    """Return the keyword arguments of one harness pass.

    - dataset_name, split: the SWE-bench dataset.
    - instance_ids: the ids to evaluate.
    - predictions_path: the path of predictions.jsonl.
    - max_workers: how many docker workers run together.
    - run_id: the harness run id.
    - timeout: the test limit of one instance, in seconds.

    The keys are the names of `HARNESS_PARAMETERS`, each one time. The run is
    local (no Modal), it writes new reports, and it uses the dataset and not a
    task repo.
    """
    return {
        "dataset_name": dataset_name,
        "split": split,
        "instance_ids": list(instance_ids),
        "predictions_path": str(predictions_path),
        "max_workers": max_workers,
        "open_file_limit": OPEN_FILE_LIMIT,
        "run_id": run_id,
        "timeout": timeout,
        "rewrite_reports": False,
        "modal": False,
        "report_dir": REPORT_DIR,
        "task_repo": None,
    }


def is_docker_failure(error):
    """Return True when `error` is a docker failure.

    - error: the error that the harness raised.

    The test reads the class names, and imports no docker module. A subclass
    of a docker class is a docker failure too.
    """
    for kind in type(error).__mro__:
        name = f"{kind.__module__}.{kind.__qualname__}"
        if kind.__module__.startswith(DOCKER_ERROR_MODULE):
            return True
        if name == HARNESS_IMAGE_ERROR:
            return True
    return False


def is_memory_failure(error):
    """Return True when the text of a docker failure says exit 137 or OOM.

    - error: a docker failure.
    """
    text = str(error).lower()
    return any(mark in text for mark in MEMORY_MARKS)


def call_harness(run, arguments):
    """Do one harness pass, and return its docker failure or None.

    - run: the harness function, `swebench.harness.run_evaluation.main`.
    - arguments: the keyword arguments from `harness_arguments`.

    A docker failure is returned, so the caller logs it and reads the
    reports that completed. Any other error raises `HarnessCallError`.
    """
    try:
        run(**arguments)
    except Exception as error:
        if is_docker_failure(error):
            return error
        raise HarnessCallError(error) from error
    return None
