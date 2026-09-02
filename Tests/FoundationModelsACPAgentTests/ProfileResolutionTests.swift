import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter
import Testing

/// The error the failing loader throws, with one fixed readable message a
/// test can look for in the reported error.
struct ScriptedLoadFailure: Error, CustomStringConvertible {
    /// The one message every scripted failure carries.
    static let message = "the scripted loader refuses to load"

    var description: String { Self.message }
}

/// A loader that fails every load, so a test observes the error report of
/// the resolve path. It downloads nothing and touches no network.
struct FailingModelLoader: ModelLoader {
    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        throw ScriptedLoadFailure()
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        throw ScriptedLoadFailure()
    }

    func preload(container: any LoadedModelContainer) async throws {}
}

/// Profile resolution (plan.md §1, §2.1, §2.2): the mapping from the
/// `profile` config section to Router's `ProfileDefinition`, the dotfolder
/// name fallback, the resolution at agent construction over a scripted
/// loader, the readable failure report, and the strongly held resident
/// profile.
@Suite struct ProfileResolutionTests {
    /// The dotfolder name each test maps and resolves against.
    static let dotfolderWord = "coding"

    /// The validated dotfolder name of ``dotfolderWord``.
    ///
    /// - Returns: The validated name.
    /// - Throws: `DotfolderNameError` when ``dotfolderWord`` is refused.
    static func makeDotfolderName() throws -> DotfolderName {
        try DotfolderName(dotfolderWord)
    }

    /// A throwaway cache directory for one router.
    ///
    /// - Parameter role: The directory's role inside this suite.
    /// - Returns: The created directory.
    private static func makeCacheDirectory(role: String) -> URL {
        makeResolvedDirectory(label: "ProfileResolutionTests-\(role)")
    }

    /// An agent through the shared `makeStubAgent` factory, constructed
    /// with the in-code default configuration.
    ///
    /// - Parameter loader: The loader the router loads through.
    /// - Returns: The constructed agent.
    /// - Throws: Whatever agent construction throws.
    private static func makeAgent(
        loader: any ModelLoader = StubModelLoader()
    ) async throws -> RoutedACPAgent {
        try await makeStubAgent(
            name: dotfolderWord,
            cacheDirectory: makeCacheDirectory(role: "cache"),
            loader: loader)
    }

    // MARK: - The mapping matrix

    /// With no configured `profile.name`, the definition's name falls back
    /// to the dotfolder name (plan.md §2.1).
    @Test func defaultNameFallsBackToTheDotfolderName() throws {
        let definition = ProfileConfiguration().definition(
            fallbackName: try Self.makeDotfolderName())

        #expect(definition.name == Self.dotfolderWord)
    }

    /// A configured `profile.name` wins over the dotfolder name.
    @Test func configuredNameWinsOverTheDotfolderName() throws {
        var configuration = ProfileConfiguration()
        configuration.name = "custom"

        let definition = configuration.definition(
            fallbackName: try Self.makeDotfolderName())

        #expect(definition.name == "custom")
    }

    /// A config that lists three `standard` candidates maps to three
    /// `ModelRef` values in preference order, with the `@` revision
    /// separator intact. The refs come through `Codable`, the only decode
    /// door `ModelRef` has.
    @Test func threeStandardCandidatesMapInPreferenceOrder() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        let loaded = try fixture.loadProjectConfig(
            """
            profile:
              standard:
                - org/one
                - org/two@rev
                - org/three
            """)

        let definition = loaded.configuration.profile.definition(
            fallbackName: try Self.makeDotfolderName())

        #expect(definition.standard.map(\.stringValue) == ["org/one", "org/two@rev", "org/three"])
    }

    /// The description and every slot map through: the configured values
    /// arrive in the definition unchanged.
    @Test func descriptionAndEverySlotMapThrough() throws {
        let fixture = ConfigurationLoaderTests.Fixture()
        let loaded = try fixture.loadProjectConfig(
            """
            profile:
              description: a mapped description
              standard:
                - org/standard
              flash:
                - org/flash
              embedding:
                - org/embedding
            """)

        let definition = loaded.configuration.profile.definition(
            fallbackName: try Self.makeDotfolderName())

        #expect(definition.description == "a mapped description")
        #expect(definition.standard.map(\.stringValue) == ["org/standard"])
        #expect(definition.flash.map(\.stringValue) == ["org/flash"])
        #expect(definition.embedding.map(\.stringValue) == ["org/embedding"])
    }

    /// The config has no context key (plan.md §2.4), so the mapping passes
    /// `nil` — not the initializer's 8192 default — and the ladder applies.
    @Test func contextStaysNilSoTheLadderApplies() throws {
        let definition = ProfileConfiguration().definition(
            fallbackName: try Self.makeDotfolderName())

        #expect(definition.context == nil)
    }

    // MARK: - Construction

    /// Agent construction with the in-code default configuration resolves
    /// through the scripted loader, and the resident profile carries the
    /// dotfolder name as its definition name.
    @Test func constructionResolvesThroughTheScriptedLoader() async throws {
        let agent = try await Self.makeAgent()

        #expect(agent.residentProfile.definitionName == Self.dotfolderWord)
    }

    /// A scripted resolution failure surfaces as a `ProfileResolutionError`
    /// whose message names the profile and carries the underlying reason.
    @Test func scriptedResolutionFailureReportsAReadableMessage() async throws {
        do {
            _ = try await Self.makeAgent(loader: FailingModelLoader())
            Issue.record("expected a ProfileResolutionError")
        } catch let error as ProfileResolutionError {
            #expect(error.description.contains(Self.dotfolderWord))
            #expect(error.description.contains(ScriptedLoadFailure.message))
        } catch {
            Issue.record("expected a ProfileResolutionError, got \(error)")
        }
    }

    /// The agent holds the resident profile strongly: a second session
    /// still constructs after the first one was closed and dropped, so no
    /// `makeSession` precondition fired and the profile stayed alive.
    @Test func theResidentProfileSurvivesTwoSequentialSessions() async throws {
        let agent = try await Self.makeAgent()

        let firstSession = agent.residentProfile.standard.makeSession()
        #expect(firstSession.profile === agent.residentProfile)
        await firstSession.close()

        let secondSession = agent.residentProfile.standard.makeSession()
        #expect(secondSession.profile === agent.residentProfile)
        await secondSession.close()
    }
}
