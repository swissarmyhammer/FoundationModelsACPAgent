import FoundationModels

extension Transcript {
  /// The joined text of the leading `.instructions` entry of the transcript,
  /// or `nil` when the transcript starts with a different entry.
  var leadingInstructionsText: String? {
    guard case .instructions(let instructions)? = Array(self).first else {
      return nil
    }
    return instructions.segments.compactMap { segment in
      if case .text(let text) = segment {
        return text.content
      }
      return nil
    }.joined()
  }
}
