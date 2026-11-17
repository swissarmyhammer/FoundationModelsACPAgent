import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The profile files: the two bundled profiles, `large` and `small`, and the
/// decode of one profile file over the bundled `large` profile.
@Suite struct ProfileFileTests {
  /// The path that each decode in this suite names in its errors.
  private static let path = "/tmp/profiles/custom.yaml"

  /// The name of the profile of ``path``.
  private static let name = "custom"

  /// The embedding model of each bundled profile.
  private static let embedding: [ModelRef] = ["erjigit17/embeddinggemma-300m-ane-coreml"]

  /// The JSON encoding of a profile, with sorted keys, because
  /// `ProfileDefinition` is not `Equatable`.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The JSON text.
  /// - Throws: The encoding error.
  static func encoding(of profile: ProfileDefinition) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(profile), as: UTF8.self)
  }

  /// A profile with one model in the `standard` and `flash` slots, and the
  /// embedding and the decision of the bundled profiles.
  ///
  /// - Parameters:
  ///   - name: The name.
  ///   - description: The description.
  ///   - model: The model of the `standard` and `flash` slots.
  /// - Returns: The profile.
  private static func profile(name: String, description: String, model: ModelRef)
    -> ProfileDefinition
  {
    ProfileDefinition(
      name: name, description: description, standard: [model], flash: [model],
      embedding: embedding)
  }

  /// Decodes the text of a profile file at ``path``.
  ///
  /// - Parameter text: The text of the file.
  /// - Returns: The profile.
  /// - Throws: ``ProfileFileError``.
  private static func decode(_ text: String) throws -> ProfileDefinition {
    try ProfileFile.definition(ofText: text, name: name, path: path)
  }

  // MARK: - The bundled profiles

  /// The bundled profiles are `large` and `small`, in that order, and
  /// `large` is the default.
  @Test func theBundledProfilesAreLargeAndSmall() {
    #expect(BundledProfiles.all.map(\.name) == ["large", "small"])
  }

  /// The default profile is `large`.
  @Test func theDefaultProfileIsLarge() {
    #expect(BundledProfiles.defaultName == "large")
  }

  /// `large` is Qwen3.8 27B at 8 bits with its 8-bit MTP drafter.
  @Test func largeIsTheEightBitModelWithItsDrafter() throws {
    let expected = Self.profile(
      name: "large",
      description: "Qwen3.8 27B 8-bit with its MTP drafter, for a Mac with much memory.",
      model: ModelRef(
        repo: "mlx-community/Qwen3.8-27B-8bit", drafter: "mlx-community/Qwen3.8-27B-MTP-8bit"))

    let large = try #require(BundledProfiles.named("large"))

    #expect(try Self.encoding(of: large) == Self.encoding(of: expected))
  }

  /// `small` is Qwen3.8 27B at 4 bits with its 4-bit MTP drafter.
  @Test func smallIsTheFourBitModelWithItsDrafter() throws {
    let expected = Self.profile(
      name: "small",
      description: "Qwen3.8 27B 4-bit with its MTP drafter, for a Mac with less memory.",
      model: ModelRef(
        repo: "mlx-community/Qwen3.8-27B-4bit", drafter: "mlx-community/Qwen3.8-27B-MTP-4bit"))

    let small = try #require(BundledProfiles.named("small"))

    #expect(try Self.encoding(of: small) == Self.encoding(of: expected))
  }

  // MARK: - The decode of a file

  /// An empty file is the bundled `large` profile under the name of the file.
  @Test func anEmptyFileIsLargeUnderTheFileName() throws {
    var expected = BundledProfiles.defaultProfile
    expected.name = Self.name

    #expect(try Self.encoding(of: Self.decode("")) == Self.encoding(of: expected))
  }

  /// A file that sets one slot replaces that slot as a whole, and keeps each
  /// other key of `large`.
  @Test func aSlotOfTheFileReplacesTheSlotOfLarge() throws {
    var expected = BundledProfiles.defaultProfile
    expected.name = Self.name
    expected.standard = ["mlx-community/Qwen3-4B-4bit"]

    let decoded = try Self.decode("standard:\n  - mlx-community/Qwen3-4B-4bit\n")

    #expect(try Self.encoding(of: decoded) == Self.encoding(of: expected))
  }

  /// A file with `kvBits` alone is valid.
  @Test func aFileWithKVBitsAloneIsValid() throws {
    #expect(throws: Never.self) { try Self.decode("kvBits: 8\n") }
  }

  /// `kvBits: 8` gives an 8-bit KV cache.
  @Test func eightKVBitsGiveAnEightBitKVCache() throws {
    #expect(try Self.decode("kvBits: 8\n").kvCacheQuantization == .bits8)
  }

  /// No `kvBits` gives an unquantized KV cache: `large` names none.
  @Test func noKVBitsGiveAnUnquantizedKVCache() throws {
    #expect(try Self.decode("").kvCacheQuantization == nil)
  }

  /// A `kvBits` other than 8 or 4 is an error that names the file.
  @Test func sixKVBitsAreAnErrorThatNamesTheFile() {
    do {
      _ = try Self.decode("kvBits: 6\n")
      Issue.record("expected a ProfileFileError")
    } catch {
      #expect(String(describing: error).contains(Self.path))
    }
  }

  /// A key that a profile does not have is an error that names the file and
  /// the key.
  @Test func anUnknownKeyIsAnError() {
    #expect(throws: ProfileFileError.unknownKey(path: Self.path, key: "slots")) {
      try Self.decode("slots: []\n")
    }
  }

  /// A `name` key that is not the name of the file is an error.
  @Test func aNameThatIsNotTheFileNameIsAnError() {
    #expect(throws: ProfileFileError.nameMismatch(path: Self.path, name: "other")) {
      try Self.decode("name: other\n")
    }
  }

  /// A `name` key that is the name of the file is valid.
  @Test func aNameThatIsTheFileNameIsValid() throws {
    #expect(try Self.decode("name: custom\n").name == Self.name)
  }

  /// A value of the wrong type is an error that names the file.
  @Test func aBadValueIsAnErrorThatNamesTheFile() {
    do {
      _ = try Self.decode("standard: 5\n")
      Issue.record("expected a ProfileFileError")
    } catch {
      #expect(String(describing: error).contains(Self.path))
    }
  }

  /// A file whose text is not a mapping is an error.
  @Test func aFileThatIsNotAMappingIsAnError() {
    #expect(throws: ProfileFileError.notAMapping(path: Self.path)) {
      try Self.decode("- large\n")
    }
  }

  /// The text of a profile decodes back to the same profile.
  @Test func theTextOfAProfileDecodesBack() throws {
    let small = try #require(BundledProfiles.named("small"))
    var expected = small
    expected.name = Self.name

    let decoded = try Self.decode(ProfileFile.text(of: small))

    #expect(try Self.encoding(of: decoded) == Self.encoding(of: expected))
  }
}
