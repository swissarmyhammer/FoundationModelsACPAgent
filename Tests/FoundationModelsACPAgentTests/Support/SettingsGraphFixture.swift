import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// A `settings` endpoint over a ``SettingsStore`` in temporary folders, for
/// the suites of the endpoint, its subscription and ``SettingsTool``.
///
/// The store reads a temporary custom home from
/// ``SettingsFoldersFixture`` and an ``InMemorySecretStore``, or a different
/// test secret store that the test gives. Thus no test reads the real home
/// directory or the real Keychain.
struct SettingsGraphFixture {
    // MARK: - Documents

    /// The fields of a `Setting` that each document of the fixture selects:
    /// the key path, the value, the level and the secrets.
    static let settingFields = "{ keyPath value level secrets { keyPath reference hasValue } }"

    /// A query of one setting. A `null` or absent `$cwd` gives no `cwd`.
    static let settingQuery = """
        query($keyPath: [String!]!, $cwd: String) {
          setting(keyPath: $keyPath, cwd: $cwd) \(settingFields)
        }
        """

    /// The response key of the `updateSetting` mutation.
    static let updateField = "updateSetting"

    /// The response key of the `clearSetting` mutation.
    static let clearField = "clearSetting"

    /// An `updateSetting` mutation that gives the setting after the change. A
    /// `null` or absent `$cwd` gives no `cwd`.
    static let setMutation = updateDocument(named: updateField)

    /// A `clearSetting` mutation that gives the setting after the change. A
    /// `null` or absent `$cwd` gives no `cwd`.
    static let clearMutation = clearDocument(named: clearField)

    /// An update mutation that a call names with `name`: `updateSetting` or
    /// one of its aliases.
    ///
    /// - Parameter name: The name of the mutation in the document.
    /// - Returns: The document, whose variables are `$keyPath`, `$value`,
    ///   `$level` and `$cwd`.
    static func updateDocument(named name: String) -> String {
        """
        mutation($keyPath: [String!]!, $value: JSON!, $level: SettingLevel!, $cwd: String) {
          \(name)(input: {keyPath: $keyPath, value: $value, level: $level, cwd: $cwd}) \(settingFields)
        }
        """
    }

    /// A clear mutation that a call names with `name`: `clearSetting` or one
    /// of its aliases.
    ///
    /// - Parameter name: The name of the mutation in the document.
    /// - Returns: The document, whose variables are `$keyPath`, `$level` and
    ///   `$cwd`.
    static func clearDocument(named name: String) -> String {
        """
        mutation($keyPath: [String!]!, $level: SettingLevel!, $cwd: String) {
          \(name)(input: {keyPath: $keyPath, level: $level, cwd: $cwd}) \(settingFields)
        }
        """
    }

    /// A query of one setting with no `cwd`. A session tool reads the
    /// setting for its session folder, and the endpoint reads the user level.
    static let sessionSettingQuery = """
        query($keyPath: [String!]!) {
          setting(keyPath: $keyPath) \(settingFields)
        }
        """

    /// An `updateSetting` mutation with no `cwd`. A session tool writes the
    /// level for its session folder.
    static let sessionSetMutation = """
        mutation($keyPath: [String!]!, $value: JSON!, $level: SettingLevel!) {
          updateSetting(input: {keyPath: $keyPath, value: $value, level: $level}) \(settingFields)
        }
        """

    /// The subscription of each change for one working directory, after a
    /// cursor. A `null` or absent `$after` gives the live changes only.
    static let changesSubscription = """
        subscription($cwd: String, $after: String) {
          changes(cwd: $cwd, after: $after) { cursor at added changed removed level cwd keyPath }
        }
        """

    /// The query of the cursor of the newest change. A `null` or absent
    /// `$cwd` gives no `cwd`.
    static let cursorQuery = "query($cwd: String) { cursor(cwd: $cwd) }"

    /// The response key of the query of the cursor.
    static let cursorField = "cursor"

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
        try self.init(label: label, secretStore: InMemorySecretStore(secrets))
    }

    /// Makes the folders, the store over a given secret store, and the
    /// endpoint.
    ///
    /// - Parameters:
    ///   - label: The prefix that names the test.
    ///   - secretStore: The secret store of the settings store, for example a
    ///     ``FailingSecretStore``.
    ///   - changeCapacity: The number of the newest changes that the change
    ///     log of the store keeps, or the default of the store.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused, or
    ///   the error of the schema build.
    init(
        label: String, secretStore: any SecretStore,
        changeCapacity: Int = SettingsStore.defaultChangeCapacity
    ) throws {
        settingsFolders = try SettingsFoldersFixture.make(label: "SettingsGraph-\(label)")
        store = SettingsStore(
            settingsFolders: settingsFolders, secretStore: secretStore, changeCapacity: changeCapacity)
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
    ///   - workingDirectory: The working directory of the session, or `nil`
    ///     for a call with no `cwd`.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func setting(_ keyPath: [String], cwd workingDirectory: URL?) async throws -> GraphQLReply {
        try await run(Self.settingQuery, variables: Self.variables(keyPath: keyPath, cwd: workingDirectory))
    }

    /// Sets one value through the endpoint.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The key path.
    ///   - level: The `SettingLevel` name.
    ///   - workingDirectory: The working directory of the session, or `nil`
    ///     for a call with no `cwd`.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func set(_ value: Map, at keyPath: [String], level: String, cwd workingDirectory: URL?) async throws
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
    ///   - workingDirectory: The working directory of the session, or `nil`
    ///     for a call with no `cwd`.
    /// - Returns: The response.
    /// - Throws: What ``run(_:variables:)`` throws.
    func clear(_ keyPath: [String], level: String, cwd workingDirectory: URL?) async throws -> GraphQLReply {
        var variables = Self.variables(keyPath: keyPath, cwd: workingDirectory)
        variables["level"] = .string(level)
        return try await run(Self.clearMutation, variables: variables)
    }

    /// Starts the subscription of each change for `workingDirectory`.
    ///
    /// - Parameters:
    ///   - workingDirectory: The working directory of the session, or `nil`
    ///     for a subscription with no `cwd`.
    ///   - cursor: The cursor to resume after, or `nil` (the default) for the
    ///     live changes only.
    /// - Returns: The iterator of the response of each event.
    /// - Throws: The fault of the endpoint.
    func changes(
        cwd workingDirectory: URL?, after cursor: String? = nil
    ) async throws -> AsyncThrowingStream<String, Error>.AsyncIterator {
        var variables = Self.cwdVariable(workingDirectory)
        variables["after"] = cursor.map(Map.string)
        return try await graph.subscribe(
            query: Self.changesSubscription, variables: variables, operationName: nil, viewer: nil
        ).makeAsyncIterator()
    }

    /// Reads the cursor of the newest change through the endpoint.
    ///
    /// - Parameter workingDirectory: The working directory of the session, or
    ///   `nil` for a call with no `cwd`.
    /// - Returns: The cursor.
    /// - Throws: What ``run(_:variables:)`` throws, or a failed requirement
    ///   when the response has no cursor.
    func cursor(cwd workingDirectory: URL?) async throws -> String {
        let reply = try await run(Self.cursorQuery, variables: Self.cwdVariable(workingDirectory))
        return try #require(reply.data?[Self.cursorField] as? String, "no cursor in \(reply.text)")
    }

    /// The variables of a key path and a working directory.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - workingDirectory: The working directory of the session, or `nil`
    ///     for no `cwd`.
    /// - Returns: The variable `keyPath`, and the variable `cwd` when
    ///   `workingDirectory` is given.
    static func variables(keyPath: [String], cwd workingDirectory: URL?) -> [String: Map] {
        var variables = cwdVariable(workingDirectory)
        variables["keyPath"] = .array(keyPath.map(Map.string))
        return variables
    }

    /// The variable of a working directory.
    ///
    /// - Parameter workingDirectory: The working directory of the session, or
    ///   `nil` for no `cwd`.
    /// - Returns: The variable `cwd`, or no variable when `workingDirectory`
    ///   is `nil`.
    private static func cwdVariable(_ workingDirectory: URL?) -> [String: Map] {
        workingDirectory.map { directory in ["cwd": .string(directory.path)] } ?? [:]
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

    /// The `code` of each item of `extensions.warnings`, in order.
    let warningCodes: [String]

    /// Each item of `extensions.rewrites` as its `from` and `to` names, in
    /// order.
    let rewrites: [[String]]

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
        let extensions = object["extensions"] as? [String: Any]
        let warnings = extensions?["warnings"] as? [[String: Any]] ?? []
        warningCodes = warnings.compactMap { warning in warning["code"] as? String }
        let rewriteItems = extensions?["rewrites"] as? [[String: Any]] ?? []
        rewrites = rewriteItems.map { rewrite in [rewrite["from"], rewrite["to"]].compactMap { $0 as? String } }
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
