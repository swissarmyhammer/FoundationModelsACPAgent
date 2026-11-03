import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport

/// What one line of the wire is, as an order test reads it. A test that
/// proves an order between the updates and a response reads the lines that
/// the agent sent (`WireTap`), because the collector of the updates does
/// not see the responses.
enum WireItem: Equatable {
    /// A whole-message upsert of a replay.
    case message

    /// A `state_update`.
    case state

    /// A `session_info_update`.
    case info

    /// A JSON-RPC response.
    case response

    /// Any other line.
    case other

    /// The kind of one update.
    ///
    /// - Parameter update: The update.
    /// - Returns: The kind.
    static func of(update: SessionUpdate) -> WireItem {
        switch update {
        case .userMessage, .agentMessage, .agentThought:
            return .message
        case .stateUpdate:
            return .state
        case .sessionInfoUpdate:
            return .info
        default:
            return .other
        }
    }

    /// Reads what the agent sent on the wire while `action` ran.
    ///
    /// - Parameters:
    ///   - tap: The tap of the wire.
    ///   - action: The work whose output is read.
    /// - Returns: The kinds of the lines that the agent sent, in wire order.
    /// - Throws: Whatever `action` throws.
    static func sent(by tap: WireTap, during action: () async throws -> Void) async rethrows -> [WireItem] {
        let countBefore = await tap.lines.count
        try await action()
        return items(ofWire: Array(await tap.lines.dropFirst(countBefore)))
    }

    /// Maps each line of the wire to its kind. The response of a request is
    /// a line with a `result`.
    ///
    /// - Parameter lines: The lines that the agent sent, in wire order.
    /// - Returns: The kinds, in order.
    static func items(ofWire lines: [String]) -> [WireItem] {
        lines.map { line in
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .other
            }
            if object["result"] != nil {
                return .response
            }
            guard object["method"] as? String == "session/update", let params = object["params"],
                let paramsData = try? JSONSerialization.data(withJSONObject: params),
                let notification = try? JSONDecoder().decode(UpdateSessionNotification.self, from: paramsData)
            else {
                return .other
            }
            return of(update: notification.update)
        }
    }
}
