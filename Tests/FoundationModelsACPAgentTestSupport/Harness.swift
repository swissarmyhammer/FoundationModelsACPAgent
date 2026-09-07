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
/// driver (plan.md §20.1): a ``HarnessWire``, an `AgentSideConnection`
/// around the agent, and a `SwiftUIACPClient` over an injected
/// ``HoldingClock`` on the other end.
///
/// The wire is `InMemoryTransport.pair()` by default, the transport the
/// Mac app and `run` mode use. A suite that must prove the `acp` wire
/// answers alike passes ``HarnessWire/makeStdioPipes()`` instead
/// (cli-plan.md §4).
///
/// ``make(wire:)`` wires the client itself through `connect(over:)`.
/// ``makeRecording(wire:)`` wires a ``RecordingClient`` in front of it,
/// so the raw notification order lands in an ``UpdateCollector`` while
/// the observable state still lands in the client.
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
    /// harness was wired without one (``make(wire:)``).
    public let collector: UpdateCollector?

    /// The recorder of the elicitation traffic, or `nil` when the
    /// harness was wired without one (``make(wire:)``).
    public let elicitations: ElicitationWireRecorder?

    /// The tap on the client end of the wire, or `nil` when the harness
    /// was wired without one.
    ///
    /// Only an order proof that spans a response and a notification
    /// needs it (plan.md §8.1), so it is off by default and every other
    /// suite runs the untapped wire.
    public let wireTap: WireTap?

    /// The tap on the agent end of the wire, or `nil` when the harness
    /// was wired without one.
    ///
    /// Its lines are the ones the CLIENT sent, because a tap records the
    /// incoming direction of the end it wraps. It is the only reading of
    /// a client-to-agent notification: `session/cancel` carries no
    /// response, so nothing else on the wire says it arrived.
    public let agentWireTap: WireTap?

    /// The transport pair the two connections run over. ``close()``
    /// ends it after both connections are down.
    public let wire: HarnessWire

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

    /// Wires a fresh agent and client over a transport pair, with the
    /// client bound through `connect(over:)`.
    ///
    /// - Parameter wire: The transport pair to run over. The in-process
    ///   pair by default.
    /// - Returns: The connected harness, with no collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    public static func make(
        wire: HarnessWire = .makeInMemory()
    ) async throws -> AgentClientHarness {
        let parts = await makeParts(
            agent: try await makeAgent(), agentEnd: wire.agentEnd)
        let connection = await parts.client.connect(over: wire.clientEnd)
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: nil,
            elicitations: nil,
            wireTap: nil,
            agentWireTap: nil,
            wire: wire)
    }

    /// Wires a fresh agent and client with a ``RecordingClient`` in
    /// front of the client, so a test can assert the raw notification
    /// order on the collector and the final state on the client.
    ///
    /// - Parameter wire: The transport pair to run over. The in-process
    ///   pair by default.
    /// - Returns: The connected harness, with a collector.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    public static func makeRecording(
        wire: HarnessWire = .makeInMemory()
    ) async throws -> AgentClientHarness {
        try await makeRecording(agent: makeAgent(), wire: wire)
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
    ///   - tapsAgentWire: Whether a ``WireTap`` stands on the agent end,
    ///     so a proof can read what the client sent. Off by default,
    ///     because only the §5.9 cancel proof reads it.
    ///   - wire: The transport pair to run over. The in-process pair by
    ///     default; a §4 comparison passes the stdio pipes instead.
    /// - Returns: The connected harness, with a collector.
    public static func makeRecording(
        agent: RoutedACPAgent,
        tapsWire: Bool = false,
        tapsAgentWire: Bool = false,
        wire: HarnessWire = .makeInMemory()
    ) async -> AgentClientHarness {
        let agentWireTap = tapsAgentWire ? WireTap(tapping: wire.agentEnd) : nil
        let parts = await makeParts(
            agent: agent, agentEnd: agentWireTap ?? wire.agentEnd)
        let collector = UpdateCollector()
        let recorder = RecordingClient(forwardingTo: parts.client, collector: collector)
        let wireTap = tapsWire ? WireTap(tapping: wire.clientEnd) : nil
        let clientEnd: any ACPTransport = wireTap ?? wire.clientEnd
        let connection = await ClientSideConnection(stream: clientEnd) { _ in recorder }
        return AgentClientHarness(
            agent: parts.agent,
            client: parts.client,
            connection: connection,
            agentConnection: parts.agentConnection,
            collector: collector,
            elicitations: recorder.elicitations,
            wireTap: wireTap,
            agentWireTap: agentWireTap,
            wire: wire)
    }

    /// Flushes the coalescing buffer of every session, so a test
    /// observes buffered text without sleeping for the cadence.
    @MainActor
    public func flushPendingChunks() {
        for state in client.sessions.values {
            state.flushPendingChunks()
        }
    }

    /// Closes both ends of the wire, ends the tap, and releases the
    /// transport pair. A pipe wire holds descriptors, so the release is
    /// what gives them back.
    public func close() async {
        await connection.close()
        await agentConnection.close()
        wireTap?.stop()
        agentWireTap?.stop()
        wire.close()
    }

    /// The wiring every factory shares: the agent with its connection
    /// over the wire's agent end, and the client over the holding clock.
    /// The factory closure binds the connection into the agent, so a
    /// prompt turn can notify through it (plan.md §8.1).
    ///
    /// - Parameters:
    ///   - agent: The agent under test.
    ///   - agentEnd: The end the agent serves: the wire's own agent end,
    ///     or a ``WireTap`` around it.
    /// - Returns: The agent with its connection, and the client.
    private static func makeParts(
        agent: RoutedACPAgent, agentEnd: any ACPTransport
    ) async -> (
        agent: RoutedACPAgent,
        agentConnection: AgentSideConnection,
        client: SwiftUIACPClient
    ) {
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            agent.bind(connection: connection)
            return agent
        }
        let client = await SwiftUIACPClient(
            coalescingCadence: coalescingCadence, clock: HoldingClock())
        return (agent, agentConnection, client)
    }
}
