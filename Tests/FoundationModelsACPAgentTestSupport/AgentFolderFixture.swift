import Foundation

/// The one writer of an agent folder of a test: the folder named by the agent id, and its
/// `AGENT.md` with the id and a description. The unit target and the integration package both
/// call it, so no suite keeps its own copy of the file format.
public enum AgentFolderFixture {
  /// The name of the document file inside an agent folder.
  public static let documentName = "AGENT.md"

  /// The path of the project layer that holds agent folders, relative to a project folder.
  static let projectLayerPath = ".agents/agents"

  /// The text of one agent document: a frontmatter with the name, the description and the extra
  /// keys, then a body.
  ///
  /// - Parameters:
  ///   - id: The agent id, which is the `name` field.
  ///   - description: The `description` field.
  ///   - extraKeys: Further frontmatter lines, each one `key: value`, in order. Empty by default.
  /// - Returns: The document text.
  public static func document(id: String, description: String, extraKeys: [String] = [])
    -> String
  {
    let extraLines = extraKeys.map { "\($0)\n" }.joined()
    return "---\nname: \(id)\ndescription: \(description)\n\(extraLines)---\n\nDo the task.\n"
  }

  /// Writes the agent folder `<layer>/<id>/AGENT.md`.
  ///
  /// - Parameters:
  ///   - id: The agent id, which is the folder name and the `name` field.
  ///   - layer: The folder that holds the agent folder.
  ///   - description: The `description` field.
  ///   - extraKeys: Further frontmatter lines, each one `key: value`. Empty by default.
  /// - Throws: The directory-creation or write error.
  public static func write(
    id: String, under layer: URL, description: String, extraKeys: [String] = []
  ) throws {
    try TestFileFixture.write(
      document(id: id, description: description, extraKeys: extraKeys),
      named: documentName, in: layer.appendingPathComponent(id, isDirectory: true))
  }

  /// Writes the agent folder `<project>/.agents/agents/<id>/AGENT.md`.
  ///
  /// - Parameters:
  ///   - id: The agent id, which is the folder name and the `name` field.
  ///   - project: The project folder, or the working directory of the session.
  ///   - description: The `description` field. Defaults to `The <id> test agent.`.
  ///   - extraKeys: Further frontmatter lines, each one `key: value`. Empty by default.
  /// - Throws: The directory-creation or write error.
  public static func writeProjectAgent(
    id: String, in project: URL, description: String? = nil, extraKeys: [String] = []
  ) throws {
    try write(
      id: id,
      under: project.appendingPathComponent(projectLayerPath, isDirectory: true),
      description: description ?? "The \(id) test agent.", extraKeys: extraKeys)
  }
}
