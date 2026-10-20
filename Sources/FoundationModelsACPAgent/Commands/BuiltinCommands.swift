import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization

/// The session state the six builtins read, bound in two phases. The
/// configuration, the instructions, the model and the profile are
/// known when `session/new` composes the session; the live ``RoutedSession``,
/// its id, its transcript directory and the assembled registry come only
/// after the session is made — and `/help` reads the registry that carries
/// the builtins, so the reference is late-bound. The known fields are `let`;
/// the late fields sit behind a `Mutex`, set once before any command runs.
final class BuiltinCommandContext: Sendable {
    /// The late-bound references, set once the session and its registry exist.
    struct Binding: Sendable {
        /// The live root session `/compact` folds and `/context` measures.
        let session: any RoutedSession

        /// The ACP session id `/status` names.
        let sessionId: SessionId

        /// The session's transcript directory `/status` names.
        let transcriptDirectory: URL

        /// The session's command registry `/help` lists, or `nil` after the
        /// release of the registry.
        ///
        /// The registry keeps the builtins, and each builtin keeps this
        /// context, so a strong reference here would make a cycle. That
        /// cycle would keep ``session``, and with it the models of the
        /// profile, after the agent went (task `^173qn8n`). The session entry
        /// of the agent keeps the registry.
        weak var registry: CommandRegistry?

        /// Makes the late-bound references.
        ///
        /// - Parameters:
        ///   - session: The live root session.
        ///   - sessionId: The ACP session id.
        ///   - transcriptDirectory: The session's transcript directory.
        ///   - registry: The session's command registry.
        init(
            session: any RoutedSession, sessionId: SessionId, transcriptDirectory: URL,
            registry: CommandRegistry
        ) {
            self.session = session
            self.sessionId = sessionId
            self.transcriptDirectory = transcriptDirectory
            self.registry = registry
        }
    }

    /// The session working directory `/status` names and `/config export
    /// project` writes under.
    let workingDirectory: URL

    /// The effective configuration `/config` prints and exports.
    let configuration: AgentConfiguration

    /// The assembled instructions `/memory` prints, source headers included.
    let instructions: String

    /// The `standard` slot model reference `/status` names.
    let modelName: String

    /// The resolved profile name `/status` names.
    let profileName: String

    /// The dotfolder name that roots the project config layer.
    let dotfolderName: DotfolderName

    /// The user config layer root `/config export home` writes under.
    let userLayerRoot: URL

    /// The late-bound references, `nil` until ``bind(_:)`` runs.
    private let bound = Mutex<Binding?>(nil)

    /// Creates a context with the fields known at session composition.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - configuration: The effective configuration.
    ///   - instructions: The assembled instructions text.
    ///   - modelName: The `standard` slot model reference string.
    ///   - profileName: The resolved profile name.
    ///   - dotfolderName: The dotfolder name of the project config layer.
    ///   - userLayerRoot: The user config layer root.
    init(
        workingDirectory: URL,
        configuration: AgentConfiguration,
        instructions: String,
        modelName: String,
        profileName: String,
        dotfolderName: DotfolderName,
        userLayerRoot: URL
    ) {
        self.workingDirectory = workingDirectory
        self.configuration = configuration
        self.instructions = instructions
        self.modelName = modelName
        self.profileName = profileName
        self.dotfolderName = dotfolderName
        self.userLayerRoot = userLayerRoot
    }

    /// Sets the late-bound references. Call once, after the session and the
    /// registry exist and before any command runs.
    ///
    /// - Parameter binding: The live session, its id, its transcript
    ///   directory and the registry.
    func bind(_ binding: Binding) {
        bound.withLock { $0 = binding }
    }

    /// The late-bound references, or `nil` before ``bind(_:)``.
    var binding: Binding? {
        bound.withLock { $0 }
    }
}

/// The six reserved builtin slash commands, the first command source.
/// No later source can replace their names. Each is
/// an `.action` closure that captures a ``BuiltinCommandContext`` and streams
/// its text, with no model call: `/compact` starts a fold, `/context` reads the
/// fill, `/memory` prints the instructions, `/status` prints the session
/// facts, `/config` prints or ejects the configuration, and `/help` lists the
/// registered commands.
enum BuiltinCommands {
    /// The config layer `/config export` writes to.
    enum ExportLayer: String {
        /// The user config layer, `<userLayerRoot>/config.yaml`.
        case home

        /// The project config layer, `<cwd>/.<name>/config.yaml`.
        case project

        /// The `config.yaml` this layer writes.
        ///
        /// - Parameter context: The session context that roots the layers.
        /// - Returns: The destination file.
        func destination(in context: BuiltinCommandContext) -> URL {
            switch self {
            case .home:
                return context.userLayerRoot
                    .appendingPathComponent(ConfigurationLoader.configFileName)
            case .project:
                return context.workingDirectory
                    .appendingPathComponent(".\(context.dotfolderName.rawValue)", isDirectory: true)
                    .appendingPathComponent(ConfigurationLoader.configFileName)
            }
        }
    }

    /// The verb that changes `/config` from a print into an export.
    private static let exportVerb = "export"

    /// The one-line usage `/config` prints for a malformed export.
    private static let configUsage = "Usage: /config export home|project"

    /// The note that each export confirmation carries: the export writes no
    /// API key value and no literal MCP header value, so that no key goes
    /// into a file that can be committed. A `keychain:` reference holds no
    /// key, thus the export keeps it.
    private static let omittedKeysNote =
        " The file holds no tools.web.apiKeys value and no literal tools.mcp headers value,"
        + " only the keychain: references."
        + " Keep each key in the layer that sets it, in the environment, or in the Keychain."

    /// The multiplier that changes a `0...1` fill fraction into a percent.
    private static let percentScale = 100.0

    /// Builds the six builtins over `context`.
    ///
    /// - Parameter context: The session context the closures capture.
    /// - Returns: The builtins, in registration order.
    static func make(context: BuiltinCommandContext) -> [SlashCommand] {
        [
            command(name: "compact", description: "Start a fold of the session transcript.") { _ in
                await compactReport(context: context)
            },
            command(name: "context", description: "Show the context fill and tokens.") { _ in
                await contextText(context: context)
            },
            command(name: "memory", description: "Show the assembled instructions.") { _ in
                memoryText(context: context)
            },
            command(
                name: "status",
                description: "Show the session id, cwd, model, profile and transcript path."
            ) { _ in
                statusText(context: context)
            },
            command(
                name: "config",
                description: "Show the effective configuration, or export it to a layer.",
                argumentHint: "[export home|project]"
            ) { invocation in
                configText(context: context, invocation: invocation)
            },
            command(name: "help", description: "List the registered commands.") { _ in
                await helpText(context: context)
            },
        ]
    }

    // MARK: - Command construction

    /// Makes one `.action` builtin whose closure produces its whole streamed
    /// text at once.
    ///
    /// - Parameters:
    ///   - name: The bare command name.
    ///   - description: The one-line description for `/help` and the menu.
    ///   - argumentHint: The input hint, or `nil` for a command that takes no
    ///     arguments worth hinting.
    ///   - produce: The text producer, run when the command is invoked.
    /// - Returns: The command.
    private static func command(
        name: String,
        description: String,
        argumentHint: String? = nil,
        produce: @escaping @Sendable (SlashCommand.Invocation) async -> String
    ) -> SlashCommand {
        SlashCommand(
            name: name, description: description, argumentHint: argumentHint,
            body: .action { invocation in
                actionStream { await produce(invocation) }
            })
    }

    /// Wraps an async text producer in a single-chunk `.action` stream.
    ///
    /// - Parameter produce: The producer of the whole streamed text.
    /// - Returns: A stream that yields the produced text once, then finishes.
    private static func actionStream(
        _ produce: @escaping @Sendable () async -> String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(await produce())
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - /compact

    /// The text that `/compact` streams.
    ///
    /// - Parameter signal: The `SignalID` of the compaction.
    /// - Returns: The text.
    static func compactionStartedText(_ signal: SignalID) -> String {
        "Compaction started. (\(signal))"
    }

    /// The `/compact` command: it sends the `compact` signal and returns at
    /// once (`mailbox.md`, section 3, "`/compact` only starts the work").
    ///
    /// The compaction is a long background process. Its report comes from
    /// its events (``CompactionReporter``), under its `SignalID`: the
    /// `in_progress` entry, then the `completed` entry with the summary, the
    /// token counts before and after and the summarizer model, or the
    /// `failed` entry with the failure or the shortfall. The
    /// ``SessionProjector`` reads those events also when no prompt is open.
    ///
    /// - Parameter context: The session context.
    /// - Returns: The text that the command streams.
    private static func compactReport(context: BuiltinCommandContext) async -> String {
        guard let binding = context.binding else {
            return "No active session to compact."
        }
        return compactionStartedText(binding.session.compact())
    }

    // MARK: - /context

    /// The `/context` report: the measured fill.
    ///
    /// - Parameter context: The session context.
    /// - Returns: The fill report.
    private static func contextText(context: BuiltinCommandContext) async -> String {
        guard let binding = context.binding else {
            return contextReport(fill: Double.nan)
        }
        return contextReport(fill: await binding.session.contextFill)
    }

    /// Formats a context fill. The fill is `Double.nan` when
    /// no submission has stamped a measurement, so the NaN is guarded with "not
    /// measured yet" and never printed.
    ///
    /// - Parameter fill: The `0...1` fill fraction, or `Double.nan`.
    /// - Returns: The fill line.
    static func contextReport(fill: Double) -> String {
        guard !fill.isNaN else {
            return "Context fill: not measured yet."
        }
        let percent = Int((fill * percentScale).rounded())
        return "Context fill: \(percent)%."
    }

    // MARK: - /memory

    /// The `/memory` report: the assembled instructions, with the per-file
    /// source headers the assembler already carries.
    ///
    /// - Parameter context: The session context.
    /// - Returns: The instructions, or a note when none were assembled.
    private static func memoryText(context: BuiltinCommandContext) -> String {
        context.instructions.isEmpty ? "No instructions were assembled." : context.instructions
    }

    // MARK: - /status

    /// The `/status` report: the session id, the cwd, the model, the profile
    /// and the transcript path.
    ///
    /// - Parameter context: The session context.
    /// - Returns: The status report.
    private static func statusText(context: BuiltinCommandContext) -> String {
        guard let binding = context.binding else {
            return "No active session."
        }
        return """
            Session: \(binding.sessionId.rawValue)
            Working directory: \(context.workingDirectory.path)
            Model: \(context.modelName)
            Profile: \(context.profileName)
            Transcript: \(binding.transcriptDirectory.path)
            """
    }

    // MARK: - /config

    /// The `/config` report: with no argument it prints the effective
    /// configuration as YAML; `export home|project` writes it to that layer.
    ///
    /// - Parameters:
    ///   - context: The session context.
    ///   - invocation: The command invocation carrying the arguments.
    /// - Returns: The rendered configuration, the export result, or the usage.
    private static func configText(
        context: BuiltinCommandContext, invocation: SlashCommand.Invocation
    ) -> String {
        let words = invocation.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = words.first else {
            return renderConfiguration(context.configuration)
        }
        guard verb == exportVerb else {
            return configUsage
        }
        guard words.count > 1, let layer = ExportLayer(rawValue: words[1]) else {
            return configUsage
        }
        return exportConfiguration(context: context, layer: layer)
    }

    /// Renders the configuration as YAML, or the reason it could not render.
    /// Each secret shows as its `keychain:` reference or as the redacted
    /// form, such as a literal MCP header value.
    ///
    /// - Parameter configuration: The configuration to render.
    /// - Returns: The YAML, or the failure message.
    static func renderConfiguration(_ configuration: AgentConfiguration) -> String {
        do {
            return try ConfigurationYAML.documentText(for: configuration)
        } catch {
            return "The configuration could not be rendered: \(error)"
        }
    }

    /// Writes the effective configuration to a layer's `config.yaml`. It
    /// is the counterpart of `acp-agent instructions eject`: a file in a
    /// layer shadows each code-level default, so a change of behavior
    /// needs no rebuild.
    ///
    /// - Parameters:
    ///   - context: The session context.
    ///   - layer: The layer to write.
    /// - Returns: The confirmation, or the failure message.
    private static func exportConfiguration(
        context: BuiltinCommandContext, layer: ExportLayer
    ) -> String {
        let destination = layer.destination(in: context)
        do {
            let text = try ConfigurationYAML.documentText(
                for: context.configuration, secrets: .omitted)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return "Wrote the effective configuration to \(destination.path).\(omittedKeysNote)"
        } catch {
            return "Could not write the configuration: \(error)"
        }
    }

    // MARK: - /help

    /// The `/help` report: the registered commands, each with its argument
    /// hint and description.
    ///
    /// - Parameter context: The session context.
    /// - Returns: The command list.
    private static func helpText(context: BuiltinCommandContext) async -> String {
        guard let registry = context.binding?.registry else {
            return "No commands are registered."
        }
        var lines = ["Available commands:"]
        for command in await registry.commands {
            let hint = command.argumentHint.map { " \($0)" } ?? ""
            lines.append("/\(command.name)\(hint) — \(command.description)")
        }
        return lines.joined(separator: "\n")
    }
}
