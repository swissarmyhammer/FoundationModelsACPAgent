import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The composition matrix of `ToolCatalog` (plan.md §11.1–§11.4): the
/// session tools a default context mounts, the enable and disable codec,
/// the root-set confinement of the files verbs, and the watched skills
/// registry.
///
/// The per-verb argument and output structs of the capability modules are
/// internal upstream, so composition is asserted through the built
/// `APISurface.entries` paths, and a verb is exercised through the public
/// `ToolInvoker.invoke(_:content:)` door with its wire JSON.
@Suite struct ToolCatalogTests {
    /// The mount order a default context gives the model: the three
    /// Multitool session tools, then the appended standalone skills tool.
    private static let defaultToolNames = ["searchTools", "runCode", "wait", "skills"]

    /// The mount order with the skills section disabled: the Multitool
    /// session tools alone.
    private static let multitoolOnlyNames = ["searchTools", "runCode", "wait"]

    /// The surface path of the files read verb.
    private static let readVerbPath = FilesVerbSupport.readVerbPath

    /// The surface path of the shell execute verb.
    private static let executeVerbPath = "shell.execute"

    /// The noun the files capability owns on the surface.
    private static let filesNoun = "files"

    /// The noun the shell capability owns on the surface.
    private static let shellNoun = "shell"

    // MARK: Harness

    /// Makes a fresh throwaway directory and returns its URL.
    ///
    /// - Parameter label: The suffix that names the directory's role.
    /// - Returns: The created directory.
    /// - Throws: Whatever directory creation throws.
    private static func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolCatalogTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Makes a catalog context over a fresh working directory and a stub
    /// profile.
    ///
    /// - Parameters:
    ///   - additionalRoots: The session's additional roots, in order.
    ///   - configure: The mutation that shapes the configuration under
    ///     test. The default keeps every section at its default.
    /// - Returns: The context under test.
    /// - Throws: Whatever the directory creation or the profile resolve
    ///   throws.
    private static func makeContext(
        additionalRoots: [URL] = [],
        configure: (inout AgentConfiguration) -> Void = { _ in }
    ) async throws -> CatalogContext {
        var configuration = AgentConfiguration()
        configure(&configuration)
        return CatalogContext(
            workingDirectory: try makeTemporaryDirectory(label: "work"),
            additionalRoots: additionalRoots,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: try makeTemporaryDirectory(label: "cache")))
    }

    /// Invokes `tools.files.read` on `path` and decodes the wire result
    /// through the shared ``FilesVerbSupport`` helper.
    ///
    /// - Parameters:
    ///   - registry: The built registry whose read verb to invoke.
    ///   - path: The path argument to read.
    /// - Returns: The decoded wire result.
    /// - Throws: Whatever the invocation or the decode throws.
    private static func invokeRead(
        in registry: MultiTool.Registry, path: String
    ) async throws -> FilesVerbSupport.ReadVerbResult {
        try await FilesVerbSupport.invokeRead(
            try #require(registry.tools[readVerbPath]), path: path)
    }

    // MARK: The session tools

    @Test func aDefaultContextMountsTheFourSessionTools() async throws {
        let context = try await Self.makeContext()

        let surface = try await ToolCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == Self.defaultToolNames)
    }

    @Test func aDisabledSkillsSectionAppendsNoSkillsTool() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.skills = .disabled
        }

        let surface = try await ToolCatalog.sessionSurface(context: context)

        #expect(surface.tools.map(\.name) == Self.multitoolOnlyNames)
    }

    // MARK: The built surface

    @Test func aDefaultRegistrySurfacesTheFilesAndShellNouns() async throws {
        let context = try await Self.makeContext()

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        let paths = registry.surface.entries.map(\.path)
        #expect(paths.contains(Self.readVerbPath))
        #expect(paths.contains(Self.executeVerbPath))
    }

    @Test func aDisabledShellSectionYieldsNoShellNamespace() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.shell = .disabled
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.shellNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.readVerbPath })
    }

    @Test func aDisabledFilesSectionYieldsNoFilesNamespace() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.files = .disabled
        }

        let registry = try await ToolCatalog.makeRegistry(context: context).registry

        #expect(!registry.surface.entries.contains { $0.group == Self.filesNoun })
        #expect(registry.surface.entries.contains { $0.path == Self.executeVerbPath })
    }

    // MARK: Root-set confinement

    @Test func theReadVerbRefusesAPathOutsideTheRootSet() async throws {
        let context = try await Self.makeContext()
        let outside = try Self.makeTemporaryDirectory(label: "outside")
            .appendingPathComponent("secret.txt")
        try "outside the roots".write(to: outside, atomically: true, encoding: .utf8)

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let result = try await Self.invokeRead(in: registry, path: outside.path)

        #expect(result.correction != nil)
        #expect(result.lines.isEmpty)
    }

    @Test func theReadVerbAcceptsAPathInAnAdditionalRoot() async throws {
        let additionalRoot = try Self.makeTemporaryDirectory(label: "additional")
        let insideFile = additionalRoot.appendingPathComponent("inside.txt")
        try "inside the additional root".write(to: insideFile, atomically: true, encoding: .utf8)
        let context = try await Self.makeContext(additionalRoots: [additionalRoot])

        let registry = try await ToolCatalog.makeRegistry(context: context).registry
        let result = try await Self.invokeRead(in: registry, path: insideFile.path)

        #expect(result.correction == nil)
        #expect(!result.lines.isEmpty)
    }

    // MARK: The skills registry

    @Test func theSkillsRegistryWatchesForCommandUpdates() async throws {
        let context = try await Self.makeContext()

        let registry = try #require(ToolCatalog.makeSkillsRegistry(context: context))

        #expect(registry.commandUpdates != nil)
    }

    @Test func aDisabledSkillsSectionBuildsNoSkillsRegistry() async throws {
        let context = try await Self.makeContext { configuration in
            configuration.tools.skills = .disabled
        }

        #expect(ToolCatalog.makeSkillsRegistry(context: context) == nil)
    }
}
