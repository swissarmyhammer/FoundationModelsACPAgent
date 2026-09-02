import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Tier 3: the stdio contract (plan.md §17, §20.1, §20.2)
//
// The one gated suite that spawns the built `acp-agent` example across a
// real process boundary. It exists for the one thing tier 2 cannot see:
// does the ndJSON framing survive a real process, while `shell` children
// write to THEIR stdout. Set `ACP_TIER3=1` to run it. Without the
// variable the suite is skipped and `swift test` stays green.
//
// The spawned example resolves a REAL profile with a live loader, so
// this suite needs the network on its first run: the injected user
// configuration names the small `mlx-community` models the family's own
// gated suites already load.

/// The gated case's time limit in minutes. It covers the first-run
/// model download and the model load of the spawned example.
private let gatedTimeLimitMinutes = 20

/// A transport that records every inbound byte while it forwards the
/// stream and the writes unchanged (plan.md §20.1: wrap
/// `agent.transport` in a tap that records the raw inbound bytes).
///
/// The recorded bytes are the assertion surface of the §17 framing
/// MUSTs: the codec's own decode is not trusted to prove them, because
/// the codec would also repair what it can.
final class InboundTapTransport: ACPTransport, Sendable {
    /// The guarded byte record one tap and its forwarding task share.
    /// A class, because `Mutex` is noncopyable: the forwarding task's
    /// escaping closure captures this reference, not the lock itself.
    private final class TapRecord: Sendable {
        /// The recorded bytes, guarded for the reader against the
        /// forwarding task's appends.
        private let guardedBytes = Mutex(Data())

        /// Appends one recorded chunk.
        ///
        /// - Parameter chunk: The inbound bytes to record.
        func append(_ chunk: Data) {
            guardedBytes.withLock { $0.append(chunk) }
        }

        /// The bytes recorded so far.
        var snapshot: Data {
            guardedBytes.withLock { $0 }
        }
    }

    /// The forwarded inbound stream the connection consumes.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The wrapped transport the writes go to.
    private let upstream: any ACPTransport

    /// The raw inbound bytes recorded so far.
    private let record: TapRecord

    /// Wraps `upstream`, forwarding its inbound stream while recording
    /// every chunk.
    ///
    /// Cancelling the forwarded stream cancels the read of the wrapped
    /// stream, so the wrapped transport's own termination teardown — the
    /// group kill of `AgentProcess` — still runs.
    ///
    /// - Parameter upstream: The transport to wrap.
    init(wrapping upstream: any ACPTransport) {
        self.upstream = upstream
        let record = TapRecord()
        self.record = record
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.bytes = stream
        let forwarding = Task {
            do {
                for try await chunk in upstream.bytes {
                    record.append(chunk)
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forwarding.cancel() }
    }

    /// The raw inbound bytes recorded so far.
    var recordedBytes: Data {
        record.snapshot
    }

    /// Forwards one outgoing chunk to the wrapped transport.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: Whatever the wrapped transport throws.
    func write(_ data: Data) async throws {
        try await upstream.write(data)
    }
}

/// The gated tier-3 contract: one end-to-end drive of the spawned
/// example, asserted on the tapped raw bytes.
///
/// Serialized because the suite mutates the process environment —
/// `XDG_CONFIG_HOME` must reach the spawned child, and `posix_spawn`
/// passes this process's `environ` on. The time limit covers the
/// first-run model download.
@Suite(
    .enabled(
        if: TierThreeFixture.isGateOpen,
        "the tier-3 stdio contract runs only with \(TierThreeFixture.gateVariable)=\(TierThreeFixture.gateOpenValue)"
    ),
    .serialized,
    .timeLimit(.minutes(gatedTimeLimitMinutes)))
struct StdioContractTests {
    // MARK: - Constants

    /// The id of the probe skill, and so its `/probe` command name.
    private static let probeSkillID = "probe"

    /// The project-layer skills directory name of a session working
    /// directory (`ToolCatalog.skillsDotfolderName`, project layer).
    private static let projectSkillsDirectoryName = ".skills"

    /// The marker the probe's shell child writes to ITS stdout. It must
    /// never appear on the agent's stdout outside a JSON frame.
    private static let probeMarker = "tier3-stdout-probe"

    /// The file the probe's shell child also writes the marker to, in
    /// the skill's own directory. The disk is the proof the child ran
    /// (plan.md §20.1: check the filesystem, never the transcript).
    private static let probeWitnessFileName = "tier3-probe-ran.txt"

    /// The one prompt the suite sends: the probe skill command.
    private static let promptText = "/" + probeSkillID

    /// The newline byte that divides ndJSON frames (plan.md §17).
    private static let newlineByte = UInt8(ascii: "\n")

    /// The `SKILL.md` of the probe skill. The body's first line is a
    /// shell injection: the render pass runs it through `/bin/sh -c`
    /// with captured output, so a real child writes the marker to ITS
    /// stdout during the turn, with no dependence on the model's tool
    /// choice. The `tee` copy is the on-disk witness that the child ran.
    private static let probeSkillMarkdown = """
        ---
        name: \(probeSkillID)
        description: Runs one probe command through the shell pass.
        ---
        !`echo \(probeMarker) | tee \(probeWitnessFileName)`

        Answer with one short sentence.
        """

    // MARK: - Fixtures

    /// Writes the probe skill into the session working directory's
    /// project skills layer, `<cwd>/.skills/probe/SKILL.md`.
    ///
    /// - Parameter workspace: The session working directory.
    /// - Returns: The skill's own directory, where the witness file
    ///   lands — the shell injection runs with it as the child's
    ///   working directory.
    /// - Throws: The directory-creation or write error.
    private static func writeProbeSkill(under workspace: URL) throws -> URL {
        let skillDirectory =
            workspace
            .appendingPathComponent(projectSkillsDirectoryName, isDirectory: true)
            .appendingPathComponent(probeSkillID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory, withIntermediateDirectories: true)
        try probeSkillMarkdown.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8)
        return skillDirectory
    }

    /// Sets `TierThreeFixture.configHomeVariable` for this process —
    /// and so for every child it spawns — and returns the restorer for
    /// the prior value.
    ///
    /// - Parameter configHome: The directory to point the variable at.
    /// - Returns: The closure that puts the prior value back.
    private static func pointConfigHome(at configHome: URL) -> () -> Void {
        let variable = TierThreeFixture.configHomeVariable
        let previous = ProcessInfo.processInfo.environment[variable]
        setenv(variable, configHome.path, 1)
        return {
            if let previous {
                setenv(variable, previous, 1)
            } else {
                unsetenv(variable)
            }
        }
    }

    // MARK: - Waits

    /// Consumes `updates` until the first idle state update, then
    /// returns its stop reason.
    ///
    /// - Parameter updates: The session's update stream, subscribed
    ///   before the prompt.
    /// - Returns: The stop reason, or `nil` when the stream ended with
    ///   no idle update — the connection died before the turn ended.
    private static func waitForIdle(on updates: AsyncStream<SessionUpdate>) async -> StopReason? {
        for await update in updates {
            if case .stateUpdate(.idle(let idle)) = update {
                return idle.stopReason
            }
        }
        return nil
    }

    // MARK: - The frame assertions (plan.md §17)

    /// Asserts the §17 framing MUSTs on the tapped raw bytes: the
    /// stream divides on `\n` into complete frames, every frame parses
    /// as one JSON-RPC message, no frame is empty, and nothing follows
    /// the final newline. A frame with an interior newline cannot pass:
    /// the split would break it into pieces that do not parse.
    ///
    /// - Parameter data: The tapped raw inbound bytes.
    /// - Throws: The `#require` failure when the stream is empty.
    private static func assertFramesArePureJSONRPC(in data: Data) throws {
        let lines = data.split(separator: newlineByte, omittingEmptySubsequences: false)
        try #require(lines.count > 1, "the agent's stdout carried no complete frame")
        #expect(
            lines.last?.isEmpty == true,
            "bytes after the final newline are a torn or unterminated frame")
        for line in lines.dropLast() {
            #expect(!line.isEmpty, "an empty line is not a JSON-RPC message")
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let message = object as? [String: Any]
            else {
                Issue.record(
                    "a stdout line does not parse as a JSON object: \(String(decoding: line, as: UTF8.self))"
                )
                continue
            }
            #expect(
                message["jsonrpc"] as? String == "2.0",
                "a stdout frame is not a JSON-RPC message: \(message)")
        }
    }

    // MARK: - The contract

    /// The whole tier-3 drive, in one case on purpose (plan.md §20.1:
    /// tiers 3 and 4 stay gated, and stay small): spawn the built
    /// example, initialize, open a session, run one turn whose shell
    /// child writes to ITS stdout, then assert the §17 MUSTs on the
    /// tapped bytes and the reaped child on teardown.
    @Test func framingSurvivesTheProcessBoundaryWhileAShellChildRuns() async throws {
        let workspace = makeResolvedDirectory(label: "StdioContract-repo")
        let configHome = makeResolvedDirectory(label: "StdioContract-config")
        try TierThreeFixture.writeUserConfig(under: configHome)
        let skillDirectory = try Self.writeProbeSkill(under: workspace)
        let restoreConfigHome = Self.pointConfigHome(at: configHome)
        defer { restoreConfigHome() }

        // Spawn the built example through the client package's process
        // owner, with the absolute path it requires (plan.md §20.1).
        let command = try BuiltProductLocator.executableURL(
            named: TierThreeFixture.agentExecutableName)
        let agent = try AgentProcess(command: command.path)
        let tap = InboundTapTransport(wrapping: agent.transport)
        let client = await SwiftUIACPClient()
        let connection = await client.connect(over: tap)

        // `swift run acp-agent` starts and answers `initialize` over
        // stdio — asserted here, not by hand. The await also covers the
        // example's construction-time profile resolution.
        let initialized = try await connection.initialize(
            AgentClientHarness.makeInitializeRequest())
        #expect(initialized.info.name == RoutedACPAgent.implementation.name)
        #expect(initialized.protocolVersion == RoutedACPAgent.latestProtocolVersion)

        let session = try await connection.newSession(
            NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: workspace.path))))

        // Subscribe before the prompt: updates with no subscriber are
        // dropped by the router.
        let updates = connection.updates(for: session.sessionId)
        _ = try await connection.prompt(
            ScriptedTurnFixture.makePromptRequest(
                sessionId: session.sessionId, text: Self.promptText))
        let stopReason = await Self.waitForIdle(on: updates)
        #expect(stopReason != nil, "the turn never reached an idle state update")

        // The child ran, proven on the file system: the probe's `tee`
        // wrote the marker beside the skill (plan.md §20.1's
        // discipline — check the filesystem, never the transcript).
        let witness = try textOnDisk(
            at: skillDirectory.appendingPathComponent(Self.probeWitnessFileName))
        #expect(witness.contains(Self.probeMarker))

        // Teardown: close the wire, then prove the reap by pid — the
        // group kill leaves no child behind (plan.md §20.1).
        await connection.close()
        agent.shutdown()
        #expect(agent.processIdentifier == nil)

        // The §17 MUSTs, on the tapped raw bytes. The marker crossed a
        // captured pipe into the render, never the agent's stdout: a
        // leak would stand as a bare non-JSON line and fail the parse
        // assertion.
        let recordedBytes = tap.recordedBytes
        try Self.assertFramesArePureJSONRPC(in: recordedBytes)
        let rawLines = recordedBytes.split(
            separator: Self.newlineByte, omittingEmptySubsequences: true)
        #expect(
            !rawLines.contains(Data(Self.probeMarker.utf8)),
            "the shell child's stdout leaked raw into the frame stream")
    }
}
