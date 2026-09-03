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
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

// The one choice a frontend makes. It roots ~/.config/acp-agent/ for the
// user layer, <cwd>/.acp-agent/ for the project layer, and the transcripts.
let name = try DotfolderName("acp-agent")
let cwd = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let configuration = try ConfigurationLoader(name: name, workingDirectory: cwd)
    .load().configuration

// Real models: the configured weights download on first use and stay resident.
let router = Router(
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()))

let agent = try await RoutedACPAgent(
    name: name, router: router, configuration: configuration)

// Full duplex on one pipe: the read loop serves every request while a turn
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
[`Examples/acp-agent/main.swift`](Examples/acp-agent/main.swift).

## Install

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsACPAgent.git", branch: "main")
```

## Tools

The model-facing surface is three code-mode tools from
`FoundationModelsMultitool` — `searchTools`, `runCode` and `wait` — plus the
standalone `skills` tool. Capability modules mount inside the Multitool
registry, one row here per capability. Each capability is on by default. Set
its config section to `false` to turn it off.

| Capability | What it gives the model | Config section |
|---|---|---|
| `files` | The `tools.files.*` verbs, confined to the session root set | `tools.files` |
| `shell` | The `tools.shell.*` verbs, under a Seatbelt sandbox over the root set | `tools.shell` |
| `mcp` | The verbs of each connected MCP server, as `tools.<server>.*` | `tools.mcp` |
| `skills` | The standalone `skills` tool, over the `skills` dotfolder stack | `tools.skills` |

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
