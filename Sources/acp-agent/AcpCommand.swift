import ArgumentParser
import Foundation
import FoundationModelsACP

extension AcpAgentCommand {
    /// `acp-agent acp`: serve ACP on stdin and stdout (cli-plan.md §5.3).
    /// In this mode stdin is the wire (§5.5), and it is never read for a
    /// prompt.
    ///
    /// The shape is full duplex on purpose (plan.md §17): the connection's
    /// read loop serves every request while the agent streams mid-turn
    /// `session/update` notifications on the same pipe. A program written
    /// as a read-one-request-then-write-one-response loop deadlocks on the
    /// first mid-turn update — never write that shape.
    ///
    /// stdout is sacred: only ndJSON frames go there. Logs go to stderr.
    /// Shell children never inherit stdout — the shell capability captures
    /// their output — and the tier-3 stdio contract test proves both MUSTs
    /// across this real process boundary.
    ///
    /// There is no `--cwd` here (§5.10). The client gives the working
    /// directory with each `session/new`, and a flag would fight the
    /// protocol: one process serves many sessions in many repositories,
    /// and each session loads its own project layer from its own `cwd`.
    struct Acp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "acp", abstract: "Serve ACP on stdin and stdout.")

        mutating func run() async throws {
            // Construction resolves the configured profile to a resident
            // profile (plan.md §1). A resolution failure is fatal here,
            // before the wire opens, and its reason goes to stderr — never
            // to stdout. This is the first of the two loads of §5.10, and
            // the only one keyed by the process working directory.
            // The download of §5.9 is interruptible here too: the first
            // `Ctrl-C` cancels the composition and the process exits 4,
            // leaving the partly downloaded model in the Hugging Face cache.
            let composed: AgentComposition.Composed
            do {
                composed = try await InterruptibleComposition.run(
                    interruptedBy: InterruptHandler.onSIGINT
                ) {
                    try await AgentComposition.compose(
                        workingDirectory: AgentComposition.processWorkingDirectory,
                        environment: ProcessInfo.processInfo.environment)
                }
            } catch is CompositionInterrupted {
                throw ExitCode(InterruptHandler.cancelledExitCode)
            }
            // The wrapper is what makes the stdin end observable; see
            // `InboundEndTransport`. Underneath it stands the same
            // `StdioTransport` `.stdio` vends, so the wire is unchanged.
            let transport = InboundEndTransport(wrapping: StdioTransport())
            // `.standardError` keeps every log line off the wire (§17).
            let connection = await composed.serve(over: transport, logger: .standardError)
            // The client owns the lifecycle (plan.md §17): it closes
            // stdin, and there is no teardown handshake to wait for. So
            // the process stands here for as long as the client speaks,
            // and ends when the client stops.
            await transport.waitForInboundEnd()
            await connection.close()
        }
    }
}
