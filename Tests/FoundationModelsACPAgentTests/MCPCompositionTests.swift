import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsMultitool
import MCPTestServer
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The MCP composition (plan.md §7.3, §11.2, §11.5): two sources compose in
/// order, a name collision is refused, `mcp: false` refuses the client's
/// servers, the servers connect before the registry build, and the surface
/// refresher stages each catalog change for the next turn boundary.
///
/// The roster cases run the pure composition step with no connection. The
/// mounted cases spawn the `mcp-test-server` executable that Multitool ships,
/// through the composition's own stdio path. The reconnect case scripts an
/// in-process `ScriptedServer` from the `MCPTestServer` library behind a
/// transport factory, so a reconnect serves a fresh in-memory pair.
@Suite struct MCPCompositionTests {
    /// The name of the first config-derived server.
    private static let alphaName = "alpha"

    /// The name of the second config-derived server.
    private static let betaName = "beta"

    /// The name of the client-supplied server.
    private static let gammaName = "gamma"

    /// The name of a second client-supplied server.
    private static let deltaName = "delta"

    /// The name of the dynamic-scenario server, and so the noun its verbs
    /// render under.
    private static let dynamicName = "dynamic"

    /// The name of the server of the reconnect case.
    private static let reconnectName = "reconnecting"

    /// The name of the tool the reconnect case publishes between two
    /// connects.
    private static let extraToolName = "extra"

    /// The name of an http client server in the roster cases.
    private static let remoteName = "remote"

    /// A command path for roster cases that never spawn.
    private static let unusedCommand = "/bin/echo"

    /// The `--mode` flag of the `mcp-test-server` executable.
    private static let modeFlag = "--mode"

    /// The mode that registers the echo tool alone.
    private static let echoMode = "echo"

    /// The mode that adds, re-schemas and removes a tool on a timer.
    private static let dynamicMode = "dynamic"

    /// The rendered path of the tool the dynamic scenario starts with.
    private static let counterPath =
        "\(dynamicName).\(ScriptedServer.dynamicToolsetReschemadToolName)"

    /// The rendered path of the tool the dynamic scenario adds.
    private static let greeterPath =
        "\(dynamicName).\(ScriptedServer.dynamicToolsetVanishingToolName)"

    /// The snippet that answers the mounted surface as a JSON array of
    /// paths.
    private static let helpSnippet = "return help();"

    /// How long a polled condition may take before its case fails.
    private static let pollDeadline = Duration.seconds(30)

    /// How long a poll sleeps between two reads.
    private static let pollInterval = Duration.milliseconds(50)

    /// How long a case waits, after the change it expects nothing from, to
    /// show that no stage follows.
    private static let noStageSettleDelay = Duration.milliseconds(300)

    // MARK: - Harness

    /// Makes a fresh throwaway directory and returns its URL.
    ///
    /// - Parameter label: The suffix that names the directory's role.
    /// - Returns: The created directory.
    /// - Throws: Whatever directory creation throws.
    private static func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MCPCompositionTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Makes a catalog context over a fresh working directory and a stub
    /// profile.
    ///
    /// - Parameters:
    ///   - clientServers: The client-supplied per-session servers.
    ///   - configure: The mutation that shapes the configuration under
    ///     test.
    /// - Returns: The context under test.
    /// - Throws: Whatever the directory creation or the profile resolve
    ///   throws.
    private static func makeContext(
        clientServers: [FoundationModelsACP.MCPServer] = [],
        configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> CatalogContext {
        var configuration = AgentConfiguration()
        configure(&configuration)
        return CatalogContext(
            workingDirectory: try makeTemporaryDirectory(label: "work"),
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: try makeTemporaryDirectory(label: "cache")),
            clientMCPServers: clientServers)
    }

    /// A config-derived stdio entry that spawns the `mcp-test-server`
    /// executable in `mode`.
    ///
    /// - Parameters:
    ///   - name: The server name, and so the noun.
    ///   - command: The absolute path of the executable.
    ///   - mode: The `--mode` value.
    /// - Returns: The config entry.
    private static func configServer(
        named name: String, command: String, mode: String
    ) -> MCPServerConfiguration {
        MCPServerConfiguration(
            name: name, transport: .stdio(command: command, args: [modeFlag, mode], env: [:]))
    }

    /// A client-supplied stdio server over the `mcp-test-server` executable
    /// in echo mode.
    ///
    /// - Parameters:
    ///   - name: The server name, and so the noun.
    ///   - command: The absolute path of the executable.
    /// - Returns: The wire value `session/new` carries.
    /// - Throws: Nothing today; `#require` reports a command that is not
    ///   absolute.
    private static func clientStdioServer(
        named name: String, command: String
    ) throws -> FoundationModelsACP.MCPServer {
        .stdio(
            MCPServerStdio(
                command: try #require(AbsolutePath(rawValue: command)),
                name: name,
                args: [modeFlag, echoMode]))
    }

    /// Polls `condition` until it holds, or fails the case at the deadline.
    ///
    /// - Parameters:
    ///   - label: What the case waits for, for the failure message.
    ///   - condition: The condition to poll.
    /// - Throws: Whatever `condition` throws.
    private static func pollUntil(
        _ label: String, _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + pollDeadline
        while ContinuousClock.now < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("timed out while waiting until \(label)")
    }

    /// The paths `help()` lists in a snippet run on `runCode`.
    ///
    /// - Parameter runCode: The mounted tool to run the snippet on.
    /// - Returns: The paths, in render order.
    /// - Throws: What the run or the decode throws.
    private static func helpPaths(of runCode: MultiTool) async throws -> [String] {
        let rendered = try await runCode.call(arguments: RunCodeArguments(code: helpSnippet))
        return try JSONDecoder().decode([String].self, from: Data(rendered.utf8))
    }

    /// A `RegistryStaging` that counts each staged registry, records its
    /// surface paths, and passes it on to the staging the mounted session
    /// vended.
    private final class RecordingStaging: RegistryStaging, Sendable {
        /// What the lock guards: the stage count and the paths of the
        /// newest staged registry.
        private struct State {
            /// How many registries were staged so far.
            var count = 0

            /// The surface paths of the newest staged registry.
            var newestPaths: [String] = []
        }

        /// The staging of the mounted session, which every staged registry
        /// is passed on to.
        private let mounted: any RegistryStaging

        /// The guarded state.
        private let state = Mutex(State())

        /// Creates a staging that records, and then passes on to `mounted`.
        ///
        /// - Parameter mounted: The staging the mounted session vended.
        init(passingTo mounted: any RegistryStaging) {
            self.mounted = mounted
        }

        /// How many registries this staging recorded so far.
        var count: Int {
            state.withLock { $0.count }
        }

        /// The surface paths of the newest staged registry.
        var newestPaths: [String] {
            state.withLock { $0.newestPaths }
        }

        /// Records `registry`, and then stages it on the mounted staging.
        ///
        /// - Parameter registry: The registry to stage.
        func stage(_ registry: MultiTool.Registry) {
            state.withLock {
                $0.count += 1
                $0.newestPaths = registry.surface.entries.map(\.path)
            }
            mounted.stage(registry)
        }
    }

    // MARK: - The roster: two sources, config first

    @Test func configServersComeFirstAndClientServersFollow() async throws {
        let section = MCPToolSection.enabled(servers: [
            Self.configServer(named: Self.alphaName, command: Self.unusedCommand, mode: Self.echoMode),
            Self.configServer(named: Self.betaName, command: Self.unusedCommand, mode: Self.echoMode),
        ])
        let client = try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand)

        let roster = MCPComposition.composeRoster(section: section, clientServers: [client])

        #expect(roster.entries.map(\.name) == [Self.alphaName, Self.betaName, Self.gammaName])
        #expect(roster.refusals.isEmpty)
    }

    @Test func aClientNameThatCollidesWithAConfigServerIsRefused() async throws {
        let section = MCPToolSection.enabled(servers: [
            Self.configServer(named: Self.alphaName, command: Self.unusedCommand, mode: Self.echoMode)
        ])
        let colliding = try Self.clientStdioServer(named: Self.alphaName, command: Self.unusedCommand)
        let clean = try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand)

        let roster = MCPComposition.composeRoster(
            section: section, clientServers: [colliding, clean])

        #expect(roster.entries.map(\.name) == [Self.alphaName, Self.gammaName])
        #expect(roster.refusals == [.nameCollision(serverName: Self.alphaName)])
    }

    @Test func aClientNameThatRepeatsAnEarlierClientNameIsRefused() async throws {
        let first = try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand)
        let repeated = try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand)

        let roster = MCPComposition.composeRoster(
            section: .enabled(servers: []), clientServers: [first, repeated])

        #expect(roster.entries.map(\.name) == [Self.gammaName])
        #expect(roster.refusals == [.nameCollision(serverName: Self.gammaName)])
    }

    @Test func mcpDisabledRefusesEveryClientServerWithOneRefusal() async throws {
        let clients = [
            try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand),
            try Self.clientStdioServer(named: Self.deltaName, command: Self.unusedCommand),
        ]

        let roster = MCPComposition.composeRoster(section: .disabled, clientServers: clients)

        #expect(roster.entries.isEmpty)
        #expect(roster.refusals == [.mcpDisabled(serverNames: [Self.gammaName, Self.deltaName])])
    }

    @Test func mcpDisabledWithNoClientServersRecordsNoRefusal() async throws {
        let roster = MCPComposition.composeRoster(section: .disabled, clientServers: [])

        #expect(roster.entries.isEmpty)
        #expect(roster.refusals.isEmpty)
    }

    @Test func anUnknownClientTransportIsRefused() async throws {
        let client = FoundationModelsACP.MCPServer.unknown(
            "carrier-pigeon", .object(["name": .string(Self.remoteName)]))

        let roster = MCPComposition.composeRoster(
            section: .enabled(servers: []), clientServers: [client])

        #expect(roster.entries.isEmpty)
        #expect(roster.refusals == [.unknownTransport(serverName: Self.remoteName)])
    }

    @Test func clientEnvEntriesNormalizeWithTheLastRepeatedNameWinning() async throws {
        let client = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: try #require(AbsolutePath(rawValue: Self.unusedCommand)),
                name: Self.gammaName,
                args: ["--flag"],
                env: [
                    EnvVariable(name: "TOKEN", value: "first"),
                    EnvVariable(name: "TOKEN", value: "second"),
                ]))

        let roster = MCPComposition.composeRoster(
            section: .enabled(servers: []), clientServers: [client])

        #expect(
            roster.entries == [
                MCPServerConfiguration(
                    name: Self.gammaName,
                    transport: .stdio(
                        command: Self.unusedCommand, args: ["--flag"], env: ["TOKEN": "second"]))
            ])
    }

    @Test func clientHeaderEntriesNormalizeWithTheLastRepeatedNameWinning() async throws {
        let client = FoundationModelsACP.MCPServer.http(
            MCPServerHTTP(
                name: Self.remoteName,
                url: "https://example.test/mcp",
                headers: [
                    HTTPHeader(name: "Authorization", value: "first"),
                    HTTPHeader(name: "Authorization", value: "second"),
                ]))

        let roster = MCPComposition.composeRoster(
            section: .enabled(servers: []), clientServers: [client])

        #expect(
            roster.entries == [
                MCPServerConfiguration(
                    name: Self.remoteName,
                    transport: .http(
                        url: "https://example.test/mcp",
                        headers: ["Authorization": "second"]))
            ])
    }

    // MARK: - Connect errors

    @Test func aRelativeStdioCommandThrowsInsteadOfSpawning() async throws {
        let relativeCommand = "relative/mcp-test-server"
        let section = MCPToolSection.enabled(servers: [
            MCPServerConfiguration(
                name: Self.alphaName,
                transport: .stdio(command: relativeCommand, args: [], env: [:]))
        ])

        await #expect(
            throws: StdioServerProcess.StdioServerProcessError.commandNotAbsolute(relativeCommand)
        ) {
            _ = try await MCPComposition.connectServers(section: section, clientServers: [])
        }
    }

    @Test func anHTTPServerURLThatDoesNotParseThrows() async throws {
        let section = MCPToolSection.enabled(servers: [
            MCPServerConfiguration(name: Self.remoteName, transport: .http(url: "", headers: [:]))
        ])

        await #expect(
            throws: MCPCompositionError.invalidServerURL(serverName: Self.remoteName, url: "")
        ) {
            _ = try await MCPComposition.connectServers(section: section, clientServers: [])
        }
    }

    @Test func mcpDisabledConnectsNothingAndKeepsTheRefusal() async throws {
        let client = try Self.clientStdioServer(named: Self.gammaName, command: Self.unusedCommand)

        let connected = try await MCPComposition.connectServers(
            section: .disabled, clientServers: [client])

        #expect(connected.servers.isEmpty)
        #expect(connected.processes.isEmpty)
        #expect(connected.refusals == [.mcpDisabled(serverNames: [Self.gammaName])])
    }

    // MARK: - The mounted surface

    @Test func configNounsMountFirstThenClientNounsAndNoPathCarriesAnMCPSegment() async throws {
        let command = try BuiltProductLocator.mcpTestServerURL().path
        let context = try await Self.makeContext(
            clientServers: [try Self.clientStdioServer(named: Self.gammaName, command: command)]
        ) { configuration in
            configuration.tools.mcp = .enabled(servers: [
                Self.configServer(named: Self.alphaName, command: command, mode: Self.echoMode),
                Self.configServer(named: Self.betaName, command: command, mode: Self.echoMode),
            ])
        }
        let serverNames = [Self.alphaName, Self.betaName, Self.gammaName]

        let built = try await ToolCatalog.makeRegistry(context: context)
        let entries = built.registry.surface.entries
        await built.pool.shutdownAll()

        let mountedNouns = entries.compactMap(\.group).filter(serverNames.contains)
        var orderedNouns: [String] = []
        for noun in mountedNouns where orderedNouns.last != noun {
            orderedNouns.append(noun)
        }
        #expect(orderedNouns == serverNames)
        let paths = entries.map(\.path)
        for name in serverNames {
            #expect(paths.contains("\(name).\(ScriptedServer.echoToolName)"))
        }
        for path in paths {
            #expect(!path.split(separator: ".").contains("mcp"))
        }
    }

    @Test func aToolListChangeIsStagedAndAppliesOnlyAtTheNextTurnBoundary() async throws {
        let command = try BuiltProductLocator.mcpTestServerURL().path
        let context = try await Self.makeContext { configuration in
            configuration.tools.mcp = .enabled(servers: [
                Self.configServer(named: Self.dynamicName, command: command, mode: Self.dynamicMode)
            ])
        }

        let surface = try await ToolCatalog.sessionSurface(context: context)
        var thrown: (any Error)?
        do {
            let runCode = try #require(surface.tools.compactMap { $0 as? MultiTool }.first)
            let initial = try await Self.helpPaths(of: runCode)
            #expect(initial.contains(Self.counterPath))
            #expect(!initial.contains(Self.greeterPath))

            // The dynamic scenario adds the greeter and sends
            // `tools/list_changed` on its own timer. Before each turn tick
            // the mounted surface must not hold it; the tick that follows a
            // staged rebuild brings it in.
            try await Self.pollUntil("the greeter applies at a turn boundary") {
                let beforeTick = try await Self.helpPaths(of: runCode)
                #expect(!beforeTick.contains(Self.greeterPath))
                await runCode.turnWillBegin()
                return try await Self.helpPaths(of: runCode).contains(Self.greeterPath)
            }
        } catch {
            thrown = error
        }
        await surface.serverPool.shutdownAll()
        if let thrown {
            throw thrown
        }
    }

    // MARK: - Reconnects

    @Test func aReconnectStagesARebuildAndAnUnchangedCatalogStagesNothing() async throws {
        // Each connect serves a fresh scripted server on a fresh in-memory
        // pair. The factory keeps every served instance alive, because the
        // scripted handlers hold their server weakly.
        let served = Mutex<[ScriptedServer]>([])
        let publishExtraTool = Mutex(false)
        let factory: TransportFactory = {
            let scripted = ScriptedServer(name: Self.reconnectName)
            await scripted.addEchoTool()
            if publishExtraTool.withLock({ $0 }) {
                await scripted.addEchoTool(named: Self.extraToolName)
            }
            served.withLock { $0.append(scripted) }
            return try await scripted.startOnInMemoryPair()
        }
        let server = FoundationModelsMultitool.MCPServer(name: Self.reconnectName)
        try await server.connect(via: factory)
        try await server.waitUntilReady()

        let builder = MultiTool.Builder()
        try await builder.withMCP(servers: [server])
        let registry = try builder.buildRegistry()
        let mounted = try registry.makeSessionToolsAndStaging(librarian: nil)
        let recording = RecordingStaging(passingTo: mounted.staging)
        await MCPComposition.startSurfaceRefresher(
            source: builder.registrySource, staging: recording, servers: [server],
            pool: builder.serverPool)

        // The connect snapshot always rebuilds one time.
        try await Self.pollUntil("the connect snapshot staged") { recording.count >= 1 }

        // A reconnect with the same catalog stages nothing more.
        try await server.reconnect()
        try await Task.sleep(for: Self.noStageSettleDelay)
        #expect(recording.count == 1)

        // A reconnect that comes back with a moved catalog stages a rebuild.
        publishExtraTool.withLock { $0 = true }
        try await server.reconnect()
        try await Self.pollUntil("the changed reconnect staged") { recording.count >= 2 }
        #expect(recording.newestPaths.contains("\(Self.reconnectName).\(Self.extraToolName)"))

        // The pool stops the attached refresher before it closes the
        // server, so releasing everything trips no deinit assertion.
        await builder.serverPool.shutdownAll()
        #expect(await builder.serverPool.isEmpty)
        withExtendedLifetime(served) {}
    }

    // MARK: - No persistence

    @Test func aSessionIndexRecordCarriesNoClientServerList() throws {
        let record = SessionIndexRecord(
            sessionId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/tmp/project",
            title: "a title",
            updatedAt: Date(timeIntervalSince1970: 0),
            additionalDirectories: [])

        let encoded = try JSONEncoder().encode(record)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(
            Set(object.keys) == [
                "sessionId", "cwd", "title", "updatedAt", "additionalDirectories",
            ])
    }
}
