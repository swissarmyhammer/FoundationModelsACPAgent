#!/usr/bin/env python3
"""Make the recording of an interrupted nested child.

The script runs the built `acp-agent-stub acp` over the stub model script
`script.template.json`. A root session starts a child, the child starts a
grandchild, and the grandchild waits on a gate that never opens. When the
grandchild is running, the script closes the stdin of the agent. That is an
orderly shutdown: the sessions are suspended, and no session gets an
`endedAt` mark.

Usage: make.py <path of the acp-agent-stub binary> [<standard model id>]

The `standard` slot of the recording names the model `STANDARD_MODEL` by default
(`mlx-community/Qwen3.8-27B-mxfp4`) and names no drafter. The stub model plays
the script. The recording holds the model id as metadata only.

The script deletes `workspace/` and writes it again.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE / "workspace"
TRANSCRIPTS = WORKSPACE / ".acp-agent" / "transcripts"
ROOT_PROMPT = "ROOT-NESTED-MARKER start the child"
GRANDCHILD_AGENT = "leaf"
GRANDCHILD_PROMPT = "GRANDCHILD-NESTED-MARKER"
STANDARD_MODEL = "mlx-community/Qwen3.8-27B-mxfp4"
PROTOCOL_VERSION = 2
POLL_SECONDS = 0.2
DEADLINE_SECONDS = 120
SHUTDOWN_SECONDS = 60
JSON_RPC_METHOD_NOT_FOUND = -32601

AGENT_DOCUMENT = """---
name: {name}
description: The {name} agent of the nested recording.
{tools}---

Do the task.
"""


def write_agent(name: str, tools: str) -> None:
    """Write the agent folder `name` in the project folder of the workspace."""
    folder = WORKSPACE / ".agents" / "agents" / name
    folder.mkdir(parents=True)
    tools_line = f"tools: {tools}\n" if tools else ""
    document = AGENT_DOCUMENT.format(name=name, tools=tools_line)
    (folder / "AGENT.md").write_text(document, encoding="utf-8")


def write_script(scratch: Path) -> Path:
    """Write the stub script in the scratch folder, and return its path.

    The script holds the path of the gate, a path of this machine. It stays out of
    the recording folder, so no file of the folder holds that path.
    """
    gate = scratch / "gate-that-never-opens"
    template = (HERE / "script.template.json").read_text(encoding="utf-8")
    script = scratch / "script.json"
    script.write_text(template.replace("GATE-PATH", str(gate)), encoding="utf-8")
    return script


def environment(script: Path, scratch: Path, model: str) -> dict:
    """The environment of the agent: offline defaults, own homes, the script.

    The user layer (`config/acp-agent/config.yaml` of the scratch folder) names
    `model` as the plain `standard` candidate. A plain string has no drafter,
    and the default profile would add one. The defaults layer does not set the
    profile of the start-up configuration, thus the profile is in the user layer.
    """
    defaults = scratch / "defaults"
    defaults.mkdir()
    (defaults / "config.yaml").write_text(
        "tools:\n  skills:\n    marketplaces: []\n", encoding="utf-8"
    )
    user_layer = scratch / "config" / "acp-agent"
    user_layer.mkdir(parents=True)
    (user_layer / "config.yaml").write_text(
        f"profile:\n  standard:\n    - {model}\n", encoding="utf-8"
    )
    env = dict(os.environ)
    env.update(
        {
            "ACP_AGENT_DEFAULTS_DIR": str(defaults),
            "XDG_CONFIG_HOME": str(scratch / "config"),
            "XDG_DATA_HOME": str(scratch / "data"),
            "ACP_AGENT_STUB_SCRIPT": str(script),
        }
    )
    return env


def send(process: subprocess.Popen, message: dict) -> None:
    """Write one JSON-RPC message as a line to the stdin of the agent."""
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def read_until_response(process: subprocess.Popen, request_id: int) -> dict:
    """Read lines until the response to `request_id`; refuse agent requests."""
    for line in process.stdout:
        message = json.loads(line)
        if message.get("id") == request_id and "method" not in message:
            return message
        if "id" in message and "method" in message:
            send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "error": {"code": JSON_RPC_METHOD_NOT_FOUND, "message": "no"},
                },
            )
    raise RuntimeError(f"the agent ended before the response {request_id}")


def grandchild_has_prompt() -> bool:
    """Whether the transcript of the grandchild holds the prompt it was given."""
    for folder in TRANSCRIPTS.glob("*"):
        index = folder / "index.md"
        transcript = folder / "transcript.jsonl"
        if not index.exists() or not transcript.exists():
            continue
        if f"agentName: {GRANDCHILD_AGENT}\n" not in index.read_text(encoding="utf-8"):
            continue
        if GRANDCHILD_PROMPT in transcript.read_text(encoding="utf-8"):
            return True
    return False


def wait_for_grandchild() -> None:
    """Wait until the grandchild runs, and waits on its gate."""
    deadline = time.monotonic() + DEADLINE_SECONDS
    while time.monotonic() < deadline:
        if grandchild_has_prompt():
            return
        time.sleep(POLL_SECONDS)
    raise RuntimeError("the grandchild never started")


def main(executable: str, model: str) -> None:
    """Run the agent, start the nested run, and shut the agent down."""
    shutil.rmtree(WORKSPACE, ignore_errors=True)
    WORKSPACE.mkdir()
    write_agent("parent", "Agent")
    write_agent("leaf", "")
    scratch = Path(subprocess.check_output(["mktemp", "-d"], text=True).strip())
    script = write_script(scratch)
    process = subprocess.Popen(
        [executable, "acp"],
        cwd=WORKSPACE,
        env=environment(script, scratch, model),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "info": {"name": "recorder", "version": "1"},
                "capabilities": {},
            },
        },
    )
    initialized = read_until_response(process, 1)
    if "error" in initialized:
        raise RuntimeError(f"initialize failed: {initialized['error']}")
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/new",
            "params": {"cwd": str(WORKSPACE), "mcpServers": []},
        },
    )
    created = read_until_response(process, 2)
    if "error" in created:
        raise RuntimeError(f"session/new failed: {created['error']}")
    session_id = created["result"]["sessionId"]
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "session/prompt",
            "params": {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": ROOT_PROMPT}],
            },
        },
    )
    wait_for_grandchild()
    process.stdin.close()
    process.wait(timeout=SHUTDOWN_SECONDS)
    shutil.rmtree(scratch, ignore_errors=True)
    print(f"root session: {session_id}")
    print(f"recording root: {TRANSCRIPTS}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else STANDARD_MODEL)
