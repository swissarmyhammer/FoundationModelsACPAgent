import FoundationModels

/// The reading of the entries of a model transcript in the import tests.
enum ImportedTranscriptReading {
  /// The text of each entry of a transcript, with the kind of the entry.
  ///
  /// - Parameter transcript: The transcript.
  /// - Returns: `prompt: <text>` or `response: <text>` for each entry, and `other` for each
  ///   other entry.
  static func texts(of transcript: Transcript) -> [String] {
    transcript.map { entry in
      switch entry {
      case .prompt(let prompt):
        "prompt: " + text(of: prompt.segments)
      case .response(let response):
        "response: " + text(of: response.segments)
      default:
        "other"
      }
    }
  }

  /// The joined text of the text segments.
  ///
  /// - Parameter segments: The segments.
  /// - Returns: The text.
  private static func text(of segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined()
  }
}
