import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// A `settings` endpoint over a ``SettingsStore`` in temporary folders, for
/// the suites of the endpoint, its subscription and ``SettingsTool``.
///
/// The store reads a temporary root settings folder from
/// ``SettingsFoldersFixture`` and an ``InMemorySecretStore``. Thus no test
/// reads the real home directory or the real Keychain.
struct SettingsGraphFixture {
    // MARK: - Documents

    /// A query of one setting: its key path, its value, its level and its
    /// secrets.
    static let settingQuery = """
        query($keyPath: [String!]!, $cwd: String!) {
          setting(keyPath: $keyPath, cwd: $cwd) {
            keyPath value level secrets { keyPath reference hasValue }
          }
        }
        """

    /// A `set` mutation that gives the value and the level of the result.
    static let setMutation = """
        mutation($keyPath: [String!]!, $value: JSON!, $level: SettingLevel!, $cwd: String!) {
          set(keyPath: $keyPath, value: $value, level: $level, cwd: $cwd) { value level }
        }
        """

    /// A `clear` mutation that gives the value and the level of the result.
    static let clearMutation = """
        mutation($keyPath: [String!]!, $level: SettingLevel!, $cwd: String!) {
          clear(keyPath: $keyPath, level: $level, cwd: $cwd) { value level }
        }
        """

    /// The subscription of each change for one working directory.
    static let changesSubscription = """
        subscription($cwd: String) { changes(cwd: $cwd) { level cwd keyPath } }
        """

    // MARK: - Names of the schema

    /// The `SettingLevel` and `SettingLayer` name of the user level.
    static let userLevel = "USER"

    /// The `SettingLevel` and `SettingLayer` name of the session level.
    static let sessionLevel = "SESSION"

    /// The `SettingLayer` name of the builtin layer.
    static let builtinLayer = "BUILTIN"

    // MARK: - Key paths

    /// The key path of `compaction.trigger`.
    static let triggerKeyPath = ["compaction", "trigger"]

    /// The key path of `tools.web.apiKeys.tavily`, a secret key.
    static let tavilyKeyPath = ["tools", "web", "apiKeys", "tavily"]

    /// The dotted form of ``tavilyKeyPath``, as a secret of a setting names it.
    static let tavilyDottedKeyPath = tavilyKeyPath.joined(separator: ".")

    /// The key path of `tools.web`, the section that holds ``tavilyKeyPath``.
    static let webKeyPath = ["tools", "web"]

    // MARK: - The objects

    /// The settings folders of the store.
    let settingsFolders: SettingsFolders

    /// The store under the endpoint.
    let store: SettingsStore

    /// The endpoint.
    let graph: SettingsGraph

    /// The working directory of the first session.
    let firstDirectory: URL

    /// The working directory of the second session.
    let secondDirectory: URL

    /// Makes the folders, the store and the endpoint.
    ///
    /// - Parameters:
    ///   - label: The prefix that names the test.
    ///   - secrets: The values of the secret store, keyed by the reference
    ///     name.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused, or
    ///   the error of the schema build.
    init(label: String, secrets: [String: String] = [:]) throws {
        settingsFolders = try SettingsFoldersFixture.make(label: "SettingsGraph-\(label)")
        store = SettingsStore(settingsFolders: settingsFolders, secretStore: InMemorySecretStore(secrets))
        graph = try SettingsGraph(store: store)
        firstDirectory = makeResolvedDirectory(label: "SettingsGraph-\(label)-first")
        secondDirectory = makeResolvedDirectory(label: "SettingsGraph-\(label)-second")
    }

    /// The folder of the user level.
    var userRoot: URL {
        get throws {
            try #require(
                SettingsFoldersFixture.layerRoot(of: .user, in: settingsFolders, workingDirectory: firstDirectory))
        }
    }

    /// The folder of the session level of `workingDirectory`.
    ///
    /// - Parameter workingDirectory: The working directory of the session.
    /// - Returns: The folder.
    /// - Throws: A failed requirement when the stack has no project layer.
    func sessionRoot(of workingDirectory: URL) throws -> URL {
        try #require(
            SettingsFoldersFixture.layerRoot(of: .project, in: settingsFolders, workingDirectory: workingDirectory))
    }

    // MARK: - Calls

    /// Runs one document against the endpoint with no viewer.
    ///
    /// - Parameters:
    ///   - document: The GraphQL document.
    ///   - variables: The values of its variables.
    /// - Returns: The parsed response.
    /// - Throws: The fault of the endpoint, or a failed requirement when the
    ///   response is not a JSON object.
    func run(_ document: String, variables: [String: Map] = [:]) async throws -> GraphQLReply {
        try GraphQLReply(
            await graph.execute(query: document, variables: variables, operationName: nil, viewer: nil))
    }

    /// Reads one setting through the endpoint.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func setting(_ keyPath: [String], cwd workingDirectory: URL) async throws -> GraphQLReply {
        try await run(Self.settingQuery, variables: Self.variables(keyPath: keyPath, cwd: workingDirectory))
    }

    /// Sets one value through the endpoint.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The key path.
    ///   - level: The `SettingLevel` name.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func set(_ value: Map, at keyPath: [String], level: String, cwd workingDirectory: URL) async throws
        -> GraphQLReply
    {
        var variables = Self.variables(keyPath: keyPath, cwd: workingDirectory)
        variables["value"] = value
        variables["level"] = .string(level)
        return try await run(Self.setMutation, variables: variables)
    }

    /// Clears one key through the endpoint.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - level: The `SettingLevel` name.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func clear(_ keyPath: [String], level: String, cwd workingDirectory: URL) async throws -> GraphQLReply {
        var variables = Self.variables(keyPath: keyPath, cwd: workingDirectory)
        variables["level"] = .string(level)
        return try await run(Self.clearMutation, variables: variables)
    }

    /// Starts the subscription of each change for `workingDirectory`.
    ///
    /// - Parameter workingDirectory: The working directory of the session.
    /// - Returns: The iterator of the response of each event.
    /// - Throws: The fault of the endpoint.
    func changes(cwd workingDirectory: URL) async throws -> AsyncThrowingStream<String, Error>.AsyncIterator {
        try await graph.subscribe(
            query: Self.changesSubscription, variables: ["cwd": .string(workingDirectory.path)],
            operationName: nil, viewer: nil
        ).makeAsyncIterator()
    }

    /// The variables of a key path and a working directory.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The variables `keyPath` and `cwd`.
    static func variables(keyPath: [String], cwd workingDirectory: URL) -> [String: Map] {
        ["keyPath": .array(keyPath.map(Map.string)), "cwd": .string(workingDirectory.path)]
    }
}

/// One GraphQL response that a test reads.
struct GraphQLReply {
    /// The JSON text of the response.
    let text: String

    /// The `data` object, or `nil` when the response has none.
    let data: [String: Any]?

    /// The `extensions.code` of each error, in order.
    let codes: [String]

    /// The `message` of each error, in order.
    let messages: [String]

    /// Reads a response.
    ///
    /// - Parameter text: The JSON text.
    /// - Throws: A failed requirement when the text is not a JSON object.
    init(_ text: String) throws {
        self.text = text
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        data = object["data"] as? [String: Any]
        let errors = object["errors"] as? [[String: Any]] ?? []
        codes = errors.compactMap { error in (error["extensions"] as? [String: Any])?["code"] as? String }
        messages = errors.compactMap { error in error["message"] as? String }
    }

    /// The object of one field of `data`.
    ///
    /// - Parameter name: The response key of the field.
    /// - Returns: The object.
    /// - Throws: A failed requirement when the field is not an object.
    func object(_ name: String) throws -> [String: Any] {
        try #require(data?[name] as? [String: Any], "no object \(name) in \(text)")
    }
}
