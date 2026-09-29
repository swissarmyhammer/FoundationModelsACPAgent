// `SpawnedACPAgent` — one built `acp-agent acp` that this process spawned,
// with an environment of its own, and ended by a stdin close or a signal.
//
// `AgentProcess` of the client package cannot take an environment, and it
// collects the exit status of the child itself, so a test cannot read the
// exit code. `SubprocessTransport` of the wire package takes an environment
// and gives the status, but it cannot close stdin without `SIGTERM`. An exit
// path proof needs all three: its own environment, the choice of the end
// (the end of stdin, or `SIGTERM`), and the exit code.

import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Synchronization

/// An ACP transport over the stdin and stdout pipes of a spawned agent.
struct SpawnedAgentTransport: ACPTransport {
    /// The chunks the agent writes to its stdout.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The write end of the stdin pipe of the agent.
    let input: FileHandle

    /// Writes one whole frame to the stdin of the agent.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: The write error, for example after the agent ended.
    func write(_ data: Data) async throws {
        try input.write(contentsOf: data)
    }
}

/// The reads of one pipe of a spawned agent.
///
/// A `FileHandle` readability handler reads on a Dispatch queue. A blocking
/// read on a task would hold a thread of the cooperative pool for the life of
/// the agent, and the suites of this package run at the same time: enough
/// held threads stop every task of the test process.
private enum PipeReader {
    /// Starts the reads of `pipe`.
    ///
    /// - Parameters:
    ///   - pipe: The pipe to read.
    ///   - receive: What each chunk goes to.
    ///   - atEnd: What runs when the pipe reaches its end.
    /// - Returns: A stream that finishes when the pipe reaches its end. One
    ///   task at a time may wait on it.
    static func start(
        _ pipe: Pipe,
        receive: @escaping @Sendable (Data) -> Void,
        atEnd: @escaping @Sendable () -> Void = {}
    ) -> AsyncStream<Never> {
        let (end, finish) = AsyncStream<Never>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                atEnd()
                finish.finish()
                return
            }
            receive(chunk)
        }
        return end
    }
}

/// The stderr bytes of a spawned agent, shared with the handler that reads
/// them.
private final class StandardErrorRecord: Sendable {
    /// The bytes so far.
    private let bytes = Mutex(Data())

    /// Appends one chunk.
    ///
    /// - Parameter chunk: The bytes read.
    func append(_ chunk: Data) {
        bytes.withLock { $0.append(chunk) }
    }

    /// The bytes so far, as text.
    var text: String {
        String(decoding: bytes.withLock { $0 }, as: UTF8.self)
    }
}

/// How a spawned agent ended.
struct SpawnedAgentExit {
    /// The exit code, or the signal number when a signal ended the agent.
    let status: Int32

    /// `true` when the agent called `exit`, and `false` when a signal ended
    /// it with no handler.
    let didExit: Bool

    /// The time from the end request to the end of the agent.
    let elapsed: Swift.Duration

    /// The stderr text of the agent.
    let standardError: String
}

/// One spawned `acp-agent acp`.
struct SpawnedACPAgent {
    /// The prefix of each standard OpenTelemetry environment variable.
    static let openTelemetryVariablePrefix = "OTEL_"

    /// The transport to give to the ACP client.
    let transport: SpawnedAgentTransport

    /// The child process.
    private let process: Process

    /// The stderr bytes of the child.
    private let standardError: StandardErrorRecord

    /// One stream for each output pipe of the child, stdout and stderr. Each
    /// stream finishes when its pipe reaches its end.
    private let pipeEnds: [AsyncStream<Never>]

    /// Wraps a running child.
    ///
    /// - Parameters:
    ///   - process: The running child.
    ///   - transport: The transport over its pipes.
    ///   - standardError: The record of its stderr.
    ///   - pipeEnds: The end streams of its stdout and stderr.
    private init(
        process: Process, transport: SpawnedAgentTransport,
        standardError: StandardErrorRecord, pipeEnds: [AsyncStream<Never>]
    ) {
        self.process = process
        self.transport = transport
        self.standardError = standardError
        self.pipeEnds = pipeEnds
    }

    /// The environment of this process with no `OTEL_*` variable, so only
    /// the pairs a test sets reach the child.
    static var environmentWithoutOpenTelemetry: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix(openTelemetryVariablePrefix) }
    }

    /// Spawns the built `acp-agent acp`.
    ///
    /// The child starts from ``environmentWithoutOpenTelemetry`` and gets
    /// each pair of `environment` on top of it.
    ///
    /// - Parameters:
    ///   - workspace: The working directory of the child.
    ///   - environment: The extra environment pairs.
    /// - Returns: The running agent.
    /// - Throws: The locator or spawn error.
    static func start(workspace: URL, environment: [String: String]) throws -> SpawnedACPAgent {
        // The setup marks the stdin pipe close-on-exec too: a copy of its
        // write end in another child would keep the stdin of this agent open
        // after the close, and the agent would never read its end of file.
        let inputPipe = Pipe()
        let child = try PipedChildProcess(
            executableNamed: TierThreeFixture.agentExecutableName,
            arguments: [TierThreeFixture.acpSubcommand],
            workspace: workspace,
            inheritedEnvironment: environmentWithoutOpenTelemetry,
            environment: environment,
            standardInput: inputPipe)
        let process = child.process
        let outputPipe = child.standardOutput
        let errorPipe = child.standardError
        // A write to the stdin of a child that ended raises `SIGPIPE`, and that
        // signal ends this whole test process. With the flag the write fails
        // with `EPIPE` instead.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let (bytes, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let record = StandardErrorRecord()
        // The byte stream of the transport ends with stdout, so the client
        // sees the end of the wire.
        let outputEnd = PipeReader.start(
            outputPipe, receive: { continuation.yield($0) }, atEnd: { continuation.finish() })
        let errorEnd = PipeReader.start(errorPipe, receive: { record.append($0) })
        return SpawnedACPAgent(
            process: process,
            transport: SpawnedAgentTransport(bytes: bytes, input: inputPipe.fileHandleForWriting),
            standardError: record,
            pipeEnds: [outputEnd, errorEnd])
    }

    /// Closes the stdin of the agent, which is the end of the ACP wire, and
    /// waits until the agent ends.
    ///
    /// - Parameter limit: How long to wait for the end.
    /// - Returns: How the agent ended.
    /// - Throws: ``SignalledRunError`` when the wait runs out, or the close
    ///   error.
    func closeStandardInputAndWait(within limit: Swift.Duration) async throws -> SpawnedAgentExit {
        try await end(within: limit) {
            try transport.input.close()
        }
    }

    /// Sends `SIGTERM` to the agent and waits until the agent ends.
    ///
    /// - Parameter limit: How long to wait for the end.
    /// - Returns: How the agent ended.
    /// - Throws: ``SignalledRunError`` when the wait runs out.
    func terminateAndWait(within limit: Swift.Duration) async throws -> SpawnedAgentExit {
        try await end(within: limit) {
            process.terminate()
        }
    }

    /// Asks the agent to end, and waits until it ends and closes its pipes.
    ///
    /// - Parameters:
    ///   - limit: How long to wait for the end.
    ///   - request: The end request.
    /// - Returns: How the agent ended.
    /// - Throws: ``SignalledRunError`` when the wait runs out, or the error
    ///   of `request`.
    private func end(within limit: Swift.Duration, request: () throws -> Void) async throws
        -> SpawnedAgentExit
    {
        let clock = ContinuousClock()
        let start = clock.now
        try request()
        try await SignalledExecutableRun.waitForExit(of: process, within: limit)
        let elapsed = clock.now - start
        for end in pipeEnds {
            for await _ in end {}
        }
        return SpawnedAgentExit(
            status: process.terminationStatus,
            didExit: process.terminationReason == .exit,
            elapsed: elapsed,
            standardError: standardError.text)
    }
}
