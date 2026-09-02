import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsSkills
import os

/// The logger of the command registry: merge wins, reserved-name drops,
/// and update-stream lifecycles.
let commandLogger = Logger(subsystem: RoutedACPAgent.implementation.name, category: "Commands")

/// The per-session slash-command registry (plan.md §14.1).
///
/// One registry is assembled at session creation, from three sources in
/// precedence order: the builtins, the linked `SlashCommandProviding`
/// conformers, and the skills. A later source wins a name collision,
/// and the win is logged — except that builtin names are reserved: a
/// later command with a builtin name is dropped, and the drop is
/// logged.
///
/// The registry follows each provider's `commandUpdates` stream. An
/// update replaces that provider's set wholesale, re-merges, and — once
/// ``beginPublishing(_:)`` set a publisher — publishes the new merged
/// set, which feeds `available_commands_update` (plan.md §14.4).
actor CommandRegistry {
    /// The reserved source-1 commands (plan.md §14.1). Their names can
    /// never be taken by a later source.
    private let builtins: [SlashCommand]

    /// The later sources, in precedence order: linked conformers first,
    /// skills last.
    private let providers: [any SlashCommandProviding]

    /// The session working directory each provider resolves against.
    private let workingDirectory: URL

    /// Each provider's current command set, index-aligned with
    /// ``providers``. Empty until ``load()`` ran.
    private var providerSets: [[SlashCommand]] = []

    /// The merged command set, in merge order: the builtins first, then
    /// each later source's new names in source order. A collision
    /// winner keeps the loser's position.
    private(set) var commands: [SlashCommand] = []

    /// The consumer of each merged-set publication, or `nil` before
    /// ``beginPublishing(_:)``.
    private var publisher: (@Sendable ([SlashCommand]) async -> Void)?

    /// The update-stream follower tasks, one per provider that has a
    /// `commandUpdates` stream.
    private var subscriptions: [Task<Void, Never>] = []

    /// Creates a registry over the three sources.
    ///
    /// - Parameters:
    ///   - builtins: The reserved source-1 commands.
    ///   - providers: The later sources, in precedence order.
    ///   - workingDirectory: The session working directory.
    init(builtins: [SlashCommand], providers: [any SlashCommandProviding], workingDirectory: URL) {
        self.builtins = builtins
        self.providers = providers
        self.workingDirectory = workingDirectory
    }

    deinit {
        for subscription in subscriptions {
            subscription.cancel()
        }
    }

    /// Loads each provider's initial command set, merges, and starts to
    /// follow each provider's `commandUpdates` stream. Call it one time,
    /// at session creation.
    func load() async {
        providerSets = []
        for provider in providers {
            providerSets.append(await provider.commands(workingDirectory: workingDirectory))
        }
        merge()
        subscribe()
    }

    /// Sets the publisher and publishes the current merged set at once.
    /// Every later provider update publishes again through the same
    /// publisher (plan.md §14.4).
    ///
    /// - Parameter publisher: The consumer of each merged-set
    ///   publication.
    func beginPublishing(_ publisher: @escaping @Sendable ([SlashCommand]) async -> Void) async {
        self.publisher = publisher
        await publisher(commands)
    }

    /// The merged command with `name`, or `nil` when no source offers
    /// it.
    ///
    /// - Parameter name: The bare command name, no leading slash.
    /// - Returns: The winning command, or `nil`.
    func command(named name: String) -> SlashCommand? {
        commands.first { $0.name == name }
    }

    /// The number of near-miss suggestions an unknown command names.
    private static let maxSuggestions = 3

    /// The largest edit distance a suggestion may have. A name farther
    /// from every command gives no suggestion.
    private static let maxSuggestionDistance = 3

    /// The merged command names closest to `name`, nearest first, for
    /// the unknown-command error (plan.md §14.3).
    ///
    /// - Parameter name: The unknown command name.
    /// - Returns: At most ``maxSuggestions`` names within
    ///   ``maxSuggestionDistance`` edits, ordered by distance and then
    ///   by name.
    func nearMisses(to name: String) -> [String] {
        commands
            .map { command in (name: command.name, distance: Self.editDistance(name, command.name)) }
            .filter { $0.distance <= Self.maxSuggestionDistance }
            .sorted { ($0.distance, $0.name) < ($1.distance, $1.name) }
            .prefix(Self.maxSuggestions)
            .map(\.name)
    }

    /// Maps a merged set to the wire's command list (plan.md §14.4):
    /// `name` and `description` map straight across, and the provider's
    /// argument-hint string passes through unchanged as the text
    /// input's `hint`.
    ///
    /// - Parameter commands: The merged set to map.
    /// - Returns: The wire command list, in the same order.
    static func availableCommands(for commands: [SlashCommand]) -> [AvailableCommand] {
        commands.map { command in
            AvailableCommand(
                description: command.description,
                name: command.name,
                input: command.argumentHint.map { .text(TextCommandInput(hint: $0)) })
        }
    }

    // MARK: - The merge (plan.md §14.1)

    /// Rebuilds ``commands`` from the builtins and the current provider
    /// sets. Logs every collision win and every reserved-name drop.
    private func merge() {
        var positions: [String: Int] = [:]
        var merged: [SlashCommand] = []
        for builtin in builtins {
            guard positions[builtin.name] == nil else {
                commandLogger.error(
                    "duplicate builtin /\(builtin.name, privacy: .public) dropped")
                continue
            }
            positions[builtin.name] = merged.count
            merged.append(builtin)
        }
        let reservedNames = Set(positions.keys)
        for set in providerSets {
            for command in set {
                if reservedNames.contains(command.name) {
                    commandLogger.notice(
                        "/\(command.name, privacy: .public) is a reserved builtin name; the later command is dropped"
                    )
                    continue
                }
                if let position = positions[command.name] {
                    commandLogger.notice(
                        "/\(command.name, privacy: .public) collided; the later source wins")
                    merged[position] = command
                } else {
                    positions[command.name] = merged.count
                    merged.append(command)
                }
            }
        }
        commands = merged
    }

    /// Starts one follower task per provider with a `commandUpdates`
    /// stream. Each pushed set replaces that provider's slot wholesale
    /// (plan.md §14.4).
    private func subscribe() {
        for (index, provider) in providers.enumerated() {
            guard let updates = provider.commandUpdates else { continue }
            subscriptions.append(
                Task { [weak self] in
                    for await set in updates {
                        guard let self else { return }
                        await self.replaceSet(at: index, with: set)
                    }
                })
        }
    }

    /// Replaces one provider's set, re-merges, and publishes.
    ///
    /// - Parameters:
    ///   - index: The provider's position in ``providers``.
    ///   - set: The pushed replacement set.
    private func replaceSet(at index: Int, with set: [SlashCommand]) async {
        providerSets[index] = set
        merge()
        if let publisher {
            await publisher(commands)
        }
    }

    // MARK: - The edit distance

    /// The Levenshtein distance between two names, for the near-miss
    /// search.
    ///
    /// - Parameters:
    ///   - left: The first name.
    ///   - right: The second name.
    /// - Returns: The number of single-character edits that turn one
    ///   name into the other.
    static func editDistance(_ left: String, _ right: String) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var previousRow = Array(0...rightCharacters.count)
        for (leftIndex, leftCharacter) in leftCharacters.enumerated() {
            var currentRow = [leftIndex + 1]
            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                let substitution = previousRow[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = currentRow[rightIndex] + 1
                let deletion = previousRow[rightIndex + 1] + 1
                currentRow.append(min(substitution, insertion, deletion))
            }
            previousRow = currentRow
        }
        return previousRow[rightCharacters.count]
    }
}

// MARK: - The skills source (plan.md §14.2)

/// The skills source of the registry: `SkillsRegistry`'s own
/// `SlashCommandProviding` conformance, with one temporary correction.
///
/// TEMPORARY SPECIAL CASE. Skills' conformance still emits
/// `.prompt(template:)` carrying the skill's raw, unrendered body. The
/// harness template engine would render only its own pass, so Skills'
/// `$`-argument substitution and shell-injection passes would never run
/// (plan.md §14.2, gap 1). This source therefore replaces each `.prompt`
/// skill body with a `.rendered` body that runs
/// `registry.call(id:arguments:)` — synchronous, throwing — which runs
/// all three render passes. Remove this wrap when Skills emits
/// `.rendered` itself (upstream adoption `c2pad49`, plan.md §21): the
/// pass-through arm below already forwards a `.rendered` body unchanged.
struct SkillCommandSource: SlashCommandProviding {
    /// The session's skills registry, built with `watch: true` so
    /// `commandUpdates` is non-nil (plan.md §14.1, source 3).
    let registry: SkillsRegistry

    /// The registry's user-invocable skills, one `/id` command each,
    /// with the temporary `.rendered` wrap applied.
    ///
    /// - Parameter workingDirectory: The session working directory.
    /// - Returns: The wrapped command set.
    func commands(workingDirectory: URL) async -> [SlashCommand] {
        await registry.commands(workingDirectory: workingDirectory).map(routed(_:))
    }

    /// The registry's pushed re-publications, each set wrapped the same
    /// way. `nil` when the registry was built with `watch: false`.
    var commandUpdates: AsyncStream<[SlashCommand]>? {
        guard let updates = registry.commandUpdates else { return nil }
        let (stream, continuation) = AsyncStream<[SlashCommand]>.makeStream()
        let source = self
        let bridge = Task {
            for await set in updates {
                continuation.yield(set.map(source.routed(_:)))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridge.cancel() }
        return stream
    }

    /// Applies the temporary wrap to one skill command: a `.prompt`
    /// body becomes a `.rendered` body that runs
    /// `registry.call(id:arguments:)`. Any other body passes through
    /// unchanged — that arm is what makes the wrap removable once
    /// Skills emits `.rendered` itself.
    ///
    /// - Parameter command: The skill command to wrap.
    /// - Returns: The wrapped command.
    private func routed(_ command: SlashCommand) -> SlashCommand {
        guard case .prompt = command.body else { return command }
        let registry = registry
        let id = command.name
        var wrapped = command
        wrapped.body = .rendered { invocation in
            try registry.call(id: id, arguments: Self.splitArguments(invocation.arguments))
        }
        return wrapped
    }

    /// Splits the raw invocation text into the positional argument list
    /// `registry.call(id:arguments:)` takes: whitespace-separated
    /// words, empty words dropped.
    ///
    /// - Parameter raw: The raw text after `/name `.
    /// - Returns: The positional arguments.
    static func splitArguments(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
