import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// A model reference that names a folder on the disk: the format (Core ML or
/// MLX) comes from the files of the folder, and the doctor never asks the Hub
/// about it.
struct LocalModelPathTests {
  // MARK: - Helpers

  /// Makes a throwaway folder that holds the named entries. A name that
  /// ends in `.mlpackage` is a folder, any other name is an empty file.
  ///
  /// - Parameter names: The top-level names of the model.
  /// - Returns: The folder.
  private static func makeModelFolder(holding names: [String]) throws -> URL {
    let folder = URL.temporaryDirectory.appending(path: "local-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in names {
      let entry = folder.appending(path: name)
      if name.hasSuffix(".mlpackage") {
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
      } else {
        try Data().write(to: entry)
      }
    }
    return folder
  }

  /// The doctor findings of a profile whose `embedding` slot names
  /// `reference`. The resolver refuses every reference, so a lookup of the
  /// local path would show as an error.
  private static func findings(embedding reference: ModelRef) async -> [HealthCheck] {
    var configuration = AgentConfiguration()
    configuration.profile.embedding = [reference]
    let resolver = StubModelResolver(
      namedLookups: StubModelResolver.foundLookups(
        of: ProfileConfiguration.defaultStandard
          + ProfileConfiguration.defaultFlash
          + ProfileConfiguration.defaultStandard.compactMap(\.drafter)),
      lookup: .notFound)
    return await ProfileDoctor(
      configuration: configuration, resolver: resolver,
      memoryBytes: DoctorMachineFigures.generousMemoryBytes,
      freeDiskBytes: DoctorMachineFigures.generousDiskBytes
    ).runHealthChecks()
  }

  // MARK: - The format

  @Test func aFolderWithAPackageAndNoWeightsIsCoreML() throws {
    let folder = try Self.makeModelFolder(holding: ["model.mlpackage", "tokenizer.json"])
    #expect(ModelReferenceFormat.localFormat(of: folder) == .coreML)
  }

  @Test func aFolderWithWeightsIsMLX() throws {
    let folder = try Self.makeModelFolder(holding: ["model.safetensors", "config.json"])
    #expect(ModelReferenceFormat.localFormat(of: folder) == .mlx)
  }

  @Test func aFolderWithBothFormatsIsMLX() throws {
    let folder = try Self.makeModelFolder(holding: ["model.mlpackage", "model.safetensors"])
    #expect(ModelReferenceFormat.localFormat(of: folder) == .mlx)
  }

  @Test func anEmptyOrMissingFolderHasNoFormat() throws {
    let empty = try Self.makeModelFolder(holding: [])
    #expect(ModelReferenceFormat.localFormat(of: empty) == nil)
    #expect(ModelReferenceFormat.localFormat(of: empty.appending(path: "absent")) == nil)
  }

  // MARK: - The reference

  @Test func thePrefixesMakeAPathAndAHubIdIsNotOne() {
    #expect(ModelReferenceFormat.isLocalPath(ModelRef(repo: "/models/x")))
    #expect(ModelReferenceFormat.isLocalPath(ModelRef(repo: "~/models/x")))
    #expect(ModelReferenceFormat.isLocalPath(ModelRef(repo: "./models/x")))
    #expect(!ModelReferenceFormat.isLocalPath(ModelRef(repo: "org/name")))
  }

  @Test func aTildePathExpandsToTheHomeFolder() {
    let directory = ModelReferenceFormat.localDirectory(of: ModelRef(repo: "~/models/x"))
    #expect(directory.path == (("~/models/x") as NSString).expandingTildeInPath)
  }

  // MARK: - The doctor

  @Test func aCoreMLFolderPassesAndIsNeverLookedUp() async throws {
    let folder = try Self.makeModelFolder(holding: ["model.mlpackage"])

    let checks = await Self.findings(embedding: ModelRef(repo: folder.path))

    #expect(checks.allSatisfy { $0.status == .ok })
    #expect(checks.contains { $0.message.contains("Core ML") })
  }

  @Test func anMLXFolderPasses() async throws {
    let folder = try Self.makeModelFolder(holding: ["model.safetensors"])

    let checks = await Self.findings(embedding: ModelRef(repo: folder.path))

    #expect(checks.allSatisfy { $0.status == .ok })
    #expect(checks.contains { $0.message.contains("MLX") })
  }

  @Test func aMissingFolderIsOneErrorWithAFix() async throws {
    let missing = URL.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")

    let checks = await Self.findings(embedding: ModelRef(repo: missing.path))

    let errors = checks.filter { $0.status == .error }
    #expect(errors.count == 1)
    #expect(errors.first?.fix != nil)
  }

  @Test func aPathWithAnAtSignIsAnError() async throws {
    let folder = try Self.makeModelFolder(holding: ["model.safetensors"])

    let checks = await Self.findings(embedding: ModelRef(repo: folder.path + "@main"))

    #expect(checks.filter { $0.status == .error }.count == 1)
  }
}
