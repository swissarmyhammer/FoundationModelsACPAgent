"""Keep the transcripts of the agent runs of one instance.

An agent run (`start agent` of the `agents` tool) is a child session. The
Router writes its transcript into its own recordings root,
`<tmp>/acp-agent-recordings-<uuid>/<router id>/<child id>/transcript.jsonl`,
and not into `.acp-agent/transcripts` of the clone, which `keep_transcripts`
copies. The recordings root also holds the short tool-selection sessions of
the Router, which are not agent runs.

The parent transcript names each run that it started, in the result of the
run: "Agent coder (<id>) finished." So the copy takes the ids that the kept
transcripts name, and only those. A run can start a run of its own, so the
copy also reads each transcript that it copies. Each copy goes to
`<instance dir>/agent-runs/<id>/`.
"""

import re
import shutil
import tempfile
from pathlib import Path

# The folder below the kept transcripts of an instance that holds the
# transcripts of its agent runs.
AGENT_RUNS_DIR = "agent-runs"

# The prefix of the recordings root that the agent makes in its temporary
# folder (`ComposedAgent.recordingsDirectoryPrefix`).
RECORDINGS_PREFIX = "acp-agent-recordings-"

# The words of the agents tool that name a run and its session id, for
# example "Agent coder (01M5AXX01RB3XX05J0EKEFJY2S) finished.".
AGENT_RUN = re.compile(r"Agent [\w.-]+ \((01[0-9A-HJKMNP-TV-Z]{24})\)")

# The name of the transcript file of a session.
TRANSCRIPT = "transcript.jsonl"


def agent_run_ids(transcript):
    """Give the session ids of the agent runs that `transcript` names, in order, each one time."""
    text = Path(transcript).read_text(errors="replace")
    return list(dict.fromkeys(AGENT_RUN.findall(text)))


def find_recording(run_id, recordings_roots):
    """Give the folder that holds the transcript of `run_id`, or None."""
    for root in recordings_roots:
        for folder in Path(root).glob(f"{RECORDINGS_PREFIX}*/*/{run_id}"):
            if (folder / TRANSCRIPT).is_file():
                return folder
    return None


def keep_agent_run_transcripts(instance_dir, recordings_roots=None):
    """Copy the transcripts of the agent runs that the kept transcripts of an instance name.

    Returns the ids of the runs that were copied, in the order found. A named
    run with no recording is left out.
    """
    instance_dir = Path(instance_dir)
    roots = recordings_roots if recordings_roots is not None else [Path(tempfile.gettempdir())]
    pending = []
    for transcript in sorted(instance_dir.glob(f"*/{TRANSCRIPT}")):
        pending += agent_run_ids(transcript)
    copied = []
    while pending:
        run_id = pending.pop(0)
        if run_id in copied:
            continue
        source = find_recording(run_id, roots)
        if source is None:
            continue
        destination = instance_dir / AGENT_RUNS_DIR / run_id
        if destination.exists():
            shutil.rmtree(destination, ignore_errors=True)
        shutil.copytree(source, destination)
        copied.append(run_id)
        pending += agent_run_ids(destination / TRANSCRIPT)
    return copied
