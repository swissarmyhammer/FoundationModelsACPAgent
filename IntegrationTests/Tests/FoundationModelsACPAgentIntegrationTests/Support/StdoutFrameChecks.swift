// `StdoutFrameChecks` — the shared checks on the stdout of a spawned
// `acp-agent acp`.
//
// `StdioContractTests` and `TelemetryStdoutTests` both spawn the agent in
// `acp` mode and hold its stdout to the plan.md §17 framing rule. This one
// home keeps the rule and the idle wait in one place, so the two suites
// cannot drift apart.

import Foundation
import FoundationModelsACP
import Testing

/// The checks on the stdout bytes of a spawned `acp-agent acp`, and the wait
/// for the end of a prompt.
enum StdoutFrameChecks {
    /// The newline byte that divides ndJSON frames (plan.md §17).
    static let newlineByte = UInt8(ascii: "\n")

    /// The JSON-RPC version each frame must name.
    private static let jsonRPCVersion = "2.0"

    /// Asserts the §17 framing rules on the tapped raw bytes: the stream
    /// divides on `\n` into complete frames, each frame parses as one
    /// JSON-RPC message, no frame is empty, and no byte follows the final
    /// newline. A frame with a newline inside it cannot pass: the split
    /// breaks it into pieces that do not parse.
    ///
    /// - Parameter data: The tapped raw inbound bytes.
    /// - Throws: The `#require` failure when the stream has no complete frame.
    static func assertFramesArePureJSONRPC(in data: Data) throws {
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
                message["jsonrpc"] as? String == jsonRPCVersion,
                "a stdout frame is not a JSON-RPC message: \(message)")
        }
    }

    /// Consumes `updates` until the first idle state update, then returns
    /// its stop reason.
    ///
    /// - Parameter updates: The update stream of the session. Subscribe to
    ///   it before the prompt.
    /// - Returns: The stop reason, or `nil` when the stream ended with no
    ///   idle update. That is, the connection stopped before the prompt
    ///   ended.
    static func waitForIdle(on updates: AsyncStream<SessionUpdate>) async -> StopReason? {
        for await update in updates {
            if case .stateUpdate(.idle(let idle)) = update {
                return idle.stopReason
            }
        }
        return nil
    }
}
