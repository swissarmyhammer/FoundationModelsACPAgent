import Foundation
import FoundationModels
import FoundationModelsExtras

/// A payload that ``SettingsTool/perform(_:)`` refuses.
public enum SettingsToolError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The payload has no `op` string.
    case missingOperation

    /// The `op` of the payload is not an operation of the tool. The value is
    /// that `op`.
    case unknownOperation(String)

    /// A human-readable reason that names the operation of the tool.
    public var description: String {
        switch self {
        case .missingOperation:
            "the payload has no op; the settings tool has the one op \"\(SettingsTool.queryOperation)\""
        case .unknownOperation(let operation):
            "\"\(operation)\" is not an op of the settings tool; it has the one op \"\(SettingsTool.queryOperation)\""
        }
    }
}

/// The `settings` model tool of the agent (ACPA-17, D75): one GraphQL
/// document goes in, and one `{data, errors}` response comes out, over the
/// same engine as the `settings` endpoint (``SettingsGraph``).
///
/// The tool gives its endpoint through `GraphQLEndpointTool`, so a host
/// registers the same engine for its clients. It gives one operation through
/// `OperationDescribing`, so that Multitool mounts it as
/// `tools.<noun>.querySettings` (`MultiTool.Builder.withOperationTool`). A
/// call through the tool has no viewer, and the tool does not run a
/// subscription.
public struct SettingsTool: GraphQLEndpointTool, OperationDescribing {
    /// The op string of the one operation of the tool.
    public static let queryOperation = "query settings"

    /// The verb of ``queryOperation``.
    private static let queryVerb = "query"

    /// The noun of ``queryOperation``.
    private static let queryNoun = "settings"

    /// The key of the op string in a payload of ``perform(_:)``.
    private static let operationKey = "op"

    /// The keys of a payload that `GraphQLArguments` reads. They are the
    /// names of the parameters of ``queryOperation``.
    private enum ArgumentKey {
        /// The key of the GraphQL document.
        static let query = "query"

        /// The key of the values of the variables.
        static let variables = "variables"

        /// The key of the name of the operation to run.
        static let operationName = "operationName"
    }

    /// What the agent can do in place of a subscription.
    private static let subscriptionHint = "Query the setting again to read a change."

    /// The description of the tool for the model.
    private static let toolDescription = """
        Reads and changes the agent settings with GraphQL. Query `sections` for the first key of each key \
        path. Query `setting(keyPath:)` for the merged value of a key in the session folder and the level \
        that set it. Change a key with the mutation `set(keyPath:, value:, level:)` or \
        `clear(keyPath:, level:)`, where level is USER or SESSION. SESSION changes the settings of the \
        session folder only. In a session, do not give `cwd`: the session folder applies. A secret key \
        takes only a keychain:<name> reference.
        """

    /// The name of the tool: `settings`.
    public let name = SettingsGraph.endpointName

    /// The description of the tool for the model.
    public let description = Self.toolDescription

    /// The schema of the arguments: a GraphQL document, its variables and the
    /// name of its operation.
    public var parameters: GenerationSchema {
        GraphQLArguments.generationSchema
    }

    /// The endpoint that runs each document.
    private let endpoint: SettingsGraph

    /// The absolute path of the folder of the session that owns the tool, or
    /// `nil` for a tool of no session.
    private let sessionDirectory: String?

    /// Makes the tool over a store.
    ///
    /// The session composition gives each session its own tool with the
    /// working directory of that session. Then a call that gives no `cwd`
    /// reads the merged value for that folder and writes the session level
    /// of that folder, and a `cwd` of a different folder is refused
    /// (``SettingsGraphError/otherSessionWorkingDirectory(path:)``).
    ///
    /// - Parameters:
    ///   - store: The store of the agent settings.
    ///   - sessionDirectory: The working directory of the session that owns
    ///     the tool, or `nil` (the default) for a tool of no session, where
    ///     each call must give `cwd`, the same as the endpoint.
    /// - Throws: An error of the schema builder.
    public init(store: SettingsStore, sessionDirectory: URL? = nil) throws {
        endpoint = try SettingsGraph(store: store)
        self.sessionDirectory = sessionDirectory?.path
    }

    /// The endpoint of the tool: a list of one, the `settings` endpoint.
    public var graphQLEndpoints: [any GraphQLEndpoint] {
        [endpoint]
    }

    /// Runs the document of the arguments on the endpoint, with no viewer and
    /// for the session folder of the tool.
    ///
    /// - Parameter arguments: The decoded arguments of the call.
    /// - Returns: The GraphQL response (`{data, errors}`) as JSON text.
    /// - Throws: A fault of the endpoint that is not a GraphQL error.
    public func call(arguments: GraphQLArguments) async throws -> String {
        try await GraphQLTool.answer(arguments, subscriptionHint: Self.subscriptionHint) {
            query, variables, operationName in
            try await endpoint.execute(
                query: query, variables: variables, operationName: operationName,
                sessionDirectory: sessionDirectory)
        }
    }

    // MARK: - OperationDescribing

    /// The one operation of the tool: ``queryOperation``, whose parameters
    /// are the parts of a GraphQL call.
    public var operationDescriptors: [OperationDescriptor] {
        [
            OperationDescriptor(
                verb: Self.queryVerb, noun: Self.queryNoun, opString: Self.queryOperation,
                description: Self.toolDescription,
                parameters: [
                    OperationParameterDescriptor(
                        name: ArgumentKey.query, type: .string, required: true,
                        description: "The GraphQL document: a query or a mutation.", aliases: [],
                        allowedValues: nil),
                    OperationParameterDescriptor(
                        name: ArgumentKey.variables, type: .string, required: false,
                        description: "The values of the variables: a JSON object, or text that holds a JSON object.",
                        aliases: [], allowedValues: nil),
                    OperationParameterDescriptor(
                        name: ArgumentKey.operationName, type: .string, required: false,
                        description: "The operation of the document to run, when the document has more than one.",
                        aliases: [], allowedValues: nil),
                ])
        ]
    }

    /// Runs the document of one `op` payload on the endpoint.
    ///
    /// - Parameter arguments: The payload: `op` is ``queryOperation``, and the
    ///   other keys are the arguments of ``call(arguments:)``.
    /// - Returns: The GraphQL response as JSON text.
    /// - Throws: ``SettingsToolError`` when the payload has no `op` or an
    ///   other `op`; `GraphQLArguments.MissingQueryError` when it has no
    ///   `query`; a fault of the endpoint.
    public func perform(_ arguments: GeneratedContent) async throws -> String {
        guard case .structure(let properties, _) = arguments.kind,
            case .string(let operation)? = properties[Self.operationKey]?.kind
        else {
            throw SettingsToolError.missingOperation
        }
        guard operation == Self.queryOperation else {
            throw SettingsToolError.unknownOperation(operation)
        }
        return try await call(arguments: GraphQLArguments(arguments))
    }
}
