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

// The one choice a frontend makes. It roots ~/.config/acp-agent/ for the
// user layer, <cwd>/.acp-agent/ for the project layer, and the transcripts.
let name = try DotfolderName("acp-agent")
let cwd = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

// Loads the configuration stack and resolves the profile over the real
// models: the configured weights download on first use and stay resident.
let composed = try await ComposedAgent.compose(name: name, workingDirectory: cwd)

// Full duplex on one pipe: the read loop serves every request while a prompt
// streams session/update notifications. stdout carries ndJSON only; logs go
// to stderr. A read-one-then-write-one loop deadlocks here.
let connection = await composed.serve(over: .stdio, logger: .standardError)
// The connection serves until the client closes the wire. Then the agent
// closes each open session, and the host waits for that before it exits, so
// the history of each session is written.
_ = await connection.closed
await composed.waitForConnectionTeardown()
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

| Slot | Default model |
|---|---|
| `standard` | `mlx-community/Qwen3.8-27B-mxfp4` |
| `flash` | `mlx-community/Qwen3-4B-4bit` |
| `embedding` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |

These three are the defaults of `ProfileConfiguration` in
[`Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift`](Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift).
The `profile:` section of a `config.yaml` replaces the candidates of any
slot.

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

`acp-agent --help`, and `--help` on any command, gives the options.

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
| `snapshots` | The `tools.snapshots.*` verbs — `list`, `take`, `undo` and `redo` — over the workspace snapshots of the session. Each tool call that changes a file of a git work tree makes one checkpoint. The snapshots are in `$XDG_DATA_HOME/<name>/hooks/snapshot` (default `~/.local/share/acp-agent/hooks/snapshot` for the CLI). Always on | none |
| `skills` | The standalone `skills` tool, over the `skills` dotfolder stack and the `marketplaces` list. Always on | `tools.skills` |
| `agents` | The standalone `agents` tool of `FoundationModelsAgents` — `list agents`, `start agent`, `check agent`, `cancel agent`, `send agent` and `send caller` — over the agent folders `agents/<name>/AGENT.md` of the `agents` dotfolder stack. Always on | none |

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
      tavily: tvly-...
```

Set `enabled: false` (or `web: false`) to set the web tool off. No key value
shows: `config show`, `/config`, `doctor` and the logs show `<redacted>` or
the provider name only, and `/config export` writes no key. `config show`
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
`agents/<name>/AGENT.md` in a layer of the `agents` dotfolder stack
(`<cwd>/.agents/` and `~/.config/agents/`), or in a marketplace of
`tools.skills.marketplaces`; the agent registry reads the same marketplace
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

## Instructions

The system prompt is one markdown file, `Instructions.md`, resolved through the
dotfolder stack. The nearest layer wins, and it replaces the whole file:
compiled in, then `~/.config/<name>/Instructions.md`, then
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
  can drift and a resume then restores the wrong conversation. A fork or a
  sub-agent is never an ACP session: `session/list` does not show it, and it
  does not accept `session/prompt`.
- **A prompt is mail.** `session/prompt` puts the prompt into the mailbox of
  the Router session, and the response comes at once: its `messageId` is the
  `MailID` of the prompt. A prompt that comes while another one is open is
  accepted too. The prompt ends at the terminal event of its own mail, so a
  client waits for the first `idle` after the echo of its own `messageId`.
- **`running` and `idle` follow the work of the session.** The session is
  busy while Router works (an answer that runs, an open background run, or
  queued run mail) or a prompt is open. `running` goes out when the session
  becomes busy, also with no prompt open, and `idle` when it is not busy any
  more. The `idle` carries the stop reason of the last prompt that ended
  since the last `running`; after only background work it has no stop
  reason. A run that waits only for the user is no work, so an open question
  does not keep the session `running`. The agent never sends
  `requires_action`.
- **`session/cancel` is a signal.** It sends `cancelAll()` to the Router
  session. Each open prompt ends `cancelled` at once, and its response says
  so. The `idle` comes when the work of the session ends. You can only stop
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
  to `<cwd>/.<name>/transcripts/<sessionId>/`. Each session has its own
  directory, thus two persons make no merge conflict. `sessions.jsonl` is
  append-only, and `.gitattributes` sets `merge=union` on it. The
  `transcripts.location` key of `config.yaml` moves the root: `project` (the
  default), `home`, or an absolute path. A host that runs the agent in its
  own process can set the location in code, with no config file:
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
and swift-metrics. It exports no telemetry. Log records go to stderr, and
tracing and metrics stay no-op. The log record of `session/cancel` carries
`cancel.signal_id`, the `SignalID` of its `cancelAll()` signal. That key
replaces `cancel.result`, which an earlier version wrote. The OTLP exporter (`swift-otel`) is not a
dependency until SwiftPM 6.4.1, because SwiftPM 6.4 `update` loses the traits
that the root manifest sets on a dependency
(swiftlang/swift-package-manager#10397).

## License

No license file is currently published in this repository.
