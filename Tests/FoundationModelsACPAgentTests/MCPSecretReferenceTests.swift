import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The `keychain:<name>` references in the `env` and `headers` values of an
/// `mcp:` server entry (ACPA-18, D98(d)): the loader gives each reference
/// its value from the ``SecretStore``, a reference with no item gives one
/// warning and leaves out only that variable or header, and each text form
/// shows the reference and never the value. A literal header value is
/// redacted, and a literal env value shows as it is.
///
/// Each load reads an ``InMemorySecretStore`` or a ``FailingSecretStore``,
/// thus no test touches the real Keychain.
@Suite struct MCPSecretReferenceTests {
    // MARK: - Constants

    /// The name of the http server.
    private static let httpServerName = "github-remote"

    /// The name of the stdio server.
    private static let stdioServerName = "github-local"

    /// The reference name of the header token.
    private static let headerReference = "github-mcp-token"

    /// The reference name of the env token.
    private static let envReference = "github-token"

    /// The value that the store holds for ``headerReference``.
    private static let headerValue = "mcp-header-secret-value-51c7e2"

    /// The value that the store holds for ``envReference``.
    private static let envValue = "mcp-env-secret-value-0d93ab"

    /// A literal header value in `config.yaml`.
    private static let literalHeaderValue = "mcp-literal-header-value-8e14f6"

    /// A literal env value in `config.yaml`, which is not a secret.
    private static let literalEnvValue = "/usr/local/bin:/usr/bin"

    /// The header that carries the token.
    private static let headerName = "Authorization"

    /// The second header, which holds a literal value.
    private static let literalHeaderName = "X-Api-Key"

    /// The env variable that carries the token.
    private static let envName = "GITHUB_TOKEN"

    /// The env variable that holds a literal value.
    private static let literalEnvName = "PATH"

    /// The URL of the http server, which no test connects to.
    private static let serverURL = "https://example.test/mcp"

    /// The command of the stdio server, which no test spawns.
    private static let serverCommand = "/usr/local/bin/github-mcp"

    /// The key path of the header token.
    private static let headerKeyPath = "tools.mcp.\(httpServerName).headers.\(headerName)"

    /// The key path of the env token.
    private static let envKeyPath = "tools.mcp.\(stdioServerName).env.\(envName)"

    /// A project `config.yaml` with one http server and one stdio server.
    /// Each server has one reference and one literal.
    private static let serversYAML = """
        tools:
          mcp:
            - name: \(httpServerName)
              url: \(serverURL)
              headers:
                \(headerName): keychain:\(headerReference)
                \(literalHeaderName): \(literalHeaderValue)
            - name: \(stdioServerName)
              command: \(serverCommand)
              env:
                \(envName): keychain:\(envReference)
                \(literalEnvName): \(literalEnvValue)
        """

    /// The store that holds the value of each reference of ``serversYAML``.
    private static let storeWithItems = InMemorySecretStore([
        headerReference: headerValue,
        envReference: envValue,
    ])

    /// The text of the warning for a reference with no item.
    private static let noItemText = "has no item"

    // MARK: - Helpers

    /// Loads ``serversYAML`` as the project `config.yaml` over `store`.
    ///
    /// - Parameter store: The store of the load.
    /// - Returns: The load.
    /// - Throws: Whatever the load throws.
    private static func load(store: any SecretStore) throws -> LoadedConfiguration {
        try ConfigurationLoaderTests.Fixture().loadProjectConfig(serversYAML, secretStore: store)
    }

    /// The server named `name` of `loaded`.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - loaded: The load.
    /// - Returns: The server, or `nil` when MCP is off or no server has the
    ///   name.
    private static func server(named name: String, in loaded: LoadedConfiguration) -> MCPServerConfiguration? {
        switch loaded.configuration.tools.mcp {
        case .enabled(let servers):
            servers.first { $0.name == name }
        case .disabled:
            nil
        }
    }

    /// The headers of `transport`.
    ///
    /// - Parameter transport: The transport of a server.
    /// - Returns: The headers, or `nil` for a stdio transport.
    private static func headers(of transport: MCPServerConfiguration.Transport) -> [String: ConfiguredSecret]? {
        switch transport {
        case .http(_, let headers):
            headers
        case .stdio:
            nil
        }
    }

    /// The env of `transport`.
    ///
    /// - Parameter transport: The transport of a server.
    /// - Returns: The env, or `nil` for an http transport.
    private static func env(of transport: MCPServerConfiguration.Transport) -> [String: ConfiguredSecret]? {
        switch transport {
        case .stdio(_, _, let env):
            env
        case .http:
            nil
        }
    }

    /// The headers of the http server of `loaded`.
    ///
    /// - Parameter loaded: The load.
    /// - Returns: The headers.
    /// - Throws: A failed requirement when the server is missing or is not
    ///   an http server.
    private static func headers(of loaded: LoadedConfiguration) throws -> [String: ConfiguredSecret] {
        let server = try #require(server(named: httpServerName, in: loaded))
        return try #require(headers(of: server.transport))
    }

    /// The env of the stdio server of `loaded`.
    ///
    /// - Parameter loaded: The load.
    /// - Returns: The env.
    /// - Throws: A failed requirement when the server is missing or is not
    ///   a stdio server.
    private static func env(of loaded: LoadedConfiguration) throws -> [String: ConfiguredSecret] {
        let server = try #require(server(named: stdioServerName, in: loaded))
        return try #require(env(of: server.transport))
    }

    // MARK: - The load

    /// A header reference with an item gets the value of the item, and
    /// keeps its reference.
    @Test func aHeaderReferenceGetsTheValueOfTheItem() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let header = try #require(try Self.headers(of: loaded)[Self.headerName])
        #expect(header.value == Self.headerValue)
        #expect(header.reference == Self.headerReference)
        #expect(loaded.warnings.isEmpty)
    }

    /// An env reference with an item gets the value of the item, and a
    /// literal env value stays as it is.
    @Test func anEnvReferenceGetsTheValueOfTheItem() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let env = try Self.env(of: loaded)
        #expect(env[Self.envName]?.value == Self.envValue)
        #expect(env[Self.envName]?.reference == Self.envReference)
        #expect(env[Self.literalEnvName] == ConfiguredSecret(Self.literalEnvValue))
    }

    /// A reference with no item gives one warning for each reference. Each
    /// warning names the server, the key and the reference. Only that
    /// variable or header is left out, and each server stays.
    @Test func aReferenceWithNoItemGivesAWarningAndLeavesOutOnlyThatKey() throws {
        let loaded = try Self.load(store: InMemorySecretStore())

        #expect(
            loaded.warnings == [
                .unresolvedSecret(keyPath: Self.headerKeyPath, reference: Self.headerReference),
                .unresolvedSecret(keyPath: Self.envKeyPath, reference: Self.envReference),
            ])
        let headers = try Self.headers(of: loaded)
        let env = try Self.env(of: loaded)
        #expect(headers[Self.headerName] == nil)
        #expect(headers[Self.literalHeaderName] == ConfiguredSecret(Self.literalHeaderValue))
        #expect(env[Self.envName] == nil)
        #expect(env[Self.literalEnvName] == ConfiguredSecret(Self.literalEnvValue))
        let message = try #require(loaded.warnings.first).description
        #expect(message.contains(Self.httpServerName))
        #expect(message.contains(Self.headerName))
        #expect(message.contains(Self.headerReference))
        #expect(message.contains(Self.noItemText))
    }

    /// A store that throws gives one lookup-failed warning for each
    /// reference, and leaves out only that variable or header.
    @Test func aStoreFailureGivesALookupFailedWarningAndLeavesOutOnlyThatKey() throws {
        let loaded = try Self.load(store: FailingSecretStore())

        #expect(
            loaded.warnings == [
                .unreadableSecret(keyPath: Self.headerKeyPath, reference: Self.headerReference),
                .unreadableSecret(keyPath: Self.envKeyPath, reference: Self.envReference),
            ])
        #expect(try Self.headers(of: loaded)[Self.headerName] == nil)
        #expect(try Self.env(of: loaded)[Self.envName] == nil)
    }

    /// A client-supplied server of `session/new` does not change: a value
    /// that starts with `keychain:` is a literal, and no store reads it.
    @Test func aClientServerValueIsALiteral() {
        let text = "keychain:\(Self.headerReference)"
        let client = FoundationModelsACP.MCPServer.http(
            MCPServerHTTP(
                name: Self.httpServerName, url: Self.serverURL,
                headers: [HTTPHeader(name: Self.headerName, value: text)]))

        let roster = MCPComposition.composeRoster(section: .enabled(servers: []), clientServers: [client])

        #expect(
            roster.entries.map(\.configuration) == [
                MCPServerConfiguration(
                    name: Self.httpServerName,
                    transport: .http(url: Self.serverURL, headers: [Self.headerName: ConfiguredSecret(text)]))
            ])
    }

    // MARK: - The consumers

    /// The resolved header value goes into `httpAdditionalHeaders` of the
    /// session that connects to the server.
    @Test func theResolvedHeaderReachesTheHTTPAdditionalHeaders() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let configuration = MCPComposition.sessionConfiguration(headers: try Self.headers(of: loaded))

        let additional = try #require(configuration.httpAdditionalHeaders as? [String: String])
        #expect(additional[Self.headerName] == Self.headerValue)
        #expect(additional[Self.literalHeaderName] == Self.literalHeaderValue)
    }

    /// The resolved env value goes into the environment of the child
    /// process, in name order.
    @Test func theResolvedEnvValueReachesTheChildProcess() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let variables = MCPComposition.envVariables(try Self.env(of: loaded))

        #expect(
            variables == [
                StdioServerProcess.EnvVariable(name: Self.envName, value: Self.envValue),
                StdioServerProcess.EnvVariable(name: Self.literalEnvName, value: Self.literalEnvValue),
            ])
    }

    /// A reference that has no value gives no variable and no header, and
    /// never an empty one.
    @Test func anUnresolvedReferenceGivesNoVariableAndNoHeader() throws {
        let unresolved = [Self.envName: ConfiguredSecret(reference: Self.envReference)]

        let configuration = MCPComposition.sessionConfiguration(headers: unresolved)

        #expect(MCPComposition.envVariables(unresolved).isEmpty)
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    // MARK: - The text forms

    /// The document that a person reads shows each reference, redacts the
    /// literal header, keeps the literal env value, and never shows a
    /// value of the store.
    @Test func theRedactedFormShowsTheReferencesAndRedactsTheLiteralHeader() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let yaml = try ConfigurationYAML.documentText(for: loaded.configuration, secrets: .redacted)

        #expect(yaml.contains("\(Self.headerName): \"keychain:\(Self.headerReference)\""))
        #expect(yaml.contains("\(Self.envName): \"keychain:\(Self.envReference)\""))
        #expect(yaml.contains("\(Self.literalHeaderName): \"\(ConfiguredSecret.redactedForm)\""))
        #expect(yaml.contains("\(Self.literalEnvName): \"\(Self.literalEnvValue)\""))
        for secret in [Self.headerValue, Self.envValue, Self.literalHeaderValue] {
            #expect(!yaml.contains(secret))
        }
    }

    /// The document that goes into a layer file keeps each reference and
    /// the literal env value, and writes no literal header.
    @Test func theOmittedFormKeepsTheReferencesAndWritesNoLiteralHeader() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let yaml = try ConfigurationYAML.documentText(for: loaded.configuration, secrets: .omitted)

        #expect(yaml.contains("\(Self.headerName): \"keychain:\(Self.headerReference)\""))
        #expect(yaml.contains("\(Self.envName): \"keychain:\(Self.envReference)\""))
        #expect(yaml.contains("\(Self.literalEnvName): \"\(Self.literalEnvValue)\""))
        #expect(!yaml.contains(Self.literalHeaderName))
        for secret in [Self.headerValue, Self.envValue, Self.literalHeaderValue] {
            #expect(!yaml.contains(secret))
        }
    }

    /// The JSON form shows each reference, redacts the literal header, and
    /// never shows a value of the store.
    @Test func theJSONFormShowsTheReferencesAndRedactsTheLiteralHeader() throws {
        let loaded = try Self.load(store: Self.storeWithItems)

        let json = String(decoding: try JSONEncoder().encode(loaded.configuration), as: UTF8.self)

        #expect(json.contains("keychain:\(Self.headerReference)"))
        #expect(json.contains("keychain:\(Self.envReference)"))
        for secret in [Self.headerValue, Self.envValue, Self.literalHeaderValue] {
            #expect(!json.contains(secret))
        }
    }

    /// The document that goes into a layer file loads back to the same
    /// references, and the store then gives the same values.
    @Test func theOmittedFormLoadsBackToTheSameReferences() throws {
        let loaded = try Self.load(store: Self.storeWithItems)
        let yaml = try ConfigurationYAML.documentText(for: loaded.configuration, secrets: .omitted)

        let reloaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            yaml, secretStore: Self.storeWithItems)

        #expect(try Self.headers(of: reloaded)[Self.headerName] == (try Self.headers(of: loaded))[Self.headerName])
        #expect(try Self.env(of: reloaded) == (try Self.env(of: loaded)))
    }

    // MARK: - The log

    /// The load writes no value of the store and no literal header into a
    /// log record, and the warning record names the key path.
    @Test func noLogRecordHoldsAValue() async throws {
        let records = try await TelemetryCapture.run(
            forbidding: [Self.headerValue, Self.envValue, Self.literalHeaderValue]
        ) { context in
            _ = try Self.load(store: InMemorySecretStore([Self.headerReference: Self.headerValue]))
            return context.logRecords
        }

        let sectionKey = ACPAgentTelemetry.LogMetadataKey.configSection
        let sectionRecords = records.filter { $0.metadata[sectionKey] != nil }
        #expect(sectionRecords.map { $0.metadata[sectionKey] } == [.string(Self.envKeyPath)])
    }
}
