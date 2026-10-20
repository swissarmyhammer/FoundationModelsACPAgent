import Foundation
import FoundationModelsExtras
import GraphQL

/// The `settings` GraphQL endpoint (ACPA-17, D100, D75): the agent settings
/// of each level for the clients of the agent, over one ``SettingsStore``.
///
/// The endpoint has the server scope: one endpoint serves each session, and
/// each call names the working directory of its session (`cwd`).
///
/// - `Query.setting` gives the merged value of a key for a session, and the
///   layer that set it. `Query.sections` gives the first key of each key
///   path: the sections of ``AgentConfiguration``.
/// - `Mutation.set` and `Mutation.clear` change one key on the
///   level that the call names: `USER` or `SESSION`. A clear on the session
///   level makes the user value apply again.
/// - `Subscription.changes` gives each change of the store, from a mutation,
///   from ``SettingsTool``, or from a change of a file.
///
/// A secret key holds only a `keychain:<name>` reference, and no secret value
/// goes through the endpoint (``SettingsSecretKeys``). ``SettingsTool`` runs
/// each call of the model on this same endpoint.
public struct SettingsGraph: GraphQLEndpoint {
    /// The name of the endpoint.
    public static let endpointName = "settings"

    /// The other names that a call can write for the names of the schema:
    /// for the key path and the working directory everywhere, and for the
    /// `set` and `clear` mutations.
    static let rules = GraphQLNameRules(
        aliases: GraphQLAliasTable(
            everywhere: [
                "keyPath": ["key", "keys"],
                "cwd": ["workingDirectory", "directory", "folder"],
            ],
            byType: [
                "Mutation": [
                    "set": ["setSetting", "update", "updateSetting"],
                    "clear": ["clearSetting", "unset", "remove", "removeSetting"],
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
        try await api.respond(
            to: query, variables: variables, operationName: operationName, rules: Self.rules,
            formattedWith: .sortedKeys, context: SettingsGraphContext())
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
            formattedWith: .sortedKeys, context: SettingsGraphContext())
    }
}
