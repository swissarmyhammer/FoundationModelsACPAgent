"""
test_swebench_excludes.py -- the proof that a patch holds no file of the agent.

`capture_patch` of `swebench_run.py` is `git diff <base_commit>` with the
pathspecs of `AGENT_EXCLUDES`. `git diff <commit>` reports tracked files only,
so an untracked file of the agent is already out of the patch. But an agent
that commits a folder of its own puts that folder in the diff, and only an
exclude takes it out again.

The kanban board is such a folder. The `kanban` skill says to commit
`.kanban/` with the code, and in the run root4 (2026-11-09) the `committer`
agent did that: the patch of django__django-13925 held 16 files of the board
next to its 2 files of code.

The script runs at import, so this test reads it with `ast`, as
`test_swebench_log_lines.py` does. It needs the standard library only:

    uv run bench/test_swebench_excludes.py
    python3 bench/test_swebench_excludes.py
"""
import ast
import unittest
from pathlib import Path

RUN_SCRIPT = Path(__file__).parent / "swebench_run.py"


def agent_excludes():
    """The values of the `AGENT_EXCLUDES` list of `swebench_run.py`."""
    tree = ast.parse(RUN_SCRIPT.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "AGENT_EXCLUDES"
            for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError("swebench_run.py has no AGENT_EXCLUDES")


class AgentExcludesTests(unittest.TestCase):
    def test_the_patch_holds_no_kanban_board(self):
        self.assertIn(".kanban", agent_excludes())

    def test_the_patch_holds_no_transcript_and_no_environment(self):
        self.assertIn(".acp-agent", agent_excludes())
        self.assertIn(".venv", agent_excludes())


if __name__ == "__main__":
    unittest.main()
