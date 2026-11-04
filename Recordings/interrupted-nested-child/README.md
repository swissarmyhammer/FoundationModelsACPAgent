# Recording of an interrupted nested child

This folder holds a recording that the agent made. No record in it is written by hand.
AgentViewKit uses it to test the resume of a nested session tree.

## The path

The recorded working directory (`cwd`) of all three sessions:

    /tmp/AgentViewKitDemo-nested-work

The recording root, which the agent knows (the default `project` location):

    /tmp/AgentViewKitDemo-nested-work/.acp-agent/transcripts

The recorded `cwd` is the string `/tmp/...`, not `/private/tmp/...`. The host compares
the `cwd` of `session/resume` with the recorded `cwd` as a standardized path string.
It does not resolve symbolic links. On macOS `/tmp` is a link to `/private/tmp`, but
the two strings are not equal for the host. The host records the string that the
client sent in `session/new`. So the string is stable and the same on each machine.
A resume must send exactly `/tmp/AgentViewKitDemo-nested-work`.

The `cwd` is in the `index.md` of each session: the `cwd:` line (line 3), and the
`workingDirectory:` line and the `recordingRoot:` line in the config block.
No other file of this folder holds a path.

## How to replay it

1. Make the directory `/tmp/AgentViewKitDemo-nested-work`. An empty directory is enough.
   The host does not make it. If it is missing, the root resumes in replay-only mode and
   the children are not restored.
2. Copy `workspace/.acp-agent/transcripts` of this folder to
   `/tmp/AgentViewKitDemo-nested-work/.acp-agent/transcripts`. Or set `transcripts.location`
   in the config to the place of the copy.
3. Put the agent definitions `parent` and `leaf` in the USER layer of the agents. That is
   `$XDG_CONFIG_HOME/agents/` (`~/.config/agents/` when `XDG_CONFIG_HOME` is not set). The
   folder `agents/` of this folder holds the two definitions. Copy `agents/parent` and
   `agents/leaf` into the USER layer. The project layer `/tmp/AgentViewKitDemo-nested-work/.agents/agents/`
   is also a good place for them, and it has the same effect.
4. Set the `standard` model to `mlx-community/Qwen3.8-27B-mxfp4` (one plain string, no
   drafter). The sessions are recorded with that model id.
5. Send `initialize`, wait for its response, then send `session/resume` with the root
   session id and `"cwd": "/tmp/AgentViewKitDemo-nested-work"`.

The definitions, as `make.py` writes them:

`agents/parent/AGENT.md`

    ---
    name: parent
    description: The parent agent of the nested recording.
    tools: Agent
    ---

    Do the task.

`agents/leaf/AGENT.md`

    ---
    name: leaf
    description: The leaf agent of the nested recording.
    ---

    Do the task.

## The tree

| Level | Agent | Session id | Parent |
|---|---|---|---|
| root | none (the lead session) | `01M6KZFJJQ3RGRAXDP42Q9GV3J` | none |
| child | `parent` | `01M6KZFJKJZWF47K4NWB69RP7R` | the root |
| grandchild | `leaf` | `01M6KZFJZNK29EZVQ9KV2F4BFV` | the child |

- The child and the grandchild have `agentSpawn` with `parentSessionId`, `parentToolCallId`
  and `rootSessionId`. The chain goes from the grandchild to the child to the root.
- No session has an `endedAt` mark. The process ended with an orderly shutdown while the
  child and the grandchild were running, so the sessions are suspended.
- The `session-history.json` of the root and of the child holds the `agents` tool call with
  the status `paused` and no final status. Thus a resume reads the call as interrupted.
- The grandchild never finished. Its model waited on a gate that never opens.
- The first prompt of the child is in its transcript: `CHILD-NESTED-MARKER do the parent task`.
  The first prompt of the grandchild is in its transcript:
  `GRANDCHILD-NESTED-MARKER do the leaf task`. The first prompt of the root is
  `ROOT-NESTED-MARKER start the child`.
- The agent definitions `parent` and `leaf` are in `agents/` of this folder. The recording
  was made with them in the USER layer. `parent` has `tools: Agent`, so the child can start
  the grandchild.
- The `standard` slot of the three sessions names the model
  `mlx-community/Qwen3.8-27B-mxfp4`, and no drafter. The sessions run on the stub model.
  The text of the sessions is from `script.template.json`. The model id is metadata only.

## The steps to make it again

1. Build the stub agent from the package root:
   `swift build --product acp-agent-stub`
2. Run the script from the package root:
   `python3 Recordings/interrupted-nested-child/make.py "$PWD/.build/debug/acp-agent-stub"`
   The option `--cwd <absolute path>` sets the recorded `cwd`. The default is
   `/tmp/AgentViewKitDemo-nested-work`. The option `--model <id>` sets the `standard`
   model. The default is `mlx-community/Qwen3.8-27B-mxfp4`. The recording has no drafter.

The script does these steps:

1. It makes the directory `--cwd` and deletes `.acp-agent` and `.agents` in it.
2. It writes `parent` and `leaf` in the USER layer of an isolated config, and copies them
   to `agents/` of this folder.
3. It writes the script from `script.template.json` in a scratch folder, because the script
   holds the path of the gate. The script is for the stub model
   (`ACP_AGENT_STUB_SCRIPT`). The root calls the `agents` tool to start `parent`. `parent`
   calls the `agents` tool to start `leaf`. `leaf` plays one `gate` step on a file that
   never exists.
4. It starts `acp-agent-stub acp` in `--cwd` with an offline defaults layer (no skills
   marketplace), a user layer that names the `standard` model, and its own config and data
   folders.
5. It sends `initialize`, `session/new` and `session/prompt` on the stdin of the agent.
6. It waits until the transcript of `leaf` holds its prompt. Then the grandchild is running.
7. It closes the stdin of the agent. That is the orderly shutdown: the sessions are suspended
   and get no `endedAt` mark.
8. It deletes `workspace/` of this folder and copies `<cwd>/.acp-agent/transcripts` to
   `workspace/.acp-agent/transcripts`.

Each run makes new session ids. After a new run, write the new ids in the table above.

## How to check the result

- `grep -rl endedAt workspace/.acp-agent/transcripts` prints nothing.
- `grep -c paused workspace/.acp-agent/transcripts/<session id>/session-history.json` prints 1
  for the root and for the child.
- `grep -rn drafter workspace/.acp-agent/transcripts` prints nothing.
- Each `workspace/.acp-agent/transcripts/<session id>/index.md` of the child and the
  grandchild has an `agentSpawn` block.
