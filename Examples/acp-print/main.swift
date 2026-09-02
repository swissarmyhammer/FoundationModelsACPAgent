import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// # The `acp-print` example: a one-shot ACP client CLI.
///
/// One executable, one lesson (plan.md §20.2): how a frontend drives an
/// ACP agent through `FoundationModelsACPClient`. The CLI takes one
/// prompt, spawns `acp-agent` over stdio, runs one turn, prints the
/// answer, and exits at the stop reason. It is the client-server interop
/// example for the two role packages.
///
/// This target links ONLY the client package and the wire — never this
/// package's library. Every byte crosses ACP into the spawned agent
/// process. A back-door import would break the interop proof.
///
/// stdout carries only the answer text. Logs and the stop reason go to
/// stderr. The exit code is 0 for `end_turn` and nonzero for a refusal,
/// a cancellation, or an error.

// MARK: - Constants

/// The name of the agent executable this CLI spawns. It stands beside
/// this binary in the build products directory.
let agentExecutableName = "acp-agent"

/// The count of command-line arguments of a correct invocation: the
/// binary path and the one positional prompt. There is no flag surface.
let expectedArgumentCount = 2

/// The client name `initialize` reports to the agent.
let clientName = "acp-print"

/// The client version `initialize` reports to the agent.
let clientVersion = "1.0.0"

// MARK: - stderr, and only stderr, for diagnostics

/// Writes one log line to stderr. stdout is for the answer text only.
///
/// - Parameter message: The line to write.
func logToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - The answer stream

/// Consumes the session's update stream: writes each agent message
/// chunk's text to stdout as it arrives, and returns the stop reason of
/// the first idle state update.
///
/// A completing newline follows the answer when the last chunk does not
/// end with one, so a shell prompt does not glue onto the answer.
///
/// - Parameter updates: The session's update stream, subscribed before
///   the prompt.
/// - Returns: The stop reason, or `nil` when the stream ended with no
///   idle update — the connection died before the turn ended.
func streamAnswer(from updates: AsyncStream<SessionUpdate>) async -> StopReason? {
    var wroteText = false
    var endedWithNewline = false
    for await update in updates {
        switch update {
        case .agentMessageChunk(let chunk):
            guard case .text(let content) = chunk.content else { break }
            FileHandle.standardOutput.write(Data(content.text.utf8))
            wroteText = true
            endedWithNewline = content.text.hasSuffix("\n")
        case .stateUpdate(.idle(let idle)):
            if wroteText && !endedWithNewline {
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return idle.stopReason
        default:
            break
        }
    }
    return nil
}

// MARK: - The one-shot turn

/// Spawns the agent, drives one prompt turn over ACP, and returns the
/// process exit code.
///
/// The flow is the client plan's own: initialize → session/new(cwd) →
/// session/prompt → stream the answer → exit at the stop reason. The
/// `AgentProcess` owns the spawned agent — its process group is killed
/// and reaped on `shutdown()` and on transport teardown — so no agent
/// process remains after this function returns.
///
/// - Parameters:
///   - prompt: The one prompt to send.
///   - agentCommand: The absolute path of the agent executable.
/// - Returns: `EXIT_SUCCESS` for `end_turn`; `EXIT_FAILURE` for a
///   refusal, a cancellation, or an error.
@MainActor
func runOneShotTurn(prompt: String, agentCommand: String) async -> Int32 {
    do {
        let agent = try AgentProcess(command: agentCommand)
        defer { agent.shutdown() }
        let client = SwiftUIACPClient()
        let connection = await client.connect(over: agent.transport, logger: .standardError)

        _ = try await connection.initialize(
            InitializeRequest(
                info: Implementation(name: clientName, version: clientVersion),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities))

        guard let cwd = AbsolutePath(rawValue: FileManager.default.currentDirectoryPath) else {
            logToStandardError("acp-print cannot express its working directory as an absolute path")
            return EXIT_FAILURE
        }
        let session = try await connection.newSession(NewSessionRequest(cwd: cwd))

        // Subscribe before the prompt: an update with no subscriber is
        // dropped by the connection's router.
        let updates = connection.updates(for: session.sessionId)
        let answer = Task { await streamAnswer(from: updates) }
        do {
            _ = try await connection.prompt(
                PromptRequest(prompt: [.text(TextContent(text: prompt))], sessionId: session.sessionId)
            )
        } catch {
            answer.cancel()
            _ = await answer.value
            await connection.close()
            logToStandardError("the prompt turn failed: \(error)")
            return EXIT_FAILURE
        }

        let stopReason = await answer.value
        await connection.close()
        guard let stopReason else {
            logToStandardError("the connection ended before the turn reached an idle state")
            return EXIT_FAILURE
        }
        logToStandardError("stop reason: \(stopReason.wireValue)")
        return stopReason == .endTurn ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
        logToStandardError("acp-print failed: \(error)")
        return EXIT_FAILURE
    }
}

// MARK: - 1. The one positional prompt argument

let arguments = CommandLine.arguments
guard arguments.count == expectedArgumentCount else {
    logToStandardError("usage: acp-print <prompt>")
    exit(EXIT_FAILURE)
}
let promptText = arguments[1]

// MARK: - 2. The sibling agent binary

// `AgentProcess` requires an absolute path, and the build puts both
// example executables into one products directory, so the agent stands
// beside this binary.
guard let ownExecutable = Bundle.main.executableURL else {
    logToStandardError("acp-print cannot resolve its own executable path")
    exit(EXIT_FAILURE)
}
let agentCommand =
    ownExecutable
    .deletingLastPathComponent()
    .appendingPathComponent(agentExecutableName)
    .path
guard FileManager.default.isExecutableFile(atPath: agentCommand) else {
    logToStandardError("acp-print needs \(agentExecutableName) beside its own binary; none stands at \(agentCommand)")
    exit(EXIT_FAILURE)
}

// MARK: - 3. Run the turn and exit at the stop reason

exit(await runOneShotTurn(prompt: promptText, agentCommand: agentCommand))
