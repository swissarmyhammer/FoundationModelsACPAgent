import Foundation

extension RoutedACPAgent {
  /// The rule "this folder is readable now" of the transcript search index of the agent
  /// (``transcriptSearchIndex``): each folder. The agent gets no rule from its host yet. The
  /// reconcile at launch (^en1kt61) reads the folders of the project store, and the host then
  /// gives the rule of its sandbox.
  ///
  /// - Parameter folder: A folder.
  /// - Returns: `true`.
  static func everyFolderIsReadable(_ folder: URL) -> Bool {
    true
  }
}
