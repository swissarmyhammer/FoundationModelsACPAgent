"""Tests for `swebench_agent_runs`: keep the transcripts of the agent runs of an instance.

An agent run (`start agent`) is a child session. The Router writes its
transcript into its own recordings root, `acp-agent-recordings-<uuid>/
<router id>/<child id>/transcript.jsonl`, and not into `.acp-agent/transcripts`
of the clone. That root also holds the short tool-selection sessions of the
Router, which are not agent runs. The parent transcript names each run that
it started: "Agent coder (<id>) ...". So the copy takes the ids that the kept
transcripts name, and only those.
"""

import json
import tempfile
import unittest
from pathlib import Path

from swebench_agent_runs import AGENT_RUNS_DIR, agent_run_ids, keep_agent_run_transcripts

ROOT_ID = "01M5AXF8MMTNFMPH3ESJR2N3VH"
ROUTER_ID = "01M5AXF3S5XJ4CGGH431S48S72"
CHILD_ID = "01M5AXX01RB3XX05J0EKEFJY2S"
GRANDCHILD_ID = "01M5AYFMG4HGFQQCQKAD71HQJS"
SELECTION_ID = "01M5AXYARFFKAS218B6VRRSVYM"


def write_transcript(folder, texts):
    """Write a transcript.jsonl in `folder` with one toolOutput row for each text."""
    folder.mkdir(parents=True, exist_ok=True)
    rows = [json.dumps({"seq": i, "kind": "toolOutput", "text": t}) for i, t in enumerate(texts)]
    (folder / "transcript.jsonl").write_text("\n".join(rows) + "\n")


class AgentRunTranscriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.kept = self.tmp / "preds.transcripts" / "django__django-1"
        self.recordings = self.tmp / "T" / "acp-agent-recordings-AA1D9AD9" / ROUTER_ID
        write_transcript(self.kept / ROOT_ID, [
            "[agents] agents (01M5AXWZWFW65MBDV391GAGTTY) running: pending",
            f"[agents] agents (01M5AXWZWFW65MBDV391GAGTTY) completed: Agent coder ({CHILD_ID}) finished.",
        ])
        write_transcript(self.recordings / CHILD_ID, ["the coder did the work"])
        write_transcript(self.recordings / SELECTION_ID, ["a tool selection session"])

    def test_the_ids_are_the_agent_runs_that_a_transcript_names(self):
        self.assertEqual(agent_run_ids(self.kept / ROOT_ID / "transcript.jsonl"), [CHILD_ID])

    def test_only_the_named_agent_runs_are_copied(self):
        copied = keep_agent_run_transcripts(self.kept, recordings_roots=[self.tmp / "T"])

        self.assertEqual(copied, [CHILD_ID])
        self.assertTrue((self.kept / AGENT_RUNS_DIR / CHILD_ID / "transcript.jsonl").is_file())
        self.assertFalse((self.kept / AGENT_RUNS_DIR / SELECTION_ID).exists())

    def test_an_agent_run_that_an_agent_run_started_is_copied_too(self):
        write_transcript(self.recordings / CHILD_ID, [f"Agent general-purpose ({GRANDCHILD_ID}) finished."])
        write_transcript(self.recordings / GRANDCHILD_ID, ["the search"])

        copied = keep_agent_run_transcripts(self.kept, recordings_roots=[self.tmp / "T"])

        self.assertEqual(sorted(copied), sorted([CHILD_ID, GRANDCHILD_ID]))
        self.assertTrue((self.kept / AGENT_RUNS_DIR / GRANDCHILD_ID / "transcript.jsonl").is_file())

    def test_a_named_run_with_no_recording_is_left_out(self):
        (self.recordings / CHILD_ID / "transcript.jsonl").unlink()

        self.assertEqual(keep_agent_run_transcripts(self.kept, recordings_roots=[self.tmp / "T"]), [])

    def test_an_instance_with_no_agent_run_copies_nothing(self):
        write_transcript(self.kept / ROOT_ID, ["[runCode] runCode (01M5AXKC44G6M9DB7A6MDQ7AF3) completed: {}"])

        self.assertEqual(keep_agent_run_transcripts(self.kept, recordings_roots=[self.tmp / "T"]), [])
        self.assertFalse((self.kept / AGENT_RUNS_DIR).exists())


if __name__ == "__main__":
    unittest.main()
