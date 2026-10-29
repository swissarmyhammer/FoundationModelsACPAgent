import ArgumentParser
import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter
import Testing

@testable import acp_agent

/// The discoverability obligation of the compiled-in instructions floor:
/// the README points a reader at the one copy of the builtin instructions
/// text. The README does not repeat the text — a second copy is a copy that
/// goes stale — so what this suite protects is the link, not the prose.
///
/// The suite carries the same obligation for the three things a person
/// needs before the first run (cli-plan.md §5.3 and §7): the command tree,
/// the default models of the profile, and the memory floor. Each of those
/// is read from the code, never repeated here, so a change to the code
/// with no change to the README fails a test.
@Suite struct DocumentationSyncTests {
    /// The repository root, found relative to this source file.
    static var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FoundationModelsACPAgentTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // the repository root
    }

    /// The repository's `README.md`.
    static var readmeURL: URL {
        repositoryRootURL.appendingPathComponent("README.md")
    }

    /// The text of the README, which every test of this suite reads.
    ///
    /// - Returns: The whole file, as UTF-8.
    /// - Throws: The read error, when the file is absent or is not UTF-8.
    static func readmeText() throws -> String {
        try String(contentsOf: readmeURL, encoding: .utf8)
    }

    /// The repository-relative path of the one copy of the builtin
    /// instructions text — the link target the README must carry.
    static let builtinInstructionsPath =
        "Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift"

    /// The heading of the README's tool roster section. Step 3 of the
    /// `ToolCatalog` contract adds a row to this section for each new
    /// capability.
    static let toolsHeading = "## Tools"

    /// The README links to the builtin instructions source, and that path
    /// resolves. A moved or renamed file fails here, at the link, instead
    /// of silently leaving the README pointing at nothing.
    @Test func readmeLinksToTheBuiltinInstructionsSource() throws {
        let readme = try Self.readmeText()

        #expect(readme.contains(Self.builtinInstructionsPath))
        #expect(
            FileManager.default.fileExists(
                atPath: Self.repositoryRootURL
                    .appendingPathComponent(Self.builtinInstructionsPath).path))
    }

    /// The README does not repeat the builtin instructions text. One copy
    /// only: the source file the link names.
    @Test func readmeDoesNotRepeatTheBuiltinInstructionsText() throws {
        let readme = try Self.readmeText()

        #expect(!readme.contains(BuiltinInstructions.text))
    }

    // MARK: - The links

    /// The schemes of a README link that goes out of the repository, in
    /// lowercase. A link with one of these prefixes is not a repository
    /// path. A URI scheme is case-insensitive (RFC 3986), thus the
    /// comparison lowercases the link target first.
    static let externalLinkPrefixes = ["http://", "https://", "mailto:", "#"]

    /// The repository-relative target of each Markdown link in `markdown`
    /// that names a repository path. An external link, and the fragment of a
    /// link, are not part of a path.
    ///
    /// - Parameter markdown: The Markdown text to read.
    /// - Returns: Each relative link target, in document order.
    static func relativeLinkTargets(in markdown: String) -> [String] {
        markdown.matches(of: /\]\(([^)\s]+)\)/).map { String($0.output.1) }
            .filter { target in
                let lowercasedTarget = target.lowercased()
                return !externalLinkPrefixes.contains { lowercasedTarget.hasPrefix($0) }
            }
            .map { target in
                String(target.prefix { $0 != "#" })
            }
    }

    /// A URI scheme is case-insensitive (RFC 3986), so a link with an
    /// uppercase or a mixed-case scheme is external too. Only the
    /// repository path stays.
    @Test func relativeLinkTargetsDropsAnUppercaseOrMixedCaseScheme() {
        let markdown = "[a](HTTPS://example.com) [b](Mailto:someone@example.com) [c](README.md)"

        #expect(Self.relativeLinkTargets(in: markdown) == ["README.md"])
    }

    /// Each relative link of the README names a file or a folder that
    /// exists. A deleted or moved document fails here, so the README never
    /// points a reader at nothing.
    @Test func readmeRelativeLinksResolve() throws {
        let targets = Self.relativeLinkTargets(in: try Self.readmeText())

        #expect(!targets.isEmpty, "README has no relative link to check")
        for target in targets {
            #expect(
                FileManager.default.fileExists(
                    atPath: Self.repositoryRootURL.appendingPathComponent(target).path),
                "README links to \(target), which does not exist")
        }
    }

    /// Step 3 of the `ToolCatalog` contract: the README's `## Tools`
    /// table names every capability of the roster. The roster is
    /// `ToolsConfiguration.CodingKeys`, the same list the config codec
    /// decodes, so a new roster entry fails this test until the table
    /// gains its row.
    @Test func readmeToolsTableNamesEveryCapability() throws {
        let readme = try Self.readmeText()

        #expect(readme.contains(Self.toolsHeading))
        for capability in ToolsConfiguration.CodingKeys.allCases {
            #expect(
                readme.contains("| `\(capability.stringValue)` |"),
                "README § Tools has no row for \(capability.stringValue)")
        }
    }

    // MARK: - The profile

    /// The memory floor of the default profile (cli-plan.md §7), as the
    /// README spells it. The figure lives in the doc comment of
    /// ``ProfileConfiguration``, thus this string is the one assertion
    /// that keeps the README saying it.
    static let memoryFloorText = "32 GB"

    /// Every model the default profile names, over the three slots, in
    /// slot order, and the MTP drafter of each reference that names one.
    /// The list is the `ProfileConfiguration` statics, so a changed default
    /// fails the README test until the README changes too.
    static var defaultProfileModels: [String] {
        (ProfileConfiguration.defaultStandard + ProfileConfiguration.defaultFlash
            + ProfileConfiguration.defaultEmbedding).flatMap { reference in
                [reference.stringValue] + (reference.drafter.map { [$0.stringValue] } ?? [])
            }
    }

    /// The README names all three default model ids, exactly as
    /// ``ProfileConfiguration`` gives them.
    @Test func readmeNamesEveryDefaultProfileModel() throws {
        let readme = try Self.readmeText()

        for model in Self.defaultProfileModels {
            #expect(readme.contains(model), "README names no model \(model)")
        }
    }

    /// The README states the memory floor of the default profile. A person
    /// who reads the README before the first run learns which machine the
    /// three models fit on.
    @Test func readmeStatesTheMemoryFloor() throws {
        let readme = try Self.readmeText()

        #expect(readme.contains(Self.memoryFloorText))
    }

    // MARK: - The command tree

    /// The invocation of every command of the tree, root included, each as
    /// the words a person types.
    ///
    /// The walk reads `AcpAgentCommand.configuration`, which is the tree
    /// the binary parses, so a new subcommand joins this list on the day
    /// it ships and fails ``readmeNamesEveryCommandOfTheTree()`` until the
    /// README documents it.
    static var commandInvocations: [String] {
        invocations(of: AcpAgentCommand.self, prefix: []).map {
            $0.joined(separator: " ")
        }
    }

    /// The invocation words of `command` and of every command under it.
    ///
    /// - Parameters:
    ///   - command: The command to walk.
    ///   - prefix: The words of the commands above `command`.
    /// - Returns: One word list for `command`, then one for each command
    ///   under it, depth first.
    static func invocations(
        of command: any ParsableCommand.Type, prefix: [String]
    ) -> [[String]] {
        let path = prefix + [name(of: command)]
        return [path]
            + command.configuration.subcommands.flatMap {
                invocations(of: $0, prefix: path)
            }
    }

    /// The word a person types for `command`: its declared command name,
    /// or the lowercased type name the parser falls back to when a command
    /// declares none.
    ///
    /// - Parameter command: The command to name.
    /// - Returns: The one word of the invocation.
    static func name(of command: any ParsableCommand.Type) -> String {
        command.configuration.commandName ?? String(describing: command).lowercased()
    }

    /// The README documents every command of the tree (cli-plan.md §5.3).
    /// A subcommand cannot ship undocumented: it joins
    /// ``commandInvocations`` and fails here.
    @Test func readmeNamesEveryCommandOfTheTree() throws {
        let readme = try Self.readmeText()

        for invocation in Self.commandInvocations {
            #expect(readme.contains(invocation), "README documents no `\(invocation)`")
        }
    }
}
