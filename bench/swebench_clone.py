"""
swebench_clone.py -- clone the repository of an instance, and hide the
dotfolder of the agent from git in that clone.

The agent writes its config and its transcripts into `<clone>/.acp-agent/`.
The git tools of the agent read the status of the clone, so
`tools.git.status` listed those files as untracked, and `tools.git.diff({})`
put them first. On 2026-10-08 that diff result was 15059 characters, and the
4000-character limit of a runCode result cut it before the change of the
agent (task ^exkkyyr).

`<clone>/.git/info/exclude` is the ignore file of one repository that git
does not track. A pattern there hides the folder from `git status` and from
the git tools, and the tracked `.gitignore` does not change. That matters:
the prediction is `git diff <base_commit>`, and a change to a tracked file
would be part of the patch.

A clone goes over the network, and a flaky network can stall or break it
(2026-11-09: the clone of django__django-13447 hung 13 minutes, then failed
with exit 128, and the run lost the instance). `clone_repository` gives each
try a time limit, and it tries again after a wait that grows.

This module needs the standard library only.
"""
import shutil
import subprocess
import time
from pathlib import Path

# The pattern that hides the dotfolder of the agent, in gitignore syntax.
AGENT_FOLDER_PATTERN = ".acp-agent/"
# The ignore file of the clone that git does not track, below the clone.
INFO_EXCLUDE = Path(".git") / "info" / "exclude"
# How many times a clone is tried before the run gives up on the instance.
CLONE_ATTEMPTS = 5
# The longest that one try of a clone can take, in seconds. A full clone of
# django takes about 30 s on a good network; a stalled one never ends.
CLONE_TIMEOUT_S = 600
# The wait before the second try, in seconds. Each later wait is two times
# the one before it: 15, 30, 60, 120.
CLONE_FIRST_WAIT_S = 15


def clone_repository(url, dest, *, run=subprocess.run, sleep=time.sleep):
    """Clone url into dest, and try again when the network fails.

    - url: the URL of the repository.
    - dest: the folder of the clone. A part of a clone from a failed try is
      removed before the next try.
    - run, sleep: the runner and the wait, for a test.

    Raises the error of the last try when each try fails.
    """
    dest = Path(dest)
    wait = CLONE_FIRST_WAIT_S
    for attempt in range(1, CLONE_ATTEMPTS + 1):
        shutil.rmtree(dest, ignore_errors=True)
        try:
            run(["git", "clone", "--quiet", url, str(dest)],
                check=True, capture_output=True, timeout=CLONE_TIMEOUT_S)
            return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if attempt == CLONE_ATTEMPTS:
                raise
            sleep(wait)
            wait *= 2


def exclude_agent_folder(repo):
    """Add the dotfolder of the agent to the local ignore file of the clone.

    - repo: the clone of the instance.

    The lines that are in the file stay. A second call adds no second line.
    """
    exclude = Path(repo) / INFO_EXCLUDE
    exclude.parent.mkdir(parents=True, exist_ok=True)
    text = exclude.read_text() if exclude.exists() else ""
    if AGENT_FOLDER_PATTERN in text.splitlines():
        return
    if text and not text.endswith("\n"):
        text += "\n"
    exclude.write_text(f"{text}{AGENT_FOLDER_PATTERN}\n")
