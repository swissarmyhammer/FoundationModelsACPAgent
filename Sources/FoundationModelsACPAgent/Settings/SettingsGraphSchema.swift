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
    /// - Parameter cwd: The working directory that names the session level,
    ///   or `nil` when the call gives no working directory. The user level
    ///   needs no working directory.
    /// - Returns: The level of the store.
    /// - Throws: ``SettingsGraphError/missingWorkingDirectory`` for the
    ///   session level with no working directory.
    func storeLevel(cwd: URL?) throws -> SettingsLevel {
        switch self {
        case .user:
            return .user
        case .session:
            guard let cwd else {
                throw SettingsGraphError.missingWorkingDirectory
            }
            return .session(cwd)
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

    /// `true` when the secret store has an item for the reference, or `nil`
    /// when the result of a mutation does not know it (the secret store
    /// could not read the item after the change).
    let hasValue: Bool?
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

/// The `SettingsChange` object: one change of the settings, in the shape of
/// rule 9 (`cursor`, `at`, `added`, `changed`, `removed`), with the level,
/// the working directory and the key path of the change as more fields.
struct SettingsGraphChange: Codable, Sendable {
    /// The cursor that resumes `changes(after:)` after this change.
    let cursor: String

    /// The time of the change.
    let at: DateTime

    /// The dotted key path of each key that the change added.
    let added: [ToolkitID]

    /// The dotted key path of each key that the change changed.
    let changed: [ToolkitID]

    /// The dotted key path of each key that the change removed.
    let removed: [ToolkitID]

    /// The level that changed.
    let level: SettingsGraphLevel

    /// The working directory of a session level, or `nil` for the user level.
    let cwd: String?

    /// The changed key path, or `nil` when the store read the file of the
    /// level again.
    let keyPath: [String]?

    /// Makes the object of one entry of the change log.
    ///
    /// - Parameter entry: The entry: its cursor, its time and its change.
    init(_ entry: SettingsEngine.LoggedEntry) {
        let change = entry.event.change
        let ids = entry.event.ids
        cursor = entry.cursor
        at = DateTime(entry.at)
        added = ids.added.map(ToolkitID.init(_:))
        changed = ids.changed.map(ToolkitID.init(_:))
        removed = ids.removed.map(ToolkitID.init(_:))
        level = SettingsGraphLevel(change.level)
        cwd = change.level.workingDirectory?.path
        keyPath = change.keyPath
    }
}

extension ChangeLogEntry where Event == SettingsLoggedChange {
    /// Resolves one event of `Subscription.changes`.
    ///
    /// - Parameters:
    ///   - context: The context of the subscription.
    ///   - arguments: The arguments of the subscription.
    /// - Returns: The object of the change.
    func graphQLChange(
        context _: SettingsGraphContext, arguments _: SettingsGraphChangesArguments
    ) async throws -> SettingsGraphChange {
        SettingsGraphChange(self)
    }
}

// MARK: - Arguments

/// The arguments of `Query.setting`.
struct SettingsGraphSettingArguments: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The absolute path of the working directory of the session, or `nil`
    /// for the session folder of the call, or for the user level only when
    /// the call has no session folder
    /// (``SettingsGraphContext/workingDirectory(given:)``).
    let cwd: String?
}

/// The `UpdateSettingInput` input object of `Mutation.updateSetting`.
struct SettingsGraphUpdateInput: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The new value.
    let value: Map

    /// The level that gets the value.
    let level: SettingsGraphLevel

    /// The absolute path of the working directory of the session, or `nil`
    /// for the session folder of the call, or for no working directory when
    /// the call has no session folder: then only a user level change works
    /// (``SettingsGraphContext/workingDirectory(given:)``).
    let cwd: String?
}

/// The arguments of `Mutation.updateSetting`.
struct SettingsGraphUpdateArguments: Codable, Sendable {
    /// The input object of the mutation.
    let input: SettingsGraphUpdateInput
}

/// The `ClearSettingInput` input object of `Mutation.clearSetting`.
struct SettingsGraphClearInput: Codable, Sendable {
    /// The key path.
    let keyPath: [String]

    /// The level that loses the key.
    let level: SettingsGraphLevel

    /// The absolute path of the working directory of the session, or `nil`
    /// for the session folder of the call, or for no working directory when
    /// the call has no session folder: then only a user level change works
    /// (``SettingsGraphContext/workingDirectory(given:)``).
    let cwd: String?
}

/// The arguments of `Mutation.clearSetting`.
struct SettingsGraphClearArguments: Codable, Sendable {
    /// The input object of the mutation.
    let input: SettingsGraphClearInput
}

/// The arguments of `Subscription.changes`.
struct SettingsGraphChangesArguments: Codable, Sendable {
    /// The cursor to resume after, or `nil` for the new changes only.
    let after: String?

    /// The absolute path of the working directory whose session level the
    /// subscription watches, or `nil` for the user level only.
    let cwd: String?
}

/// The arguments of `Query.cursor`.
struct SettingsGraphCursorArguments: Codable, Sendable {
    /// The absolute path of the working directory whose session level the
    /// read starts to watch, or `nil` for the session folder of the call, or
    /// for the user level only when the call has no session folder
    /// (``SettingsGraphContext/workingDirectory(given:)``).
    let cwd: String?
}

// MARK: - Resolver and context

/// The context of one call of the `settings` endpoint.
struct SettingsGraphContext: GraphQLRunContext {
    /// The warnings of the call.
    let warnings = ResponseWarnings()

    /// The absolute path of the session folder of a call of the
    /// ``SettingsTool`` of a session, or `nil` for a call of the endpoint,
    /// which serves each session.
    let sessionDirectory: String?

    /// Gives the working directory of one field of the call.
    ///
    /// A call of the endpoint can omit `cwd`: then no working directory
    /// applies, a read gives the user level, and the engine refuses a session
    /// level change (``SettingsGraphError/missingWorkingDirectory``). A call
    /// of the tool of a session can omit `cwd`, and then the session folder
    /// applies. A `cwd` that the tool of a session gets must name its session
    /// folder, thus a session level write always goes to the cwd of that
    /// session. A relative `cwd` goes to the engine as it is, and the engine
    /// refuses it.
    ///
    /// - Parameter cwd: The `cwd` argument of the field, or `nil`.
    /// - Returns: The path of the working directory, or `nil` when a call of
    ///   the endpoint gives no `cwd`.
    /// - Throws: ``SettingsGraphError/otherSessionWorkingDirectory(path:)``
    ///   when the `cwd` is an absolute path of a folder that is not the
    ///   session folder.
    func workingDirectory(given cwd: String?) throws -> String? {
        guard let sessionDirectory else {
            return cwd
        }
        guard let cwd else {
            return sessionDirectory
        }
        guard SessionSetup.isAbsolute(cwd) else {
            return cwd
        }
        guard Self.resolvedPath(of: cwd) == Self.resolvedPath(of: sessionDirectory) else {
            throw SettingsGraphError.otherSessionWorkingDirectory(path: cwd)
        }
        return sessionDirectory
    }

    /// Gives the path of a folder with each symbolic link resolved, so that
    /// two spellings of one folder (for example with and with no `/private`)
    /// compare equal.
    ///
    /// - Parameter path: The absolute path of the folder.
    /// - Returns: The resolved path.
    private static func resolvedPath(of path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
    }
}

/// The root resolver of the `settings` endpoint over the engine.
struct SettingsGraphResolver: Sendable {
    /// The code of the warning in `extensions.warnings` that tells that a
    /// mutation is saved, but its read after the change did not complete.
    static let readBackWarningCode = "READ_AFTER_CHANGE_INCOMPLETE"

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
    /// - Parameters:
    ///   - context: The context of the call, which gives the working
    ///     directory when the call gives no `cwd`.
    ///   - arguments: The key path and the working directory.
    /// - Returns: The setting, or `nil` when no layer has the key.
    /// - Throws: What ``SettingsGraphContext/workingDirectory(given:)`` and
    ///   ``SettingsEngine/setting(at:cwd:)`` throw.
    func setting(
        context: SettingsGraphContext, arguments: SettingsGraphSettingArguments
    ) async throws -> SettingsGraphSetting? {
        try await mergedSetting(at: arguments.keyPath, cwd: context.workingDirectory(given: arguments.cwd))
    }

    /// Resolves `Mutation.updateSetting`.
    ///
    /// A failure of the read after the change does not fail the mutation,
    /// because the change is saved before that read. Then the result has an
    /// unknown part, as ``settingAfterChange(at:cwd:context:)`` tells.
    ///
    /// - Parameters:
    ///   - context: The context of the call, which gives the working
    ///     directory when the call gives no `cwd`, and gets the warning of a
    ///     read after the change that did not complete.
    ///   - arguments: The input object: the key path, the value, the level
    ///     and the working directory.
    /// - Returns: The merged setting after the change, or `nil` when no layer
    ///   has the key or when the read after the change failed as a whole.
    /// - Throws: What ``SettingsGraphContext/workingDirectory(given:)`` and
    ///   ``SettingsEngine/set(_:at:level:cwd:)`` throw. The change is then not
    ///   saved.
    func updateSetting(
        context: SettingsGraphContext, arguments: SettingsGraphUpdateArguments
    ) async throws -> SettingsGraphSetting? {
        let input = arguments.input
        let cwd = try context.workingDirectory(given: input.cwd)
        try await engine.set(YAMLValue(graphQLMap: input.value), at: input.keyPath, level: input.level, cwd: cwd)
        return await settingAfterChange(at: input.keyPath, cwd: cwd, context: context)
    }

    /// Resolves `Mutation.clearSetting`.
    ///
    /// A failure of the read after the change does not fail the mutation,
    /// because the change is saved before that read. Then the result has an
    /// unknown part, as ``settingAfterChange(at:cwd:context:)`` tells.
    ///
    /// - Parameters:
    ///   - context: The context of the call, which gives the working
    ///     directory when the call gives no `cwd`, and gets the warning of a
    ///     read after the change that did not complete.
    ///   - arguments: The input object: the key path, the level and the
    ///     working directory.
    /// - Returns: The merged setting after the change, or `nil` when no layer
    ///   has the key or when the read after the change failed as a whole.
    /// - Throws: What ``SettingsGraphContext/workingDirectory(given:)`` and
    ///   ``SettingsEngine/clear(at:level:cwd:)`` throw. The change is then not
    ///   saved.
    func clearSetting(
        context: SettingsGraphContext, arguments: SettingsGraphClearArguments
    ) async throws -> SettingsGraphSetting? {
        let input = arguments.input
        let cwd = try context.workingDirectory(given: input.cwd)
        try await engine.clear(at: input.keyPath, level: input.level, cwd: cwd)
        return await settingAfterChange(at: input.keyPath, cwd: cwd, context: context)
    }

    /// Reads the merged setting of one key for the query.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - cwd: The absolute path of the working directory of the session, or
    ///     `nil` for the user level only.
    /// - Returns: The setting, or `nil` when no layer has the key.
    /// - Throws: What ``SettingsEngine/setting(at:cwd:)`` throws.
    private func mergedSetting(at keyPath: [String], cwd: String?) async throws -> SettingsGraphSetting? {
        try await engine.setting(at: keyPath, cwd: cwd).map(SettingsGraphSetting.init)
    }

    /// Reads the merged setting of one key after a mutation that the store
    /// saved, for the result of the mutation.
    ///
    /// This read never fails the mutation, because the change is already
    /// saved, and a client that gets an error can make the same change again.
    /// A part that the read cannot get is unknown in the result:
    ///
    /// - A secret that the secret store cannot read has `hasValue: null`.
    /// - A read that fails as a whole, for example for a level file that the
    ///   store cannot read, gives a `null` result.
    ///
    /// In both cases the read adds a warning with the code
    /// ``readBackWarningCode`` to `extensions.warnings`, and writes a log
    /// record with the key path and the case of the error, never a value.
    ///
    /// - Parameters:
    ///   - keyPath: The key path.
    ///   - cwd: The absolute path of the working directory of the session, or
    ///     `nil` for the user level only.
    ///   - context: The context of the call, which gets the warning.
    /// - Returns: The setting, or `nil` when no layer has the key or when the
    ///   read failed as a whole.
    private func settingAfterChange(
        at keyPath: [String], cwd: String?, context: SettingsGraphContext
    ) async -> SettingsGraphSetting? {
        do {
            let reading = try await engine.settingAfterChange(at: keyPath, cwd: cwd)
            if let reading, !reading.isComplete {
                await Self.warnOfIncompleteRead(of: keyPath, in: context)
            }
            return reading.map(SettingsGraphSetting.init)
        } catch {
            SettingsEngine.logIncompleteReadAfterChange(of: keyPath.joined(separator: "."), error: error)
            await Self.warnOfIncompleteRead(of: keyPath, in: context)
            return nil
        }
    }

    /// Adds the warning of a read after a saved change that did not complete.
    ///
    /// - Parameters:
    ///   - keyPath: The key path of the change.
    ///   - context: The context of the call.
    private static func warnOfIncompleteRead(of keyPath: [String], in context: SettingsGraphContext) async {
        await context.warnings.add(
            "The change of \(keyPath.joined(separator: ".")) is saved, but the read of the setting after the change "
                + "did not complete. A null result or a null hasValue is unknown. Do not make the change again. "
                + "Read the setting with the setting query.",
            code: readBackWarningCode)
    }

    /// Resolves `Query.cursor`.
    ///
    /// - Parameters:
    ///   - context: The context of the call, which gives the working
    ///     directory when the call gives no `cwd`.
    ///   - arguments: The working directory to watch.
    /// - Returns: The cursor of the newest change.
    /// - Throws: What ``SettingsGraphContext/workingDirectory(given:)`` and
    ///   ``SettingsEngine/cursor(cwd:)`` throw.
    func cursor(context: SettingsGraphContext, arguments: SettingsGraphCursorArguments) async throws -> String {
        try await engine.cursor(cwd: context.workingDirectory(given: arguments.cwd))
    }

    /// Resolves the source of `Subscription.changes`.
    ///
    /// - Parameter arguments: The cursor to resume after and the working
    ///   directory to watch.
    /// - Returns: The stream of each entry of the change log.
    /// - Throws: What ``SettingsEngine/changes(after:cwd:)`` throws.
    func changes(
        context _: SettingsGraphContext, arguments: SettingsGraphChangesArguments
    ) async throws -> AsyncThrowingStream<SettingsEngine.LoggedEntry, Error> {
        try await engine.changes(after: arguments.after, cwd: arguments.cwd)
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
        "The absolute path of the working directory of the session. It names the session level. A call of the "
        + "settings endpoint can omit it: then a read gives the USER level over the builtin layers, a USER change "
        + "needs no cwd, and a SESSION change is refused. The settings tool of a session can omit it: the folder "
        + "of that session applies, and a different folder is refused."

    /// The text of the description of a `level` argument.
    private static let levelDescription = "The level that the mutation changes."

    /// The text of the description of the setting that a mutation gives.
    private static let resultDescription =
        "The merged setting after the change, or null when no layer has the key. The change is saved before the "
        + "read of this result. When that read does not complete, the mutation does not fail: a part that the read "
        + "could not get is null, and extensions.warnings has the code "
        + "\(SettingsGraphResolver.readBackWarningCode)."

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
            .addToolkitIDScalar()
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
                        .description(
                            "True when the secret store has an item for the reference. Null in the result of a "
                                + "mutation when the secret store could not read the item: the value is unknown.")
                }
                .description("One secret key inside a setting. The endpoint never gives a secret value.")
                Type(SettingsGraphSetting.self, as: "Setting") {
                    Field("keyPath", at: \.keyPath).description("The key path of the setting.")
                    Field("value", at: \.value)
                        .description("The merged value. A literal secret shows as <redacted>.")
                    Field("level", at: \.level).description("The layer that set the value.")
                    Field("secrets", at: \.secrets).description("Each secret key inside the value.")
                }
                .description(
                    "The merged value of one key for a session, or of the USER level when no cwd applies, and the "
                        + "layer that set it.")
                Type(SettingsGraphChange.self, as: "SettingsChange") {
                    Field("cursor", at: \.cursor)
                        .description("The cursor of this change. changes(after:) with it resumes after this change.")
                    Field("at", at: \.at).description("The time of the change.")
                    Field("added", at: \.added)
                        .description("The dotted key path of each key that the change added: it had no value on the level.")
                    Field("changed", at: \.changed)
                        .description(
                            "The dotted key path of each key that the change changed. A change of a file names each "
                                + "leaf key whose value differs.")
                    Field("removed", at: \.removed).description("The dotted key path of each key that the change removed.")
                    Field("level", at: \.level).description("The level that changed.")
                    Field("cwd", at: \.cwd)
                        .description("The working directory of a session level, or null for the user level.")
                    Field("keyPath", at: \.keyPath)
                        .description("The changed key path, or null when the file of the level changed. Read it again.")
                }
                .description("One change of the settings.")
                Input(SettingsGraphUpdateInput.self, as: "UpdateSettingInput") {
                    InputField("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    InputField("value", at: \.value)
                        .description("The new value. A secret key takes only a keychain:<name> reference.")
                    InputField("level", at: \.level).description(Self.levelDescription)
                    InputField("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description("The key, the new value and the level of an updateSetting mutation.")
                Input(SettingsGraphClearInput.self, as: "ClearSettingInput") {
                    InputField("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    InputField("level", at: \.level).description(Self.levelDescription)
                    InputField("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description("The key and the level of a clearSetting mutation.")
            }
            .addQuery {
                Field("sections", at: SettingsGraphResolver.sections)
                    .description("The sections of the settings: the first key of each key path.")
                Field("setting", at: SettingsGraphResolver.setting) {
                    Argument("keyPath", at: \.keyPath).description(Self.keyPathDescription)
                    Argument("cwd", at: \.cwd).description(Self.cwdDescription)
                }
                .description(
                    "The merged value of one key for a session, or of the USER level when no cwd applies, or null "
                        + "when no layer has the key.")
                Field("cursor", at: SettingsGraphResolver.cursor) {
                    Argument("cwd", at: \.cwd)
                        .description(
                            "The working directory whose session level the read starts to watch, thus an outside "
                                + "write of its file after the read is in the changes after the cursor. "
                                + Self.cwdDescription)
                }
                .description(
                    "The cursor of the newest change of the settings. Read the state, read this cursor, then "
                        + "subscribe to changes(after:) with it for each change after the read.")
            }
            .addMutation {
                Field("updateSetting", at: SettingsGraphResolver.updateSetting) {
                    Argument("input", at: \.input).description("The key, the new value and the level.")
                }
                .description("Sets the value of one key on one level. \(Self.resultDescription)")
                Field("clearSetting", at: SettingsGraphResolver.clearSetting) {
                    Argument("input", at: \.input).description("The key and the level.")
                }
                .description(
                    "Removes one key from one level. The value of a lower level applies again. "
                        + Self.resultDescription)
            }
            .addSubscription {
                SubscriptionField(
                    "changes", at: SettingsEngine.LoggedEntry.graphQLChange, atSub: SettingsGraphResolver.changes
                ) {
                    Argument("after", at: \.after)
                        .description(
                            "The cursor to resume after: the cursor query or the cursor of a change. Null for the "
                                + "new changes only. A cursor of another run of the agent, a cursor whose next change "
                                + "left the change log, or a cursor after the newest change ends the subscription with "
                                + "RESYNC_REQUIRED: read the state and the cursor again, then subscribe again.")
                    Argument("cwd", at: \.cwd)
                        .description(
                            "The working directory whose session level to watch, or null for the changes of USER only.")
                }
                .description(
                    "Each change of the settings after a cursor, from a mutation or from a change of a file. With no "
                        + "cwd, only the changes of USER.")
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
