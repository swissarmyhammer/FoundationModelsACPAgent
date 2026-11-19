import Foundation
import FoundationModelsExtras

/// The facts of one session that its session item of the transcript search holds (D207 (b)
/// (1)): the name, the slug, the tags, the folder, the name of the agent, the recap (D206) and
/// the last summary (ROUTER-9).
///
/// The host gives them to ``TranscriptSearchIndex/index(session:chunks:metadata:)``. The agent
/// takes them from the session directory (``init(summary:)``), and the Mac app from the sessions
/// that it shows.
public struct TranscriptSessionMetadata: Codable, Hashable, Sendable {
  /// The name of the session (D199): its title, or an empty text when it has none.
  public let name: String

  /// The slug of the session (D199).
  public let slug: String

  /// The tags of the session, in sorted order, so the same tags always give the same block.
  public let tags: [String]

  /// The working folder of the session.
  public let folder: URL

  /// The display name of the agent of the session, or `nil`.
  public let agentName: String?

  /// The recap of the session (D206), or `nil`.
  public let recap: String?

  /// The last final reply of the session, cut to a fixed length (ROUTER-9), or `nil`.
  public let lastSummary: String?

  /// Makes the facts of a session.
  ///
  /// - Parameters:
  ///   - name: The name of the session.
  ///   - slug: The slug of the session.
  ///   - tags: The tags of the session, in any order. The facts keep them in sorted order.
  ///   - folder: The working folder of the session.
  ///   - agentName: The display name of the agent, or `nil`.
  ///   - recap: The recap, or `nil`.
  ///   - lastSummary: The last summary, or `nil`.
  public init(
    name: String, slug: String, tags: [String], folder: URL, agentName: String?, recap: String?,
    lastSummary: String?
  ) {
    self.name = name
    self.slug = slug
    self.tags = tags.sorted()
    self.folder = folder
    self.agentName = agentName
    self.recap = recap
    self.lastSummary = lastSummary
  }

  /// Makes the facts of a session of the session directory: its title as the name, and its slug,
  /// tags, working folder, agent name, recap and last summary.
  ///
  /// - Parameter summary: The summary of the session in the directory.
  public init(summary: SessionSummary) {
    self.init(
      name: summary.title ?? "", slug: summary.slug, tags: Array(summary.tags),
      folder: summary.workingDirectory, agentName: summary.agentName, recap: summary.recap,
      lastSummary: summary.lastSummary)
  }

  /// The lines of the block of the session item: the name, the slug, the tags, the folder, the
  /// agent name, the recap and the last summary, one on each line. A fact that the session does
  /// not have is an empty line, so each fact always has the same line.
  var blockLines: [String] {
    [
      name, slug, tags.joined(separator: " "), folder.path, agentName ?? "", recap ?? "",
      lastSummary ?? "",
    ]
  }
}
