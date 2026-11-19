import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

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

  /// Makes the facts of a recorded session from its record (`index.md`), with no read of the
  /// session directory. The reconcile at launch reads the record of each session of a folder
  /// that the process can read: a summary of the directory for a session that is not live reads
  /// the recording root of each project, also of a folder that the process cannot read.
  ///
  /// The name and the slug follow `SessionSummary` of FoundationModelsExtras: the name is the
  /// title, and the slug is the slug of the title, or the short id when the title gives no slug.
  ///
  /// - Parameter record: The record of the session.
  init(record: SessionRecord) {
    let facts = record.facts
    let name = facts.title ?? ""
    let titleSlug = SessionSlug.make(from: name)
    self.init(
      name: name,
      slug: titleSlug.isEmpty ? Self.shortID(of: record.sessionId) : titleSlug,
      tags: Array(facts.tags), folder: record.workingDirectory, agentName: facts.agentName,
      recap: facts.recap, lastSummary: facts.lastSummary)
  }

  /// The number of characters of the short id of a session, as `SessionSummary.shortID` of
  /// FoundationModelsExtras counts them.
  private static let shortIDLength = 7

  /// The short id of a session, as `SessionSummary.shortID` of FoundationModelsExtras makes it:
  /// the last characters of the text of the id, in lower case.
  ///
  /// - Parameter id: The session id.
  /// - Returns: The short id.
  private static func shortID(of id: ULID) -> String {
    String(id.ulidString.suffix(shortIDLength)).lowercased()
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
