import Foundation
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter

/// The secrets port of the MCP server registry of Multitool
/// (`MCPServerSecrets`) over the secret store of the agent (D101).
///
/// A secret value goes to the store, under the item name of Multitool
/// (`mcp.<server>.header.<name>` or `mcp.<server>.env.<name>`), and the
/// registry stores the reference `keychain:<item>`. The value is never in
/// an entry, a change event, an error text, a log record or a tool result.
struct AgentMCPServerSecrets: MCPServerSecrets {
  /// The field of the form that holds the value.
  static let valueField = "value"

  /// The store that gets each value. It is the store that the
  /// configuration load reads, thus a new reference resolves.
  let writer: any SecretWriter

  /// Writes a value, and gives its reference.
  ///
  /// - Parameters:
  ///   - value: The secret value.
  ///   - server: The name of the server.
  ///   - key: The header or env variable of the value.
  /// - Returns: The reference `keychain:<item>`.
  /// - Throws: The error of the store.
  func store(_ value: String, server: String, key: MCPSecretKey) async throws -> String {
    try writer.setValue(value, forReference: key.keychainItemName(server: server))
    return key.keychainReference(server: server)
  }

  /// Asks the user for a value through a sensitive elicitation of the
  /// tool call that runs now, writes it, and gives its reference (D101).
  ///
  /// The question is sensitive (`ElicitationRequest.sensitive`), thus
  /// Router gives the full answer to this call only: the mail to the model
  /// and the recording get a fixed text with no value, and the client gets
  /// the flag in the `_meta` of the request (``ElicitationAskerMeta``). The
  /// value goes to the store only; the model sees the reference.
  ///
  /// - Parameters:
  ///   - server: The name of the server.
  ///   - key: The header or env variable of the value.
  /// - Returns: The reference, or `nil` when the user declines or cancels,
  ///   or when no tool call runs, so the agent cannot ask.
  /// - Throws: The error of the elicitation or of the store.
  func request(server: String, key: MCPSecretKey) async throws -> String? {
    guard let context = ToolContext.current else {
      return nil
    }
    let response = try await context.elicit(Self.question(server: server, key: key))
    guard response.action == .accept,
      case .string(let value)? = response.content?[Self.valueField], !value.isEmpty
    else {
      return nil
    }
    return try await store(value, server: server, key: key)
  }

  /// The sensitive form that asks for one secret value.
  ///
  /// - Parameters:
  ///   - server: The name of the server.
  ///   - key: The header or env variable of the value.
  /// - Returns: The request.
  static func question(server: String, key: MCPSecretKey) -> ElicitationRequest {
    ElicitationRequest(
      message:
        "The MCP server \"\(server)\" needs the secret value of its \(key). The agent writes it to the "
        + "Keychain, and the model sees only a reference to it.",
      elicitationId: ULID(),
      requestedSchema: ElicitationRequestedSchema(
        properties: [
          valueField: .string(
            ElicitationStringSchema(title: "\(key)", description: "The secret value.", minLength: 1))
        ],
        required: [valueField]),
      sensitive: true)
  }
}
