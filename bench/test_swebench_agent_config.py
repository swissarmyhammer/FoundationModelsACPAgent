#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_agent_config.py -- the proof that `--agent-config` reaches the
profile of the agent, and not only the sessions.

`swebench_run.py` copied the `--agent-config` file into the clone of each
instance only (`<work_root>/repo/.acp-agent/config.yaml`). The agent reads the
`tools:` section of a session from there at `session/new`. But it resolves its
model profile one time, when the process starts, from the configuration of its
own directory, and the agent process stands in the working root. So the
`profile:` section of the file had no effect.

On 2026-10-29 the run mtpsmoke1 gave `profile.standard` as
`{repo: mlx-community/Qwen3.8-27B-4bit, drafter: mlx-community/Qwen3.8-27B-MTP-4bit}`.
The telemetry showed 185 standard calls on `mlx-community/Qwen3.8-27B-mxfp4`,
the builtin default, and none on the configured model.

These tests hold the fix: the driver gives the file to the working root
before the agent starts, and to each clone before its session starts.
"""
import tempfile
import unittest
from pathlib import Path

from swebench_agent_config import AGENT_CONFIG, give_agent_config

CONFIG_TEXT = (
    "profile:\n"
    "  standard:\n"
    "    - repo: mlx-community/Qwen3.8-27B-4bit\n"
    "      drafter: mlx-community/Qwen3.8-27B-MTP-4bit\n"
)


class GiveAgentConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "run.config.yaml"
        self.config.write_text(CONFIG_TEXT)

    def test_the_working_root_gets_the_file_for_the_profile(self):
        work_root = self.root / "work"
        work_root.mkdir()
        give_agent_config(work_root, self.config)
        self.assertEqual((work_root / AGENT_CONFIG).read_text(), CONFIG_TEXT)

    def test_a_clone_gets_the_file_for_its_session(self):
        repo = self.root / "work" / "repo"
        repo.mkdir(parents=True)
        give_agent_config(repo, self.config)
        self.assertEqual((repo / AGENT_CONFIG).read_text(), CONFIG_TEXT)

    def test_no_file_writes_nothing(self):
        work_root = self.root / "work"
        work_root.mkdir()
        give_agent_config(work_root, None)
        self.assertFalse((work_root / AGENT_CONFIG).exists())

    def test_the_project_layer_is_below_the_dotfolder(self):
        self.assertEqual(AGENT_CONFIG, Path(".acp-agent") / "config.yaml")


if __name__ == "__main__":
    unittest.main()
