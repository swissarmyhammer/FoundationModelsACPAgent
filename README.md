# FoundationModelsACPAgent

[![CI](https://github.com/swissarmyhammer/FoundationModelsACPAgent/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACPAgent/actions/workflows/ci.yml)

A complete [Agent Client Protocol](https://agentclientprotocol.com) coding
agent over local models — one type to construct, one connection to serve.

`RoutedACPAgent` composes the family: Router resolves the models, a layered
dotfolder stack gives configuration, instructions and skills, and a code-mode
tool surface gives the model files, shell and MCP behind one `runCode`
function. A frontend chooses a dotfolder name. Everything else derives.

```swift
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent

// The one choice a frontend makes. It roots <cwd>/.acp-agent/ for the
// project layer and the transcripts.
let name = try DotfolderName("acp-agent")
let cwd = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

// The home of the host: here the XDG folders, ~/.config/acp-agent/ for the
// user layer. An app gives its own two roots with AgentHome.makeCustom.
let home = AgentHome.makeXDG(name: name, environment: ProcessInfo.processInfo.environment)

// Loads the configuration stack and resolves the profile over the real
// models: the configured weights download on first use and stay resident.
let composed = try await ComposedAgent.compose(name: name, workingDirectory: cwd, home: home)

// Full duplex on one pipe: the read loop serves every request while a prompt
// streams session/update notifications. stdout carries ndJSON only; logs go
// to stderr. A read-one-then-write-one loop deadlocks here.
let connection = await composed.serve(over: .stdio, logger: .standardError)
// The connection serves until the client closes the wire. A closed connection
// frees its sessions and they go on, so the host closes each open session
// before it exits, and the history of each session is written.
_ = await connection.closed
await composed.waitForConnectionTeardown()
await composed.closeOpenSessions()
```

A host that makes its own `AgentSideConnection`, for example over an
in-process transport, gives the agent from the factory closure. The call is
synchronous and does not throw, and it starts no transport of its own:

```swift
let connection = await AgentSideConnection(stream: transport) { connection in
    composed.agent(boundTo: connection)
}
```

The same composition, with its full commentary, is
[`Sources/FoundationModelsACPAgent/ComposedAgent.swift`](Sources/FoundationModelsACPAgent/ComposedAgent.swift),
the composition the `acp-agent` CLI builds every mode on.

## Install

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsACPAgent.git", branch: "main")
```

## The machine, and the models

The agent needs a Mac with **32 GB** of memory. The default profile fills
three model slots at one time, and Router's `JointFit` prices the three
models together against the memory of the machine. A 27B model at 4 bits is
approximately 15 GB alone, so a 16 GB machine is too small.

| Slot | Default model | MTP drafter |
|---|---|---|
| `standard` | `mlx-community/Qwen3.8-27B-4bit` | `mlx-community/Qwen3.8-27B-MTP-4bit` |
| `flash` | `mlx-community/Qwen3-4B-4bit` | none |
| `embedding` | `erjigit17/embeddinggemma-300m-ane-coreml` | none |

These three are the defaults of `ProfileConfiguration` in
[`Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift`](Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift).
The `profile:` section of a `config.yaml` replaces the candidates of any
slot.

Every slot takes a Hub repository id or a folder on the disk. The loader finds
the format (MLX or Core ML) by itself from the files: a `.mlpackage` folder and
no `safetensors` file means Core ML, which runs on the Apple Neural Engine
(only the `embedding` slot loads Core ML). Any other model loads with MLX.

```yaml
profile:
  embedding:
    - ~/models/embeddinggemma-300m-ane-coreml   # a folder: no download
```

A path starts with `/`, `~` or `./`. Use an absolute path or `~`: `./` is
relative to the working directory of the agent process. A path must not hold
`@`, which is read as a revision. `doctor` shows the format it found in the
folder.

The `standard` slot decodes with MTP (multi-token prediction): its MTP head
drafts a few tokens each round, and the model checks them in one pass. The
output is the output of plain decoding, and it comes faster. A reference
turns MTP on only when it names its `drafter`, in the mapping form:

```yaml
profile:
  standard:
    - repo: mlx-community/Qwen3.8-27B-4bit
      drafter: mlx-community/Qwen3.8-27B-MTP-4bit
```

A plain string (`- mlx-community/Qwen3.8-27B-4bit`) decodes with no drafter.

The first run downloads the weights of each slot, which is many gigabytes.
The weights stay in the Hugging Face cache, so a later run starts from
disk. `acp-agent doctor` is the command that checks a configuration before
the first run. Its checks are not written yet: today it runs no check and
exits 0.

## Command line

`acp-agent` is one binary with one subcommand tree. `run` is the default
subcommand, so `acp-agent "write a haiku"` runs a prompt.

| Command | What it does |
|---|---|
| `acp-agent run` | Run one prompt, and print the answer. This is the default. |
| `acp-agent acp` | Serve ACP on stdin and stdout. |
| `acp-agent config show` | Print the merged configuration, and where each value came from. |
| `acp-agent config init` | Write a `config.yaml` with every key at its default. |
| `acp-agent config path` | Print each layer path, and say which ones exist. |
| `acp-agent config edit` | Open the nearest `config.yaml` in `$EDITOR`. |
| `acp-agent instructions eject` | Write `Instructions.md` into a layer. |
| `acp-agent doctor` | Check that this configuration will actually work. |
| `acp-agent snapshots list` | List each snapshot folder, with its checkpoint count, the time of its last checkpoint, and `recorded` or `unrecorded`. `--json` gives the same data as one JSON array. |
| `acp-agent snapshots remove <key>...` | Remove the snapshot folders of the named session keys. A key with no snapshot folder goes to stderr, and the exit status is 1. `--unrecorded` removes each folder that no recorded session has. |

`acp-agent --help`, and `--help` on any command, gives the options. Each
command that reads the settings takes `--home <dir>`, the folder of the home
of the CLI (see [The home](#the-home)).

## Tools

The model-facing surface is two code-mode tools from
`FoundationModelsMultitool` — `searchTools` and `runCode` — plus the
standalone `skills` and `agents` tools. A `runCode` run that does not settle
in its inline grace continues in the background. When the run settles, its
result is injected into the session as a new message, and that message starts
the model working again. While the run continues, the model does other work
that does not need the result, or it does nothing. The model does not call a
tool to wait for the result or to check it. Capability modules mount
inside the Multitool registry, one row here per capability. Each capability
is on by default. Set its config section to `false` to set it off.

| Capability | What it gives the model | Config section |
|---|---|---|
| `files` | The `tools.files.*` verbs, confined to the session root set | `tools.files` |
| `shell` | The `tools.shell.*` verbs, under a Seatbelt sandbox over the root set | `tools.shell` |
| `mcp` | The verbs of each connected MCP server, as `tools.<server>.*` | `tools.mcp` |
| `codeContext` | The `tools.code_context.*` verbs — symbol lookup, call graph, blast radius and the language server operations — over an index of the session working directory | `tools.codeContext` |
| `web` | The `tools.web.search` and `tools.web.fetch` verbs: search the web, and read one page | `tools.web` |
| `git` | The read-only `tools.git.*` verbs — `blame`, `show`, `log`, `commit`, `status`, `branches`, `changes` and `diff` — over the repository of the session working directory | `tools.git` |
| `environment` | The read-only `tools.environment.*` verbs — `variables` (the environment variables of the agent process), `os` (the platform, the host and the user) and `now` (the date and the time) | `tools.environment` |
| `snapshots` | The `tools.snapshots.*` verbs — `list`, `take` and `rollback` — over the workspace snapshots of the session. Each tool call that changes a file of a git work tree makes one checkpoint. A rollback returns the work tree to a checkpoint and adds a new checkpoint, so the history is append only. The snapshots are in the `snapshot` folder of the hook data of the home: `<local>/hooks/snapshot` of a custom home, and `$XDG_DATA_HOME/<name>/hooks/snapshot` (default `~/.local/share/acp-agent/hooks/snapshot`) of the XDG home of the CLI. The folder of a session stays after the session ends, and the agent removes no folder at start, because another process can run the session of a folder. `session/delete` removes the folder of its own session. `acp-agent snapshots list` shows the folders, and `acp-agent snapshots remove` removes the ones that you name, or each `unrecorded` one with `--unrecorded`. A folder is `recorded` when the recording root of a registered project has the session folder, with its `index.md`, of its session. Always on | none |
| `settings` | The `tools.settings.querySettings` verb: one GraphQL document over the agent settings, the same schema as the `settings` endpoint. A query gives the merged value of a key for the session folder and the level that set it. A mutation sets or clears a key on the `USER` level or on the `SESSION` level of the session folder. The verb takes no `cwd`: the session folder applies, and a `cwd` of a different folder is refused. It is only in the registry, not a top-level tool. Always on | none |
| `skills` | The standalone `skills` tool, over the `skills` dotfolder stack and the `marketplaces` list. Always on | `tools.skills` |
| `agents` | The standalone `agents` tool of `FoundationModelsAgents` — `list agents`, `start agent`, `check agent`, `cancel agent`, `send agent` and `send caller` — over the agent folders `<id>/AGENT.md` and `agents/<id>/AGENT.md` of the `agents` dotfolder stack. Always on | none |

The `skills` tool and the `agents` tool are always on. A config that sets
`tools.skills: false`, `tools.agents: false` or `tools.agents.enabled: false`
still loads: the loader gives a warning, and the tool stays on.

`tools.files` has four keys. `readOnly`, `allowSymlinks` and `recordsChanges`
are flags, and each default is `false`. `exclude` is a list of patterns in
gitignore syntax. The search verbs (`files.grep`, `files.glob` and each other
verb that walks a tree) skip a path that a pattern matches, also when a call
sets `respectGitIgnore: false`. A read or a write of an explicit path does not
change. The default list is the dotfolder of the agent, `.<name>/`
(`.acp-agent/` for the CLI), which holds the transcripts, thus a search does
not give the model its own earlier output. `ConfigurationLoader` puts the
default in from the dotfolder name. A list replaces the default; add the
dotfolder to your list to keep it. `exclude: []` turns the exclusion off.
`config show` and `config init` show the list in effect.

```yaml
tools:
  files:
    exclude:
      - .acp-agent/
      - build/
```

`tools.codeContext` has two keys. `autoInstall` (default `true`) says whether a
language server that is not installed is installed automatically.
`semanticSearch` (default `true`) says whether the index embeds each chunk with
the `embedding` slot of the profile, which the `searchCode` verb ranks with.
That pass is long for a large repository, and it uses the same GPU as the
model; with `false`, the index calls no model, each other verb works, and
`searchCode` answers with an error that says the embedding layer is off. The
first index pass runs after the session starts, thus `session/new` does not
wait for it.

`tools.web` searches with no setup. With no API key, the providers are the
keyless result pages of DuckDuckGo (`duckDuckGoHTML`), then Brave
(`braveHTML`). An API key adds its provider before them. The agent reads
the keys from its process environment, and from the `tools.web.apiKeys` map:

| `apiKeys` key | Environment variable | Provider |
|---|---|---|
| `brave` | `BRAVE_SEARCH_API_KEY` (or `BRAVE_API_KEY`) | `braveAPI` |
| `tavily` | `TAVILY_API_KEY` | `tavily` |
| `exa` | `EXA_API_KEY` | `exa` |
| `serper` | `SERPER_API_KEY` | `serper` |
| `kagi` | `KAGI_API_KEY` | `kagi` |
| `searxngURL` | `SEARXNG_URL` (a base URL, not a key) | `searxng` |

The order to try is the order of this table, then `duckDuckGoHTML`, then
`braveHTML`. The first provider that gives results wins. A key in
`config.yaml` wins over the environment variable of the same provider. An
empty value is not a key. Another `apiKeys` key is an error that names the
valid keys.

```yaml
tools:
  web:
    enabled: true
    apiKeys:
      tavily: keychain:tavily-api-key
```

A value `keychain:<name>` is a reference. The agent gets the key from the
Keychain item whose account is `<name>`: the login Keychain under the service
`acp-agent` for the CLI, or the store that a host gives. A reference with no
item gives one warning that names the key path and the reference, and the key
is not set. A lookup that fails, for example on a locked Keychain, gives one
warning that says the lookup failed, and the key is not set. Another value is
the key itself.

Set `enabled: false` (or `web: false`) to set the web tool off. No key value
shows: `config show`, `/config`, `doctor` and the logs show
`keychain:<name>`, `<redacted>` or the provider name only, and
`/config export` writes the references and no key. `config show`
ends with one comment line that names the providers in force, and `doctor`
has one row for them. The web verbs run in the agent process, not in the
shell sandbox; they refuse private and local addresses.

`tools.git` has one key, `enabled` (default `true`). The git verbs only read
the repository: they change no file, no index and no branch. Their root is the
session working directory, which can be a folder below the top of the
repository. Outside a repository, each verb gives a correction that the model
reads, and the session continues. Set `enabled: false` (or `git: false`) to set
the git tool off; `doctor` then has one row that says it is disabled.

```yaml
tools:
  git:
    enabled: false
```

`tools.environment` has one key, `enabled` (default `true`). The tool has
three read-only verbs: `variables` (each environment variable of the agent
process, or the variables that a `name` or a `prefix` selects), `os` (the
platform name and version, the architecture, the host name, the user name, the
home directory, the processor count, the memory and the locale) and `now` (the
date and the time, in an optional `timeZone`). Set `enabled: false` (or
`environment: false`) to set the environment tool off; `doctor` then has one
row that says it is disabled.

```yaml
tools:
  environment: false
```

**Know the environment risk.** `tools.environment.variables` gives the model
each variable of the agent process, and secrets are included. An example is
the web API keys that `tools.web.apiKeys` reads from the environment. The
value goes into the model context and into the transcript. There is no
variable filter. If the agent process holds a secret, set the environment tool
off. When the tool is on, `doctor` has one row that states this risk; the row
shows no variable value.

The `tools.skills.marketplaces` list names remote skill marketplaces. Each entry
has a `url`, and optionally a `ref` (a branch or a tag), a `sha`, a `path`, an
`alias`, a `select`, an `autoUpdate` and a `grants` key. The default list has
one marketplace: the `main` branch of `swissarmyhammer/skills`. It gives skills
and agents:

```yaml
tools:
  skills:
    marketplaces:
      - url: https://github.com/swissarmyhammer/skills.git
        ref: main
```

A session start fetches each marketplace, thus the default needs the network.
The fetch goes into the cache folder `SKILLS_MARKETPLACE_CACHE` when that
variable is set. A fetch that fails gives a diagnostic, and the session starts
with no marketplace skill. To use only the local `skills` and `agents`
dotfolder stacks, set an empty list in the user layer or in the project layer:

```yaml
tools:
  skills:
    marketplaces: []
```

Use the HTTPS form of a marketplace URL. The SSH form (`git@github.com:…`) is
not supported: the skills package gives `unreachable` for it, and the session
then has no marketplace skill.

The `agents` tool has no option, thus the config has no `tools.agents`
section. The tool starts an agent in its own session: an agent is a folder
`<id>/AGENT.md` or `agents/<id>/AGENT.md` in a layer of the `agents` dotfolder
stack (`<cwd>/.agents/`, and the user level of
[Settings folders](#settings-folders)), or a folder `agents/<id>/AGENT.md` in a
marketplace of `tools.skills.marketplaces`. In one layer, `<id>/AGENT.md` wins
over `agents/<id>/AGENT.md`, and the root `AGENT.md` of a layer is the default
agent. The agent registry reads the same marketplace
store as the skills. A `start agent` call waits for its run for the settle
period of the session. A run that ends in that time gives its final message
as the output of the call; a longer run goes to the background, and its final
message is injected into the session as a new message, which starts the model
working again. Each run gets the `searchTools`,
`runCode` and `skills` tools, and the root session and the runs read one skills
registry. When the session closes, its agent runs stop first.

**Know the sandbox limit.** The sandbox is the only gate on shell commands:
there is no permission prompt, and the agent never sends
`session/request_permission`.
The sandbox bounds writing and deleting only. Reads are free and the network is open, so exfiltration is not bounded.

## Shutdown and restart

The agent leaves the working agent runs restorable when the process ends in an orderly way. An
orderly shutdown pauses the work. It does not cancel the work. The shutdown happens at the end of
the input, at `SIGTERM`, and at the end of `acp-agent run`. The order is:

1. `RouterSessionDirectory.suspendLiveSessions()`. After this, the journal of each session
   refuses every terminal event, so a run that works stays an orphan in the journal of its
   caller.
2. Each tool call that runs gets the status `paused`, in the session and in each session nested
   in it. A `paused` call gets no final status, neither on the wire nor in the history. Each
   open prompt ends with the stop reason `_interrupted`, and no call gets the status
   `cancelled`.
3. `AgentRunner.stop()` stops the agent runs. A stop marks no run as ended and posts no result.
4. Each session closes, the parent before the child. The history is written, and the MCP
   servers stop.

The shutdown never calls `cancelRuns(caller:)`. It would mark each run as ended, and nothing
would be restored. `acp-agent acp` and `acp-agent run` run the shutdown first, and then wait
until the connections are torn down. The reverse order is wrong: the teardown of a connection
waits for its open prompts, and a prompt that waits for a child can end only after the run
grace. The child would then be complete, and not restorable.

A user `session/close` is not a shutdown. It cancels the work with `cancelRuns(caller:)`, and
each run of the session is marked as ended with the reason cancelled. A connection that closes
while the process lives is not a shutdown either: the sessions stay active, and nothing is
suspended.

The history of a `paused` call has no final status. The next `session/resume` reads this as an
interrupted call, and restores the child that the call started (see
[Sub-agent sessions](#sub-agent-sessions)).

## Sub-agent sessions

A sub-agent is an ACP child session. The `agents` tool starts an agent run, and the agent shows
the run to the client as a session with its own `sessionId`. A run can start runs of its own.
The sessions then make a tree. The root of the tree is the session that the client made with
`session/new`. A child session is the same kind of session as a root session. It has a parent
link and a set of permitted methods. No code path is special for a child.

### The sessions and their ids

- The id of a child session is the id of its run. It is the ULID of the Router session of the
  run. The id is the same after a restore, also in the next process.
- No client request makes a child session. `session/new` makes roots only.
- The agent announces a child with a `subagent_update` on the stream of its parent. The
  announcement comes before any message that uses the id of the child. It has the agent name
  as `title`, the agent description, the `capabilities` and the `state`. A run of a run is
  announced on the stream of its parent run, after that parent.
- Each session sends its own events under its own id: text, tool calls, `state_update` and the
  announcements of its own children. The `state_update` of a child is `running` while its run
  works, and `idle` when it ends.
- The final `tool_call_update` of an `agents` call comes after the last update of its child and
  after the final `idle` of that child.
- `session/list` shows root sessions only. A child has its own recording, and the list leaves it
  out.
- A client that reads all sessions in one stream (`subscribeToAllSessions()` of the client
  connection) sees the wire order. `SubagentWireTraceValidator` of FoundationModelsACP checks a
  recorded trace against the rules. The suites `SubagentSessionsTests` (real processes) and
  `SubagentSessionsReplayTests` (in process) use it.

### What a client can do with a session

Each session has a set of permitted methods. A root session permits every method. A child
session permits only the methods that its `subagent_update` advertises in `capabilities`.
The agent advertises `cancel` only. A method that the set does not name is refused with an
invalid params error. The error `data` holds the session id, the method and the reason. The
handlers of `session/prompt`, `session/close`, `session/delete`, `session/resume` and
`session/set_config_option` check the set. A `session/cancel` for a session that does not
permit it is ignored.

### Cancel and close

- `session/cancel` on the id of a child cancels the foreground work of that child only: its
  model work, its queued mail, and the runs that it waits for inline. The client sees `idle`
  with the stop reason `cancelled` for the child, and for each run that it waited for. The
  parent and the sibling sessions go on.
- `session/cancel` on a parent stops the foreground work of the parent. A child that the
  prompt waits for inline is cancelled. A child that the `background` list names goes on.
- `session/close` on a root session cancels all the runs below it, nested ones too. Each
  working sub-agent sends `idle` with the stop reason `cancelled`, and the open `agents` call
  of the root gets the final status `cancelled`. `session/close` on a child is refused.

### Messages between sessions

The agent shows a message between a caller and a child as `session_message` updates. A message
has two views. The outgoing view is in the transcript of the sender. The incoming view is in the
transcript of the receiver. Each view has its own `messageId`. The outgoing view names the
incoming view in `recipientMessageId` and `recipientSessionId`. The incoming view names the
outgoing view in `senderMessageId` and `senderSessionId`. Both ids come from one key, so the
same message has the same two ids after a restore. Three routes make messages:

- The mail that the `agents` tool sends with `send agent` and `send caller`.
- A message that a run posts to its caller.
- The final reply of a run. A run that failed or was cancelled has no reply, so it has no
  outgoing view.

### Cold resume

A cold resume is a `session/resume` of a root session that is not live in this process. This
is the case after a restart of the process.

1. The agent restores the root session. It then restores each child whose `agents` call has no
   final status in the history. These children are the interrupted runs. A shutdown of the
   process leaves them like this, because it pauses the calls and does not cancel them. The
   agent builds the tools and the instructions of a restored child from the current agent
   definition. A child whose call has a final status is finished. The agent does not restore
   it, but a replay still sends its history.
2. With `replayFrom: start`, the agent replays the history of the tree before the response. The
   announcements go first, the parent before the child. Then each session sends its history
   under its own id. A replayed announcement has no `capabilities`. A replay sends no
   `state_update` of a child and no request to the client.
3. The agent sends the current `state_update` of the root with its `background` list, the
   `session_info_update`, and then the response.
4. After the response, the agent sends the current snapshot of each child, the parent before
   the child: a `subagent_update` with the state, the `capabilities` and the working
   directory, and then the `state_update` of the child. A restored child is `idle` in its
   snapshot. A child that did not restore gets one `subagent_update` with no state, no
   capabilities, and the reason in `_meta.sah.restoreFailure`. The same holds for its
   descendants.
5. After the snapshots, the agent starts the restored runs again (the re-drive), the children
   before their callers. Each run gets a first message that says the process stopped while it
   worked. The end of a re-driven child completes the original `agents` call of its caller.
   The agent starts nothing when the root closed, or lost its connection, since the resume.
   A child that did not restore has no run to start. Its original call already ended with the
   status `lost`.

The response is the freshness boundary. All history comes before it. All current state of the
children comes after it. A snapshot of a child is the first update of that child after the
response.

### Hot resume

A hot resume is a `session/resume` of a root session that is live in this process. The new
connection takes over the whole live tree, the root and the sessions nested in it, and the work
goes on. Nothing is torn down: the open prompts stay open, the running sub-agent runs keep
running, and the Router sessions stay as they are. The order is:

1. The agent takes the session for the new connection. A `userDevice` connection takes each
   session. An `external` connection takes only a session that has no owner. Otherwise the
   request fails with `SESSION_HAS_OWNER`, and the owner does not change.
2. The agent withdraws the open questions of the tree from the old connection.
3. The agent replays the tree (with `replayFrom: start`), sends the current state, and sends
   the response.
4. After the response, the agent sends the current snapshot of each child, and asks the
   withdrawn questions again on the new owner. A question goes out after the snapshot of its
   child.

### The stub script in tests

The test-only product `acp-agent-stub` is the command tree of `acp-agent` over a stub model. The
environment variable `ACP_AGENT_STUB_SCRIPT` names a JSON file that tells the stub model what
each session says and calls:

```json
{ "sessions": [
    { "match": { "promptContains": "<text>" },
      "passes": [ [ <step>, ... ], [ <step>, ... ] ] } ] }
```

- The first prompt of a session chooses its entry: the first entry whose `promptContains` text
  is in the prompt. Each session plays its own copy of the passes.
- A pass is one model call. The passes play in order. After the last pass, and for a prompt that
  no entry matches, each call echoes the prompt.
- A step has one key: `text` (a text delta), `reasoning`, `toolCall` (`name` and `arguments`),
  `gate` (a path: the pass waits until a file exists there, or until one byte can be read
  from the named pipe there; a stop of the run ends the wait while the file is missing) and
  `elicit` (a form question to the user; the session needs the `runCode` tool).
- A file that is not valid stops the agent with an error that names the place. It never
  becomes a silent echo.

To start a nested agent, a pass calls the `agents` tool:
`{"toolCall":{"name":"agents","arguments":{"op":"start agent","name":"<agent>","prompt":"<text>"}}}`.
The project folder must hold `.agents/agents/<agent>/AGENT.md`. An agent that starts agents of its
own needs the line `tools: agents` in its front matter. `SubagentSessionsTests` in
`IntegrationTests` plays a chain of three sessions this way.

## Settings folders

Each settings stack comes from one list of folders (`SettingsFolders`), at two
levels over the built-in level. The session level wins over the user level.

- **The session level** is the project dotfolder of the working directory of
  each session: `<cwd>/.<name>/` for `config.yaml` and `Instructions.md`,
  `<cwd>/.skills/` for the skills, `<cwd>/.agents/` for the agents, and
  `<cwd>/.rules/` for the rules.
- **The user level** comes from the home of the host (`AgentHome`), which
  `ComposedAgent.compose` and `RoutedACPAgent.init` take as `home:`.

### The theme

The top-level `theme` key of `config.yaml` is one string: `system` (the
default), `light` or `dark`, in any case. Another value is an error that names
the choices. The agent does not read the key: it keeps it in the settings stack
for a host, which reads and sets it through the `settings` endpoint with the key
path `["theme"]`.

```yaml
theme: dark
```

### The home

The home holds each folder outside the project that the agent reads or
writes. It has two roots:

- **synced**: the data that follows the user from device to device: the user
  level of each settings stack, and the projects folder.
- **local**: the state of this machine, which never syncs: the hook data and
  the snapshot timelines, the caches (the skills marketplace, the models, the
  router metadata, the install record of the language servers), and the
  machine state of each project, such as the shell store.

An app gives its own two roots with `AgentHome.makeCustom(synced:local:)`, for
example a folder in its iCloud container and a folder in Application Support.
The `acp-agent` CLI uses `AgentHome.makeXDG(name:environment:)`, which keeps the
XDG folders that the CLI always used. The CLI takes a home folder with
`--home <dir>` (on `run`, `acp`, `config`, `instructions eject`, `doctor` and
`snapshots`) or with the `ACP_AGENT_HOME` variable; `--home` wins. That folder
gives the custom home `<dir>/synced` and `<dir>/local`. With neither, the CLI
uses the XDG home.

| Kind | Custom home | XDG home (the CLI) |
|---|---|---|
| `config.yaml`, `Instructions.md` | `<synced>/` | `$XDG_CONFIG_HOME/<name>/` (default `~/.config/<name>/`) |
| skills | `<synced>/_skills/` | `$XDG_CONFIG_HOME/skills/` |
| rules | `<synced>/_rules/` | `$XDG_CONFIG_HOME/rules/` |
| agents | `<synced>/` | `$XDG_CONFIG_HOME/agents/` |
| hook data and snapshots | `<local>/hooks/` | `$XDG_DATA_HOME/<name>/hooks/` (default `~/.local/share/<name>/hooks/`) |
| skills marketplace cache | `<local>/skills-marketplace/` | `SKILLS_MARKETPLACE_CACHE`, or its default folder |
| model cache | `<local>/models/` | `HF_HUB_CACHE` or `HF_HOME`, or `~/.cache/huggingface/hub` |
| shell store of a project | `<local>/projects/<key>/shell/` | `$XDG_DATA_HOME/<name>/projects/<key>/shell/` |
| projects folder (one file for each project) | `<synced>/projects/` | `$XDG_CONFIG_HOME/<name>/projects/` |

With a custom home, no stack holds a folder in the home directory or in
`XDG_CONFIG_HOME`. The agents layer of the synced root is the root itself, so
an agent is `<synced>/<id>/AGENT.md` (or `<synced>/agents/<id>/AGENT.md`), and
the session level is `<cwd>/.agents/`, never the working directory itself. A
folder in the synced root whose name starts with `_` holds settings: it is
never a valid agent id, so `<synced>/_skills/` and `<synced>/_rules/` are not
agents and give no diagnostic. The built-in level is the defaults folder that
`<NAME>_DEFAULTS_DIR` names, for example `SKILLS_DEFAULTS_DIR`, and the
compiled-in `builtin.config.yaml`. `acp-agent config path` shows the layers of
these folders, and `acp-agent doctor` shows the two roots of the home and
whether each one can be written.

## Instructions

The system prompt is one markdown file, `Instructions.md`, resolved through the
dotfolder stack. The nearest layer wins, and it replaces the whole file:
compiled in, then the user level (`<synced>/Instructions.md` of a custom home,
or `~/.config/<name>/Instructions.md` of the XDG home of the CLI), then
`<project>/.<name>/Instructions.md`. Additive instructions go in `AGENTS.md`.
`Instructions.md` replaces; `AGENTS.md` adds.

The compiled-in floor is
[`Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift`](Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift)
— one copy of the text, never mirrored here. It is written for a small local
model, and its doc comment states why each section reads the way it does.

## Design decisions

The code depends on these decisions. The doc comment at each place in the
code gives the local detail.

- **ACP v2 only.** A client that asks for an earlier protocol version gets
  version 2 in a successful `initialize` response. The client then decides
  to disconnect. Extensions go in `_meta`, and an extension value of an
  enum starts with `_` (for example the tool status `_lost` and the stop
  reasons `_no_output`, `_stalled` and `_truncated`).
- **No authentication.** A local agent on the device has nothing to
  authenticate. The agent advertises no `authMethods`, and `auth/login` gives
  `-32601`. The dotfolder name never goes on the wire: `initialize` reports
  the package name.
- **One ACP session is one root Router session.** The ACP `sessionId` is the
  ULID of the root Router session. There is no mapping table, because a table
  can drift and a resume then restores the wrong conversation. A fork is
  never an ACP session. A sub-agent is an ACP child session of its parent
  (see [Sub-agent sessions](#sub-agent-sessions)): `session/list` does not
  show it, and it does not accept `session/prompt`.
- **An agent run is announced with `subagent_update`.** The agent sends one
  `subagent_update` on the parent session before any message that uses the id
  of the child. The id of the child is the id of its run. The update has the
  agent name as `title`, the agent description, the `cancel` capability and
  the `state`. The update has no `cwd` and no `additionalDirectories`,
  because a run has no public working directory. When an `agents` tool call
  started the run, `_meta.sah.agentRun.toolCallId` names the ACP tool call of
  that call. The announcement waits for that tool call id, and it waits in
  its own task, so one run never holds another run. A run of the host has no
  tool call, so it is announced at once with no link. Later updates carry
  only the fields that changed. The end of the run sends the final `state`.
  A run of a run is announced on its parent run, after the parent. The agent
  sends nothing for a closed session or a closed connection.
- **A prompt is mail.** `session/prompt` puts the prompt into the mailbox of
  the Router session, and the response comes at once: its `messageId` is the
  `MailID` of the prompt. A prompt that comes while another one is open is
  accepted too. The prompt ends at the terminal event of its own mail, so a
  client waits for the first `idle` after the echo of its own `messageId`.
- **`running`, `requires_action` and `idle` follow the work of the
  session.** The session is busy while Router works (an answer that runs, an
  open background run, or queued run mail) or a prompt is open. `running`
  goes out when the session becomes busy, also with no prompt open, and
  `idle` when it is not busy any more. The `idle` carries the stop reason of
  the last prompt that ended since the last `running`. After only background
  work it has no stop reason. A run that waits only for the user is no work,
  so an open question does not keep the session `running`. While a question
  of the session waits for the user, the agent sends `requires_action`. When
  the question ends, it sends `running` or `idle`. An accepted URL-mode
  question ends only when its flow completes or ends, so the session stays
  `requires_action` while the user works in the browser. The copy of a
  question of a child session sends nothing. A `session/resume` sends the current state
  after the replay and before the response.
- **Every `state_update` lists the background work.** The `background` list
  holds the work that goes on apart from the foreground work. An item is a
  terminal, a tool call, or a running sub-agent session. The list is `[]` when nothing
  goes on apart. An item is listed only after its update went to the client.
  It leaves the list only after its final status or its exit status went to
  the client. When the list changes, the agent sends the state again with the
  new list. A tool call whose terminal runs is listed as that terminal. A
  sub-agent is listed while its session is not `idle`, or while its own list
  is not empty. A `session/resume` with no replay sends the current update of
  each listed item before the state.
- **`session/cancel` is a signal.** It sends `cancelForeground()` to the Router
  session. It stops the queued mail, the model work, and the inline runs that
  the prompt waits for. A run in the background goes on, and so does each
  sub-agent that the `background` list names. Each open prompt ends
  `cancelled` at once, and its response says so. A `session/cancel` on the id
  of a sub-agent cancels only the run of that sub-agent and the runs that it
  waits for. Its client sees `idle` with the stop reason `cancelled`, and the
  parent and the siblings go on. A `session/close` of a parent cancels all the
  runs below it, nested ones too, and each working sub-agent sends `idle` with
  the stop reason `cancelled`. The `idle` comes when the work of the session ends. You can only stop
  what you stop: model work that ignores cancellation runs to its end, so
  that `idle` can come later than the response, and the client can send
  input before it. With no prompt open and no work, it sends the signal and
  no state update.
- **`acp-agent run` waits for its `idle`.** The headless CLI stops at the
  first `idle` after the echo of its own prompt. That `idle` comes when the
  session has no work, so the CLI also waits for the background runs that its
  prompt started.
- **A pause of the mail delivery is a session update.** Router holds new run
  results when 100 answers in a row had no caller message, and it starts no
  answer for them. The agent then sends one `_mail_delivery_paused` update
  before the `idle`. Its payload is `limit` (the limit in force), `heldCount`,
  `heldMail` (one `{tool, op, completionToken}` object for each held result,
  in queue order) and `message` (one line for a person). The history keeps
  the update, so a resume sends it again. The next `session/prompt` carries
  the held results into its answer and lifts the pause; no update tells of
  the lift. A headless `acp-agent run` cannot send a next prompt, so it
  writes the reason on stderr and exits 6.
- **`/compact` is a signal.** It starts the compaction and returns at once with
  "Compaction started." and the `SignalID`. The compaction entry of the
  session gives the result: the summary, the tokens before and after and the
  summarizer model, or the reason of a failure or a shortfall.
- **The sandbox is the only gate.** The agent does not advertise or send
  `session/request_permission`. There is no permission mode, no
  `permissions:` section and no stored decision. A denylist over the command
  text is easy to bypass, and a question that a person answers a hundred
  times each day is not a boundary. `SeatbeltSandbox` is a kernel boundary,
  and the spelling of a command does not change it. Its writable roots are
  the session root set: the `cwd` and the `additionalDirectories`. The root
  set is never empty, because an empty list gives write access to the working
  directory of the process. `sandbox.extraWritePaths` is the only
  configuration key. A failed sandbox preflight stops the command, and no
  command runs without the sandbox. The sandbox limit below applies.
- **Transcripts are project context, and you commit them.** A session records
  to `<cwd>/.<name>/transcripts/<sessionId>/`: one folder for each session,
  with its transcript and an `index.md`, whose YAML frontmatter holds the
  record of the session (its working directory, title, additional
  directories and last activity). No file is shared by two sessions, thus two
  persons make no merge conflict, and a synced folder has no file that two
  devices write. `session/list` reads the `index.md` of each session folder,
  and lists a session after its first prompt. The projects folder of the
  home holds one file for each project that ran a session, and the
  cross-project `session/list` reads it. The `transcripts.location` key of
  `config.yaml` moves the root: `project` (the default), `home`, or an
  absolute path. A host that runs the agent in its own process can set the
  location in code, with no config file:
  `ComposedAgent.compose(..., transcriptLocation: .path(directory))`. That
  value wins over every config layer, in `session/new`, `session/resume`,
  `session/list` and `session/delete`. It is not a config layer, so
  `config show` does not show it.
- **No redaction.** The agent records each transcript verbatim. Redaction
  damages the record, and a partial redaction gives false confidence. To
  record less, set `recording.level: off` in the project layer. There is no
  level between `full` and `off`.
- **Client MCP servers are not stored.** The `mcpServers` of `session/new` and
  `session/resume` connect after the configured servers, for that session
  only. Their headers can hold tokens, and the session metadata is committed.
  A client server whose name is the name of an accepted server is refused.
  `tools.mcp: false` refuses the client servers too.
- **Configured MCP tokens can stay in the Keychain.** An `env` value or a
  `headers` value of a `tools.mcp` server can be `keychain:<name>`, for
  example `Authorization: keychain:github-mcp-token`. The agent gets the value
  from the Keychain item, as for `tools.web.apiKeys`. A reference with no item
  gives one warning that names the server, the key and the reference, and only
  that variable or header is not set. `config show` and `/config` show each
  reference, and show a literal header value as `<redacted>`. A literal `env`
  value shows as it is. `/config export` writes the references and no literal
  header value. A value of a client server of `session/new` is always a
  literal.
- **A capability is on until the configuration sets it off.** Set
  `tools.<name>: false` to set one capability off. There is no switch that
  sets all tools off.
- **Unknown and closed sessions.** `session/prompt` and
  `session/set_config_option` give `-32602` for an unknown or a closed
  session; a closed session must be resumed first. `session/resume` of a
  closed session succeeds. `session/close` of a closed session succeeds.
  `session/delete` succeeds also when the session does not exist.
- **`session/delete` is a real delete.** It removes the transcript directory
  and the index record. A version that git has stays in the git history.
- **A compaction changes only the model context.** The ACP history keeps each
  message with its id, and a compaction is one more entry in it. A resume
  replays the ACP history that the agent keeps in `session-history.json`,
  never the Router journal.
- **A `resource_link` reads only a file in the root set.** The agent reads a
  `file://` URI through the `files` capability. It refuses each other scheme,
  with a reason: a fetch that the user did not ask for is not permitted.

## Documentation

[`cli-plan.md`](cli-plan.md) is the design record of the `acp-agent` command
line. `swift test` runs the hermetic suites;
`swift test --package-path IntegrationTests` runs the tiers that spawn a built
binary or load a real model.

The agent uses the telemetry APIs only: swift-log, swift-distributed-tracing
and swift-metrics. By default it exports no telemetry: log records at
`warning` and up go to stderr, and tracing and metrics stay no-op.
`acp-agent acp --telemetry-file PATH` also appends each log record at `debug`
and up, each span when it ends, and each metric recording to `PATH`, one JSON
object for each line with a `type` of `log`, `span` or `metric`; stderr keeps
its `warning` records. The file holds no error description and no span status
message, only the type name of an error. The log record of `session/cancel` carries
`cancel.signal_id`, the `SignalID` of its `cancelAll()` signal. That key
replaces `cancel.result`, which an earlier version wrote. The OTLP exporter (`swift-otel`) is not a
dependency until SwiftPM 6.4.1, because SwiftPM 6.4 `update` loses the traits
that the root manifest sets on a dependency
(swiftlang/swift-package-manager#10397).

## License

No license file is currently published in this repository.
