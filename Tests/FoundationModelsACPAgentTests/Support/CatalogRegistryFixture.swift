import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool

@testable import FoundationModelsACPAgent

/// The shared build of the catalog registry of a session over one
/// working directory and one configuration. `FilesExcludeTests`,
/// `SandboxCompositionTests`, `TerminalStreamTests` and `TierTwoTests`
/// compose their tools through the same door, so the setup lives here
/// once, in the pattern of ``FilesVerbSupport``.
///
/// Each suite keeps its own configuration setup and gives the result to
/// this fixture.
enum CatalogRegistryFixture {
    /// The label of the throwaway cache directory of the stub profile.
    private static let cacheLabel = "CatalogRegistryFixture-cache"

    /// Builds the catalog registry of a session over `workingDirectory`
    /// with `configuration`, and returns all that the build gives.
    ///
    /// The stub profile gets a new cache directory for each build. The
    /// environment is empty, so the build does not read the API keys of
    /// the machine that runs the tests.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - configuration: The configuration under test.
    /// - Returns: The built registry, with its pool and its stream.
    /// - Throws: Whatever the profile resolve or the registry build throws.
    static func makeBuiltRegistry(
        workingDirectory: URL, configuration: AgentConfiguration
    ) async throws -> ToolCatalog.BuiltRegistry {
        let context = CatalogContext(
            workingDirectory: workingDirectory,
            configuration: configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: cacheLabel)),
            environment: [:])
        return try await ToolCatalog.makeRegistry(context: context)
    }

    /// Builds the catalog registry of a session over `workingDirectory`
    /// with `configuration`, and returns only the registry.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - configuration: The configuration under test.
    /// - Returns: The built registry.
    /// - Throws: Whatever the profile resolve or the registry build throws.
    static func makeRegistry(
        workingDirectory: URL, configuration: AgentConfiguration
    ) async throws -> MultiTool.Registry {
        try await makeBuiltRegistry(
            workingDirectory: workingDirectory, configuration: configuration
        ).registry
    }
}
