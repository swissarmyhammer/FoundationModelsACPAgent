import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import Logging
import MCP
import Tracing

/// Errors thrown while the MCP composition connects a server.
enum MCPCompositionError: Error, CustomStringConvertible, Equatable {
    /// An http server entry carries a `url` that does not parse into a URL
    /// with a scheme.
    case invalidServerURL(serverName: String, url: String)

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .invalidServerURL(let serverName, let url):
            return "mcp server \"\(serverName)\" has a url that does not parse: \"\(url)\""
        }
    }
}

/// The MCP composition (plan.md §7.3, §11.5): two sources become one ordered
/// server roster, the roster connects before the registry build, and a
/// surface refresher watches every connected server.
///
/// **The two sources, in order.** The config-derived `mcp:` servers come
/// first, then the client-supplied per-session `mcpServers`. The client list
/// has session scope and is never persisted; `session/resume` supplies it
/// again (§7.3).
///
/// **The collision rule (§7.3).** A client-supplied server whose name
/// collides with an already accepted server — a config-derived one, or an
/// earlier client-supplied one — is refused and logged, and the session
/// still starts. The server name is the noun of its tools, so a name
/// collision is a noun collision. Config is the user's own committed intent;
/// a silent replacement would let a connecting editor shadow a trusted
/// server.
///
/// **`mcp: false` (§11.2).** MCP is fully off, and the client's servers are
/// refused as well, with one logged refusal that names them. This differs
/// from `mcp: []`, which still accepts the client's servers.
///
/// **Elicitation (§16).** Every composed server keeps `elicitationHandler`
/// nil on purpose: we are a Router host, and the `ToolContext` of the
/// calling run answers first through Router's mailbox. Router wins when
/// present, so a Router host never sets the handler.
enum MCPComposition {
    /// One refused client-supplied server, and why (plan.md §7.3, §11.2).
    enum Refusal: Equatable, Sendable {
        /// `mcp: false` turned MCP fully off, so every client-supplied
        /// server is refused in one entry.
        case mcpDisabled(serverNames: [String])

        /// The client server's name collides with an already accepted
        /// server, so the earlier server keeps the noun.
        case nameCollision(serverName: String)

        /// The client server arrived with a transport this agent does not
        /// know. The name is `nil` when the payload does not carry one.
        case unknownTransport(serverName: String?)

        /// The metadata of the log record of this refusal: the name of the
        /// refusal case, and the server name. The `mcp: false` refusal gives
        /// an array of names. A server with no name gives no name value.
        ///
        /// The record holds no other value of the server. An `env` value or
        /// a `headers` value is a secret, and it never goes into a record.
        var logMetadata: Logger.Metadata {
            var metadata: Logger.Metadata = [
                ACPAgentTelemetry.LogMetadataKey.mcpRefusalReason:
                    "\(ACPAgentTelemetry.caseName(of: self))"
            ]
            metadata[ACPAgentTelemetry.LogMetadataKey.mcpServerName] = serverNameValue
            return metadata
        }

        /// The message of the log record of this refusal. The `mcp: false`
        /// refusal refuses all client-supplied servers in one record, thus
        /// its message refers to all the servers. Each other refusal refuses
        /// one server, thus its message refers to one server.
        var logMessage: Logger.Message {
            switch self {
            case .mcpDisabled:
                "The composition refused all client-supplied MCP servers, because MCP is off."
            case .nameCollision, .unknownTransport:
                "The composition refused a client-supplied MCP server."
            }
        }

        /// The reason of the `.failed` outcome of each server that this
        /// refusal refuses.
        var failureReason: ServerOutcome.FailureReason {
            switch self {
            case .mcpDisabled: .mcpDisabled
            case .nameCollision: .nameCollision
            case .unknownTransport: .unknownTransport
            }
        }

        /// The server name value of the log record, or `nil` when the
        /// refused server has no name.
        private var serverNameValue: Logger.MetadataValue? {
            switch self {
            case .mcpDisabled(let serverNames):
                .array(serverNames.map { .string($0) })
            case .nameCollision(let serverName):
                .string(serverName)
            case .unknownTransport(let serverName):
                serverName.map { .string($0) }
            }
        }
    }

    /// The outcome of one server of the composition: its name, its
    /// transport, its origin, and if it connected or why it did not. The
    /// status report of the session shows the outcomes to the client.
    ///
    /// An outcome holds no `env` value, no `headers` value, no URL, no
    /// command argument and no description of an error. Each of these can
    /// hold a secret, so the reason of a failure is a closed set of agent
    /// texts (``FailureReason``).
    struct ServerOutcome: Equatable, Sendable {
        /// The transport of one server.
        enum Transport: Equatable, Sendable {
            /// A subprocess that speaks MCP on its stdin and stdout.
            case stdio

            /// A server at an http url.
            case http

            /// The wire text of the transport: `stdio` or `http`.
            var wireName: String {
                switch self {
                case .stdio: MCPComposition.stdioTransportName
                case .http: MCPComposition.httpTransportName
                }
            }
        }

        /// The source of the entry of one server. The raw value is the text
        /// of the origin in a log record and in the `origin` member of the
        /// status report (``MCPServerStatusReport``).
        enum Origin: String, Equatable, Sendable {
            /// The `mcp:` section of the configuration.
            case config

            /// The `mcpServers` of the `session/new` or the
            /// `session/resume` request.
            case client
        }

        /// Why one server is not connected. The raw value of each case is
        /// the agent text of the reason.
        enum FailureReason: String, Equatable, Sendable {
            /// The stdio command is not an absolute path.
            case commandNotAbsolute = "The command is not an absolute path."

            /// The http url does not parse into a URL with a scheme.
            case invalidURL = "The url does not parse."

            /// The connect or the wait for the ready state failed.
            case connectFailed = "The connect to the server failed."

            /// The name is the name of an earlier server.
            case nameCollision = "An earlier server has the same name."

            /// The configuration turns MCP off.
            case mcpDisabled = "MCP is off in the configuration."

            /// The agent does not know the transport of the server.
            case unknownTransport = "The transport is not known."

            /// The table from a connect error to its reason. Each row holds
            /// the test that matches the type and the case of an error, and
            /// the reason of that error. An error that no row matches is a
            /// failure of the connect or of the ready wait.
            private static let connectErrorReasons:
                [(matches: @Sendable (any Error) -> Bool, reason: FailureReason)] = [
                    (
                        {
                            if case .commandNotAbsolute? = $0 as? StdioServerProcess.StdioServerProcessError {
                                true
                            } else {
                                false
                            }
                        },
                        .commandNotAbsolute
                    ),
                    (
                        { if case .invalidServerURL? = $0 as? MCPCompositionError { true } else { false } },
                        .invalidURL
                    ),
                ]

            /// The reason of a connect that threw `error`. The reason is
            /// read from the type and the case of the error, never from its
            /// description.
            ///
            /// - Parameter error: The error the connect threw.
            init(connectError error: any Error) {
                self = Self.connectErrorReasons.first { $0.matches(error) }?.reason ?? .connectFailed
            }
        }

        /// If the server connected, or why it did not.
        enum Result: Equatable, Sendable {
            /// The server connected and is `.ready`.
            case connected

            /// The server is not connected, for `reason`.
            case failed(reason: FailureReason)

            /// The text of the result in a log record: `connected` or
            /// `failed`.
            var logName: String {
                switch self {
                case .connected: "connected"
                case .failed: "failed"
                }
            }

            /// The level of the log record of the result: `info` for a
            /// connected server, `warning` for a failed server.
            var logLevel: Logger.Level {
                switch self {
                case .connected: .info
                case .failed: .warning
                }
            }

            /// The message of the log record of the result. The message
            /// does not hold the server name; the metadata holds it.
            var logMessage: Logger.Message {
                switch self {
                case .connected: "The composition connected an MCP server."
                case .failed: "The composition did not connect an MCP server."
                }
            }
        }

        /// The server name, and so the noun of its tools.
        let name: String

        /// The transport of the server, or `nil` when the agent does not
        /// know it.
        let transport: Transport?

        /// The source of the entry of the server.
        let origin: Origin

        /// If the server connected, or why it did not.
        let result: Result

        /// The metadata of the log record of this outcome: the server name,
        /// the transport (when the agent knows it), the origin, the result,
        /// and the case name of the reason of a failure.
        ///
        /// The record holds no other value of the server. The outcome holds
        /// no `env` value, no `headers` value, no URL, no command argument
        /// and no description of an error, so the record holds none.
        var logMetadata: Logger.Metadata {
            typealias Key = ACPAgentTelemetry.LogMetadataKey
            var metadata: Logger.Metadata = [
                Key.mcpServerName: "\(name)",
                Key.mcpServerOrigin: "\(origin.rawValue)",
                Key.mcpServerResult: "\(result.logName)",
            ]
            metadata[Key.mcpServerTransport] = transport.map { "\($0.wireName)" }
            if case .failed(let reason) = result {
                metadata[Key.mcpFailureReason] = "\(reason)"
            }
            return metadata
        }
    }

    /// The composed roster: the accepted entries in mount order, and each
    /// refusal in arrival order.
    struct Roster: Equatable, Sendable {
        /// One accepted entry and its source.
        struct Entry: Equatable, Sendable {
            /// The entry, in the config shape.
            let configuration: MCPServerConfiguration

            /// The source of the entry. A connect failure of a
            /// config-derived entry throws; a connect failure of a
            /// client-supplied entry gives a `.failed` outcome.
            let origin: ServerOutcome.Origin
        }

        /// The accepted server entries — config-derived first, then the
        /// accepted client-supplied ones.
        let entries: [Entry]

        /// The refused client-supplied servers.
        let refusals: [Refusal]

        /// One `.failed` outcome for each refused server that has a name,
        /// in arrival order.
        let refusalOutcomes: [ServerOutcome]
    }

    /// The connected composition: the servers in mount order, the spawned
    /// stdio subprocesses, the refusals the roster recorded, and the outcome
    /// of each server.
    struct ConnectedServers: Sendable {
        /// The connected servers, each `.ready`, in mount order.
        let servers: [FoundationModelsMultitool.MCPServer]

        /// The subprocesses the stdio entries spawned, for the server pool.
        let processes: [StdioServerProcess]

        /// The refused client-supplied servers, already logged.
        let refusals: [Refusal]

        /// The outcome of each entry in mount order, then the outcome of
        /// each refused server that has a name.
        let outcomes: [ServerOutcome]
    }

    /// A client-supplied server after normalization: a config-shaped entry,
    /// or a refusal of a transport this agent does not know.
    private enum NormalizedClientServer {
        /// The entry, shaped like a config-derived one.
        case entry(MCPServerConfiguration)

        /// The transport is unknown; the name is carried when the payload
        /// has one.
        case unknownTransport(serverName: String?)
    }

    // MARK: - The roster

    /// Composes the two sources into one ordered roster (plan.md §7.3):
    /// config-derived entries first, then each accepted client-supplied
    /// entry, with a refusal for each collision — see the collision rule in
    /// the type documentation — and one refusal for every client server
    /// when the section is `mcp: false`. Each refused server that has a name
    /// also gets one `.failed` outcome.
    ///
    /// - Parameters:
    ///   - section: The decoded `mcp:` section.
    ///   - clientServers: The client-supplied per-session servers, in wire
    ///     order.
    /// - Returns: The composed roster.
    static func composeRoster(
        section: MCPToolSection,
        clientServers: [FoundationModelsACP.MCPServer]
    ) -> Roster {
        switch section {
        case .disabled:
            guard !clientServers.isEmpty else {
                return Roster(entries: [], refusals: [], refusalOutcomes: [])
            }
            let refusal = Refusal.mcpDisabled(
                serverNames: clientServers.compactMap(Self.clientServerName))
            return Roster(
                entries: [],
                refusals: [refusal],
                refusalOutcomes: clientServers.compactMap {
                    refusalOutcome(of: $0, reason: refusal.failureReason)
                })
        case .enabled(let configEntries):
            return composeEnabledRoster(configEntries: configEntries, clientServers: clientServers)
        }
    }

    /// Appends each accepted client entry after the config entries, and
    /// records a refusal and its outcome for each name collision and
    /// unknown transport.
    ///
    /// - Parameters:
    ///   - configEntries: The config-derived entries, in document order.
    ///   - clientServers: The client-supplied servers, in wire order.
    /// - Returns: The composed roster.
    private static func composeEnabledRoster(
        configEntries: [MCPServerConfiguration],
        clientServers: [FoundationModelsACP.MCPServer]
    ) -> Roster {
        var entries = configEntries.map { Roster.Entry(configuration: $0, origin: .config) }
        var refusals: [Refusal] = []
        var refusalOutcomes: [ServerOutcome] = []
        var takenNames = Set(configEntries.map(\.name))
        for clientServer in clientServers {
            let refusal: Refusal
            switch normalize(clientServer) {
            case .entry(let entry) where !takenNames.contains(entry.name):
                takenNames.insert(entry.name)
                entries.append(Roster.Entry(configuration: entry, origin: .client))
                continue
            case .entry(let entry):
                refusal = .nameCollision(serverName: entry.name)
            case .unknownTransport(let serverName):
                refusal = .unknownTransport(serverName: serverName)
            }
            refusals.append(refusal)
            if let outcome = refusalOutcome(of: clientServer, reason: refusal.failureReason) {
                refusalOutcomes.append(outcome)
            }
        }
        return Roster(entries: entries, refusals: refusals, refusalOutcomes: refusalOutcomes)
    }

    /// The `.failed` outcome of one refused client-supplied server, or `nil`
    /// when the server has no name to show.
    ///
    /// - Parameters:
    ///   - clientServer: The refused wire value.
    ///   - reason: Why the server is refused.
    /// - Returns: The outcome, when the server has a name.
    private static func refusalOutcome(
        of clientServer: FoundationModelsACP.MCPServer,
        reason: ServerOutcome.FailureReason
    ) -> ServerOutcome? {
        guard let name = clientServerName(of: clientServer) else {
            return nil
        }
        return ServerOutcome(
            name: name, transport: clientTransport(of: clientServer), origin: .client,
            result: .failed(reason: reason))
    }

    /// The transport of one client-supplied server, or `nil` for a
    /// transport this agent does not know.
    ///
    /// - Parameter clientServer: The wire value to read.
    /// - Returns: The transport, when the agent knows it.
    private static func clientTransport(
        of clientServer: FoundationModelsACP.MCPServer
    ) -> ServerOutcome.Transport? {
        switch clientServer {
        case .stdio: .stdio
        case .http: .http
        case .unknown: nil
        }
    }

    /// Normalizes one client-supplied server into the config entry shape.
    ///
    /// The wire's `env` and `headers` are `{name, value}` pair lists; a
    /// repeated name keeps the later value, per plan.md §7.3.
    ///
    /// - Parameter clientServer: The wire value to normalize.
    /// - Returns: The normalized entry, or the unknown-transport marker.
    private static func normalize(
        _ clientServer: FoundationModelsACP.MCPServer
    ) -> NormalizedClientServer {
        switch clientServer {
        case .stdio(let stdio):
            var env: [String: String] = [:]
            for variable in stdio.env ?? [] {
                env[variable.name] = variable.value
            }
            return .entry(
                MCPServerConfiguration(
                    name: stdio.name,
                    transport: .stdio(
                        command: stdio.command.rawValue, args: stdio.args ?? [], env: env)))
        case .http(let http):
            var headers: [String: String] = [:]
            for header in http.headers ?? [] {
                headers[header.name] = header.value
            }
            return .entry(
                MCPServerConfiguration(
                    name: http.name, transport: .http(url: http.url, headers: headers)))
        case .unknown(_, let payload):
            return .unknownTransport(serverName: Self.name(inUnknownPayload: payload))
        }
    }

    /// The `name` member of one client-supplied server, or `nil` for an
    /// unknown transport whose payload carries none.
    ///
    /// - Parameter clientServer: The wire value to read.
    /// - Returns: The server name, when there is one.
    private static func clientServerName(
        of clientServer: FoundationModelsACP.MCPServer
    ) -> String? {
        switch clientServer {
        case .stdio(let stdio):
            return stdio.name
        case .http(let http):
            return http.name
        case .unknown(_, let payload):
            return name(inUnknownPayload: payload)
        }
    }

    /// The `name` member of an unknown-transport payload, when the payload
    /// is an object with a string `name`.
    ///
    /// - Parameter payload: The captured members of the unknown variant.
    /// - Returns: The name, or `nil`.
    private static func name(inUnknownPayload payload: JSONValue) -> String? {
        guard case .object(let members) = payload, case .string(let name)? = members["name"] else {
            return nil
        }
        return name
    }

    // MARK: - The connect step

    /// Composes the roster, logs each refusal, connects every accepted
    /// entry, and logs the outcome of each server — the async step
    /// `session/new` awaits before the registry build (plan.md §7.3, §11.5).
    ///
    /// Each stdio entry spawns a `StdioServerProcess`, whose `respawn` is
    /// the server's transport factory, so a reconnect respawns the
    /// subprocess. Each http entry connects through a fresh
    /// `HTTPClientTransport` per attempt, built from the entry's headers.
    /// Every server is awaited to `.ready`, so `withMCP(servers:)` can read
    /// its catalog. `elicitationHandler` stays nil — see the type
    /// documentation.
    ///
    /// A connect failure of a client-supplied entry does not throw: the
    /// failed server is disconnected, its subprocess is shut down, the entry
    /// gets a `.failed` outcome, and the next entry connects. Thus one broken
    /// client server does not stop `session/new` or `session/resume`.
    ///
    /// A connect failure of a config-derived entry throws, because the
    /// config is the committed intent of the user. Before the throw, every
    /// server this call connected is disconnected and every subprocess it
    /// spawned is shut down, so a failed `session/new` leaks nothing.
    ///
    /// - Parameters:
    ///   - section: The decoded `mcp:` section.
    ///   - clientServers: The client-supplied per-session servers.
    /// - Returns: The connected composition.
    /// - Throws: For a config-derived entry:
    ///   `StdioServerProcess.StdioServerProcessError` for a command that is
    ///   not an absolute path, ``MCPCompositionError`` for a url that does
    ///   not parse, and whatever a connect throws.
    static func connectServers(
        section: MCPToolSection,
        clientServers: [FoundationModelsACP.MCPServer]
    ) async throws -> ConnectedServers {
        let roster = composeRoster(section: section, clientServers: clientServers)
        for refusal in roster.refusals {
            ACPAgentTelemetry.logger(.mcpComposition).error(
                refusal.logMessage, metadata: refusal.logMetadata)
        }
        var servers: [FoundationModelsMultitool.MCPServer] = []
        var processes: [StdioServerProcess] = []
        var outcomes: [ServerOutcome] = []
        for entry in roster.entries {
            let result = try await connect(entry: entry, servers: &servers, processes: &processes)
            outcomes.append(
                ServerOutcome(
                    name: entry.configuration.name,
                    transport: transport(of: entry.configuration.transport),
                    origin: entry.origin,
                    result: result))
        }
        outcomes += roster.refusalOutcomes
        log(outcomes: outcomes)
        return ConnectedServers(
            servers: servers, processes: processes, refusals: roster.refusals, outcomes: outcomes)
    }

    /// Writes one log record for each outcome, in the order of the outcomes:
    /// an `info` record for a connected server and a `warning` record for a
    /// failed server. The metadata of the record is
    /// ``ServerOutcome/logMetadata``, and the message does not hold the
    /// server name.
    ///
    /// - Parameter outcomes: The outcomes of the composition.
    private static func log(outcomes: [ServerOutcome]) {
        let logger = ACPAgentTelemetry.logger(.mcpComposition)
        for outcome in outcomes {
            logger.log(
                level: outcome.result.logLevel, outcome.result.logMessage, metadata: outcome.logMetadata)
        }
    }

    /// Connects one entry of the roster, and records the connected server
    /// and its subprocess.
    ///
    /// A failure first disconnects the failed server and shuts its
    /// subprocess down. A client-supplied entry then gives a `.failed`
    /// result. A config-derived entry also disconnects every server in
    /// `servers` and shuts every subprocess in `processes` down, and then
    /// throws the error again.
    ///
    /// - Parameters:
    ///   - entry: The entry to connect.
    ///   - servers: The servers connected so far; a connected server is
    ///     appended.
    ///   - processes: The subprocesses spawned so far; the subprocess of a
    ///     connected stdio server is appended.
    /// - Returns: `.connected`, or `.failed` with the reason of the failure
    ///   of a client-supplied entry.
    /// - Throws: What the connect of a config-derived entry throws.
    private static func connect(
        entry: Roster.Entry,
        servers: inout [FoundationModelsMultitool.MCPServer],
        processes: inout [StdioServerProcess]
    ) async throws -> ServerOutcome.Result {
        let server = FoundationModelsMultitool.MCPServer(name: entry.configuration.name)
        var spawned: [StdioServerProcess] = []
        do {
            try await connect(entry: entry.configuration, server: server, spawnedProcesses: &spawned)
        } catch {
            await shutDown(servers: [server], processes: spawned)
            guard entry.origin == .client else {
                await shutDown(servers: servers, processes: processes)
                throw error
            }
            return .failed(reason: ServerOutcome.FailureReason(connectError: error))
        }
        servers.append(server)
        processes.append(contentsOf: spawned)
        return .connected
    }

    /// The ``ACPAgentTelemetry/AttributeKey/mcpServerTransport`` value of a
    /// stdio server.
    private static let stdioTransportName = "stdio"

    /// The ``ACPAgentTelemetry/AttributeKey/mcpServerTransport`` value of an
    /// http server.
    private static let httpTransportName = "http"

    /// Connects one entry and waits until the server is `.ready`.
    ///
    /// The connect runs in one MCP connect span (``AgentTracing``), a child
    /// of the span of the request that composes the session. The span
    /// carries the server name and the transport. A connect that throws gives
    /// the span the error status and the type of the error, never the
    /// description of the error. A slow server can hold the connect for a
    /// long time, so the span writes one "enter" record when it opens. The
    /// span and the record never carry the command arguments, an `env`
    /// value, a `headers` value or the URL.
    ///
    /// A connect that throws also adds one to the `mcp_connect_failures`
    /// counter (``AgentMetrics``), with the transport and never the server
    /// name.
    ///
    /// - Parameters:
    ///   - entry: The entry to connect.
    ///   - server: The server to connect, named for the entry. The caller
    ///     disconnects it when the connect throws.
    ///   - spawnedProcesses: Where a spawned stdio subprocess is recorded —
    ///     appended before the connect, so the caller's failure path can
    ///     shut it down.
    /// - Throws: What the process construction, the connect, or the ready
    ///   wait throws.
    private static func connect(
        entry: MCPServerConfiguration,
        server: FoundationModelsMultitool.MCPServer,
        spawnedProcesses: inout [StdioServerProcess]
    ) async throws {
        let transportName = transport(of: entry.transport).wireName
        do {
            try await AgentTracing.withEnteredSpan(
                ACPAgentTelemetry.SpanName.mcpConnect,
                logger: ACPAgentTelemetry.logger(.mcpComposition),
                attributes: { attributes in
                    attributes[ACPAgentTelemetry.AttributeKey.mcpServerName] = entry.name
                    attributes[ACPAgentTelemetry.AttributeKey.mcpServerTransport] = transportName
                },
                metadata: [ACPAgentTelemetry.LogMetadataKey.mcpServerName: "\(entry.name)"]
            ) { _ in
                try await connectToReady(
                    entry: entry, server: server, spawnedProcesses: &spawnedProcesses)
            }
        } catch {
            AgentMetrics.recordMCPConnectFailure(transport: transportName)
            throw error
        }
    }

    /// The transport of one entry, for the connect span and the outcome.
    ///
    /// - Parameter transport: The transport of the entry.
    /// - Returns: `.stdio` or `.http`.
    private static func transport(
        of transport: MCPServerConfiguration.Transport
    ) -> ServerOutcome.Transport {
        switch transport {
        case .stdio: .stdio
        case .http: .http
        }
    }

    /// Connects one entry and waits until the server is `.ready`: the work
    /// of ``connect(entry:server:spawnedProcesses:)`` in the connect span.
    ///
    /// - Parameters:
    ///   - entry: The entry to connect.
    ///   - server: The server to connect.
    ///   - spawnedProcesses: Where a spawned stdio subprocess is recorded.
    /// - Throws: What the process construction, the connect, or the ready
    ///   wait throws.
    private static func connectToReady(
        entry: MCPServerConfiguration,
        server: FoundationModelsMultitool.MCPServer,
        spawnedProcesses: inout [StdioServerProcess]
    ) async throws {
        switch entry.transport {
        case .stdio(let command, let args, let env):
            let process = try StdioServerProcess(
                command: command, args: args, env: envVariables(env), name: entry.name)
            spawnedProcesses.append(process)
            try await server.connect(via: process.respawn)
        case .http(let url, let headers):
            guard let endpoint = URL(string: url), endpoint.scheme != nil else {
                throw MCPCompositionError.invalidServerURL(serverName: entry.name, url: url)
            }
            try await server.connect(via: httpTransportFactory(endpoint: endpoint, headers: headers))
        }
        try await server.waitUntilReady()
    }

    /// The config env mapping as the ordered pair list a spawn takes, in
    /// name order so a spawn is deterministic. The pairs layer onto the
    /// inherited environment; they never replace it.
    ///
    /// - Parameter env: The env mapping of one entry.
    /// - Returns: The ordered pairs.
    private static func envVariables(_ env: [String: String]) -> [StdioServerProcess.EnvVariable] {
        env.sorted { $0.key < $1.key }
            .map { StdioServerProcess.EnvVariable(name: $0.key, value: $0.value) }
    }

    /// A transport factory that builds a fresh `HTTPClientTransport` per
    /// connect attempt, with `headers` applied to every request.
    ///
    /// - Parameters:
    ///   - endpoint: The server URL.
    ///   - headers: The headers of the entry — the auth carrier of an http
    ///     server (plan.md §11.5).
    /// - Returns: The factory a server connects and reconnects through.
    private static func httpTransportFactory(
        endpoint: URL, headers: [String: String]
    ) -> TransportFactory {
        {
            let configuration = URLSessionConfiguration.ephemeral
            if !headers.isEmpty {
                configuration.httpAdditionalHeaders = headers
            }
            return HTTPClientTransport(endpoint: endpoint, configuration: configuration)
        }
    }

    /// Disconnects each server and shuts each subprocess down — the cleanup
    /// of a connect step that threw partway.
    ///
    /// ``SystemToolsProber`` calls this too: its probe connects one entry
    /// and then gives everything back, so a `doctor` run leaves no server
    /// connected and no subprocess alive.
    ///
    /// - Parameters:
    ///   - servers: The servers already connected.
    ///   - processes: The subprocesses already spawned.
    static func shutDown(
        servers: [FoundationModelsMultitool.MCPServer], processes: [StdioServerProcess]
    ) async {
        for server in servers {
            await server.disconnect()
        }
        for process in processes {
            await process.shutdown()
        }
    }

    // MARK: - The surface refresher

    /// Makes a `SurfaceRefresher` over the connected servers, starts it,
    /// and attaches it to `pool` — so `MCPServerPool.shutdownAll()` stops
    /// the watch before it closes any server, and the refresher's deinit
    /// assertion never trips (plan.md §11.5).
    ///
    /// The refresher consumes each server's `catalogUpdates` stream, which
    /// fires for a connect that reached `.ready`, for a reconnect, and for
    /// a coalesced `tools/list_changed` re-list. A snapshot whose catalog
    /// did not move stages nothing, so the rebuild is idempotent and cheap.
    /// A staged registry applies at the next submission boundary.
    ///
    /// A composition with no server starts no refresher: there is nothing
    /// to watch.
    ///
    /// - Parameters:
    ///   - source: The recorded registrations of the build —
    ///     `Builder.registrySource`.
    ///   - staging: Where each rebuilt registry is staged — the staging
    ///     half of `makeSessionToolsAndStaging(selection:embedder:sampleSession:)`.
    ///   - servers: The connected servers to watch.
    ///   - pool: The pool that stops the refresher at shutdown.
    static func startSurfaceRefresher(
        source: MultiTool.RegistrySource,
        staging: any RegistryStaging,
        servers: [FoundationModelsMultitool.MCPServer],
        pool: MCPServerPool
    ) async {
        guard !servers.isEmpty else {
            return
        }
        let refresher = SurfaceRefresher(source: source, staging: staging, servers: servers)
        refresher.start()
        await pool.attach(attachment: refresher)
    }
}
