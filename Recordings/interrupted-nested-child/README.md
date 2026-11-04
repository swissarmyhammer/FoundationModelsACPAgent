# Recording of an interrupted nested child

This folder holds a recording that the agent made. No record in it is written by hand.
AgentViewKit uses it to test the resume of a nested session tree.

## The path

The recording root, which the agent knows (the default `project` location):

    /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Recordings/interrupted-nested-child/workspace/.acp-agent/transcripts

The working directory (`cwd`) of all three sessions:

    /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Recordings/interrupted-nested-child/workspace

## The tree

| Level | Agent | Session id | Parent |
|---|---|---|---|
| root | none (the lead session) | `01M6JKRZ7HWFCD7GFPEETKGX83` | none |
| child | `parent` | `01M6JKRZA4NJBNESVN3DV9T2KY` | the root |
| grandchild | `leaf` | `01M6JKRZN9H4V39ECSWBBPT5QJ` | the child |

- The child and the grandchild have `agentSpawn` with `parentSessionId`, `parentToolCallId`
  and `rootSessionId`. The chain goes from the grandchild to the child to the root.
- No session has an `endedAt` mark. The process ended with an orderly shutdown while the
  child and the grandchild were running, so the sessions are suspended.
- The grandchild never finished. Its model waited on a gate that never opens.
- The first prompt of the child is in its transcript: `CHILD-NESTED-MARKER do the parent task`.
  The first prompt of the grandchild is in its transcript:
  `GRANDCHILD-NESTED-MARKER do the leaf task`. The first prompt of the root is
  `ROOT-NESTED-MARKER start the child`.
- The agent definitions `parent` and `leaf` are in `workspace/.agents/agents/`. They exist
  in the project layer of the current configuration. `parent` has `tools: Agent`, so the
  child can start the grandchild.
- The model is the stub model. The text of the sessions is from `script.json`.

## The steps to make it again

1. Build the stub agent from the package root:
   `swift build --product acp-agent-stub`
2. Run the script from the package root:
   `python3 Recordings/interrupted-nested-child/make.py "$PWD/.build/debug/acp-agent-stub"`

The script does these steps:

1. It deletes `workspace/`, and writes the two agent definitions in it.
2. It writes `script.json` from `script.template.json`. The script is for the stub model
   (`ACP_AGENT_STUB_SCRIPT`). The root calls the `agents` tool to start `parent`. `parent`
   calls the `agents` tool to start `leaf`. `leaf` plays one `gate` step on a file that
   never exists.
3. It starts `acp-agent-stub acp` in `workspace/` with an offline defaults layer (no skills
   marketplace) and its own config and data folders.
4. It sends `initialize`, `session/new` and `session/prompt` on the stdin of the agent.
5. It waits until the transcript of `leaf` holds its prompt. Then the grandchild is running.
6. It closes the stdin of the agent. That is the orderly shutdown: the sessions are suspended
   and get no `endedAt` mark.

Each run makes new session ids. After a new run, write the new ids in the table above. The
`cwd` is a fixed path, thus make the recording at this place.

## How to check the result

- `grep -rl endedAt workspace/.acp-agent/transcripts` prints nothing.
- Each `workspace/.acp-agent/transcripts/<session id>/index.md` of the child and the
  grandchild has an `agentSpawn` block.
