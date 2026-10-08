#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_history.py -- the proof that a run finds each git read of the
agent that reaches past the base commit.

The clone of an instance is a full clone. The agent sees the base commit as a
detached HEAD, but the clone also holds the later history of the project, for
example `main` and `origin/main`. A git read of such a rev can show the
upstream fix. The user decided that a fix the agent finds that way is a valid
result (task ^exkkyyr). The run must not block it: it records it, and the
score report shows it.

The tests make a small git repository with an "upstream" commit after the
base commit, clone it, and put the clone at the base commit, as
`swebench_run.py` does. Git runs on a temporary directory only, with no
network. This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_history.py
    python3 bench/test_swebench_history.py
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import swebench_history
from swebench_history import git_reads, upstream_reads

# The settings that each git command of a test needs to make a commit.
GIT_IDENTITY = ["-c", "user.name=bench test", "-c", "user.email=bench@example.invalid"]
# The file that the commits of the test change.
A_FILE = "module.py"


def git(repo, *args):
    """Run one git command in repo, and give its standard output, stripped.

    - repo: the directory of the repository.
    - args: the arguments of the git command.
    """
    done = subprocess.run(
        ["git", "-C", str(repo), *GIT_IDENTITY, *args],
        capture_output=True, text=True, check=True,
    )
    return done.stdout.strip()


def commit(repo, text):
    """Write text to the file of the test, commit it, and give the sha.

    - repo: the directory of the repository.
    - text: the new content of the file, and the commit message.
    """
    (Path(repo) / A_FILE).write_text(text)
    git(repo, "add", A_FILE)
    git(repo, "commit", "--quiet", "-m", text)
    return git(repo, "rev-parse", "HEAD")


def a_snippet_call(code):
    """Give one transcript row of a runCode call of the model with code.

    - code: the JavaScript of the snippet.
    """
    arguments = json.dumps({"code": code})
    return {"kind": "toolCalls",
            "entry": {"toolCalls": [{"id": "call_1", "toolName": "runCode", "argumentsJSON": arguments}]}}


class GitReadsOfOneSnippet(unittest.TestCase):
    """Which revs one snippet of the model reads with the git verbs."""

    def test_a_ref_argument_is_a_read(self):
        """`tools.git.log` and `tools.git.show` name the commit with `ref`."""
        self.assertEqual(git_reads('await tools.git.log({ ref: "main", path: "a.py" })'), [("log", "main")])

    def test_a_rev_argument_of_blame_is_a_read(self):
        """`tools.git.blame` names the commit with `rev`."""
        self.assertEqual(git_reads("tools.git.blame({path: 'a.py', rev: 'origin/main'})"),
                         [("blame", "origin/main")])

    def test_a_branch_argument_of_changes_is_a_read(self):
        """`tools.git.changes` reads the commits of a local branch."""
        self.assertEqual(git_reads('tools.git.changes({branch: "main"})'), [("changes", "main")])

    def test_a_range_gives_each_end(self):
        """A range `from..to` reads the two ends, and `...` is a range too."""
        self.assertEqual(git_reads('tools.git.changes({range: "v1..main"})'),
                         [("changes", "v1"), ("changes", "main")])
        self.assertEqual(git_reads('tools.git.changes({range: "a...b"})'),
                         [("changes", "a"), ("changes", "b")])

    def test_an_empty_end_of_a_range_is_no_read(self):
        """An empty end is HEAD, and HEAD is the clone itself."""
        self.assertEqual(git_reads('tools.git.changes({range: "main.."})'), [("changes", "main")])

    def test_a_side_with_a_ref_gives_the_ref(self):
        """`tools.git.diff` reads a side `path@ref` at the ref, and a plain path in the work folder."""
        self.assertEqual(git_reads('tools.git.diff({left: "a.py@main", right: "a.py"})'), [("diff", "main")])

    def test_a_quoted_key_is_a_read(self):
        """The model can write the argument object in the JSON form."""
        self.assertEqual(git_reads('tools.git.show({"path": "a.py", "ref": "main"})'), [("show", "main")])

    def test_a_call_with_no_rev_is_no_read(self):
        """A call with no rev reads the clone at HEAD, which is the base commit."""
        self.assertEqual(git_reads("tools.git.status({}); tools.git.log({path: 'a.py'}); tools.git.diff()"), [])

    def test_a_verb_of_another_group_is_no_read(self):
        """Only the git group reads the git history."""
        self.assertEqual(git_reads('tools.files.read({path: "a.py", ref: "main"})'), [])


class UpstreamReadsOfAClone(unittest.TestCase):
    """Which git reads of a clone reach the history after the base commit."""

    def setUp(self):
        """Make the upstream repository and a clone at its base commit.

        The upstream has the base commit, then the fix on `main`. The clone
        is checked out at the base commit, with a detached HEAD, exactly as
        `swebench_run.py` does it.
        """
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        upstream = root / "upstream"
        upstream.mkdir()
        git(upstream, "init", "--quiet", "--initial-branch=main")
        self.base = commit(upstream, "the base commit")
        self.fix = commit(upstream, "the upstream fix")
        self.repo = root / "repo"
        subprocess.run(["git", "clone", "--quiet", str(upstream), str(self.repo)], check=True)
        git(self.repo, "checkout", "--quiet", "--force", self.base)
        self.transcripts = self.repo / ".acp-agent" / "transcripts"

    def tearDown(self):
        """Remove the repositories of the test."""
        self.tmp.cleanup()

    def agent_wrote(self, *codes):
        """Write a transcript of the agent with one runCode call for each code.

        - codes: the JavaScript of each snippet.
        """
        session = self.transcripts / "01SESSION"
        session.mkdir(parents=True)
        rows = [a_snippet_call(code) for code in codes]
        (session / "transcript.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))

    def reads(self):
        """Give the upstream reads of the clone of the test."""
        return upstream_reads(self.repo, self.base, self.transcripts)

    def test_a_read_of_the_branch_after_the_base_is_upstream(self):
        """`main` of the clone holds the fix, so a read of `main` can show it."""
        self.agent_wrote('tools.git.log({ref: "main"})')
        self.assertEqual(self.reads(), [{"verb": "log", "rev": "main", "commit": self.fix}])

    def test_a_read_of_the_remote_branch_is_upstream(self):
        """The clone also has `origin/main`, which holds the same fix."""
        self.agent_wrote("tools.git.show({path: 'module.py', ref: 'origin/main'})")
        self.assertEqual(self.reads(), [{"verb": "show", "rev": "origin/main", "commit": self.fix}])

    def test_a_read_of_the_base_commit_is_not_upstream(self):
        """The base commit and its ancestors are the history the agent may read."""
        self.agent_wrote(f'tools.git.show({{path: "module.py", ref: "{self.base}"}})',
                         'tools.git.log({ref: "HEAD"})')
        self.assertEqual(self.reads(), [])

    def test_a_commit_of_the_agent_is_not_upstream(self):
        """The agent can commit its own change. That commit is no upstream history."""
        commit(self.repo, "the change of the agent")
        self.agent_wrote('tools.git.show({path: "module.py", ref: "HEAD"})')
        self.assertEqual(self.reads(), [])

    def test_a_rev_that_names_no_commit_is_not_upstream(self):
        """The git tool gives a correction for it, so the agent read nothing."""
        self.agent_wrote('tools.git.log({ref: "no-such-branch"})')
        self.assertEqual(self.reads(), [])

    def test_a_rev_that_starts_with_a_dash_does_not_go_to_git(self):
        """A rev comes from the model. Git must not read it as an option."""
        target = Path(self.tmp.name) / "written-by-git"
        self.agent_wrote(f'tools.git.log({{ref: "--output={target}"}})')
        self.assertEqual(self.reads(), [])
        self.assertFalse(target.exists())

    def test_two_reads_of_the_same_rev_give_one_row(self):
        """The record holds each read one time, in two snippets or in one."""
        self.agent_wrote('tools.git.log({ref: "main"})',
                         'tools.git.log({ref: "main"}); tools.git.log({ref: "main"})')
        self.assertEqual(len(self.reads()), 1)

    def test_a_row_with_another_shape_does_not_stop_the_check(self):
        """The run checks the clone before it removes it. A bad row must not stop the run."""
        self.agent_wrote('tools.git.log({ref: "main"})')
        transcript = self.transcripts / "01SESSION" / "transcript.jsonl"
        odd_rows = [{"kind": "toolCalls", "entry": []}, {"kind": "toolCalls", "entry": {"toolCalls": ["x"]}},
                    ["not", "a", "row"]]
        with transcript.open("a") as stream:
            stream.write("".join(json.dumps(r) + "\n" for r in odd_rows) + '{"half a line\n')
        self.assertEqual([r["rev"] for r in self.reads()], ["main"])

    def test_a_clone_with_no_transcript_has_no_read(self):
        """An agent that did not start wrote no transcript."""
        self.assertEqual(self.reads(), [])

    def test_no_git_program_gives_none(self):
        """None says that the check did not run, and [] says that it found no read."""
        self.agent_wrote('tools.git.log({ref: "main"})')
        with mock.patch.object(swebench_history, "GIT", str(Path(self.tmp.name) / "no-git-here")):
            self.assertIsNone(self.reads())


if __name__ == "__main__":
    unittest.main()
