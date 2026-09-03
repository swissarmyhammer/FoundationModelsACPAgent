import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient

/// The instant type of ``HoldingClock``: an offset from the clock's epoch.
struct HoldingInstant: InstantProtocol {
    /// The offset from the clock's epoch.
    let offset: Swift.Duration

    func advanced(by duration: Swift.Duration) -> HoldingInstant {
        HoldingInstant(offset: offset + duration)
    }

    func duration(to other: HoldingInstant) -> Swift.Duration {
        other.offset - offset
    }

    static func < (lhs: HoldingInstant, rhs: HoldingInstant) -> Bool {
        lhs.offset < rhs.offset
    }
}

/// A clock that never fires: `now` stands still, and a sleep suspends
/// until its task is cancelled.
///
/// The harness injects it into `SwiftUIACPClient`, so no coalescing
/// flush runs on a cadence. A test drains the buffer with
/// ``AgentClientHarness/flushPendingChunks()`` and never sleeps
/// (plan.md §20.1).
struct HoldingClock: Clock {
    var now: HoldingInstant { HoldingInstant(offset: .zero) }

    var minimumResolution: Swift.Duration { .zero }

    /// Suspends until the surrounding task is cancelled. The deadline
    /// never arrives on this clock.
    ///
    /// - Parameters:
    ///   - deadline: Ignored; it never arrives.
    ///   - tolerance: Ignored; nothing fires.
    /// - Throws: `CancellationError` when the task is cancelled.
    func sleep(until deadline: HoldingInstant, tolerance: Swift.Duration?) async throws {
        // A stream that never yields: awaiting it suspends, and the
        // task's cancellation ends the iteration.
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        for await _ in stream {}
        withExtendedLifetime(continuation) {}
        try Task.checkCancellation()
    }
}

/// One in-process wiring of `RoutedACPAgent` and the shipped client
/// driver (plan.md §20.1): `InMemoryTransport.pair()`, an
/// `AgentSideConnection` around the agent, and a `SwiftUIACPClient` over
/// an injected ``HoldingClock`` on the other end.
///
/// ``make()`` wires the client itself through `connect(over:)`.
/// ``makeRecording()`` wires a ``RecordingClient`` in front of it, so
/// the raw notification order lands in an ``UpdateCollector`` while the
/// observable state still lands in the client.
public struct AgentClientHarness: Sendable {
    /// The dotfolder name the harness constructs the agent with. The
    /// wire must never carry it (plan.md §5).
    public static let dotfolderName = "coding"

    /// The number of seconds in ``coalescingCadence``. The name records
    /// that the length is arbitrary: the ``HoldingClock`` never reaches
    /// any deadline.
    private static let inertCadenceSeconds = 60

    /// The coalescing cadence the harness client is created with. The
    /// value is inert: the ``HoldingClock`` never reaches any deadline.
    public static let coalescingCadence: Swift.Duration = .seconds(inertCadenceSeconds)

    /// The agent under test.
    public let agent: RoutedACPAgent

    /// The observable client container, the primary assertion surface.
    public let client: SwiftUIACPClient

    /// The client side of the wire, which drives the agent.
    public let connection: ClientSideConnection

    /// The agent side of the wire.
    public let agentConnection: AgentSideConnection

    /// The recorder of the raw update sequence, or `nil` when the
    /// harness was wired without one (``make()``).
    public let collector: UpdateCollector?

    /// The recorder of the elicitation traffic, or `nil` when the
    /// harness was wired without one (``make()``).
    public let elicitations: ElicitationWireRecorder?

    /// The tap on the client end of the wire, or `nil` when the harness
    /// was wired without one.
    ///
    /// Only an order proof that spans a response and a notification
    /// needs it (plan.md §8.1), so it is off by default and every other
    /// suite runs the untapped wire.
    public let wireTap: WireTap?

    /// Makes an agent for ``dotfolderName`` through the shared
    /// `makeStubAgent` factory, so the construction-time profile
    /// resolution downloads nothing.
    ///
    /// - Returns: The agent.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused,
    ///   or `ProfileResolutionError` when the stub resolution fails.
    public static func makeAgent() async throws -> RoutedACPAgent {
        try await makeStubAgent(
            name: dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "AgentClientHarness-cache"))
    }

    /// The client's `initialize` request with the driver's own values.
    ///
    /// - Parameters:
    ///   - protocolVersion: The latest version the client supports.
    ///   - capabilities: The client's capabilities.
    /// - Returns: The request.
    public static func makeInitializeRequest(
        protocolVersion: ProtocolVersion = ACPClient.supportedProtocolVersion,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities
    ) -> InitializeRequest {
        InitializeRequest(
            info: Implementation(name: "test-driver", version: "1.0.0"),
            protocolVersion: protocolVersion,
            capabilities: capabilities)
    }

    /// The prompt request with one text block.
    ///
    /// It stands beside ``makeInitializeRequest(protocolVersion:capabilities:)``
    /// because every driver of this harness — the in-process unit suites
    /// and the integration package's spawned-binary suites alike — sends
    /// its turn through it.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - text: The text of the one block.
    /// - Returns: The request.
    public static func makePromptRequest(sessionId: SessionId, text: String) -> PromptRequest {
        PromptRequest(prompt: [.text(TextContent(text: text))], sessionId: sessionId)
    }

    /// Wires a fresh agent and client over an in-memory transport pair,
    /// with the client bound through `connect(over:)`.
    ///
    /// - Returns: The connected harness, with no collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    public static func make() async throws -> AgentClientHarness {
        let parts = await makeParts(agent: try await makeAgent())
        let connection = await parts.client.connect(over: parts.clientEnd)
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: nil,
            elicitations: nil,
            wireTap: nil)
    }

    /// Wires a fresh agent and client with a ``RecordingClient`` in
    /// front of the client, so a test can assert the raw notification
    /// order on the collector and the final state on the client.
    ///
    /// - Returns: The connected harness, with a collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    public static func makeRecording() async throws -> AgentClientHarness {
        try await makeRecording(agent: makeAgent())
    }

    /// Wires the given agent — for example one whose model plays a
    /// script — with a ``RecordingClient`` in front of the client.
    ///
    /// `ClientSideConnection(stream:)` binds the recorder here, because
    /// `connect(over:)` binds the client itself (plan.md §20.1).
    ///
    /// - Parameters:
    ///   - agent: The agent under test.
    ///   - tapsWire: Whether a ``WireTap`` stands on the client end, so
    ///     a proof can read the raw line order. Off by default, because
    ///     only the §8.1 order proof reads it.
    /// - Returns: The connected harness, with a collector.
    public static func makeRecording(
        agent: RoutedACPAgent, tapsWire: Bool = false
    ) async -> AgentClientHarness {
        let parts = await makeParts(agent: agent)
        let collector = UpdateCollector()
        let recorder = RecordingClient(forwardingTo: parts.client, collector: collector)
        let wireTap = tapsWire ? WireTap(tapping: parts.clientEnd) : nil
        let clientEnd: any ACPTransport = wireTap ?? parts.clientEnd
        let connection = await ClientSideConnection(stream: clientEnd) { _ in recorder }
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: collector,
            elicitations: recorder.elicitations,
            wireTap: wireTap)
    }

    /// Flushes the coalescing buffer of every session, so a test
    /// observes buffered text without sleeping for the cadence.
    @MainActor
    public func flushPendingChunks() {
        for state in client.sessions.values {
            state.flushPendingChunks()
        }
    }

    /// Closes both ends of the wire and ends the tap.
    public func close() async {
        await connection.close()
        await agentConnection.close()
        wireTap?.stop()
    }

    /// The wiring every factory shares: the transport pair, the agent
    /// with its connection, and the client over the holding clock. The
    /// factory closure binds the connection into the agent, so a prompt
    /// turn can notify through it (plan.md §8.1).
    private static func makeParts(agent: RoutedACPAgent) async -> (
        clientEnd: InMemoryTransport,
        agent: RoutedACPAgent,
        agentConnection: AgentSideConnection,
        client: SwiftUIACPClient
    ) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            agent.bind(connection: connection)
            return agent
        }
        let client = await SwiftUIACPClient(
            coalescingCadence: coalescingCadence, clock: HoldingClock())
        return (clientEnd, agent, agentConnection, client)
    }
}
