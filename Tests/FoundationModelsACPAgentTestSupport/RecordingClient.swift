import FoundationModelsACP
import FoundationModelsACPClient

/// Collects every `session/update` notification in arrival order.
///
/// A `SessionModel` is a projection and keeps no history of the raw
/// updates, so an order proof — prompt order, cancellation, replay —
/// reads this raw sequence instead (plan.md §20.1).
public actor UpdateCollector {
    /// The collected notifications, in arrival order.
    public private(set) var updates: [UpdateSessionNotification] = []

    /// Creates a collector that has collected nothing.
    public init() {}

    /// Appends one notification.
    ///
    /// - Parameter notification: The notification to record.
    public func append(notification: UpdateSessionNotification) {
        updates.append(notification)
    }
}

/// Collects the elicitation traffic the agent sends to the client: each
/// `elicitation/create` request and each `elicitation/complete`
/// notification, in arrival order. The observable models keep no history
/// of them, so a count or an order proof reads this recorder.
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
    public func recordCreate(request: CreateElicitationRequest) {
        creates.append(request)
    }

    /// Appends one completion notification.
    ///
    /// - Parameter notification: The notification to record.
    public func recordCompletion(notification: CompleteElicitationNotification) {
        completions.append(notification)
    }
}

/// The forwarding recorder (plan.md §20.1): it appends each
/// `UpdateSessionNotification` to its ``UpdateCollector`` and then
/// forwards it to the router of a `ConnectionModel`. The elicitation
/// traffic lands in the ``ElicitationWireRecorder`` the same way.
///
/// The router ignores each `session/update`, because each `SessionModel`
/// reads its updates from its own subscription. The recorder still
/// forwards each one: the router contract asks each wrapper to forward
/// `sessionUpdate(_:)` and `elicitationComplete(_:)`.
///
/// Wire it with the `client` closure of
/// `ConnectionModel.connect(over:client:)`, which gives the router.
///
/// There is no configurable permission answer. This agent never sends
/// `session/request_permission` (plan.md §11.7), and a test asserts
/// `pendingPermissions` stays empty as a regression tripwire. Every
/// request therefore forwards to the router unchanged.
final class RecordingClient: Client {
    /// The recorder of the raw update sequence.
    let collector: UpdateCollector

    /// The recorder of the elicitation traffic.
    let elicitations: ElicitationWireRecorder

    /// The router of the connection model, which gets each message.
    private let router: any Client

    /// Creates a recorder in front of `router`.
    ///
    /// - Parameters:
    ///   - router: The router of the connection model to forward to.
    ///   - collector: The recorder of the raw update sequence.
    ///   - elicitations: The recorder of the elicitation traffic.
    init(
        forwardingTo router: any Client,
        collector: UpdateCollector,
        elicitations: ElicitationWireRecorder
    ) {
        self.router = router
        self.collector = collector
        self.elicitations = elicitations
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await collector.append(notification: notification)
        await router.sessionUpdate(notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        try await router.requestPermission(params)
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        await elicitations.recordCreate(request: params)
        return try await router.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await elicitations.recordCompletion(notification: notification)
        await router.elicitationComplete(notification)
    }
}
