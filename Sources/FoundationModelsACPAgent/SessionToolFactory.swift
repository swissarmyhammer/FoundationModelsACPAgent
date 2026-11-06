import Foundation
import FoundationModels
import FoundationModelsACP

/// What a ``SessionToolFactory`` knows of the session that it makes tools for.
public struct SessionToolContext: Sendable {
  /// The working directory of the session.
  public let workingDirectory: URL

  /// The name of the agent: the dotfolder name that the host chose.
  public let agentName: String

  /// A short text (``sessionTagLength`` characters) that differs for each composition of a session. A
  /// factory that needs an actor for each session builds its name from the
  /// agent name and this tag, so that two sessions of one folder do not
  /// share an actor.
  public let sessionTag: String

  /// Makes a context.
  ///
  /// - Parameters:
  ///   - workingDirectory: The working directory of the session.
  ///   - agentName: The name of the agent.
  ///   - sessionTag: The tag of the session.
  public init(workingDirectory: URL, agentName: String, sessionTag: String) {
    self.workingDirectory = workingDirectory
    self.agentName = agentName
    self.sessionTag = sessionTag
  }

  /// A name for the actor of the session: the agent name and the tag.
  public var actorName: String {
    "\(agentName) \(sessionTag)"
  }

  /// The length of a tag, in characters.
  static let sessionTagLength = 8

  /// Makes a tag: the first ``sessionTagLength`` characters of a new UUID.
  ///
  /// - Returns: The tag.
  static func makeSessionTag() -> String {
    String(UUID().uuidString.prefix(sessionTagLength))
  }
}

/// The tag of a session, kept with its recording so that a resume gets the same
/// tag, and so the same actor, as the session had before.
///
/// The session id does not exist when the tools are composed: Router makes it
/// with the session, and the tools go into that call. A new session therefore
/// gets a random tag, and `session/new` records it after the session exists.
/// A resume reads it back. A session recorded before this store existed gets
/// the first characters of its id, which are stable too.
enum SessionTagStore {
  /// The name of the file in the recording folder of the session.
  static let fileName = "session-tag"

  /// The tag of a resumed session.
  ///
  /// - Parameters:
  ///   - sessionId: The id of the session.
  ///   - transcriptRoot: The recording root.
  /// - Returns: The recorded tag, or the first characters of the id when
  ///   nothing is recorded.
  static func tag(of sessionId: SessionId, in transcriptRoot: URL) -> String {
    let fromId = String(sessionId.rawValue.prefix(SessionToolContext.sessionTagLength))
    let file = file(of: sessionId, in: transcriptRoot)
    // A missing file is expected: the session was recorded before this store existed.
    guard FileManager.default.fileExists(atPath: file.path) else { return fromId }
    do {
      let recorded = try String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return recorded.isEmpty ? fromId : recorded
    } catch {
      // An unreadable file gives the session another actor, so the defect is logged.
      ACPAgentTelemetry.logger(.session).warning(
        "The tag of the session could not be read. The tag from its id is used.",
        metadata: ACPAgentTelemetry.sessionMetadata(sessionId))
      assertionFailure("the session tag file is unreadable: \(error)")
      return fromId
    }
  }

  /// Records the tag of a new session.
  ///
  /// - Parameters:
  ///   - tag: The tag.
  ///   - sessionId: The id of the session.
  ///   - transcriptRoot: The recording root.
  /// - Throws: The file system error. The caller logs it: a session with no
  ///   recorded tag still works, and a resume then uses the tag from its id.
  static func record(_ tag: String, for sessionId: SessionId, in transcriptRoot: URL) throws {
    let file = file(of: sessionId, in: transcriptRoot)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try tag.write(to: file, atomically: true, encoding: .utf8)
  }

  /// The file of one session.
  private static func file(of sessionId: SessionId, in transcriptRoot: URL) -> URL {
    transcriptRoot.appendingPathComponent(sessionId.rawValue, isDirectory: true)
      .appendingPathComponent(fileName)
  }
}

/// Makes the tools of one session from its context. The composition of each
/// session runs each registered factory, and the surface of the session
/// mounts the tools that it returns after the tools of the catalog and the
/// host tools.
///
/// A factory must not keep the tools, the agent or the session: the tool
/// value holds what it needs, and the release of the session releases it.
public typealias SessionToolFactory =
  @Sendable (SessionToolContext) async throws -> [any FoundationModels.Tool]
