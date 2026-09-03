import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The registry merge and its sources (plan.md §14.1): the precedence
/// order, the reserved builtin names, the skills wrap, the pushed
/// updates, the near-miss search, and the wire mapping.
struct CommandRegistryTests {
    /// The number of looks a wait makes before it records a failure.
    private static let maxPollAttempts = 500

    /// The number of milliseconds between two looks.
    private static let pollIntervalMilliseconds = 20

    /// A collector of published command sets, so a test observes each
    /// publication in arrival order.
    private actor PublicationCollector {
        /// The published sets, in arrival order.
        private(set) var publications: [[SlashCommand]] = []

        /// Appends one published set.
        ///
        /// - Parameter commands: The published set.
        func append(_ commands: [SlashCommand]) {
            publications.append(commands)
        }
    }

    /// Polls until `condition` is true, then returns. Records a failure
    /// when the condition never holds.
    ///
    /// - Parameters:
    ///   - label: What the wait is for, named in the failure.
    ///   - condition: The acceptance test.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func wait(
        for label: String, _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<maxPollAttempts {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
        }
        Issue.record("the registry never reached: \(label)")
    }

    // MARK: - Precedence and reserved builtins (plan.md §14.1)

    /// A provider command that collides with a builtin name loses, and
    /// the builtin still dispatches.
    @Test(.timeLimit(.minutes(1)))
    func aBuiltinNameIsReservedAgainstALaterProvider() async throws {
        let builtin = makeActionCommand(name: "status", output: "BUILTIN STATUS")
        let provider = StubCommandProvider(commandSet: [
            SlashCommand(name: "status", description: "provider status", body: .prompt(template: "x"))
        ])
        let registry = CommandRegistry(
            builtins: [builtin],
            providers: [provider],
            workingDirectory: makeResolvedDirectory(label: "CommandRegistryTests-reserved"))
        await registry.load()

        let commands = await registry.commands
        #expect(commands.count(where: { $0.name == "status" }) == 1)
        let winner = try #require(await registry.command(named: "status"))
        #expect(winner.description == builtin.description)

        // The builtin still dispatches: its action streams its text.
        guard case .action(let action) = winner.body else {
            Issue.record("expected the builtin .action body, got \(winner.body)")
            return
        }
        let invocation = SlashCommand.Invocation(
            arguments: "", workingDirectory: URL(fileURLWithPath: "/", isDirectory: true))
        var streamed = ""
        for try await text in action(invocation) {
            streamed += text
        }
        #expect(streamed == "BUILTIN STATUS")
    }

    /// A later source wins a name collision, and the merged set keeps
    /// one entry for the name.
    @Test(.timeLimit(.minutes(1)))
    func aLaterSourceWinsANameCollision() async throws {
        let first = StubCommandProvider(commandSet: [
            SlashCommand(name: "deploy", description: "first source", body: .prompt(template: "a"))
        ])
        let second = StubCommandProvider(commandSet: [
            SlashCommand(name: "deploy", description: "second source", body: .prompt(template: "b"))
        ])
        let registry = CommandRegistry(
            builtins: [],
            providers: [first, second],
            workingDirectory: makeResolvedDirectory(label: "CommandRegistryTests-collision"))
        await registry.load()

        let commands = await registry.commands
        #expect(commands.count(where: { $0.name == "deploy" }) == 1)
        let winner = try #require(await registry.command(named: "deploy"))
        #expect(winner.description == "second source")
    }

    // MARK: - The skills source (plan.md §14.2)

    /// The skills source wraps a `.prompt` skill command in a
    /// `.rendered` body that runs `registry.call(id:arguments:)`, so
    /// the `$`-argument pass runs.
    @Test(.timeLimit(.minutes(1)))
    func theSkillsSourceRoutesThroughRegistryCall() async throws {
        let root = makeResolvedDirectory(label: "CommandRegistryTests-skills")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkillFixture(id: "greet", markdown: greetSkillMarkdown, under: root)

        let registry = CommandRegistry(
            builtins: [],
            providers: [SkillCommandSource(registry: SkillsRegistry(roots: [root]))],
            workingDirectory: root)
        await registry.load()

        let greet = try #require(await registry.command(named: "greet"))
        guard case .rendered(let render) = greet.body else {
            Issue.record("expected the skills wrap to give a .rendered body, got \(greet.body)")
            return
        }
        let rendered = try await render(
            SlashCommand.Invocation(arguments: "alpha beta", workingDirectory: root))
        #expect(rendered.contains("Hello beta."))
    }

    // MARK: - Pushed updates (plan.md §14.4)

    /// A provider update replaces that provider's set, re-merges, and
    /// publishes the new merged set.
    @Test(.timeLimit(.minutes(1)))
    func aProviderUpdateReplacesItsSetAndPublishes() async throws {
        let (stream, continuation) = AsyncStream<[SlashCommand]>.makeStream()
        let provider = StubCommandProvider(
            commandSet: [makeRenderedCommand(name: "old", prefix: "OLD ")],
            updates: stream)
        let registry = CommandRegistry(
            builtins: [],
            providers: [provider],
            workingDirectory: makeResolvedDirectory(label: "CommandRegistryTests-updates"))
        await registry.load()
        #expect(await registry.command(named: "old") != nil)

        let collector = PublicationCollector()
        await registry.beginPublishing { commands in
            await collector.append(commands)
        }
        // The initial publication carries the current merged set.
        try await Self.wait(for: "the initial publication") {
            await collector.publications.count >= 1
        }
        #expect(await collector.publications.first?.map(\.name) == ["old"])

        continuation.yield([makeRenderedCommand(name: "new", prefix: "NEW ")])
        try await Self.wait(for: "the pushed replacement") {
            await registry.command(named: "new") != nil
        }
        #expect(await registry.command(named: "old") == nil)
        try await Self.wait(for: "the replacement publication") {
            await collector.publications.contains { $0.map(\.name) == ["new"] }
        }
        continuation.finish()
    }

    // MARK: - Near misses (plan.md §14.3)

    /// The near-miss search names the closest command first.
    @Test(.timeLimit(.minutes(1)))
    func nearMissesNameTheClosestCommandFirst() async throws {
        let provider = StubCommandProvider(commandSet: [
            makeRenderedCommand(name: "deploy", prefix: ""),
            makeRenderedCommand(name: "status", prefix: ""),
            makeRenderedCommand(name: "help", prefix: ""),
        ])
        let registry = CommandRegistry(
            builtins: [],
            providers: [provider],
            workingDirectory: makeResolvedDirectory(label: "CommandRegistryTests-nearmiss"))
        await registry.load()

        #expect(await registry.nearMisses(to: "depoly").first == "deploy")
        #expect(await registry.nearMisses(to: "helq").first == "help")
    }

    /// A name far from every command gives no suggestion.
    @Test(.timeLimit(.minutes(1)))
    func aFarNameGivesNoSuggestion() async throws {
        let provider = StubCommandProvider(commandSet: [
            makeRenderedCommand(name: "deploy", prefix: "")
        ])
        let registry = CommandRegistry(
            builtins: [],
            providers: [provider],
            workingDirectory: makeResolvedDirectory(label: "CommandRegistryTests-far"))
        await registry.load()

        #expect(await registry.nearMisses(to: "qqqqqqqqqqqq").isEmpty)
    }

    // MARK: - The wire mapping (plan.md §14.4)

    /// The wire mapping passes the argument-hint string through as the
    /// text input's hint, unchanged.
    @Test
    func availableCommandsPassTheArgumentHintThrough() {
        let hinted = SlashCommand(
            name: "greet",
            description: "greets",
            argumentHint: "<env> [region]",
            body: .prompt(template: "x"))
        let bare = SlashCommand(name: "help", description: "helps", body: .prompt(template: "y"))

        let available = CommandRegistry.availableCommands(for: [hinted, bare])
        #expect(available.map(\.name) == ["greet", "help"])
        #expect(available.map(\.description) == ["greets", "helps"])
        #expect(available[0].input == .text(TextCommandInput(hint: "<env> [region]")))
        #expect(available[1].input == nil)
    }
}
