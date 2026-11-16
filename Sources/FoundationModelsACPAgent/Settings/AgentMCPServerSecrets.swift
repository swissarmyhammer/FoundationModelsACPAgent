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

  /// Gives no reference: the agent does not ask the user for a secret
  /// value through an elicitation yet (D101).
  ///
  /// Router mails each answer that it delivers to a tool to the model as
  /// well (`MailBody.elicitationAnswer`), with the accepted content as
  /// text. That text goes into the model input and the session recording,
  /// thus a secret value in the answer would leak. Until Router can keep
  /// the content of a secret answer out of that mail, this port does not
  /// ask. The registry then refuses the change with `secretDeclined`, and
  /// the user gives the value through the app, whose `mcpServers` endpoint
  /// writes it to the store with no elicitation.
  ///
  /// - Parameters:
  ///   - server: The name of the server.
  ///   - key: The header or env variable of the value.
  /// - Returns: `nil`.
  func request(server: String, key: MCPSecretKey) async throws -> String? {
    nil
  }

  /// The form that asks for one secret value. ``request(server:key:)``
  /// sends it when Router can keep the answer out of the model input.
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
        required: [valueField]))
  }
}
