"""
swebench_agent_config.py -- give the `--agent-config` file of a run to the
agent.

The agent reads the file from two places, and each place uses other sections:

  - The working root of the run, the directory of the agent process. The agent
    resolves its model profile (`profile:`) from there one time, when the
    process starts. So the file must be there before the agent starts.
  - The clone of each instance, the directory of its session. The agent reads
    the `tools:` section of a session from there at `session/new`. The clone
    is removed when the instance ends, so each instance gets the file again.

`.acp-agent` is in AGENT_EXCLUDES of the driver, and the file is not tracked,
so it is never part of the patch.
"""
import shutil
from pathlib import Path

# Where the agent reads the configuration of the project layer, below a
# directory.
AGENT_CONFIG = Path(".acp-agent") / "config.yaml"


def give_agent_config(directory, config):
    """Copy the `--agent-config` file into the project layer of `directory`.

    `config` is None when the run has no `--agent-config`: then nothing is
    written.
    """
    if config is None:
        return
    destination = Path(directory) / AGENT_CONFIG
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(config, destination)
