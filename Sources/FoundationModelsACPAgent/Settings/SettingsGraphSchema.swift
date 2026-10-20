import Foundation
import FoundationModelsExtras
import Graphiti
import GraphQL
import OrderedCollections

// The GraphQL schema of the `settings` endpoint (ACPA-17): the enums, the
// object types, the arguments, the resolver and the Graphiti API over one
// `SettingsEngine`.

// MARK: - Enums

/// A level that a mutation of the `settings` endpoint changes.
enum SettingsGraphLevel: String, Codable, CaseIterable, Sendable {
    /// The user level. It applies to each session.
    case user = "USER"

    /// The session level of one working directory. It wins over the user
    /// level.
    case session = "SESSION"

    /// Gives the level of an event of the store.
    ///
    /// - Parameter level: The level of the store.
    init(_ level: SettingsLevel) {
        switch level {
        case .user:
            self = .user
        case .session:
            self = .session
        }
    }

    /// Gives the level of the store.
    ///
    /// - Parameter cwd: The working directory that names the session level.
    /// - Returns: The level of the store.
    func storeLevel(cwd: URL) -> SettingsLevel {
        switch self {
        case .user:
            .user
        case .session:
            .session(cwd)
        }
    }
}

/// The layer that set a merged value, as the `settings` endpoint names it.
enum SettingsGraphLayer: String, Codable, CaseIterable, Sendable {
    /// The builtin configuration file of the agent.
    case builtin = "BUILTIN"

    /// A cached remote skill marketplace layer.
    case marketplace = "MARKETPLACE"

    /// The defaults folder that `<NAME>_DEFAULTS_DIR` names.
    case defaults = "DEFAULTS"

    /// The user level.
    case user = "USER"

    /// The session level of the working directory.
    case session = "SESSION"

    /// Gives the layer of a layer name of the configuration.
    ///
    /// - Parameter name: The layer name.
    init(_ name: ConfigurationLayerName) {
        switch name {
        case .builtin:
            self = .builtin
        case .marketplace:
            self = .marketplace
        case .defaults:
            self = .defaults
        case .user:
            self = .user
        case .project:
            self = .session
        }
    }
}

// MARK: - Object types

/// The `Secret` object: one secret key inside a setting, with no value.
struct SettingsGraphSecret: Codable, Sendable {
    /// The dotted key path of the secret key.
    let keyPath: String

    /// The reference name, or `nil` for a literal that the endpoint does not
    /// show.
    let reference: String?

    /// `true` when the secret store has an item for the reference.
    let hasValue: Bool
}

/// The `Setting` object: the merged value of one key and its layer.
struct SettingsGraphSetting: Codable, Sendable {
    /// The key path of the setting.
    let keyPath: [String]

    /// The merged value as JSON, with no secret value. A key that holds
    /// `null` gives `null`.
    let value: Map?

    /// The layer that set the value.
    let level: SettingsGraphLayer

    /// Each secret key inside the value.
    let secrets: [SettingsGraphSecret]

    /// Makes the object of a reading of the engine.
    ///
    /// - Parameter reading: The reading.
    init(_ reading: SettingsReading) {
        keyPath = reading.keyPath
        value = reading.value.graphQLMap
        level = SettingsGraphLayer(reading.level)
        secrets = reading.secrets.map { secret in
            SettingsGraphSecret(keyPath: secret.keyPath, reference: secret.reference, hasValue: secret.hasValue)
        }
    }
}

/// The `SettingsChange` object: one change of the settings.
struct SettingsGraphChange: Codable, Sendable {
    /// The level that changed.
    let level: SettingsGraphLevel

    /// The working directory of a session level, or `nil` for the user level.
    let cwd: String?

    /// The changed key path, or `nil` when the store read the file of the
    /// level again.
    let keyPath: [String]?
}

extension SettingsChange {
    /// Resolves one event of `Subscription.changes`.
    ///
    /// - Parameters:
    ///   - context: The context of the subscription.
    ///   - arguments: The arguments of the subscription.
    /// - Returns: The object of the change.
    func graphQLChange(
        context _: SettingsGraphContext, arguments _: SettingsGraphChangesArguments
    ) async throws -> SettingsGraphChange {
        SettingsGraphChange(
            level: SettingsGraphLevel(level), cwd: level.workingDirectory?.path, keyPath: keyPath)
    }
}

// MARK: - Arguments

/// The arguments of `Query.setting`.
struct SettingsGraphSettingArguments: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The absolute path of the working directory of the session.
    let cwd: String
}

/// The arguments of `Mutation.set`.
struct SettingsGraphSetArguments: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The new value.
    let value: Map

    /// The level that gets the value.
    let level: SettingsGraphLevel

    /// The absolute path of the working directory of the session.
    let cwd: String
}

/// The arguments of `Mutation.clear`.
struct SettingsGraphClearArguments: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The level that loses the key.
    let level: SettingsGraphLevel

    /// The absolute path of the working directory of the session.
    let cwd: String
}

/// The arguments of `Subscription.changes`.
struct SettingsGraphChangesArguments: Codable, Sendable {
    /// The absolute path of the working directory whose session level the
    /// subscription watches, or `nil` for the user level only.
    let cwd: String?
}

// MARK: - Resolver and context

/// The context of one call of the `settings` endpoint.
struct SettingsGraphContext: GraphQLRunContext {
    /// The warnings of the call.
    let warnings = ResponseWarnings()
}

/// The root resolver of the `settings` endpoint over the engine.
struct SettingsGraphResolver: Sendable {
    /// The engine of the settings.
    let engine: SettingsEngine

    /// Resolves `Query.sections`.
    ///
    /// - Returns: The sections of the settings.
    func sections(context _: SettingsGraphContext, arguments _: NoArguments) -> [String] {
        SettingsEngine.sections
    }

    /// Resolves `Query.setting`.
    ///
    /// - Parameter arguments: The key path and the working directory.
    /// - Returns: The setting, or `nil` when no layer has the key.
    /// - Throws: What ``SettingsEngine/setting(at:cwd:)`` throws.
    func setting(
        context _: SettingsGraphContext, arguments: SettingsGraphSettingArguments
    ) async throws -> SettingsGraphSetting? {
        try await engine.setting(at: arguments.keyPath, cwd: arguments.cwd).map(SettingsGraphSetting.init)
    }

    /// Resolves `Mutation.set`.
    ///
    /// - Parameter arguments: The key path, the value, the level and the
    ///   working directory.
    /// - Returns: The merged setting after the change.
    /// - Throws: What ``SettingsEngine/set(_:at:level:cwd:)`` throws.
    func set(
        context _: SettingsGraphContext, arguments: SettingsGraphSetArguments
    ) async throws -> SettingsGraphSetting? {
        try await engine.set(
            YAMLValue(graphQLMap: arguments.value), at: arguments.keyPath, level: arguments.level,
            cwd: arguments.cwd)
        return try await engine.setting(at: arguments.keyPath, cwd: arguments.cwd).map(SettingsGraphSetting.init)
    }

    /// Resolves `Mutation.clear`.
    ///
    /// - Parameter arguments: The key path, the level and the working
    ///   directory.
    /// - Returns: The merged setting after the change, or `nil` when no layer
    ///   has the key.
    /// - Throws: What ``SettingsEngine/clear(at:level:cwd:)`` throws.
    func clear(
        context _: SettingsGraphContext, arguments: SettingsGraphClearArguments
    ) async throws -> SettingsGraphSetting? {
        try await engine.clear(at: arguments.keyPath, level: arguments.level, cwd: arguments.cwd)
        return try await engine.setting(at: arguments.keyPath, cwd: arguments.cwd).map(SettingsGraphSetting.init)
    }

    /// Resolves the source of `Subscription.changes`.
    ///
    /// - Parameter arguments: The working directory to watch.
    /// - Returns: The stream of each change.
    /// - Throws: What ``SettingsEngine/changes(cwd:)`` throws.
    func changes(
        context _: SettingsGraphContext, arguments: SettingsGraphChangesArguments
    ) async throws -> AsyncThrowingStream<SettingsChange, Error> {
        try await engine.changes(cwd: arguments.cwd)
    }
}

// MARK: - The API

/// The Graphiti engine of the `settings` endpoint.
struct SettingsGraphAPI: API {
    /// The text of the description of a `keyPath` argument.
    private static let keyPathDescription =
        "The keys from the root, for example [\"compaction\", \"trigger\"]. The first key is a section."

    /// The text of the description of a `cwd` argument.
    private static let cwdDescription =
        "The absolute path of the working directory of the session. It names the session level."

    /// The text of the description of a `level` argument.
    private static let levelDescription = "The level that the mutation changes."

    /// The text of the description of the setting that a mutation gives.
    private static let resultDescription = "The merged setting after the change, or null when no layer has the key."

    /// The root resolver.
    let resolver: SettingsGraphResolver

    /// The schema.
    let schema: Schema<SettingsGraphResolver, SettingsGraphContext>

    /// Builds the schema over an engine.
    ///
    /// - Parameter engine: The engine of the settings.
    /// - Throws: An error of the schema builder.
    init(engine: SettingsEngine) throws {
        resolver = SettingsGraphResolver(engine: engine)
        schema = try SchemaBuilder(SettingsGraphResolver.self, SettingsGraphContext.self)
            .addToolkitScalars()
            .add {
                Enum(SettingsGraphLevel.self, as: "SettingLevel") {
                    Value(.user).description("The user level. It applies to each session.")
                    Value(.session).description("The session level of one working directory. It wins over USER.")
                }
                .description("A level that a mutation changes.")
                Enum(SettingsGraphLayer.self, as: "SettingLayer") {
                    Value(.builtin).description("The builtin configuration of the agent.")
                    Value(.marketplace).description("A cached remote skill marketplace.")
                    Value(.defaults).description("The defaults folder of the host.")
                    Value(.user).description("The user level.")
                    Value(.session).description("The session level of the working directory.")
                }
                .description("The layer that set a merged value.")
                Type(SettingsGraphSecret.self, as: "Secret") {
                    Field("keyPath", at: \.keyPath).description("The dotted key path of the secret key.")
                    Field("reference", at: \.reference)
                        .description("The name of the keychain: reference, or null for a literal that is not shown.")
                    Field("hasValue", at: \.hasValue)
                        .description("True when the secret store has an item for the reference.")
                }
                .description("One secret key inside a setting. The endpoint never gives a secret value.")
                Type(SettingsGraphSetting.self, as: "Setting") {
                    Field("keyPath", at: \.keyPath).description("The key path of the setting.")
                    Field("value", at: \.value)
                        .description("The merged value. A literal secret shows as <redacted>.")
                    Field("level", at: \.level).description("The layer that set the value.")
                    Field("secrets", at: \.secrets).description("Each secret key inside the value.")
                }
                .description("The merged value of one key for a session, and the layer that set it.")
                Type(SettingsGraphChange.self, as: "SettingsChange") {
                    Field("level", at: \.level).description("The level that changed.")
                    Field("cwd", at: \.cwd)
                        .description("The working directory of a session level, or null for the user level.")
                    Field("keyPath", at: \.keyPath)
                        .description("The changed key path, or null when the file of the level changed. Read it again.")
                }
                .description("One change of the settings.")
            }
            .addQuery {
                Field("sections", at: SettingsGraphResolver.sections)
                    .description("The sections of the settings: the first key of each key path.")
                Field("setting", at: SettingsGraphResolver.setting) {
                    Argument("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    Argument("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description("The merged value of one key for a session, or null when no layer has the key.")
            }
            .addMutation {
                Field("set", at: SettingsGraphResolver.set) {
                    Argument("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    Argument("value", at: \.value)
                        .description("The new value. A secret key takes only a keychain:<name> reference.")
                    Argument("level", at: \.level).description(Self.levelDescription)
                    Argument("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description("Sets the value of one key on one level. \(Self.resultDescription)")
                Field("clear", at: SettingsGraphResolver.clear) {
                    Argument("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    Argument("level", at: \.level).description(Self.levelDescription)
                    Argument("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description(
                    "Removes one key from one level. The value of a lower level applies again. "
                        + Self.resultDescription)
            }
            .addSubscription {
                SubscriptionField(
                    "changes", at: SettingsChange.graphQLChange, atSub: SettingsGraphResolver.changes
                ) {
                    Argument("cwd", at: \.cwd)
                        .description("The working directory whose session level to watch, or null for USER only.")
                }
                .description("Each change of the settings, from a mutation or from a change of a file.")
            }
            .build()
    }
}

// MARK: - JSON values

extension YAMLValue {
    /// Makes a settings value of a GraphQL `JSON` value. A JSON number keeps
    /// its storage type: a whole number stays an integer.
    ///
    /// - Parameter map: The GraphQL value.
    init(graphQLMap map: Map) {
        switch map {
        case .undefined, .null:
            self = .null
        case .bool(let flag):
            self = .bool(flag)
        case .number(let number):
            self = Self(graphQLNumber: number)
        case .string(let text):
            self = .string(text)
        case .array(let items):
            self = .array(items.map(YAMLValue.init(graphQLMap:)))
        case .dictionary(let fields):
            self = .dictionary(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, YAMLValue(graphQLMap: $0.value)) }))
        }
    }

    /// Makes a settings value of a GraphQL number.
    ///
    /// - Parameter number: The number.
    private init(graphQLNumber number: Number) {
        switch number.storageType {
        case .bool:
            self = .bool(number.boolValue)
        case .int:
            self = .int(number.intValue)
        case .double, .unknown:
            self = .double(number.doubleValue)
        }
    }

    /// This value as a GraphQL `JSON` value, with the keys of each mapping in
    /// sorted order.
    var graphQLMap: Map {
        switch self {
        case .string(let text):
            .string(text)
        case .int(let number):
            .number(Number(number))
        case .double(let number):
            .number(Number(number))
        case .bool(let flag):
            .bool(flag)
        case .null:
            .null
        case .array(let items):
            .array(items.map(\.graphQLMap))
        case .dictionary(let keys):
            .dictionary(
                OrderedDictionary(uniqueKeysWithValues: keys.sorted { $0.key < $1.key }.map { ($0.key, $0.value.graphQLMap) }))
        }
    }
}
