import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The download price of `SystemModelResolver` (^tq4dv8s): a reference that
/// names a path inside its repository prices only the files of that path, as
/// the loader downloads them. A reference with no path prices the whole tree.
///
/// A stub metadata source gives the tree, and an empty cache folder holds no
/// snapshot. Thus no test asks the network, and each file of the selection is
/// still to download.
struct SystemModelResolverTests {
  // MARK: - Constants

  /// The repository of each reference in the suite.
  private static let repository = "owner/model-GGUF"

  /// The file of the smaller GGUF quantization.
  private static let smallQuant = "model-Q4_K_M.gguf"

  /// The size of ``smallQuant`` in bytes.
  private static let smallQuantBytes: Int64 = 1_000

  /// The file of the larger GGUF quantization.
  private static let largeQuant = "model-Q8_0.gguf"

  /// The size of ``largeQuant`` in bytes.
  private static let largeQuantBytes: Int64 = 2_000

  /// A file at the root of the repository that is not a model.
  private static let readme = "README.md"

  /// The size of ``readme`` in bytes.
  private static let readmeBytes: Int64 = 10

  /// A folder of the repository that holds a model that is not GGUF.
  private static let weightsFolder = "weights"

  /// The weights file in ``weightsFolder``.
  private static let weights = "weights/model.safetensors"

  /// The size of ``weights`` in bytes.
  private static let weightsBytes: Int64 = 4_000

  // MARK: - Stub

  /// A metadata source that gives one fixed tree listing for each
  /// repository.
  private struct TreeSource: MetadataSource {
    /// The tree listing document.
    let treeJSON: Data

    /// Gives the fixed tree listing.
    ///
    /// - Parameters:
    ///   - repo: The repository id, which the stub ignores.
    ///   - revision: The revision, which the stub ignores.
    /// - Returns: The tree listing, with no `config.json`.
    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
      RawRepoMetadata(configJSON: nil, treeJSON: treeJSON)
    }
  }

  // MARK: - Helpers

  /// One file of a tree listing document, as the Hub writes it.
  private struct ListedFile: Encodable {
    /// The path of the file inside the repository.
    let path: String

    /// The size of the file in bytes.
    let size: Int64
  }

  /// The files of the tree in the suite: two GGUF quantizations, a README,
  /// and a folder of weights that are not GGUF.
  private static let listedFiles = [
    ListedFile(path: smallQuant, size: smallQuantBytes),
    ListedFile(path: largeQuant, size: largeQuantBytes),
    ListedFile(path: readme, size: readmeBytes),
    ListedFile(path: weights, size: weightsBytes),
  ]

  /// Makes a resolver over the tree in the suite and an empty cache folder.
  ///
  /// - Parameter name: The name of the cache folder in the test.
  /// - Returns: The resolver.
  private static func makeResolver(named name: String) throws -> SystemModelResolver {
    let treeJSON = try JSONEncoder().encode(listedFiles)
    return SystemModelResolver(
      source: TreeSource(treeJSON: treeJSON),
      cacheDirectory: makeResolvedDirectory(label: "SystemModelResolverTests-\(name)"))
  }

  // MARK: - Tests

  /// A reference whose path names one GGUF file prices only that file, and
  /// not the other quantization of the repository.
  @Test func aGGUFFilePathPricesOnlyThatFile() async throws {
    let resolver = try Self.makeResolver(named: "gguf-file")

    let lookup = await resolver.lookUp(ModelRef(repo: Self.repository, path: Self.smallQuant))

    #expect(lookup == .found(downloadBytes: Self.smallQuantBytes))
  }

  /// A reference with no path prices every file of the tree.
  @Test func noPathPricesTheWholeTree() async throws {
    let resolver = try Self.makeResolver(named: "no-path")

    let lookup = await resolver.lookUp(ModelRef(repo: Self.repository))

    let wholeTree = Self.listedFiles.reduce(Int64(0)) { $0 + $1.size }
    #expect(lookup == .found(downloadBytes: wholeTree))
  }

  /// A reference whose path names a folder that holds no GGUF model prices
  /// only the files under that folder.
  @Test func aPathWithNoGGUFModelPricesOnlyTheFilesUnderIt() async throws {
    let resolver = try Self.makeResolver(named: "folder")

    let lookup = await resolver.lookUp(ModelRef(repo: Self.repository, path: Self.weightsFolder))

    #expect(lookup == .found(downloadBytes: Self.weightsBytes))
  }
}
