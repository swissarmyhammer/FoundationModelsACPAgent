import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
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
    kvCache: KVCacheQuantization?,
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

/// Profile resolution: the mapping from the
/// `profile` config key to Router's `ProfileDefinition`, the resolution at agent construction over a scripted
/// loader, the readable failure report, and the strongly held resident
/// profile.
@Suite struct ProfileResolutionTests {
  /// The dotfolder name each test resolves against.
  static let dotfolderWord = "coding"

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

  // MARK: - The mapping

  /// The definition has the name of the selected profile.
  @Test func theDefinitionHasTheNameOfTheProfile() {
    #expect(ProfileConfiguration().definition.name == BundledProfiles.defaultName)
  }

  /// The definition is the profile that `profile` names: each slot, the
  /// description and the decision context come from its file.
  @Test func theDefinitionIsTheSelectedProfile() throws {
    let fixture = ConfigurationLoaderTests.Fixture()
    let loaded = try fixture.loadProjectConfig("profile: small\n")

    let definition = loaded.configuration.profile.definition

    let small = try #require(BundledProfiles.named("small"))
    #expect(definition.description == small.description)
    #expect(definition.standard == small.standard)
    #expect(definition.flash == small.flash)
    #expect(definition.embedding == small.embedding)
    #expect(definition.decision == small.decision)
    #expect(definition.decisionContext == small.decisionContext)
  }

  /// A bundled profile has no context key, because the context size comes
  /// from the model. So the definition has `nil`, and the ladder applies.
  @Test func contextStaysNilSoTheLadderApplies() {
    #expect(ProfileConfiguration().definition.context == nil)
  }

  // MARK: - Construction

  /// Agent construction with the in-code default configuration resolves
  /// through the scripted loader, and the resident profile carries the
  /// name of the default profile as its definition name.
  @Test func constructionResolvesThroughTheScriptedLoader() async throws {
    let agent = try await Self.makeAgent()

    #expect(agent.residentProfile.definitionName == BundledProfiles.defaultName)
  }

  /// A scripted resolution failure surfaces as a `ProfileResolutionError`
  /// whose message names the profile and carries the underlying reason.
  @Test func scriptedResolutionFailureReportsAReadableMessage() async throws {
    do {
      _ = try await Self.makeAgent(loader: FailingModelLoader())
      Issue.record("expected a ProfileResolutionError")
    } catch let error as ProfileResolutionError {
      #expect(error.description.contains(BundledProfiles.defaultName))
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
