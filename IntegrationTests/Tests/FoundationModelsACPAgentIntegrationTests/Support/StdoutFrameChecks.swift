// `StdoutFrameChecks` — the shared checks on the stdout of a spawned
// `acp-agent acp`.
//
// `StdioContractTests` and `TelemetryStdoutTests` both spawn the agent in
// `acp` mode and hold its stdout to the ACP stdio framing rule: stdout
// carries only UTF-8 JSON-RPC messages, `\n` divides them, and no message
// holds a newline. This one home keeps the rule in one place, so the two
// suites cannot drift apart.

import Foundation
import FoundationModelsACP
import Testing

/// The checks on the stdout bytes of a spawned `acp-agent acp`.
enum StdoutFrameChecks {
  /// The newline byte that divides ndJSON frames.
  static let newlineByte = UInt8(ascii: "\n")

  /// The JSON-RPC version each frame must name.
  private static let jsonRPCVersion = "2.0"

  /// Asserts the stdio framing rules on the tapped raw bytes: the stream
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
}
