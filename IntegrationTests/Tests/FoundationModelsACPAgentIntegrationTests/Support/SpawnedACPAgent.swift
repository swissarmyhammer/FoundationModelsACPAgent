// `SpawnedACPAgent` — one built `acp-agent acp` that this process spawned,
// with an environment of its own, and ended by a stdin close or a signal.
//
// `AgentProcess` of the client package cannot take an environment, and it
// collects the exit status of the child itself, so a test cannot read the
// exit code. `SubprocessTransport` of the wire package takes an environment
// and gives the status, but it cannot close stdin without `SIGTERM`. An exit
// path proof needs all three: its own environment, the choice of the end
// (the end of stdin, or `SIGTERM`), and the exit code.
//
// Every agent has a limit (`ChildDeadline`). An agent that is still running at
// its limit is killed, and the failure of the test holds its stderr.

import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

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

/// An error of a run of a spawned agent, with what the agent wrote to its
/// stderr. A test that fails shows the reason the agent gave.
struct SpawnedAgentFailure: Error, CustomStringConvertible {
  /// The error of the run.
  let underlying: any Error

  /// The stderr text of the agent.
  let standardError: String

  /// The error, and the stderr of the agent.
  var description: String {
    "\(underlying)\nstderr of the agent:\n\(standardError)"
  }
}

/// One spawned `acp-agent acp`.
struct SpawnedACPAgent {
  /// The transport to give to the ACP client.
  let transport: SpawnedAgentTransport

  /// The child process.
  private let process: Process

  /// The exit event of the child, made before it ran.
  private let exit: ProcessExitEvent

  /// The limit of the child.
  private let deadline: ChildDeadline

  /// The reads of the stdout of the child. The transport gets the bytes.
  private let standardOutput: PipeCapture

  /// The reads of the stderr of the child.
  private let standardError: PipeCapture

  /// Wraps a running child.
  ///
  /// - Parameters:
  ///   - process: The running child.
  ///   - exit: The exit event of the child, made before it ran.
  ///   - deadline: The limit of the child.
  ///   - transport: The transport over its pipes.
  ///   - standardOutput: The reads of its stdout.
  ///   - standardError: The reads of its stderr.
  private init(
    process: Process, exit: ProcessExitEvent, deadline: ChildDeadline,
    transport: SpawnedAgentTransport, standardOutput: PipeCapture, standardError: PipeCapture
  ) {
    self.process = process
    self.exit = exit
    self.deadline = deadline
    self.transport = transport
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  /// Spawns the built `acp-agent-stub acp`: the agent over the stub model.
  ///
  /// The child starts from the environment of this process and gets each
  /// pair of `environment` on top of it.
  ///
  /// - Parameters:
  ///   - workspace: The working directory of the child.
  ///   - environment: The extra environment pairs.
  ///   - limit: The longest time the agent may run. At the limit the agent is
  ///     killed.
  /// - Returns: The running agent.
  /// - Throws: The locator or spawn error.
  static func start(
    workspace: URL, environment: [String: String], limit: Duration = ChildDeadline.standardLimit
  ) throws -> SpawnedACPAgent {
    // The setup marks the stdin pipe close-on-exec too: a copy of its
    // write end in another child would keep the stdin of this agent open
    // after the close, and the agent would never read its end of file.
    let inputPipe = Pipe()
    let child = try PipedChildProcess(
      executableNamed: TierThreeFixture.stubAgentExecutableName,
      arguments: [TierThreeFixture.acpSubcommand],
      workspace: workspace,
      inheritedEnvironment: ProcessInfo.processInfo.environment,
      environment: environment,
      standardInput: inputPipe)
    let process = child.process
    let outputPipe = child.standardOutput
    let errorPipe = child.standardError
    // A write to the stdin of a child that ended raises `SIGPIPE`, and that
    // signal ends this whole test process. With the flag the write fails
    // with `EPIPE` instead.
    let noSigPipeResult = fcntl(
      inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    if noSigPipeResult == -1 {
      let failure = errno
      RunReport.write("SpawnedACPAgent: F_SETNOSIGPIPE failed, errno \(failure)")
      assertionFailure("F_SETNOSIGPIPE failed with errno \(failure)")
    }
    let exit = ProcessExitEvent(watching: process)
    try process.run()

    let (bytes, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    // The byte stream of the transport ends with stdout, so the client
    // sees the end of the wire.
    let outputCapture = PipeCapture(
      outputPipe, forwarding: { continuation.yield($0) }, atEnd: { continuation.finish() })
    let errorCapture = PipeCapture(errorPipe)
    let deadline = ChildDeadline(process: process, limit: limit) {
      outputCapture.stop()
      errorCapture.stop()
    }
    return SpawnedACPAgent(
      process: process,
      exit: exit,
      deadline: deadline,
      transport: SpawnedAgentTransport(bytes: bytes, input: inputPipe.fileHandleForWriting),
      standardOutput: outputCapture,
      standardError: errorCapture)
  }

  /// Closes the stdin of the agent, which is the end of the ACP wire, and
  /// waits until the agent ends.
  ///
  /// - Returns: How the agent ended.
  /// - Throws: The close error.
  func closeStandardInputAndWait() async throws -> SpawnedAgentExit {
    try await end {
      try transport.input.close()
    }
  }

  /// Kills the agent with `SIGKILL` and waits until it ends and closes its pipes. The agent gets no
  /// time to stop its work, to write a history file or to close a session, as when the machine
  /// loses power.
  ///
  /// - Returns: How the agent ended.
  /// - Throws: The wait error.
  func killAndWait() async throws -> SpawnedAgentExit {
    try await end {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }

  /// Gives up on the agent: kills it if it still runs, and ends the reads of
  /// its pipes. A test calls it when a request failed, so a failed test leaves
  /// no agent behind.
  func abandon() {
    deadline.abandon()
    standardOutput.stop()
    standardError.stop()
  }

  /// The failure to report for `error`, which ended a run of this agent.
  ///
  /// The kill of the deadline closes the wire, and each request in flight then
  /// fails with a closed connection. That error does not say what happened.
  /// So the report is the deadline failure when the deadline killed the agent,
  /// and else the error with the stderr of the agent.
  ///
  /// - Parameter error: The error the run ended with.
  /// - Returns: The failure to throw.
  func report(_ error: any Error) -> any Error {
    if error is ChildDeadlineExceeded || error is CancellationError {
      return error
    }
    if deadline.hasExceeded {
      return deadline.failure(
        standardOutput: standardOutput.text, standardError: standardError.text)
    }
    return SpawnedAgentFailure(underlying: error, standardError: standardError.text)
  }

  /// Asks the agent to end, and waits until it ends and closes its pipes.
  ///
  /// The wait for the end is the exit event of the child. The limit of the
  /// agent is the backstop of a child that ignores the request.
  ///
  /// - Parameter request: The end request.
  /// - Returns: How the agent ended.
  /// - Throws: The error of `request`, ``ChildDeadlineExceeded`` when the
  ///   limit killed the agent, or ``ConditionWaitCancelled`` when the test is
  ///   cancelled first.
  private func end(request: () throws -> Void) async throws -> SpawnedAgentExit {
    let clock = ContinuousClock()
    let start = clock.now
    try request()
    do {
      try await exit.wait()
      await standardOutput.untilEnd()
      await standardError.untilEnd()
      try Task.checkCancellation()
    } catch {
      abandon()
      throw error
    }
    deadline.disarm()
    if deadline.hasExceeded {
      throw deadline.failure(
        standardOutput: standardOutput.text, standardError: standardError.text)
    }
    return SpawnedAgentExit(
      status: process.terminationStatus,
      didExit: process.terminationReason == .exit,
      elapsed: clock.now - start,
      standardError: standardError.text)
  }
}
