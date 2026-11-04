import FoundationModelsACP
import FoundationModelsACPClient

/// Collects every `session/update` notification in arrival order.
///
/// A `SessionModel` is a projection and keeps no history of the raw
/// updates, so an order proof — prompt order, cancellation, replay —
/// reads this raw sequence instead.
///
/// A test waits for a condition over the sequence with
/// ``wait(for:until:)``: each append resumes the waits whose condition is
/// now true, so the wait uses no clock and no poll.
public actor UpdateCollector {
  /// The collected notifications, in arrival order, with their waits.
  private let collected = WatchedValue<[UpdateSessionNotification]>([])

  /// The collected notifications, in arrival order.
  public var updates: [UpdateSessionNotification] {
    collected.value
  }

  /// Creates a collector that has collected nothing.
  public init() {}

  /// Appends one notification, and resumes each wait whose condition is
  /// now true.
  ///
  /// - Parameter notification: The notification to record.
  public func append(notification: UpdateSessionNotification) {
    collected.update { $0.append(notification) }
  }

  /// Waits until `isMet` is true for the collected sequence. Returns at
  /// once when it is true now.
  ///
  /// - Parameters:
  ///   - condition: The name of the condition, for the error of a
  ///     cancelled wait.
  ///   - isMet: Tells if the condition is true for a sequence.
  /// - Returns: The first collected sequence for which `isMet` is true.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the condition comes.
  public nonisolated func wait(
    for condition: String,
    until isMet: @escaping @Sendable ([UpdateSessionNotification]) -> Bool
  ) async throws -> [UpdateSessionNotification] {
    try await collected.wait(for: condition, until: isMet)
  }
}

/// Collects the elicitation traffic the agent sends to the client: each
/// `elicitation/create` request and each `elicitation/complete`
/// notification, in arrival order. It also collects each
/// `session/request_permission` request, because only the `permission` step
/// of the stub script sends one, over the same relay. The observable models
/// keep no history of them, so a count or an order proof reads this
/// recorder.
public actor ElicitationWireRecorder {
  /// The recorded permission requests, in arrival order, with their waits.
  private let recordedPermissions = WatchedValue<[RequestPermissionRequest]>([])

  /// The recorded permission requests, in arrival order.
  public var permissions: [RequestPermissionRequest] {
    recordedPermissions.value
  }

  /// The recorded create requests, in arrival order, with their waits.
  private let recordedCreates = WatchedValue<[CreateElicitationRequest]>([])

  /// The recorded create requests, in arrival order.
  public var creates: [CreateElicitationRequest] {
    recordedCreates.value
  }

  /// The recorded completion notifications, in arrival order.
  public private(set) var completions: [CompleteElicitationNotification] = []

  /// Creates a recorder that has recorded nothing.
  public init() {}

  /// Appends one create request.
  ///
  /// - Parameter request: The request to record.
  public func recordCreate(request: CreateElicitationRequest) {
    Self.record(request, into: recordedCreates)
  }

  /// Waits until at least `count` create requests were recorded. Returns
  /// at once when they are recorded now. The wait uses no clock and no
  /// poll: each record resumes it.
  ///
  /// - Parameter count: The number of create requests to wait for.
  /// - Returns: The recorded requests, in arrival order.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the requests come.
  public nonisolated func waitForCreates(count: Int) async throws -> [CreateElicitationRequest] {
    try await Self.waitForCount(
      count, in: recordedCreates, label: "elicitation create request(s)")
  }

  /// Appends one permission request.
  ///
  /// - Parameter request: The request to record.
  public func recordPermission(request: RequestPermissionRequest) {
    Self.record(request, into: recordedPermissions)
  }

  /// Waits until at least `count` permission requests were recorded.
  /// Returns at once when they are recorded now. The wait uses no clock
  /// and no poll: each record resumes it.
  ///
  /// - Parameter count: The number of permission requests to wait for.
  /// - Returns: The recorded requests, in arrival order.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the requests come.
  public nonisolated func waitForPermissions(count: Int) async throws -> [RequestPermissionRequest]
  {
    try await Self.waitForCount(count, in: recordedPermissions, label: "permission request(s)")
  }

  /// Appends one element to a watched list, and resumes each wait whose
  /// condition is now true.
  ///
  /// - Parameters:
  ///   - element: The element to record.
  ///   - watched: The list that holds the recorded elements.
  private static func record<Element: Sendable>(
    _ element: Element, into watched: WatchedValue<[Element]>
  ) {
    watched.update { $0.append(element) }
  }

  /// Waits until a watched list holds at least `count` elements. Returns at
  /// once when it does now.
  ///
  /// - Parameters:
  ///   - count: The number of elements to wait for.
  ///   - watched: The list that holds the recorded elements.
  ///   - label: The name of the elements, for the error of a cancelled wait.
  /// - Returns: The recorded elements, in arrival order.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the elements come.
  private static func waitForCount<Element: Sendable>(
    _ count: Int, in watched: WatchedValue<[Element]>, label: String
  ) async throws -> [Element] {
    try await watched.wait(for: "\(count) \(label)") { $0.count >= count }
  }

  /// Appends one completion notification.
  ///
  /// - Parameter notification: The notification to record.
  public func recordCompletion(notification: CompleteElicitationNotification) {
    completions.append(notification)
  }
}

/// One `_sah/graphql/*` notification that the agent sent to the client.
public enum GraphQLTunnelNotification: Equatable, Sendable {
  /// `_sah/graphql/next`: the next result of a subscription.
  case next(SAH.GraphQL.NextNotification)

  /// `_sah/graphql/error`: the subscription ended with errors.
  case error(SAH.GraphQL.ErrorNotification)

  /// `_sah/graphql/complete`: the subscription ended with no error.
  case complete(SAH.GraphQL.CompleteNotification)

  /// Whether the notification ends its subscription: `error` or
  /// `complete`.
  public var endsSubscription: Bool {
    switch self {
    case .next: false
    case .error, .complete: true
    }
  }
}

/// Collects the `_sah/graphql/*` notifications that the agent sends to the
/// client, in arrival order.
///
/// A test waits for a condition over the sequence with
/// ``wait(for:until:)``: each record resumes the waits whose condition is
/// now true, so the wait uses no clock and no poll.
public final class GraphQLTunnelRecorder: Sendable {
  /// The recorded notifications, in arrival order, with their waits.
  private let recorded = WatchedValue<[GraphQLTunnelNotification]>([])

  /// Creates a recorder that has recorded nothing.
  public init() {}

  /// Appends one notification, and resumes each wait whose condition is
  /// now true.
  ///
  /// - Parameter notification: The notification to record.
  public func record(_ notification: GraphQLTunnelNotification) {
    recorded.update { $0.append(notification) }
  }

  /// Waits until `isMet` is true for the recorded sequence. Returns at
  /// once when it is true now.
  ///
  /// - Parameters:
  ///   - condition: The name of the condition, for the error of a
  ///     cancelled wait.
  ///   - isMet: Tells if the condition is true for a sequence.
  /// - Returns: The first recorded sequence for which `isMet` is true.
  /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
  ///   cancelled before the condition comes.
  public func wait(
    for condition: String,
    until isMet: @escaping @Sendable ([GraphQLTunnelNotification]) -> Bool
  ) async throws -> [GraphQLTunnelNotification] {
    try await recorded.wait(for: condition, until: isMet)
  }
}

/// The forwarding recorder: it appends each
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
/// There is no configurable permission answer. This agent sends
/// `session/request_permission` only for the `permission` step of the stub
/// script (the sandbox is the only gate), and a test asserts
/// `pendingPermissions` stays empty for every other script as a regression
/// tripwire. Every request therefore forwards to the router unchanged, after
/// the recorder keeps a copy.
final class RecordingClient: Client {
  /// The recorder of the raw update sequence.
  let collector: UpdateCollector

  /// The recorder of the elicitation traffic.
  let elicitations: ElicitationWireRecorder

  /// The recorder of the `_sah/graphql/*` notifications.
  let graphQLNotifications: GraphQLTunnelRecorder

  /// The router of the connection model, which gets each message.
  private let router: any Client

  /// Creates a recorder in front of `router`.
  ///
  /// - Parameters:
  ///   - router: The router of the connection model to forward to.
  ///   - collector: The recorder of the raw update sequence.
  ///   - elicitations: The recorder of the elicitation traffic.
  ///   - graphQLNotifications: The recorder of the `_sah/graphql/*`
  ///     notifications.
  init(
    forwardingTo router: any Client,
    collector: UpdateCollector,
    elicitations: ElicitationWireRecorder,
    graphQLNotifications: GraphQLTunnelRecorder
  ) {
    self.router = router
    self.collector = collector
    self.elicitations = elicitations
    self.graphQLNotifications = graphQLNotifications
  }

  /// The handlers of the router, with one handler for each notification
  /// of the GraphQL tunnel that records it in ``graphQLNotifications``.
  var extensionHandlers: ExtensionHandlers {
    var handlers = router.extensionHandlers
    let recorder = graphQLNotifications
    handlers.registerNotification(
      SAH.GraphQL.Method.next, params: SAH.GraphQL.NextNotification.self
    ) {
      recorder.record(.next($0))
    }
    handlers.registerNotification(
      SAH.GraphQL.Method.error, params: SAH.GraphQL.ErrorNotification.self
    ) {
      recorder.record(.error($0))
    }
    handlers.registerNotification(
      SAH.GraphQL.Method.complete, params: SAH.GraphQL.CompleteNotification.self
    ) {
      recorder.record(.complete($0))
    }
    return handlers
  }

  func sessionUpdate(_ notification: UpdateSessionNotification) async {
    await collector.append(notification: notification)
    await router.sessionUpdate(notification)
  }

  func requestPermission(
    _ params: RequestPermissionRequest
  ) async throws -> RequestPermissionResponse {
    await elicitations.recordPermission(request: params)
    return try await router.requestPermission(params)
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
