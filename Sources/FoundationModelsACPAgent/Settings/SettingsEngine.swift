import Foundation
import FoundationModelsExtras

/// One merged setting as the `settings` engine gives it: the value that a
/// read can show, the layer that set it, and its secret keys.
struct SettingsReading: Equatable, Sendable {
    /// One secret key inside the value, with no secret value.
    struct Secret: Equatable, Sendable {
        /// The dotted key path of the secret key from the root.
        let keyPath: String

        /// The reference name of the `keychain:<name>` reference, or `nil`
        /// when the file holds a literal, which the reading does not show.
        let reference: String?

        /// `true` when the secret store has an item for ``reference``.
        /// Always `false` for a literal. `nil` only in a reading after a
        /// change (``SettingsEngine/settingAfterChange(at:cwd:)``) when the
        /// secret store cannot tell if it has the item: the value is then
        /// unknown.
        let hasValue: Bool?
    }

    /// The key path of the setting.
    let keyPath: [String]

    /// The merged value, with each literal secret replaced by
    /// ``ConfiguredSecret/redactedForm``.
    let value: YAMLValue

    /// The layer that set the value.
    let level: ConfigurationLayerName

    /// Each secret key inside the value.
    let secrets: [Secret]

    /// `true` when the reading knows each part: each secret has a known
    /// ``Secret/hasValue``.
    var isComplete: Bool {
        !secrets.contains { secret in secret.hasValue == nil }
    }
}

/// The one engine of the agent settings under the `settings` GraphQL
/// endpoint and ``SettingsTool`` (ACPA-17, D100, D75), over a
/// ``SettingsStore``.
///
/// The engine adds the rules of the endpoint to the store: a key path starts
/// with a section of ``AgentConfiguration``, a working directory is an
/// absolute path, a secret key takes only a `keychain:<name>` reference
/// (``SettingsSecretKeys``), and a read shows no secret value. It gives each
/// known store error as a ``SettingsGraphError``.
///
/// The device settings of a host (the Sharing switch, the login item, the
/// TCC grants) are not in ``AgentConfiguration``, thus they are not in the
/// engine.
struct SettingsEngine: Sendable {
    /// The top-level keys of the settings: the sections of
    /// ``AgentConfiguration``.
    static let sections = AgentConfiguration.CodingKeys.allCases.map(\.stringValue)

    /// The store of the settings.
    let store: SettingsStore

    // MARK: - Reads

    /// Reads the merged value of one key for a session, and the layer that
    /// set it.
    ///
    /// - Parameters:
    ///   - keyPath: The key path. Its first key is a section.
    ///   - cwd: The absolute path of the working directory of the session.
    /// - Returns: The reading, or `nil` when no layer and no builtin default
    ///   has the key.
    /// - Throws: ``SettingsGraphError`` for a call that the engine refuses,
    ///   or for a secret that the secret store cannot read; what the store
    ///   throws for a file that it cannot read.
    func setting(at keyPath: [String], cwd: String) async throws -> SettingsReading? {
        try await reading(at: keyPath, cwd: cwd, secretOf: secret(of:))
    }

    /// Reads the merged value of one key after a change that the store saved,
    /// for the result of a mutation.
    ///
    /// The change is saved before this read, thus a secret that the secret
    /// store cannot read does not make the read fail: its
    /// ``SettingsReading/Secret/hasValue`` is `nil` (unknown), and the engine
    /// writes a log record with the key path and the case of the error. A
    /// failure of the read of a level file still throws, because then no part
    /// of the reading is known.
    ///
    /// - Parameters:
    ///   - keyPath: The key path. Its first key is a section.
    ///   - cwd: The absolute path of the working directory of the session.
    /// - Returns: The reading, or `nil` when no layer and no builtin default
    ///   has the key.
    /// - Throws: ``SettingsGraphError`` for a call that the engine refuses;
    ///   what the store throws for a file that it cannot read.
    func settingAfterChange(at keyPath: [String], cwd: String) async throws -> SettingsReading? {
        try await reading(at: keyPath, cwd: cwd, secretOf: secretAfterChange(of:))
    }

    /// Writes the log record of a read after a saved change that did not
    /// complete. The record holds the dotted key path and the case of the
    /// error, never a value, because a value can be a secret.
    ///
    /// - Parameters:
    ///   - keyPath: The dotted key path that the read could not read.
    ///   - error: The error of the read.
    static func logIncompleteReadAfterChange(of keyPath: String, error: any Error) {
        var metadata = ACPAgentTelemetry.errorMetadata(error)
        metadata[ACPAgentTelemetry.LogMetadataKey.configSection] = "\(keyPath)"
        metadata[ACPAgentTelemetry.LogMetadataKey.errorCase] = "\(ACPAgentTelemetry.errorCaseName(of: error))"
        ACPAgentTelemetry.logger(.configuration).warning(
            "A settings change is saved, but the read of the setting after the change did not complete.",
            metadata: metadata)
    }

    /// Reads the merged value of one key, and gives each secret key inside
    /// it through `secretOf`.
    ///
    /// - Parameters:
    ///   - keyPath: The key path. Its first key is a section.
    ///   - cwd: The absolute path of the working directory of the session.
    ///   - secretOf: Gives the secret of one secret key.
    /// - Returns: The reading, or `nil` when no layer and no builtin default
    ///   has the key.
    /// - Throws: ``SettingsGraphError`` for a call that the engine refuses;
    ///   what `secretOf` throws; what the store throws for a file that it
    ///   cannot read.
    private func reading(
        at keyPath: [String], cwd: String,
        secretOf: (SettingsSecretKeys.Slot) throws -> SettingsReading.Secret
    ) async throws -> SettingsReading? {
        let directory = try Self.checkedWorkingDirectory(cwd, keyPath: keyPath)
        let merged = try await SettingsGraphError.withCodedErrors {
            try await store.value(at: keyPath, cwd: directory)
        }
        guard let merged else {
            return nil
        }
        return SettingsReading(
            keyPath: keyPath,
            value: SettingsSecretKeys.redacted(merged.value, at: keyPath),
            level: merged.level,
            secrets: try SettingsSecretKeys.slots(in: merged.value, at: keyPath).map(secretOf))
    }

    /// Gives the secret of one secret key, with no value.
    ///
    /// - Parameter slot: The secret key.
    /// - Returns: The secret.
    /// - Throws: ``SettingsGraphError/unreadableSecret(reference:)`` when the
    ///   secret store cannot read its item.
    private func secret(of slot: SettingsSecretKeys.Slot) throws -> SettingsReading.Secret {
        guard let reference = slot.referenceName else {
            return SettingsReading.Secret(keyPath: slot.keyPath, reference: nil, hasValue: false)
        }
        let item: String?
        do {
            item = try store.secretStore.value(forReference: reference)
        } catch {
            throw SettingsGraphError.unreadableSecret(reference: reference)
        }
        return SettingsReading.Secret(keyPath: slot.keyPath, reference: reference, hasValue: item != nil)
    }

    /// Gives the secret of one secret key in a read after a saved change.
    ///
    /// - Parameter slot: The secret key.
    /// - Returns: The secret, as ``secret(of:)`` gives it. When the secret
    ///   store cannot read the item, the secret has its reference and a `nil`
    ///   ``SettingsReading/Secret/hasValue``, and the engine writes a log
    ///   record.
    private func secretAfterChange(of slot: SettingsSecretKeys.Slot) -> SettingsReading.Secret {
        do {
            return try secret(of: slot)
        } catch {
            Self.logIncompleteReadAfterChange(of: slot.keyPath, error: error)
            return SettingsReading.Secret(keyPath: slot.keyPath, reference: slot.referenceName, hasValue: nil)
        }
    }

    // MARK: - Writes

    /// Sets the value of one key on one level.
    ///
    /// - Parameters:
    ///   - value: The new value. Each secret key inside it is a
    ///     `keychain:<name>` reference.
    ///   - keyPath: The key path. Its first key is a section.
    ///   - level: The level that gets the value.
    ///   - cwd: The absolute path of the working directory of the session,
    ///     which names the session level.
    /// - Throws: ``SettingsGraphError`` for a call that the engine or the
    ///   store refuses; what the store throws for a file error.
    func set(_ value: YAMLValue, at keyPath: [String], level: SettingsGraphLevel, cwd: String) async throws {
        let directory = try Self.checkedWorkingDirectory(cwd, keyPath: keyPath)
        try SettingsSecretKeys.requireReferences(in: value, at: keyPath)
        try await SettingsGraphError.withCodedErrors {
            try await store.set(value, at: keyPath, level: level.storeLevel(cwd: directory))
        }
    }

    /// Removes one key from one level. The value of a lower level then
    /// applies again.
    ///
    /// - Parameters:
    ///   - keyPath: The key path. Its first key is a section.
    ///   - level: The level that loses the key.
    ///   - cwd: The absolute path of the working directory of the session,
    ///     which names the session level.
    /// - Throws: What ``set(_:at:level:cwd:)`` throws.
    func clear(at keyPath: [String], level: SettingsGraphLevel, cwd: String) async throws {
        let directory = try Self.checkedWorkingDirectory(cwd, keyPath: keyPath)
        try await SettingsGraphError.withCodedErrors {
            try await store.clear(at: keyPath, level: level.storeLevel(cwd: directory))
        }
    }

    // MARK: - Changes

    /// Starts a stream of each change of the settings.
    ///
    /// The stream watches the user level and, when `cwd` is given, the
    /// session level of `cwd`, thus an outside write of one of their files
    /// sends a change. It gives each change of ``SettingsStore/changes()``,
    /// of each level.
    ///
    /// ``SettingsStore/stopWatching()`` ends each stream of the store, for
    /// example when one connection of the agent closes. The subscription of a
    /// client of a different connection must not end then. Thus, when the
    /// stream of the store ends, this stream starts a new stream of the store,
    /// reads its levels again, and sends one change with no key path for each
    /// of its levels: a change can come between the stop and the new read,
    /// and a change with no key path tells the subscriber to read the level
    /// again. This stream ends only when its reader stops to read it, or
    /// with an error when the store cannot read a level again.
    ///
    /// - Parameter cwd: The absolute path of the working directory of the
    ///   session to watch, or `nil` for the user level only.
    /// - Returns: The stream.
    /// - Throws: ``SettingsGraphError`` for a working directory that is not
    ///   absolute, or for a level that the store cannot read.
    func changes(cwd: String?) async throws -> AsyncThrowingStream<SettingsChange, Error> {
        let directory = try cwd.map(Self.workingDirectory)
        let first = await store.changes()
        try await SettingsGraphError.withCodedErrors {
            try await store.startWatching(cwd: directory)
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SettingsChange.self)
        let relay = Task { [store] in
            await Self.relay(from: first, of: store, cwd: directory, to: continuation)
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    /// Gives each change of the store to a continuation, and starts a new
    /// stream of the store each time that the stream of the store ends. Ends
    /// when the task is cancelled.
    ///
    /// - Parameters:
    ///   - first: The first stream of the store.
    ///   - store: The store.
    ///   - cwd: The working directory of the session level to watch, or `nil`.
    ///   - continuation: The continuation of the stream of the subscriber.
    private static func relay(
        from first: AsyncStream<SettingsChange>, of store: SettingsStore, cwd: URL?,
        to continuation: AsyncThrowingStream<SettingsChange, Error>.Continuation
    ) async {
        var source = first
        while !Task.isCancelled {
            for await change in source {
                continuation.yield(change)
            }
            guard !Task.isCancelled else {
                break
            }
            source = await store.changes()
            do {
                try await SettingsGraphError.withCodedErrors {
                    try await store.startWatching(cwd: cwd)
                }
            } catch {
                ACPAgentTelemetry.logger(.configuration).warning(
                    "The settings store stopped, and a settings subscription could not read its levels again.",
                    metadata: ACPAgentTelemetry.errorMetadata(error))
                continuation.finish(throwing: error)
                return
            }
            for level in SettingsLevel.watched(cwd: cwd) {
                continuation.yield(SettingsChange(level: level, keyPath: nil))
            }
        }
        continuation.finish()
    }

    // MARK: - Checks

    /// Checks the working directory and the key path of one call.
    ///
    /// - Parameters:
    ///   - cwd: The path of the working directory that the call gave.
    ///   - keyPath: The key path that the call gave.
    /// - Returns: The directory URL of `cwd`, as ``workingDirectory(_:)``
    ///   gives it.
    /// - Throws: What ``workingDirectory(_:)`` and ``requireSection(of:)``
    ///   throw.
    private static func checkedWorkingDirectory(_ cwd: String, keyPath: [String]) throws -> URL {
        let directory = try workingDirectory(cwd)
        try requireSection(of: keyPath)
        return directory
    }

    /// Gives the URL of a working directory.
    ///
    /// The absolute-path rule is ``SessionSetup/isAbsolute(_:)``, the one
    /// definition of the rule. This function does not call
    /// ``SessionSetup/validatedWorkingDirectory(path:field:)``, because that
    /// function throws a ``RequestError`` of the ACP wire, and the `settings`
    /// endpoint must give a ``SettingsGraphError`` with its code.
    ///
    /// - Parameter path: The path that a call gave.
    /// - Returns: The directory URL of the path as the call gave it. The path
    ///   is not standardized: a standardized path can drop the `/private`
    ///   part of a path, and the store would then keep a second copy of the
    ///   same level under a different path.
    /// - Throws: ``SettingsGraphError/relativeWorkingDirectory(path:)`` when
    ///   the path is not absolute.
    private static func workingDirectory(_ path: String) throws -> URL {
        guard SessionSetup.isAbsolute(path) else {
            throw SettingsGraphError.relativeWorkingDirectory(path: path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Checks that a key path names a key under a section of the settings.
    ///
    /// - Parameter keyPath: The key path.
    /// - Throws: ``SettingsGraphError/invalidKeyPath(detail:)`` for an empty
    ///   key path; ``SettingsGraphError/unknownSection(key:)`` when the first
    ///   key is not a section.
    private static func requireSection(of keyPath: [String]) throws {
        guard let section = keyPath.first else {
            throw SettingsGraphError.invalidKeyPath(detail: SettingsTreeError.emptyKeyPath.description)
        }
        guard sections.contains(section) else {
            throw SettingsGraphError.unknownSection(key: section)
        }
    }
}
