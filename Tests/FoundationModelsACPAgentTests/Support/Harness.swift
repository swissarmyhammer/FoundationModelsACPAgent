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
struct AgentClientHarness {
    /// The dotfolder name the harness constructs the agent with. The
    /// wire must never carry it (plan.md §5).
    static let dotfolderName = "coding"

    /// The coalescing cadence the harness client is created with. The
    /// value is inert: the ``HoldingClock`` never reaches any deadline.
    static let coalescingCadence: Swift.Duration = .seconds(60)

    /// The agent under test.
    let agent: RoutedACPAgent

    /// The observable client container, the primary assertion surface.
    let client: SwiftUIACPClient

    /// The client side of the wire, which drives the agent.
    let connection: ClientSideConnection

    /// The agent side of the wire.
    let agentConnection: AgentSideConnection

    /// The recorder of the raw update sequence, or `nil` when the
    /// harness was wired without one (``make()``).
    let collector: UpdateCollector?

    /// Makes an agent for ``dotfolderName``.
    ///
    /// - Returns: The agent.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func makeAgent() throws -> RoutedACPAgent {
        RoutedACPAgent(name: try DotfolderName(dotfolderName))
    }

    /// The client's `initialize` request with the driver's own values.
    ///
    /// - Parameters:
    ///   - protocolVersion: The latest version the client supports.
    ///   - capabilities: The client's capabilities.
    /// - Returns: The request.
    static func makeInitializeRequest(
        protocolVersion: ProtocolVersion = ACPClient.supportedProtocolVersion,
        capabilities: ClientCapabilities = ACPClient.advertisedCapabilities
    ) -> InitializeRequest {
        InitializeRequest(
            info: Implementation(name: "test-driver", version: "1.0.0"),
            protocolVersion: protocolVersion,
            capabilities: capabilities)
    }

    /// Wires a fresh agent and client over an in-memory transport pair,
    /// with the client bound through `connect(over:)`.
    ///
    /// - Returns: The connected harness, with no collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func make() async throws -> AgentClientHarness {
        let parts = try await makeParts()
        let connection = await parts.client.connect(over: parts.clientEnd)
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: nil)
    }

    /// Wires a fresh agent and client with a ``RecordingClient`` in
    /// front of the client, so a test can assert the raw notification
    /// order on the collector and the final state on the client.
    ///
    /// `ClientSideConnection(stream:)` binds the recorder here, because
    /// `connect(over:)` binds the client itself (plan.md §20.1).
    ///
    /// - Returns: The connected harness, with a collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func makeRecording() async throws -> AgentClientHarness {
        let parts = try await makeParts()
        let collector = UpdateCollector()
        let recorder = RecordingClient(forwardingTo: parts.client, collector: collector)
        let connection = await ClientSideConnection(stream: parts.clientEnd) { _ in recorder }
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: collector)
    }

    /// Flushes the coalescing buffer of every session, so a test
    /// observes buffered text without sleeping for the cadence.
    @MainActor
    func flushPendingChunks() {
        for state in client.sessions.values {
            state.flushPendingChunks()
        }
    }

    /// Closes both ends of the wire.
    func close() async {
        await connection.close()
        await agentConnection.close()
    }

    /// The wiring both factories share: the transport pair, the agent
    /// with its connection, and the client over the holding clock.
    private static func makeParts() async throws -> (
        clientEnd: InMemoryTransport,
        agent: RoutedACPAgent,
        agentConnection: AgentSideConnection,
        client: SwiftUIACPClient
    ) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = try makeAgent()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in agent }
        let client = await SwiftUIACPClient(
            coalescingCadence: coalescingCadence, clock: HoldingClock())
        return (clientEnd, agent, agentConnection, client)
    }
}
