import Foundation
import FoundationModelsACP
import FoundationModelsMultitool
import MCP
import os

/// The logger every MCP composition refusal and connect step reports to.
let mcpCompositionLogger = Logger(subsystem: "FoundationModelsACPAgent", category: "MCPComposition")

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
    enum Refusal: Equatable, Sendable, CustomStringConvertible {
        /// `mcp: false` turned MCP fully off, so every client-supplied
        /// server is refused in one entry.
        case mcpDisabled(serverNames: [String])

        /// The client server's name collides with an already accepted
        /// server, so the earlier server keeps the noun.
        case nameCollision(serverName: String)

        /// The client server arrived with a transport this agent does not
        /// know. The name is `nil` when the payload does not carry one.
        case unknownTransport(serverName: String?)

        /// The log line this refusal writes.
        var description: String {
            switch self {
            case .mcpDisabled(let serverNames):
                return
                    "mcpClientServerRefused reason=mcpDisabled servers=\(serverNames.joined(separator: ","))"
            case .nameCollision(let serverName):
                return "mcpClientServerRefused reason=nameCollision server=\(serverName)"
            case .unknownTransport(let serverName):
                return
                    "mcpClientServerRefused reason=unknownTransport server=\(serverName ?? "unnamed")"
            }
        }
    }

    /// The composed roster: the accepted entries in mount order, and each
    /// refusal in arrival order.
    struct Roster: Equatable, Sendable {
        /// The accepted server entries — config-derived first, then the
        /// accepted client-supplied ones.
        let entries: [MCPServerConfiguration]

        /// The refused client-supplied servers.
        let refusals: [Refusal]
    }

    /// The connected composition: the servers in mount order, the spawned
    /// stdio subprocesses, and the refusals the roster recorded.
    struct ConnectedServers: Sendable {
        /// The connected servers, each `.ready`, in mount order.
        let servers: [FoundationModelsMultitool.MCPServer]

        /// The subprocesses the stdio entries spawned, for the server pool.
        let processes: [StdioServerProcess]

        /// The refused client-supplied servers, already logged.
        let refusals: [Refusal]
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
    /// when the section is `mcp: false`.
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
                return Roster(entries: [], refusals: [])
            }
            let names = clientServers.compactMap(Self.clientServerName)
            return Roster(entries: [], refusals: [.mcpDisabled(serverNames: names)])
        case .enabled(let configEntries):
            return composeEnabledRoster(configEntries: configEntries, clientServers: clientServers)
        }
    }

    /// Appends each accepted client entry after the config entries, and
    /// records a refusal for each name collision and unknown transport.
    ///
    /// - Parameters:
    ///   - configEntries: The config-derived entries, in document order.
    ///   - clientServers: The client-supplied servers, in wire order.
    /// - Returns: The composed roster.
    private static func composeEnabledRoster(
        configEntries: [MCPServerConfiguration],
        clientServers: [FoundationModelsACP.MCPServer]
    ) -> Roster {
        var entries = configEntries
        var refusals: [Refusal] = []
        var takenNames = Set(configEntries.map(\.name))
        for clientServer in clientServers {
            switch normalize(clientServer) {
            case .entry(let entry):
                if takenNames.contains(entry.name) {
                    refusals.append(.nameCollision(serverName: entry.name))
                } else {
                    takenNames.insert(entry.name)
                    entries.append(entry)
                }
            case .unknownTransport(let serverName):
                refusals.append(.unknownTransport(serverName: serverName))
            }
        }
        return Roster(entries: entries, refusals: refusals)
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

    /// Composes the roster, logs each refusal, and connects every accepted
    /// entry — the async step `session/new` awaits before the registry
    /// build (plan.md §7.3, §11.5).
    ///
    /// Each stdio entry spawns a `StdioServerProcess`, whose `respawn` is
    /// the server's transport factory, so a reconnect respawns the
    /// subprocess. Each http entry connects through a fresh
    /// `HTTPClientTransport` per attempt, built from the entry's headers.
    /// Every server is awaited to `.ready`, so `withMCP(servers:)` can read
    /// its catalog. `elicitationHandler` stays nil — see the type
    /// documentation.
    ///
    /// A thrown connect error first disconnects every server this call
    /// already connected and shuts its subprocesses down, so a failed
    /// `session/new` leaks nothing.
    ///
    /// - Parameters:
    ///   - section: The decoded `mcp:` section.
    ///   - clientServers: The client-supplied per-session servers.
    /// - Returns: The connected composition.
    /// - Throws: `StdioServerProcess.StdioServerProcessError` for a command
    ///   that is not an absolute path, ``MCPCompositionError`` for a url
    ///   that does not parse, and whatever a connect throws.
    static func connectServers(
        section: MCPToolSection,
        clientServers: [FoundationModelsACP.MCPServer]
    ) async throws -> ConnectedServers {
        let roster = composeRoster(section: section, clientServers: clientServers)
        for refusal in roster.refusals {
            mcpCompositionLogger.error("\(refusal.description, privacy: .public)")
        }
        var servers: [FoundationModelsMultitool.MCPServer] = []
        var processes: [StdioServerProcess] = []
        do {
            for entry in roster.entries {
                let server = try await connect(entry: entry, spawnedProcesses: &processes)
                servers.append(server)
            }
        } catch {
            await shutDown(servers: servers, processes: processes)
            throw error
        }
        return ConnectedServers(
            servers: servers, processes: processes, refusals: roster.refusals)
    }

    /// Connects one entry and waits until the server is `.ready`.
    ///
    /// - Parameters:
    ///   - entry: The entry to connect.
    ///   - spawnedProcesses: Where a spawned stdio subprocess is recorded —
    ///     appended before the connect, so the caller's failure path can
    ///     shut it down.
    /// - Returns: The connected server.
    /// - Throws: What the process construction, the connect, or the ready
    ///   wait throws.
    private static func connect(
        entry: MCPServerConfiguration,
        spawnedProcesses: inout [StdioServerProcess]
    ) async throws -> FoundationModelsMultitool.MCPServer {
        let server = FoundationModelsMultitool.MCPServer(name: entry.name)
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
        return server
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
    /// - Parameters:
    ///   - servers: The servers already connected.
    ///   - processes: The subprocesses already spawned.
    private static func shutDown(
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
    /// A staged registry applies at the next turn boundary.
    ///
    /// A composition with no server starts no refresher: there is nothing
    /// to watch.
    ///
    /// - Parameters:
    ///   - source: The recorded registrations of the build —
    ///     `Builder.registrySource`.
    ///   - staging: Where each rebuilt registry is staged — the staging
    ///     half of `makeSessionToolsAndStaging(librarian:)`.
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
