import Foundation
import FoundationModels

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

/// Makes the tools of one session from its context. The composition of each
/// session runs each registered factory, and the surface of the session
/// mounts the tools that it returns after the tools of the catalog and the
/// host tools.
///
/// A factory must not keep the tools, the agent or the session: the tool
/// value holds what it needs, and the release of the session releases it.
public typealias SessionToolFactory =
  @Sendable (SessionToolContext) async throws -> [any FoundationModels.Tool]
