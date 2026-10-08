"""
swebench_clone.py -- hide the dotfolder of the agent from git in the clone of
an instance.

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

This module needs the standard library only.
"""
from pathlib import Path

# The pattern that hides the dotfolder of the agent, in gitignore syntax.
AGENT_FOLDER_PATTERN = ".acp-agent/"
# The ignore file of the clone that git does not track, below the clone.
INFO_EXCLUDE = Path(".git") / "info" / "exclude"


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
