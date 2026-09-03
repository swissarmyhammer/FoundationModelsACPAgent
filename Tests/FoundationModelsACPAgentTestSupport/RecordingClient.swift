import FoundationModelsACP
import FoundationModelsACPClient

/// Collects every `session/update` notification in arrival order.
///
/// The container (`ACPSessionState`) is a projection and keeps no
/// history, so an order proof — turn order, cancellation, replay —
/// reads this raw sequence instead (plan.md §20.1).
public actor UpdateCollector {
    /// The collected notifications, in arrival order.
    public private(set) var updates: [UpdateSessionNotification] = []

    /// Creates a collector that has collected nothing.
    public init() {}

    /// Appends one notification.
    ///
    /// - Parameter notification: The notification to record.
    public func append(_ notification: UpdateSessionNotification) {
        updates.append(notification)
    }
}

/// Collects the elicitation traffic the agent sends to the client: each
/// `elicitation/create` request and each `elicitation/complete`
/// notification, in arrival order. The observable container keeps no
/// history of them, so a count or an order proof reads this recorder.
public actor ElicitationWireRecorder {
    /// The recorded create requests, in arrival order.
    public private(set) var creates: [CreateElicitationRequest] = []

    /// The recorded completion notifications, in arrival order.
    public private(set) var completions: [CompleteElicitationNotification] = []

    /// Creates a recorder that has recorded nothing.
    public init() {}

    /// Appends one create request.
    ///
    /// - Parameter request: The request to record.
    public func recordCreate(_ request: CreateElicitationRequest) {
        creates.append(request)
    }

    /// Appends one completion notification.
    ///
    /// - Parameter notification: The notification to record.
    public func recordCompletion(_ notification: CompleteElicitationNotification) {
        completions.append(notification)
    }
}

/// The forwarding recorder (plan.md §20.1): it appends each
/// `UpdateSessionNotification` to its ``UpdateCollector`` and then
/// forwards it to the `SwiftUIACPClient`, so one stream feeds both the
/// order proof and the observable state. The elicitation traffic lands in
/// the ``ElicitationWireRecorder`` the same way.
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

    /// The recorder of the elicitation traffic.
    let elicitations: ElicitationWireRecorder

    /// The observable client every message is forwarded to.
    private let client: SwiftUIACPClient

    /// Creates a recorder in front of `client`.
    ///
    /// - Parameters:
    ///   - client: The observable client to forward to.
    ///   - collector: The recorder of the raw update sequence.
    ///   - elicitations: The recorder of the elicitation traffic.
    init(
        forwardingTo client: SwiftUIACPClient,
        collector: UpdateCollector,
        elicitations: ElicitationWireRecorder = ElicitationWireRecorder()
    ) {
        self.client = client
        self.collector = collector
        self.elicitations = elicitations
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
        await elicitations.recordCreate(params)
        return try await client.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await elicitations.recordCompletion(notification)
        await client.elicitationComplete(notification)
    }
}
