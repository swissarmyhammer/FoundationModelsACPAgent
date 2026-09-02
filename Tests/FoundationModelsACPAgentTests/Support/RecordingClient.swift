import FoundationModelsACP
import FoundationModelsACPClient

/// Collects every `session/update` notification in arrival order.
///
/// The container (`ACPSessionState`) is a projection and keeps no
/// history, so an order proof — turn order, cancellation, replay —
/// reads this raw sequence instead (plan.md §20.1).
actor UpdateCollector {
    /// The collected notifications, in arrival order.
    private(set) var updates: [UpdateSessionNotification] = []

    /// Appends one notification.
    ///
    /// - Parameter notification: The notification to record.
    func append(_ notification: UpdateSessionNotification) {
        updates.append(notification)
    }
}

/// The forwarding recorder (plan.md §20.1): it appends each
/// `UpdateSessionNotification` to its ``UpdateCollector`` and then
/// forwards it to the `SwiftUIACPClient`, so one stream feeds both the
/// order proof and the observable state.
///
/// Wire it with `ClientSideConnection(stream: clientEnd) { _ in recorder }`,
/// because `connect(over:)` binds the client itself.
///
/// There is no configurable permission answer. This agent never sends
/// `session/request_permission` — the sandbox is the only gate — and a
/// test asserts `pendingPermissionRequests` stays empty. Every request
/// therefore forwards to the client unchanged.
final class RecordingClient: Client {
    /// The recorder of the raw update sequence.
    let collector: UpdateCollector

    /// The observable client every message is forwarded to.
    private let client: SwiftUIACPClient

    /// Creates a recorder in front of `client`.
    ///
    /// - Parameters:
    ///   - client: The observable client to forward to.
    ///   - collector: The recorder of the raw update sequence.
    init(forwardingTo client: SwiftUIACPClient, collector: UpdateCollector) {
        self.client = client
        self.collector = collector
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await collector.append(notification)
        await client.sessionUpdate(notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        try await client.requestPermission(params)
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        try await client.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await client.elicitationComplete(notification)
    }
}
