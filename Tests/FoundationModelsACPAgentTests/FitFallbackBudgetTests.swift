import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The fit fallback and the resolution read the same memory budget (D203,
/// task ^8a6cykg). A router whose budget does not fit `large` chooses a
/// smaller profile, and the same router resolves that choice.
@Suite struct FitFallbackBudgetTests {
  /// The budget of the CI runner that stopped at the resolution of
  /// `large`, in bytes.
  static let runnerBudgetBytes: Int64 = 26_800_603_136

  /// The bytes of the weights of each repository of `large`: more than
  /// ``runnerBudgetBytes``, so `large` does not fit.
  static let largeWeightsBytes: Int64 = 30_000_000_000

  /// A machine with the budget of the CI runner.
  struct RunnerMachine: MachineProbe {
    /// The chip of the stub machine.
    let chip = "Apple Stub Runner"

    /// The memory of the stub machine: twice its budget.
    let totalRAM: Int64 = FitFallbackBudgetTests.runnerBudgetBytes * 2

    /// The budget of the stub machine.
    let recommendedMaxWorkingSetSize: Int64 = FitFallbackBudgetTests.runnerBudgetBytes
  }

  /// The metadata of the stub model, with large weights for each
  /// repository of `large`. Each other repository keeps the small stub
  /// size.
  struct LargeProfileMetadata: MetadataSource {
    /// The stub metadata that gives each answer.
    let stub = StubMetadata()

    /// The repositories of `large` (the standard model and its drafter).
    let largeRepositories: Set<String>

    /// Gives the stub metadata, with one weights file of
    /// ``FitFallbackBudgetTests/largeWeightsBytes`` for a repository of
    /// `large`.
    ///
    /// - Parameters:
    ///   - repo: The repository id.
    ///   - revision: The revision.
    /// - Returns: The metadata.
    /// - Throws: What the stub metadata throws.
    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
      let metadata = try await stub.fetchRawMetadata(repo: repo, revision: revision)
      guard largeRepositories.contains(repo) else {
        return metadata
      }
      let tree = #"[{"type":"file","path":"model.safetensors","size":\#(FitFallbackBudgetTests.largeWeightsBytes)}]"#
      return RawRepoMetadata(configJSON: metadata.configJSON, treeJSON: Data(tree.utf8))
    }

    /// Gives the bytes of the stub metadata.
    ///
    /// - Parameters:
    ///   - repo: The repository id.
    ///   - revision: The revision.
    ///   - path: The path of the file.
    ///   - range: The byte offsets to read.
    /// - Returns: The bytes.
    /// - Throws: What the stub metadata throws.
    func fetchFileBytes(
      repo: String, revision: String?, path: String, range: Range<Int>
    ) async throws -> Data {
      try await stub.fetchFileBytes(repo: repo, revision: revision, path: path, range: range)
    }
  }

  /// Makes a router over the stub loader on a machine with the budget of
  /// the CI runner, where `large` does not fit.
  ///
  /// - Returns: The router.
  static func makeRunnerRouter() throws -> Router {
    let large = try #require(BundledProfiles.named(BundledProfiles.baseName))
    let models = large.standard + large.flash
    let repositories = models.map(\.repo) + models.compactMap(\.drafter?.repo)
    return Router(
      cacheDir: makeResolvedDirectory(label: "FitFallbackBudget-cache"),
      probe: RunnerMachine(),
      metadataSource: LargeProfileMetadata(largeRepositories: Set(repositories)),
      loader: StubModelLoader(),
      pool: ModelPool())
  }

  /// On the runner budget, the choice is not `large`.
  @Test func theChoiceOnTheRunnerBudgetIsNotLarge() async throws {
    let name = await BundledProfiles.fallbackName(using: try Self.makeRunnerRouter())

    #expect(name != BundledProfiles.baseName)
  }

  /// The router that chose the fallback resolves it: the choice and the
  /// resolution read the same budget.
  @Test func theSameRouterResolvesItsChoice() async throws {
    let router = try Self.makeRunnerRouter()
    let name = await BundledProfiles.fallbackName(using: router)

    let resident = try await ProfileConfiguration(name: name).resolveResident(
      router: router, reporting: await ResolutionProgress())

    #expect(resident.definitionName == name)
  }
}
