import Foundation
import FoundationModelsExtras

@testable import FoundationModelsACPAgent

// MARK: - The stub command sources (plan.md §20.1)
//
// `CommandRegistryTests` and `CommandDispatchTests` drive the registry
// with the same stub conformers. This file owns the stub provider, the
// command factories for the three body kinds, and the skill fixture
// writer, so a suite adds assertions and does not copy the setup.

/// A slash-command provider with a fixed command set and an optional
/// pushed update stream. The command suites use it as the code-backed
/// lane (plan.md §14.1, source 2).
struct StubCommandProvider: SlashCommandProviding {
    /// The fixed set that `commands(workingDirectory:)` returns.
    let commandSet: [SlashCommand]

    /// The pushed re-publications, or `nil` for a static provider.
    let updates: AsyncStream<[SlashCommand]>?

    /// Creates a stub provider.
    ///
    /// - Parameters:
    ///   - commandSet: The fixed set to return.
    ///   - updates: The pushed re-publications. Defaults to `nil`.
    init(commandSet: [SlashCommand], updates: AsyncStream<[SlashCommand]>? = nil) {
        self.commandSet = commandSet
        self.updates = updates
    }

    func commands(workingDirectory: URL) async -> [SlashCommand] {
        commandSet
    }

    var commandUpdates: AsyncStream<[SlashCommand]>? {
        updates
    }
}

/// Makes an `.action` command that streams `output` as one text chunk.
///
/// - Parameters:
///   - name: The command name.
///   - output: The one text chunk the action streams.
/// - Returns: The command.
func makeActionCommand(name: String, output: String) -> SlashCommand {
    SlashCommand(
        name: name,
        description: "streams \(output)",
        body: .action { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(output)
                continuation.finish()
            }
        })
}

/// Makes a `.rendered` command that returns `prefix` followed by the
/// raw invocation arguments.
///
/// - Parameters:
///   - name: The command name.
///   - prefix: The text put before the arguments.
/// - Returns: The command.
func makeRenderedCommand(name: String, prefix: String) -> SlashCommand {
    SlashCommand(
        name: name,
        description: "renders \(prefix)",
        body: .rendered { invocation in
            prefix + invocation.arguments
        })
}

/// Writes `<id>/SKILL.md` under `root`, so a `SkillsRegistry` over
/// `root` discovers one skill with that id.
///
/// - Parameters:
///   - id: The skill id — the directory name.
///   - markdown: The complete `SKILL.md` content, frontmatter included.
///   - root: The skills root directory.
/// - Throws: A file-system error when the write fails.
func writeSkillFixture(id: String, markdown: String, under root: URL) throws {
    let skillDirectory = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try markdown.write(
        to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

/// The `SKILL.md` content of the `greet` fixture skill. The body keeps
/// a `$1` token, so a rendered result proves that Skills' argument pass
/// ran (plan.md §14.2, gap 1).
let greetSkillMarkdown = """
    ---
    name: greet
    description: Greets the second argument.
    arguments:
      - first
      - second
    ---
    Hello $1.
    """
