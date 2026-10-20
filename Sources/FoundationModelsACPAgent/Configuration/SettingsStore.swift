import Foundation
import FoundationModelsExtras
import Synchronization

/// A settings level that ``SettingsStore`` keeps in memory and writes to its
/// own `config.yaml` (ACPA-17, D100(f)).
public enum SettingsLevel: Hashable, Sendable {
    /// The user level: the user layer of ``SettingsFolders``. It applies to
    /// each working directory.
    case user

    /// The session level of one working directory: the project layer of
    /// ``SettingsFolders`` for that directory. It wins over the user level.
    case session(URL)

    /// The working directory of a session level, or `nil` for the user
    /// level.
    var workingDirectory: URL? {
        switch self {
        case .user:
            nil
        case .session(let workingDirectory):
            workingDirectory
        }
    }

    /// The source of the dotfolder layer of this level.
    var source: DotfolderStack.Source {
        switch self {
        case .user:
            .user
        case .session:
            .project
        }
    }
}

/// One change of the settings that ``SettingsStore/changes()`` sends.
///
/// A change holds no value, because a value can be a secret.
public struct SettingsChange: Equatable, Sendable {
    /// The level that changed.
    public let level: SettingsLevel

    /// The key path that a `set` or a `clear` changed, or `nil` when the
    /// file of the level changed from outside and the store read it again.
    public let keyPath: [String]?

    /// Makes a change.
    ///
    /// - Parameters:
    ///   - level: The level that changed.
    ///   - keyPath: The changed key path, or `nil` for an outside change.
    public init(level: SettingsLevel, keyPath: [String]?) {
        self.level = level
        self.keyPath = keyPath
    }
}

/// The merged value of one key and the layer that set it.
public struct SettingsValue: Equatable, Sendable {
    /// The merged value after the render of the templates of the files. A
    /// `keychain:` reference stays a reference, because the render does not
    /// resolve it.
    public let value: YAMLValue

    /// The layer that set the value: ``ConfigurationLayerName/project`` for
    /// a session level, ``ConfigurationLayerName/user`` for the user level,
    /// and ``ConfigurationLayerName/builtin`` for a value that no level set.
    public let level: ConfigurationLayerName

    /// Makes a value.
    ///
    /// - Parameters:
    ///   - value: The merged value.
    ///   - level: The layer that set the value.
    public init(value: YAMLValue, level: ConfigurationLayerName) {
        self.value = value
        self.level = level
    }
}

/// A settings call that the store cannot do.
public enum SettingsStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The settings folders give no folder for the level, for example no
    /// user layer when the CLI finds no XDG folder.
    case noLayer(SettingsLevel)

    /// A human-readable reason that names the level.
    public var description: String {
        switch self {
        case .noLayer(.user):
            return "the settings folders give no folder for the user level"
        case .noLayer(.session(let workingDirectory)):
            return "the settings folders give no folder for the session level of \(workingDirectory.path)"
        }
    }
}

/// The settings of the agent in memory: one settings object for each level
/// that the store has read (ACPA-17, D100(f)).
///
/// The levels are the user level and the session level of each working
/// directory (``SettingsLevel``). ``SettingsFolders`` gives the folder of
/// each level. The store reads the `config.yaml` of a level the first time
/// that a call needs it, and then keeps its tree in memory. The sessions read
/// the merged settings from memory with ``merged(for:)``.
///
/// The store keeps the source text of each level, before the render of its
/// templates, and the rendered tree of that text. It renders only to merge,
/// check and decode.
///
/// A ``set(_:at:level:)`` or a ``clear(at:level:)`` changes the source tree
/// of its level (``SettingsSourceText``), renders the changed text, checks
/// the merged result as ``ConfigurationLoader/load()`` checks it, and refuses
/// a change that does not decode. Then it writes the changed source text to
/// the `config.yaml` of the level with an atomic write. The flush writes the
/// source tree, and not the text that the file had: comments of the file go.
/// Each template expression `{{ ... }}` stays an expression, thus no flush
/// writes a rendered value, such as a secret from the environment (D101). A
/// change that would lose a template construct (a block tag, a comment tag,
/// or a templated key on its way) is refused with
/// ``SettingsTemplateError/unkeptTemplate(keyPath:)``. A secret stays as the
/// text that the file holds: a `keychain:<name>` reference stays a reference,
/// and no flush writes a value from the secret store.
///
/// The store watches each `config.yaml` that it read with a
/// `DotfolderWatcher`. When the file changes from outside (for example,
/// iCloud brings a change from another device) and its text is not the text
/// that the store last read or wrote, the store reads the file again and
/// sends a change. ``changes()`` gives each change of a `set`, a `clear` and
/// an outside write. ``stopWatching()`` stops each watcher, forgets each
/// level and ends each ``changes()`` stream; a later call reads its levels
/// from the files again.
///
/// The defaults layer that `<NAME>_DEFAULTS_DIR` names is not a level: no
/// change goes into it, thus each merge reads it from the disk, as the loader
/// does. A `{% include %}` tag of a level file finds a partial only in the
/// folder of that level, because the tree of a level does not depend on a
/// working directory.
public actor SettingsStore {
    /// The working directory of the stack that gives the user layer and the
    /// defaults layer. These layers are the same for each working directory.
    private static let placeholderDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    /// The settings folders of the host. Each level path comes from them.
    public nonisolated let settingsFolders: SettingsFolders

    /// The transcript location that the host gives in code, or `nil` when
    /// the files decide. ``merged(for:)`` puts it over the files, as
    /// ``ConfigurationLoader/transcriptLocation`` does.
    public nonisolated let transcriptLocation: TranscriptLocation?

    /// The store that gives the value of each secret reference when
    /// ``merged(for:)`` resolves the configuration. The trees in memory and
    /// the files keep the references.
    public nonisolated let secretStore: any SecretStore

    /// The settings object of each level that the store has read, keyed by
    /// the path of its `config.yaml`.
    private var levels: [String: LevelState] = [:]

    /// The continuation of each open ``changes()`` stream, keyed by a token.
    /// A lock holds them, because the end of a stream removes its
    /// continuation from a synchronous handler.
    private nonisolated let subscribers = Mutex<[UUID: AsyncStream<SettingsChange>.Continuation]>([:])

    /// The settings object of one level.
    private struct LevelState {
        /// The level.
        let level: SettingsLevel

        /// The dotfolder layer of the level.
        let layer: DotfolderStack.Layer

        /// The rendered tree of ``text``, or `.null` when the level sets no
        /// key. The merge, the check and the decode read it.
        var root: YAMLValue

        /// The source text of the file, before the render of its templates,
        /// that the store last read or wrote, or `nil` when there was no
        /// file. A change edits it (``SettingsSourceText``).
        var text: String?

        /// The watcher of ``file``. The state keeps it, thus it watches for
        /// as long as the store keeps the level. ``SettingsStore/stopWatching()``
        /// stops it.
        let watcher: DotfolderWatcher

        /// The `config.yaml` of the level.
        var file: URL {
            SettingsStore.configFile(of: layer)
        }

        /// The tree of the level with its source, as ``MergedSettings``
        /// takes it.
        var tree: MergedSettings.LevelTree {
            (source: layer.source, root: root)
        }
    }

    /// Makes a store that has read no level.
    ///
    /// - Parameters:
    ///   - settingsFolders: The settings folders of the host.
    ///   - transcriptLocation: The transcript location that wins over the
    ///     files, or `nil` (the default) to let the files decide.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference, or `nil` (the default) for the login Keychain under the
    ///     service of the dotfolder name.
    public init(
        settingsFolders: SettingsFolders,
        transcriptLocation: TranscriptLocation? = nil,
        secretStore: (any SecretStore)? = nil
    ) {
        self.settingsFolders = settingsFolders
        self.transcriptLocation = transcriptLocation
        self.secretStore = secretStore ?? KeychainSecretStore.loginKeychain(for: settingsFolders.name)
    }

    /// Makes the configuration loader of one working directory over the
    /// settings folders, the transcript location and the secret store of
    /// this store.
    ///
    /// - Parameter workingDirectory: The working directory of the session.
    /// - Returns: The loader.
    public nonisolated func makeConfigurationLoader(workingDirectory: URL) -> ConfigurationLoader {
        ConfigurationLoader(
            settingsFolders: settingsFolders, workingDirectory: workingDirectory,
            transcriptLocation: transcriptLocation, secretStore: secretStore)
    }

    // MARK: - Reads

    /// The merged settings of one working directory, from the levels in
    /// memory.
    ///
    /// The steps after the merge are the steps of
    /// ``ConfigurationLoader/load()``: the builtin layer goes under the
    /// defaults layer, the user level and the session level of `cwd`; then
    /// the check, the decode, the resolve of each secret reference, and the
    /// code override of ``transcriptLocation``.
    ///
    /// - Parameter cwd: The working directory of the session.
    /// - Returns: The decoded configuration, its warnings, and the layer that
    ///   set each key.
    /// - Throws: What ``ConfigurationLoader/load()`` throws for a file that
    ///   cannot be read, rendered, parsed, checked or decoded.
    public func merged(for cwd: URL) throws -> LoadedConfiguration {
        let (merged, loader) = try mergedSettings(for: cwd)
        return try loader.loadedConfiguration(dotfolderRoot: merged.root, sources: merged.dottedSources)
    }

    /// The merged value of one key for a working directory, and the layer
    /// that set it. A secret reference stays a reference.
    ///
    /// - Parameters:
    ///   - keyPath: The keys from the root, such as `["compaction", "trigger"]`.
    ///   - cwd: The working directory of the session.
    /// - Returns: The value and its layer, or `nil` when no layer and no
    ///   builtin default has the key.
    /// - Throws: What ``merged(for:)`` throws for a level file, or what the
    ///   builtin file throws.
    public func value(at keyPath: [String], cwd: URL) throws -> SettingsValue? {
        let (merged, loader) = try mergedSettings(for: cwd)
        return try loader.layeredRoot(over: merged.root).value(at: keyPath).map {
            SettingsValue(value: $0, level: ConfigurationLayerName(merged.source(of: keyPath)))
        }
    }

    /// A stream of each change that the store makes or reads from now on.
    ///
    /// - Returns: The stream. It ends when the caller stops to iterate it, or
    ///   when ``stopWatching()`` runs.
    public func changes() -> AsyncStream<SettingsChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: SettingsChange.self)
        let token = UUID()
        subscribers.withLock { $0[token] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(token)
        }
        return stream
    }

    /// Forgets the continuation of a ``changes()`` stream that ended.
    ///
    /// - Parameter token: The token of the stream.
    private nonisolated func removeSubscriber(_ token: UUID) {
        _ = subscribers.withLock { $0.removeValue(forKey: token) }
    }

    // MARK: - Stop

    /// Stops the watch of each `config.yaml` that the store read, forgets
    /// each level, and ends each open ``changes()`` stream.
    ///
    /// The host calls it when the store is done, for example when the
    /// connection of the agent closed. A later call reads the file of each
    /// level that it needs again, and watches that file again, because no
    /// watcher kept the forgotten levels up to date.
    public func stopWatching() {
        for state in levels.values {
            state.watcher.stop()
        }
        levels.removeAll()
        let continuations = subscribers.withLock { subscribers in
            let continuations = Array(subscribers.values)
            subscribers.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    // MARK: - Writes

    /// Sets the value of one key on one level, and writes the level to its
    /// `config.yaml`.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - keyPath: The keys from the root. It must name a key.
    ///   - level: The level that gets the value.
    /// - Throws: ``SettingsTreeError`` for a key path that the tree cannot
    ///   take; ``SettingsTemplateError/unkeptTemplate(keyPath:)`` for a
    ///   change that a write cannot make with each template construct of
    ///   the file kept; `ConfigurationError` or `YAMLValueDecodingError` for
    ///   a result that does not pass the schema or does not decode; a file
    ///   error. After an error, the level and its file do not change.
    public func set(_ value: YAMLValue, at keyPath: [String], level: SettingsLevel) throws {
        try change(at: keyPath, level: level) { try $0.setting(value, at: keyPath) }
    }

    /// Removes one key from one level, and writes the level to its
    /// `config.yaml`. The value of a lower level then applies again.
    ///
    /// - Parameters:
    ///   - keyPath: The keys from the root. It must name a key.
    ///   - level: The level that loses the key.
    /// - Throws: What ``set(_:at:level:)`` throws.
    public func clear(at keyPath: [String], level: SettingsLevel) throws {
        try change(at: keyPath, level: level) { try $0.removingValue(at: keyPath) }
    }

    /// Changes the source tree of one level, renders the changed text,
    /// checks the merged result, writes the changed source text to the file
    /// of the level, and sends the change. A change that gives the same
    /// source tree writes nothing and sends nothing.
    ///
    /// - Parameters:
    ///   - keyPath: The changed key path, for the change event and the
    ///     errors.
    ///   - level: The level to change.
    ///   - transform: Gives the changed source tree of the level.
    /// - Throws: What ``set(_:at:level:)`` throws.
    private func change(
        at keyPath: [String], level: SettingsLevel, transform: (YAMLValue) throws -> YAMLValue
    ) throws {
        var state = try levelState(of: level)
        let source = try SettingsSourceText(text: state.text, keyPath: keyPath)
        try source.requireKeepable(keyPath)
        let changed = try transform(source.tree)
        guard changed != source.tree else {
            return
        }
        let text = try source.text(of: changed)
        let root = try Self.renderedTree(of: text, layer: state.layer)
        try check(root, of: level)
        try Self.write(text, to: state.file)
        state.root = root
        state.text = text
        levels[state.file.path] = state
        send(SettingsChange(level: level, keyPath: keyPath))
    }

    /// Checks the merged settings with `root` as the tree of `level`: the
    /// schema check and the decode of ``ConfigurationLoader/load()``.
    ///
    /// - Parameters:
    ///   - root: The changed tree of the level.
    ///   - level: The level of the tree. A user level change is checked with
    ///     no session level; a session level change is checked over the
    ///     user level.
    /// - Throws: `ConfigurationError` or `YAMLValueDecodingError`.
    private func check(_ root: YAMLValue, of level: SettingsLevel) throws {
        let lowerLevels: [SettingsLevel] = level == .user ? [] : [.user]
        let lowerTrees = try lowerLevels.map { try levelState(of: $0).tree }
        let merged = try mergedSettings(over: lowerTrees + [(source: level.source, root: root)])
        try makeConfigurationLoader(workingDirectory: level.workingDirectory ?? Self.placeholderDirectory)
            .check(dotfolderRoot: merged.root)
    }

    /// Writes `text` to `file` with an atomic write, and makes the folder of
    /// the file first.
    ///
    /// - Parameters:
    ///   - text: The file text.
    ///   - file: The `config.yaml` of a level.
    /// - Throws: The error of the folder or of the write.
    private static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Levels

    /// The merged settings of one working directory: the defaults layer, the
    /// user level and the session level of `cwd`, and the configuration
    /// loader of `cwd` that takes the merged tree further.
    ///
    /// - Parameter cwd: The working directory of the session.
    /// - Returns: The merged tree with its sources, and the loader.
    /// - Throws: What ``levelState(of:)`` and a read of the defaults file
    ///   throw.
    private func mergedSettings(for cwd: URL) throws -> (settings: MergedSettings, loader: ConfigurationLoader) {
        let trees = try [SettingsLevel.user, .session(cwd)].map { try levelState(of: $0).tree }
        return (try mergedSettings(over: trees), makeConfigurationLoader(workingDirectory: cwd))
    }

    /// The merged settings of the defaults layer and `trees`.
    ///
    /// - Parameter trees: The trees of the levels, lowest precedence first.
    /// - Returns: The merged tree and its sources.
    /// - Throws: What a read of the defaults file throws.
    private func mergedSettings(over trees: [MergedSettings.LevelTree]) throws -> MergedSettings {
        MergedSettings(levels: try defaultsTrees() + trees)
    }

    /// The tree of the defaults layer, read from the disk now, or no tree
    /// when the environment names no defaults layer.
    ///
    /// - Returns: No tree, or one tree with the source `.defaults`.
    /// - Throws: What a read of the file throws.
    private func defaultsTrees() throws -> [MergedSettings.LevelTree] {
        guard let layer = layer(of: .defaults, workingDirectory: Self.placeholderDirectory) else {
            return []
        }
        let text = try Self.text(of: Self.configFile(of: layer))
        return [(source: .defaults, root: try Self.renderedTree(of: text, layer: layer))]
    }

    /// The settings object of `level`: the object in memory, or a new object
    /// that the store reads from the file and starts to watch.
    ///
    /// - Parameter level: The level.
    /// - Returns: The state of the level.
    /// - Throws: ``SettingsStoreError/noLayer(_:)`` when the settings folders
    ///   give no folder for the level; what a read of the file throws.
    private func levelState(of level: SettingsLevel) throws -> LevelState {
        let workingDirectory = level.workingDirectory ?? Self.placeholderDirectory
        guard let layer = layer(of: level.source, workingDirectory: workingDirectory) else {
            throw SettingsStoreError.noLayer(level)
        }
        let file = Self.configFile(of: layer)
        if let state = levels[file.path] {
            return state
        }
        let text = try Self.text(of: file)
        let root = try Self.renderedTree(of: text, layer: layer)
        let watcher = DotfolderWatcher(roots: [file]) { [weak self] in
            self?.fileDidChange(at: file)
        }
        let state = LevelState(level: level, layer: layer, root: root, text: text, watcher: watcher)
        levels[file.path] = state
        watcher.start()
        return state
    }

    /// The layer of `source` in the configuration stack of
    /// `workingDirectory`.
    ///
    /// - Parameters:
    ///   - source: The source of the layer.
    ///   - workingDirectory: The working directory of the stack.
    /// - Returns: The layer, or `nil` when the stack has no such layer.
    private func layer(of source: DotfolderStack.Source, workingDirectory: URL) -> DotfolderStack.Layer? {
        settingsFolders.stack(for: .configuration, workingDirectory: workingDirectory)
            .layers.first { $0.source == source }
    }

    // MARK: - Outside changes

    /// Starts the reload of the level of `file` after its watcher saw a
    /// change. The watcher calls it on its own queue, thus a task takes the
    /// reload to the store.
    ///
    /// - Parameter file: The `config.yaml` that changed.
    private nonisolated func fileDidChange(at file: URL) {
        Task { [weak self] in
            await self?.reload(file)
        }
    }

    /// Reads the file of a level again when its text is not the text that
    /// the store last read or wrote, and sends a change. A file that cannot
    /// be read or parsed leaves the level as it was, and the store logs the
    /// type of the error.
    ///
    /// - Parameter file: The `config.yaml` of the level.
    private func reload(_ file: URL) {
        guard var state = levels[file.path] else {
            return
        }
        do {
            let text = try Self.text(of: file)
            guard text != state.text else {
                return
            }
            state.root = try Self.renderedTree(of: text, layer: state.layer)
            state.text = text
        } catch {
            ACPAgentTelemetry.logger(.configuration).warning(
                "A settings file changed, and the store could not read it again. The settings in memory stay.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return
        }
        levels[file.path] = state
        send(SettingsChange(level: state.level, keyPath: nil))
    }

    /// Sends `change` to each open ``changes()`` stream.
    ///
    /// - Parameter change: The change.
    private func send(_ change: SettingsChange) {
        let continuations = subscribers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(change)
        }
    }

    // MARK: - Files

    /// The `config.yaml` of `layer`.
    ///
    /// - Parameter layer: The layer.
    /// - Returns: The file URL.
    private static func configFile(of layer: DotfolderStack.Layer) -> URL {
        layer.root.appendingPathComponent(ConfigurationLoader.configFileName)
    }

    /// The text of `file`.
    ///
    /// - Parameter file: The file.
    /// - Returns: The text, or `nil` when there is no file.
    /// - Throws: The read error of a file that is there.
    private static func text(of file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The rendered tree of a source text of the `config.yaml` of `layer`:
    /// the text rendered under the trust of its layer and parsed, as
    /// `LayeredYAMLDocument` reads a layer file. The trust rule is the rule
    /// of `LayeredYAMLDocument`: the defaults layer is trusted, and each
    /// other layer is not.
    ///
    /// - Parameters:
    ///   - text: The source text, or `nil` when there is no file.
    ///   - layer: The layer of the file.
    /// - Returns: The tree, or `.null` when there is no text.
    /// - Throws: `LayeredYAMLDocumentError` for a text that cannot be
    ///   rendered or parsed.
    private static func renderedTree(of text: String?, layer: DotfolderStack.Layer) throws -> YAMLValue {
        guard let text else {
            return .null
        }
        let path = configFile(of: layer).path
        let trust: TemplateEngine.Trust = layer.source == .defaults ? .trusted : .untrusted
        let rendered: String
        do {
            rendered = try TemplateEngine(partials: DotfolderStack(layers: [layer]))
                .render(text, context: TemplateContext(), trust: trust)
        } catch {
            throw LayeredYAMLDocumentError.renderingFailed(path: path, message: String(describing: error))
        }
        do {
            return try YAMLValue.parse(rendered)
        } catch YAMLValueParsingError.malformed(let line, let message) {
            throw LayeredYAMLDocumentError.malformed(path: path, line: line, message: message)
        }
    }
}
