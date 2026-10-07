import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The `tools.files.exclude` list of the composed files capability (task
/// ^t30r8aj): with the default configuration of the CLI, the search verbs
/// `files.grep` and `files.glob` do not give a path under the dotfolder
/// `.acp-agent/`, which holds the transcripts of the agent. With
/// `exclude: []` the old behavior returns.
///
/// Each test composes the files capability through
/// ``CatalogRegistryFixture`` with a configuration that the CLI loader
/// gives, and calls each verb through its public wire door.
@Suite struct FilesExcludeTests {
    /// The text that each file of the workspace holds, and the pattern that
    /// grep searches for.
    private static let needle = "transcript-needle"

    /// The glob pattern that matches each file of the workspace. It names
    /// the file, because the glob verb refuses the broad `**/*.<ext>` shape
    /// over the whole session root.
    private static let jsonlGlob = "**/x.jsonl"

    /// The relative path of the recorded transcript in the workspace.
    private static let transcriptPath = ".\(AgentComposition.dotfolderName)/transcripts/x.jsonl"

    /// The relative path of a source file in the workspace, which each
    /// search must give.
    private static let sourcePath = "src/x.jsonl"

    // MARK: - Harness

    /// Makes a workspace that holds a recorded transcript and a source
    /// file, each with ``needle`` in it.
    ///
    /// - Returns: The workspace root.
    /// - Throws: The directory-creation or write error.
    private static func makeWorkspace() throws -> URL {
        let workspace = makeResolvedDirectory(label: "FilesExcludeTests-workspace")
        for path in [transcriptPath, sourcePath] {
            let file = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\"text\":\"\(needle)\"}\n".write(to: file, atomically: true, encoding: .utf8)
        }
        return workspace
    }

    /// Loads the configuration of `workspace` through the CLI loader, with
    /// an empty user layer. Only the files capability stays on, so the
    /// build starts no code context, no shell and no MCP server.
    ///
    /// - Parameters:
    ///   - workspace: The workspace whose project layer the loader reads.
    ///   - projectConfig: The project `config.yaml`, or `nil` for no file.
    /// - Returns: The loaded configuration.
    /// - Throws: The write or the load error.
    private static func loadConfiguration(
        of workspace: URL, projectConfig: String? = nil
    ) throws -> AgentConfiguration {
        if let projectConfig {
            let directory = workspace.appendingPathComponent(
                ".\(AgentComposition.dotfolderName)", isDirectory: true)
            try ConfigFileFixture.write(projectConfig, in: directory)
        }
        let configHome = makeResolvedDirectory(label: "FilesExcludeTests-config")
        var configuration = try AgentComposition.makeConfigurationLoader(
            workingDirectory: workspace,
            environment: [ConfigCommandFixture.configHomeVariable: configHome.path]
        ).load().configuration
        configuration.tools.shell = .disabled
        configuration.tools.codeContext = .disabled
        configuration.tools.web = .disabled
        configuration.tools.mcp = .disabled
        return configuration
    }

    // MARK: - The default list

    /// With the default configuration, `files.grep` gives the source file
    /// and not the transcript under `.acp-agent/`.
    @Test func theDefaultConfigurationKeepsTheTranscriptOutOfGrep() async throws {
        let workspace = try Self.makeWorkspace()
        let registry = try await CatalogRegistryFixture.makeRegistry(
            workingDirectory: workspace, configuration: try Self.loadConfiguration(of: workspace))

        let result = try await FilesVerbSupport.invokeGrep(in: registry, pattern: Self.needle)

        #expect(result.correction == nil)
        #expect(result.files == [Self.sourcePath])
    }

    /// With the default configuration, `files.glob` gives the source file
    /// and not the transcript under `.acp-agent/`.
    @Test func theDefaultConfigurationKeepsTheTranscriptOutOfGlob() async throws {
        let workspace = try Self.makeWorkspace()
        let registry = try await CatalogRegistryFixture.makeRegistry(
            workingDirectory: workspace, configuration: try Self.loadConfiguration(of: workspace))

        let result = try await FilesVerbSupport.invokeGlob(in: registry, pattern: Self.jsonlGlob)

        #expect(result.correction == nil)
        #expect(result.files == [Self.sourcePath])
    }

    // MARK: - The empty list

    /// With `tools.files.exclude: []`, the old behavior returns: grep and
    /// glob each give the transcript beside the source file.
    @Test func anEmptyExcludeListGivesTheTranscriptAgain() async throws {
        let workspace = try Self.makeWorkspace()
        let configuration = try Self.loadConfiguration(
            of: workspace, projectConfig: "tools:\n  files:\n    exclude: []\n")
        let registry = try await CatalogRegistryFixture.makeRegistry(
            workingDirectory: workspace, configuration: configuration)

        let grep = try await FilesVerbSupport.invokeGrep(in: registry, pattern: Self.needle)
        let glob = try await FilesVerbSupport.invokeGlob(in: registry, pattern: Self.jsonlGlob)

        #expect(Set(grep.files ?? []) == [Self.transcriptPath, Self.sourcePath])
        #expect(Set(glob.files ?? []) == [Self.transcriptPath, Self.sourcePath])
    }
}
