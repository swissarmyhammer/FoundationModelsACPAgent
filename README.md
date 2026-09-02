# FoundationModelsACPAgent

The composed ACP agent over the Router runtime: `AgentConfiguration` over the
dotfolder stack, the tool roster, the slash-command registry, and
`RoutedACPAgent`, the ACP `Agent` conformance over Router sessions.

## Tools

The model-facing surface is three code-mode tools from
`FoundationModelsMultitool` — `searchTools`, `runCode`, and `wait` — plus the
standalone `skills` tool. The capability modules mount inside the Multitool
registry, one row here per capability. Each capability is on by default; set
its config section to `false` to turn it off.

| Capability | What it gives the model | Config section |
|---|---|---|
| `files` | The `tools.files.*` verbs, confined to the session root set | `tools.files` |
| `shell` | The `tools.shell.*` verbs, under a Seatbelt sandbox over the root set | `tools.shell` |
| `mcp` | The verbs of each connected MCP server, as `tools.<server>.*` | `tools.mcp` |
| `skills` | The standalone `skills` tool, over the `skills` dotfolder stack | `tools.skills` |

### The sandbox limit

The shell sandbox is the only gate on shell commands: there is no permission
prompt, and the agent never sends `session/request_permission`. Know its limit.
The sandbox bounds writing and deleting only. Reads are free and the network is open, so exfiltration is not bounded.

## Builtin instructions

The system prompt is one markdown file, `Instructions.md`, resolved through
the dotfolder stack. The nearest layer wins, and it replaces the full file:

1. Compiled in — the guaranteed floor below. It is never edited, only
   shadowed.
2. `~/.config/<name>/Instructions.md` — a machine-wide replacement.
3. `<project>/.<name>/Instructions.md` — a per-repo replacement.

Additive instructions go in `AGENTS.md`; `Instructions.md` replaces,
`AGENTS.md` adds.

The compiled-in floor is shown verbatim below. It is the text of
`BuiltinInstructions.text`, and `DocumentationSyncTests` makes sure this
section cannot drift from the code.

```markdown
# Instructions

You are a careful and experienced software engineer. You work in the
user's project, through the tools of this session.

## Work rules

- Read the applicable code before you change it. Do not guess when
  you can check.
- Make the smallest change that completes the task fully.
- Obey the patterns that already exist in the project. Do not invent
  a new pattern without a clear reason.
- Keep functions small, and give each symbol a clear name.
- Do not change code that has no relation to the task.

## Quality rules

- Add or update tests for each change of behavior.
- Build the project and run its tests before you report success.
- Report each failure honestly. Do not hide an error, and do not
  invent a result.

## Communication rules

- Be concise. Give the result first, and then the reason.
- Show the paths of the files you changed.
- If a requirement is not clear, ask the user before you continue.
```
