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
    struct Acp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "acp", abstract: "Serve ACP on stdin and stdout.")

        /// The seconds one keep-alive sleep lasts. The length is
        /// arbitrary: the loop only parks this task while the connection's
        /// read loop serves the wire.
        private static let keepAliveSleepSeconds = 3600

        mutating func run() async throws {
            // Construction resolves the configured profile to a resident
            // profile (plan.md §1). A resolution failure is fatal here,
            // before the wire opens, and its reason goes to stderr — never
            // to stdout.
            let composed = try await AgentComposition.compose(
                workingDirectory: AgentComposition.processWorkingDirectory,
                environment: ProcessInfo.processInfo.environment)
            let agent = composed.agent
            // The factory closure binds the connection into the agent, so
            // a prompt turn can notify through it (plan.md §8.1).
            // `.standardError` keeps every log line off the wire (§17).
            let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) {
                connection in
                agent.bind(connection: connection)
                return agent
            }
            await Self.holdOpenUntilTerminated(connection: connection)
        }

        /// Holds the process open while `connection` serves the wire, in
        /// the wire package's own example shape (`acp-test-agent`): the
        /// client owns the lifecycle (plan.md §17) — it closes stdin and
        /// ends this process; there is no teardown handshake to wait for.
        ///
        /// - Parameter connection: The live connection to hold open.
        private static func holdOpenUntilTerminated(connection: AgentSideConnection) async {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(keepAliveSleepSeconds))
            }
        }
    }
}
