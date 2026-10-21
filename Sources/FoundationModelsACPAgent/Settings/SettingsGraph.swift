import Foundation
import FoundationModelsExtras
import GraphQL

/// The `settings` GraphQL endpoint (ACPA-17, D100, D75): the agent settings
/// of each level for the clients of the agent, over one ``SettingsStore``.
///
/// The endpoint has the server scope: one endpoint serves each session, and
/// a call names the working directory of its session (`cwd`). A call with no
/// `cwd` works on the user level only, for example the Settings scene of the
/// app, which has no working directory. A call of the ``SettingsTool`` of a
/// session can omit `cwd`: the folder of that session applies.
///
/// - `Query.setting` gives the merged value of a key for a session, and the
///   layer that set it. With no `cwd`, it gives the user level over the
///   builtin layers. `Query.sections` gives the first key of each key path:
///   the sections of ``AgentConfiguration``.
/// - `Mutation.updateSetting(input:)` and `Mutation.clearSetting(input:)`
///   change one key on the level that the input names: `USER` or `SESSION`,
///   and give the changed `Setting`. The old names `set` and `clear` are
///   aliases of them, with the same input. A `USER` change needs no `cwd`.
///   A `SESSION` change with no `cwd` is refused with
///   ``SettingsGraphError/missingWorkingDirectory``. A clear on the session
///   level makes the user value apply again.
/// - `Subscription.changes(after:)` gives each change of the store after a
///   cursor, from a mutation, from ``SettingsTool``, or from a change of a
///   file, in the shape of EXTRAS-9 rule 9: `cursor`, `at`, and the dotted
///   key paths in `added`, `changed` and `removed` (``SettingsLoggedChange``).
///   `Query.cursor` gives the cursor of the newest change. With no `cwd`, the
///   subscription gives the changes of the user level only. A cursor that the
///   change log cannot resume ends it with `RESYNC_REQUIRED`.
///
/// The change log is the log of the store
/// (``SettingsStore/loggedChanges(after:where:)``), and the agent makes one
/// endpoint instance over its one store (``RoutedACPAgent/settingsEndpoint``)
/// next to the store: the ``SettingsTool`` of each session runs on that
/// instance, thus each one gives one cursor sequence and no tool builds a
/// schema of its own. The endpoint is a class, so that this one instance has
/// an identity.
///
/// A secret key holds only a `keychain:<name>` reference, and no secret value
/// goes through the endpoint (``SettingsSecretKeys``). ``SettingsTool`` runs
/// each call of the model on this same endpoint.
public final class SettingsGraph: GraphQLEndpoint, Sendable {
    /// The name of the endpoint.
    public static let endpointName = "settings"

    /// The other names that a call can write for the names of the schema:
    /// for the key path and the working directory everywhere, and for the
    /// `updateSetting` and `clearSetting` mutations, whose old names `set`
    /// and `clear` are aliases.
    static let rules = GraphQLNameRules(
        aliases: GraphQLAliasTable(
            everywhere: [
                "keyPath": ["key", "keys"],
                "cwd": ["workingDirectory", "directory", "folder"],
            ],
            byType: [
                "Mutation": [
                    "updateSetting": ["set", "setSetting", "update"],
                    "clearSetting": ["clear", "unset", "remove", "removeSetting"],
                ]
            ])
    )

    /// The name of the endpoint.
    public let name = endpointName

    /// The version of the schema.
    public let version = "1"

    /// The scope of the endpoint: the server.
    public let scope = GraphQLEndpointScope.server

    /// The Graphiti engine of the endpoint.
    private let api: SettingsGraphAPI

    /// Makes the endpoint over a store.
    ///
    /// - Parameter store: The store of the agent settings.
    /// - Throws: An error of the schema builder.
    public init(store: SettingsStore) throws {
        api = try SettingsGraphAPI(engine: SettingsEngine(store: store))
    }

    /// The schema of the endpoint in SDL.
    public var schema: String {
        api.sdl
    }

    /// Runs one GraphQL document.
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - viewer: The client that makes the call, or `nil` for the agent.
    ///     Each client sees the same settings.
    /// - Returns: The GraphQL response as JSON text.
    /// - Throws: A fault that is not a GraphQL error.
    public func execute(
        query: String, variables: [String: Map], operationName: String?, viewer _: GraphQLViewer?
    ) async throws -> String {
        try await execute(query: query, variables: variables, operationName: operationName, sessionDirectory: nil)
    }

    /// Runs one GraphQL document for the folder of one session, or for no
    /// session.
    ///
    /// ``SettingsTool`` calls this with its session folder. Then a field with
    /// no `cwd` reads or writes the levels of that folder, and a field whose
    /// `cwd` names a different folder is refused
    /// (``SettingsGraphContext/workingDirectory(given:)``).
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - sessionDirectory: The absolute path of the session folder, or
    ///     `nil` for a call of the endpoint, where a field with no `cwd`
    ///     works on the user level only.
    /// - Returns: The GraphQL response as JSON text.
    /// - Throws: A fault that is not a GraphQL error.
    func execute(
        query: String, variables: [String: Map], operationName: String?, sessionDirectory: String?
    ) async throws -> String {
        try await api.respond(
            to: query, variables: variables, operationName: operationName, rules: Self.rules,
            formattedWith: .sortedKeys, context: SettingsGraphContext(sessionDirectory: sessionDirectory))
    }

    /// Starts one GraphQL subscription.
    ///
    /// - Parameters:
    ///   - query: The subscription document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - viewer: The client that makes the call, or `nil` for the agent.
    /// - Returns: The GraphQL response of each event as JSON text.
    /// - Throws: A fault that is not a GraphQL error.
    public func subscribe(
        query: String, variables: [String: Map], operationName: String?, viewer _: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await api.subscribe(
            to: query, variables: variables, operationName: operationName, rules: Self.rules,
            formattedWith: .sortedKeys, context: SettingsGraphContext(sessionDirectory: nil))
    }
}
