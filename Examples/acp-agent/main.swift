import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # The `acp-agent` example: an ACP server CLI over this package.
///
/// One executable, two purposes (plan.md §20.2): the family-convention
/// example — "how do I build an ACP server CLI on top of this?" — and
/// the fixture the gated tier-3 stdio contract test spawns. The
/// composition below is the whole lesson. There is no argument parsing,
/// no rendering, and no configuration wizardry: the dotfolder name is
/// the one choice a frontend makes, and everything else derives.
///
/// The shape is full duplex on purpose (plan.md §17): the connection's
/// read loop serves every request while the agent streams mid-turn
/// `session/update` notifications on the same pipe. A program written
/// as a read-one-request-then-write-one-response loop deadlocks on the
/// first mid-turn update — never write that shape.
///
/// stdout is sacred: only ndJSON frames go there. Logs go to stderr.
/// Shell children never inherit stdout — the shell capability captures
/// their output — and the gated tier-3 test proves both MUSTs across
/// this real process boundary.

// MARK: - 1. The dotfolder name — the frontend's one choice

// The name roots the configuration stack — `$XDG_CONFIG_HOME/acp-agent/`
// for the user layer, `<cwd>/.acp-agent/` for the project layer — and
// the transcript directory, and it is the fallback for the profile's
// name (plan.md §2.1). It never goes on the wire: `initialize` reports
// the package identity instead (§5).
let dotfolderName = try DotfolderName("acp-agent")

// MARK: - 2. The configuration — derived, never flagged

// The layered `config.yaml` of the process working directory selects
// the profile this agent resolves at start (plan.md §2.2). With no file
// in any layer the in-code default applies. Each session later loads
// its own stack again, keyed by the session's `cwd`.
let processWorkingDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let configuration = try ConfigurationLoader(
    name: dotfolderName, workingDirectory: processWorkingDirectory
).load().configuration

// MARK: - 3. A real router, a real model path

// `LiveModelLoader` with the Hub downloader and tokenizer macros is the
// real resolution path: the configured models download on first use and
// load as resident weights. Nothing here is scripted or stubbed.
let router = Router(
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()))

// MARK: - 4. The composed agent

// Construction resolves `configuration.profile` to a resident profile
// (config → ProfileDefinition → Router.resolve → resident profile,
// plan.md §1). A resolution failure is fatal here, before the wire
// opens, and its reason goes to stderr — never to stdout.
let agent = try await RoutedACPAgent(
    name: dotfolderName, router: router, configuration: configuration)

// MARK: - Where a frontend appends its own tools (plan.md §11.1)
//
// `ToolCatalog` is the one place this package composes the per-session
// tool surface. The session tools are `searchTools`, `runCode` and
// `wait`, plus the stand-alone `skills` tool. A frontend adds its own
// tools there, in one of two forms:
//
// - A capability behind the code-mode surface: add one
//   `builder.withCapability(myCapability)` call in
//   `ToolCatalog.makeRegistry(context:)`, before `buildRegistry()`.
//   The capability's verbs then mount behind `runCode` beside the
//   files and shell verbs.
//
// - A stand-alone tool: append one plain `FoundationModels.Tool` to
//   the `tools` array in `ToolCatalog.sessionSurface(context:)`. The
//   `skills` tool is the worked example of this form — it answers in
//   one request/response step and never goes through the async
//   code-mode lane.

// MARK: - 5. Serve ACP over stdio

// The factory closure binds the connection into the agent, so a prompt
// turn can notify through it (plan.md §8.1). `.standardError` keeps
// every log line off the wire (§17).
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { connection in
    agent.bind(connection: connection)
    return agent
}

// MARK: - 6. Stay open until the client tears the process down

/// The seconds one keep-alive sleep lasts. The length is arbitrary: the
/// loop only parks this task while the connection's read loop serves
/// the wire.
let keepAliveSleepSeconds = 3600

/// Holds the process open while `connection` serves the wire, in the
/// wire package's own example shape (`acp-test-agent`): the client owns
/// the lifecycle (plan.md §17) — it closes stdin and ends this process;
/// there is no teardown handshake to wait for here.
///
/// - Parameter connection: The live connection to hold open.
func holdOpenUntilTerminated(_ connection: AgentSideConnection) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(keepAliveSleepSeconds))
    }
}

await holdOpenUntilTerminated(connection)
