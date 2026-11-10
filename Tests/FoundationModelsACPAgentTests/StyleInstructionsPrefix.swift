@testable import FoundationModelsACPAgent

extension StyleInstructions {
  /// The start of the assembled instructions of a session whose base
  /// prompt is `base`: the style text, the section separator of the
  /// assembler, then `base`.
  ///
  /// - Parameter base: The base prompt of the session.
  /// - Returns: The expected start of the assembled instructions.
  static func prefixed(_ base: String) -> String {
    text + InstructionsAssembler.sectionSeparator + base
  }
}
