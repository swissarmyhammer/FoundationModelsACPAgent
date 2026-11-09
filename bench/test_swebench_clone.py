#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_clone.py -- the proof that the clone of an instance hides the
dotfolder of the agent from git, and that the patch does not change.

The agent writes its config and its transcripts into `<clone>/.acp-agent/`.
`tools.git.status` listed those files as untracked, and `tools.git.diff`
put them first, so the 4000-character limit of a runCode result cut the
change of the agent (task ^exkkyyr). The run now puts `.acp-agent/` into
`<clone>/.git/info/exclude`, which is local to the clone. The tracked
`.gitignore` does not change, so `git diff <base_commit>` stays the patch of
the agent only.

Git runs on a temporary directory only, with no network. Both commands run it:

    uv run bench/test_swebench_clone.py
    python3 bench/test_swebench_clone.py
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

from swebench_clone import AGENT_FOLDER_PATTERN, clone_repository, exclude_agent_folder

# The settings that each git command of a test needs to make a commit.
GIT_IDENTITY = ["-c", "user.name=bench test", "-c", "user.email=bench@example.invalid"]
# The tracked file of the test repository.
A_FILE = "module.py"
# The tracked ignore file of the test repository, and its text.
GITIGNORE = ".gitignore"
GITIGNORE_TEXT = "*.pyc\n"


def git(repo, *args):
    """Run one git command in repo, and give its standard output.

    - repo: the directory of the repository.
    - args: the arguments of the git command.
    """
    return subprocess.run(
        ["git", "-C", str(repo), *GIT_IDENTITY, *args],
        capture_output=True, text=True, check=True,
    ).stdout


class TheDotfolderOfTheAgent(unittest.TestCase):
    """How the clone hides `.acp-agent/` from git."""

    def setUp(self):
        """Make a repository with one commit, a change of the agent, and agent files."""
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "--quiet")
        (self.repo / A_FILE).write_text("x = 1\n")
        (self.repo / GITIGNORE).write_text(GITIGNORE_TEXT)
        git(self.repo, "add", A_FILE, GITIGNORE)
        git(self.repo, "commit", "--quiet", "-m", "the base commit")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()
        (self.repo / A_FILE).write_text("x = 2\n")
        agent = self.repo / ".acp-agent" / "transcripts"
        agent.mkdir(parents=True)
        (self.repo / ".acp-agent" / "config.yaml").write_text("tools: {}\n")
        (agent / "transcript.jsonl").write_text("{}\n")
        self.exclude = self.repo / ".git" / "info" / "exclude"

    def tearDown(self):
        """Remove the repository of the test."""
        self.tmp.cleanup()

    def status(self):
        """Give the paths that `git status --porcelain --untracked-files=all` lists."""
        lines = git(self.repo, "status", "--porcelain", "--untracked-files=all").splitlines()
        return [line[3:] for line in lines]

    def test_status_no_longer_lists_the_dotfolder(self):
        """`tools.git.status` reads the same status: the agent files must not be in it."""
        self.assertTrue(any(p.startswith(".acp-agent/") for p in self.status()))
        exclude_agent_folder(self.repo)
        self.assertEqual(self.status(), [A_FILE])

    def test_the_patch_does_not_change(self):
        """The prediction is `git diff <base_commit>`, and it must stay the same."""
        before = git(self.repo, "diff", self.base)
        exclude_agent_folder(self.repo)
        self.assertEqual(git(self.repo, "diff", self.base), before)
        self.assertIn(f"+++ b/{A_FILE}", before)

    def test_the_tracked_gitignore_does_not_change(self):
        """A change to `.gitignore` would be part of the patch."""
        exclude_agent_folder(self.repo)
        self.assertEqual((self.repo / GITIGNORE).read_text(), GITIGNORE_TEXT)

    def test_a_second_call_adds_no_second_line(self):
        """The run can call it again for the same clone."""
        exclude_agent_folder(self.repo)
        exclude_agent_folder(self.repo)
        lines = self.exclude.read_text().splitlines()
        self.assertEqual(lines.count(AGENT_FOLDER_PATTERN), 1)

    def test_the_lines_that_were_there_stay(self):
        """`git init` writes comment lines into the file, and a clone can hold more."""
        self.exclude.write_text("# a line of the clone\n*.log")
        exclude_agent_folder(self.repo)
        self.assertEqual(self.exclude.read_text().splitlines(),
                         ["# a line of the clone", "*.log", AGENT_FOLDER_PATTERN])


class TheCloneOfAnInstance(unittest.TestCase):
    """A clone that fails on a flaky network is tried again (2026-11-09: the
    clone of django__django-13447 hung 13 minutes and failed with exit 128,
    and the run lost the instance)."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.dest = self.root / "repo"
        self.calls = []
        self.waits = []

    def run_that_fails(self, failures):
        """A runner whose first `failures` calls fail. Each call leaves a part
        of a clone behind, as a failed `git clone` can."""
        def run(command, **kwargs):
            self.calls.append((command, kwargs))
            self.assertFalse(self.dest.exists(), "each try starts with no folder")
            self.dest.mkdir()
            if len(self.calls) <= failures:
                raise subprocess.CalledProcessError(128, command)
            return subprocess.CompletedProcess(command, 0)
        return run

    def test_a_clone_that_fails_two_times_is_tried_again(self):
        clone_repository("https://example.invalid/r.git", self.dest,
                         run=self.run_that_fails(2), sleep=self.waits.append)

        self.assertEqual(len(self.calls), 3)
        self.assertEqual(len(self.waits), 2)
        self.assertTrue(self.dest.exists())

    def test_each_try_has_a_time_limit(self):
        clone_repository("https://example.invalid/r.git", self.dest,
                         run=self.run_that_fails(0), sleep=self.waits.append)

        self.assertIn("timeout", self.calls[0][1])

    def test_a_stalled_try_is_tried_again(self):
        def run(command, **kwargs):
            self.calls.append((command, kwargs))
            self.dest.mkdir()
            if len(self.calls) == 1:
                raise subprocess.TimeoutExpired(command, kwargs["timeout"])
            return subprocess.CompletedProcess(command, 0)

        clone_repository("https://example.invalid/r.git", self.dest,
                         run=run, sleep=self.waits.append)

        self.assertEqual(len(self.calls), 2)

    def test_the_last_failure_is_raised(self):
        with self.assertRaises(subprocess.CalledProcessError):
            clone_repository("https://example.invalid/r.git", self.dest,
                             run=self.run_that_fails(99), sleep=self.waits.append)

        self.assertGreater(len(self.calls), 1)
        self.assertEqual(len(self.waits), len(self.calls) - 1)


if __name__ == "__main__":
    unittest.main()
