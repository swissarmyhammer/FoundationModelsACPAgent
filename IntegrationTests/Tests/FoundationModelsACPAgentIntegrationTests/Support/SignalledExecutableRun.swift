// `SignalledExecutableRun` — one run of a built executable that a
// signal, or two, ended: `SIGINT` by default, or `SIGTERM`.
//
// `BuiltExecutableRun` starts a process and waits for it. An interrupt
// proof needs two things that plain run cannot give: it must know when
// the child has begun to answer, so the signal lands inside a live prompt
// and not before it; and it must send more than one signal, and say how
// many of them reached a child that was still there. Each wait is an
// event (the first stdout byte, the exit of the child). The limit of the child
// (`ChildDeadline`) is the backstop: a child that ignores the interrupt, or
// that never writes, is killed at the limit, and the failure holds its stderr.

import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport

/// One finished run of a built executable that this process signalled.
struct SignalledExecutableRun {
  /// The process exit code, or the signal number when a signal with no
  /// handler ended the child.
  let exitCode: Int32

  /// `true` when the child called `exit`, and `false` when a signal with no
  /// handler ended it.
  let didExit: Bool

  /// The time from the last signal to the end of the child. It is a
  /// measurement for the report; no wait reads it.
  let exitWait: Swift.Duration

  /// The captured stdout text.
  let standardOutput: String

  /// The captured stderr text.
  let standardError: String

  /// How many signals actually reached the child.
  ///
  /// It can be fewer than the run asked for: a child that ends on one
  /// signal is gone before the next one is due, and this runner never
  /// signals a pid it no longer owns.
  let signalsSent: Int

  /// Runs the built executable `executableName`, waits for its first
  /// stdout byte, sends `signalCount` signals back to back, and waits for
  /// it to end.
  ///
  /// The child gets `configHome` as `XDG_CONFIG_HOME` and every pair of
  /// `environment` on top of `inheritedEnvironment`.
  ///
  /// - Parameters:
  ///   - executableName: The product name of the executable to run.
  ///   - arguments: The command-line arguments for the executable.
  ///   - workspace: The working directory of the run.
  ///   - configHome: The injected `XDG_CONFIG_HOME` root.
  ///   - inheritedEnvironment: The environment the child starts from. The
  ///     default is this process's environment; a caller that must keep a
  ///     variable of this process out of the child gives a filtered copy.
  ///   - environment: The extra environment pairs.
  ///   - atFirstOutput: What to do once the child has written its first
  ///     stdout byte, and before the first signal goes out. It gets the
  ///     child's own process identifier, so a caller can read a fact that
  ///     holds only while the run is live — which processes this child
  ///     started, for one. The default does nothing, so a caller that
  ///     says nothing about the live run observes none of it.
  ///   - signalNumber: The signal to send. The default is `SIGINT`, the
  ///     signal of `Ctrl-C`; a `SIGTERM` case gives `SIGTERM`.
  ///   - signalCount: How many signals to send, back to back, so each one
  ///     reaches a child that ends on the first one.
  ///   - chunkGate: The named pipe of the chunk gate of the stub model
  ///     (`ACP_AGENT_STUB_CHUNK_GATE`), or `nil` (the default) for a child
  ///     with no gate. With a gate, the run lets only the first chunk go.
  ///     After `atFirstOutput`, a run with no signal lets each later chunk
  ///     go. A run with signals sends them while the prompt is held, so
  ///     each signal lands before the chunks end, and it lets the chunks
  ///     go only after the child ended.
  ///   - limit: The longest time the child may run.
  /// - Returns: The finished run.
  /// - Throws: The locator or spawn error, what `atFirstOutput` throws, or
  ///   ``ChildDeadlineExceeded`` when the child passed `limit`.
  static func run(
    executableNamed executableName: String,
    arguments: [String],
    workspace: URL,
    configHome: URL,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    environment: [String: String],
    atFirstOutput: @Sendable (pid_t) async throws -> Void = { _ in },
    signalNumber: Int32 = SIGINT,
    signalCount: Int,
    chunkGate: URL? = nil,
    limit: Duration = ChildDeadline.standardLimit
  ) async throws -> SignalledExecutableRun {
    let child = try PipedChildProcess(
      executableNamed: executableName,
      arguments: arguments,
      workspace: workspace,
      inheritedEnvironment: inheritedEnvironment,
      environment: PipedChildProcess.environment(configHome: configHome, adding: environment))
    let process = child.process
    let exit = ProcessExitEvent(watching: process)
    try process.run()
    // Read both pipes as the child writes, so the first-output wait
    // gets each byte and a full pipe buffer never blocks the child.
    let outputCapture = PipeCapture(child.standardOutput)
    let errorCapture = PipeCapture(child.standardError)
    let deadline = ChildDeadline(process: process, limit: limit) {
      outputCapture.stop()
      errorCapture.stop()
    }
    do {
      let run = try await signal(
        process, exit: exit, output: outputCapture, error: errorCapture,
        atFirstOutput: atFirstOutput, signalNumber: signalNumber, signalCount: signalCount,
        chunkGate: chunkGate)
      deadline.disarm()
      if deadline.hasExceeded {
        throw deadline.failure(
          standardOutput: outputCapture.text, standardError: errorCapture.text)
      }
      return run
    } catch {
      deadline.abandon()
      outputCapture.stop()
      errorCapture.stop()
      throw error
    }
  }

  /// The steps of ``run(executableNamed:arguments:workspace:configHome:inheritedEnvironment:environment:atFirstOutput:signalNumber:signalCount:chunkGate:limit:)``
  /// after the start of the child.
  ///
  /// - Parameters:
  ///   - process: The running child.
  ///   - exit: The exit event of the child.
  ///   - output: The reads of the stdout of the child.
  ///   - error: The reads of the stderr of the child.
  ///   - atFirstOutput: What to do once the child wrote its first byte.
  ///   - signalNumber: The signal to send.
  ///   - signalCount: How many signals to send.
  ///   - chunkGate: The chunk gate of the stub model, or `nil`.
  /// - Returns: The finished run.
  /// - Throws: What `atFirstOutput` throws, or the cancel error.
  private static func signal(
    _ process: Process,
    exit: ProcessExitEvent,
    output: PipeCapture,
    error: PipeCapture,
    atFirstOutput: @Sendable (pid_t) async throws -> Void,
    signalNumber: Int32,
    signalCount: Int,
    chunkGate: URL?
  ) async throws -> SignalledExecutableRun {
    var gate: StubChunkGateWriter?
    if let chunkGate {
      gate = try await StubChunkGateWriter.open(at: chunkGate)
      try gate?.releaseOneChunk()
    }
    try await waitForFirstOutput(of: output, orExitOf: exit)
    // The child has answered and has not been signalled, so this is the
    // one moment a caller can read what a live run carries. The gate
    // holds the prompt open here.
    try await atFirstOutput(process.processIdentifier)
    if signalCount == 0 {
      try gate?.releaseAllChunks()
    }
    var signalsSent = 0
    for _ in 0..<signalCount {
      // A child that already ended has given its pid back, and the
      // system may have handed it to another process. So the run
      // signals only a child it still owns.
      guard process.isRunning else {
        break
      }
      kill(process.processIdentifier, signalNumber)
      signalsSent += 1
    }
    let clock = ContinuousClock()
    let lastSignal = clock.now
    try await exit.wait()
    let exitWait = clock.now - lastSignal
    if signalCount > 0 {
      try gate?.releaseAllChunks()
    }

    await output.untilEnd()
    await error.untilEnd()
    try Task.checkCancellation()
    return SignalledExecutableRun(
      exitCode: process.terminationStatus,
      didExit: process.terminationReason == .exit,
      exitWait: exitWait,
      standardOutput: output.text,
      standardError: error.text,
      signalsSent: signalsSent)
  }

  /// Waits for the first stdout byte of the child. A child that ends with no
  /// output ends the wait too, because no byte will come.
  ///
  /// - Parameters:
  ///   - output: The reads of the stdout of the child.
  ///   - exit: The exit event of the child.
  /// - Throws: ``ConditionWaitCancelled`` when the test is cancelled first.
  private static func waitForFirstOutput(
    of output: PipeCapture, orExitOf exit: ProcessExitEvent
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try await output.record.wait(for: "the first stdout byte of the child") {
          !$0.isEmpty
        }
      }
      group.addTask { try await exit.wait() }
      try await group.next()
      group.cancelAll()
    }
  }
}
