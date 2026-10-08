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
import FoundationModelsRouter

// The one choice a frontend makes. It roots ~/.config/acp-agent/ for the
// user layer, <cwd>/.acp-agent/ for the project layer, and the transcripts.
let name = try DotfolderName("acp-agent")
let cwd = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let configuration = try ConfigurationLoader(name: name, workingDirectory: cwd)
    .load().configuration

// Real models: the configured weights download on first use and stay resident.
let router = Router(loader: LiveModelLoader())

let agent = try await RoutedACPAgent(
    name: name, router: router, configuration: configuration)

// Full duplex on one pipe: the read loop serves every request while a prompt
// streams session/update notifications. stdout carries ndJSON only; logs go
// to stderr. A read-one-then-write-one loop deadlocks here.
let connection = await AgentSideConnection(
    stream: .stdio, logger: .standardError
) { connection in
    agent.bind(connection: connection)
    return agent
}
while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
```

The same composition, with its full commentary, is
[`Sources/acp-agent/AgentComposition.swift`](Sources/acp-agent/AgentComposition.swift),
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
standalone `skills` tool. There is no `wait` tool. A `runCode` run that does
not settle in its inline grace continues in the background, and its result
comes back to the session as mail when it settles. Capability modules mount
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
| `skills` | The standalone `skills` tool, over the `skills` dotfolder stack and the `marketplaces` list | `tools.skills` |

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

The `tools.skills.marketplaces` list names remote skill marketplaces. Each entry
has a `url`, and optionally a `ref` (a branch or a tag), a `sha`, a `path`, an
`alias`, a `select`, an `autoUpdate` and a `grants` key:

```yaml
tools:
  skills:
    marketplaces:
      - url: https://github.com/swissarmyhammer/skills.git
        ref: code-context
```

Use the HTTPS form of a marketplace URL. The SSH form (`git@github.com:…`) is
not supported for now: the skills package gives `unreachable` for it, and the
session then has no marketplace skill.

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

## Documentation

[`plan.md`](plan.md) is the design record: the wire, the session lifecycle, the
tool catalog, and the test tiers. `swift test` runs the hermetic suites;
`swift test --package-path IntegrationTests` runs the tiers that spawn a built
binary or load a real model.

## License

No license file is currently published in this repository.
