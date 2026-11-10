import Foundation
import FoundationModelsExtras
import FoundationModelsSkills
import Logging

/// A condition the assembler reports and continues past: a
/// missing file is only absent, but a file that is present and not readable
/// gives a logged warning, not a hard error.
public enum InstructionsWarning: Equatable, Sendable, CustomStringConvertible {
  /// A file that a layer holds but that does not read as UTF-8 text.
  case fileUnreadable(path: String)

  /// A human-readable message that names the path.
  public var description: String {
    switch self {
    case .fileUnreadable(let path):
      return "instructions file is present but not readable: \(path)"
    }
  }

  /// Writes the log record of this warning: one `warning` record with a
  /// fixed message, and the path of the file in its metadata. The record
  /// never holds the content of the file.
  func log() {
    switch self {
    case .fileUnreadable(let path):
      ACPAgentTelemetry.logger(.instructions).warning(
        "An instructions file is present but it is not readable. The assembler ignored the file.",
        metadata: ACPAgentTelemetry.fileMetadata(path: path))
    }
  }
}

/// What one assembly gives: the session instructions text and the warnings
/// the assembly logged on the way.
public struct AssembledInstructions: Equatable, Sendable {
  /// The assembled instructions text, ready for `makeSession(instructions:)`.
  public let text: String

  /// Each warning the assembly logged, in assembly order.
  public let warnings: [InstructionsWarning]
}

/// Assembles the per-session instructions, in this order:
///
/// 1. The compiled-in ``StyleInstructions``, for each base prompt. Nothing
///    replaces it.
/// 2. In ``FoundationModelsExtras/ToolMode/sandboxed`` only, the
///    compiled-in ``OpenTestudoInstructions`` section with the download URL
///    of the host (ACPA-19c).
/// 3. The base prompt: the nearest `Instructions.md` through
///    `stack.content(_:)`, which **replaces the builtin wholesale**; with no
///    file in any layer the compiled-in ``BuiltinInstructions`` renders.
/// 4. The preloaded skill bodies: `registry.preloadedBodies()`, one already-
///    rendered string.
/// 5. The user-level `AGENTS.md` through `stack.content(_:)`.
/// 6. The project-level documents through `AgentsMd.documents(from:)`, from
///    the repository root down to the working directory. The
///    ``WorkingDirectoryAgent`` role of the session tells what the `AGENT.md`
///    of the working directory is.
///
/// A header with the absolute path divides each file that came from disk,
/// so each reader of the session instructions can attribute each line.
///
/// The assembly runs once at session creation. A new session gets the
/// edits; a running session keeps its text through each compaction fold.
public struct InstructionsAssembler: Sendable {
  /// The file that replaces the builtin prompt wholesale.
  public static let instructionsFileName = "Instructions.md"

  /// The additive agent-instructions file.
  public static let agentsFileName = "AGENTS.md"

  /// The agent document of a folder (D71).
  static let agentDocumentName = "AGENT.md"

  /// The role of the `AGENT.md` of the working directory in one assembly
  /// (ACPA-1, D19, D71).
  public enum WorkingDirectoryAgent: Sendable {
    /// The file is the alias of `AGENTS.md`: it is project instructions,
    /// and an `AGENTS.md` beside it hides it. The session agent is the
    /// default agent or the builtin floor.
    case alias

    /// The file is the session agent. It is not repeated as project
    /// instructions.
    case sessionAgent

    /// The client selected the session agent. The file is project
    /// instructions, also when an `AGENTS.md` is beside it.
    case projectInstructions
  }

  /// The blank line that joins the assembled sections.
  static let sectionSeparator = "\n\n"

  /// The stack `Instructions.md`, `AGENTS.md` and `_partials/` resolve
  /// against.
  public let stack: DotfolderStack

  /// The session working directory the project-level AGENTS.md walk
  /// starts from.
  public let workingDirectory: URL

  /// The tool mode of the host. In
  /// ``FoundationModelsExtras/ToolMode/sandboxed`` the assembly adds the
  /// ``OpenTestudoInstructions`` section.
  public let toolMode: ToolMode

  /// The URL of the download page of OpenTestudo that the host gave, or
  /// `nil` for none. The ``OpenTestudoInstructions`` section gives it.
  public let openTestudoDownloadURL: URL?

  /// Creates an assembler for one session.
  ///
  /// - Parameters:
  ///   - stack: The dotfolder stack of the session's dotfolder name and
  ///     working directory, e.g. `ConfigurationLoader.stack`.
  ///   - workingDirectory: The session working directory (ACP's
  ///     `session/new(cwd)`), never the process cwd.
  ///   - toolMode: The tool mode of the host (``toolMode``). The default
  ///     is `.open`, which adds no OpenTestudo section.
  ///   - openTestudoDownloadURL: The URL of the download page of
  ///     OpenTestudo (``openTestudoDownloadURL``), or `nil` (the default)
  ///     for none.
  public init(
    stack: DotfolderStack, workingDirectory: URL, toolMode: ToolMode = .open,
    openTestudoDownloadURL: URL? = nil
  ) {
    self.stack = stack
    self.workingDirectory = workingDirectory
    self.toolMode = toolMode
    self.openTestudoDownloadURL = openTestudoDownloadURL
  }

  /// Assembles the instructions text for one session.
  ///
  /// Call it again to pick up edits: it reads `registry` at call time, so
  /// a watching registry's rebuilt catalog shows in the next assembly.
  ///
  /// - Parameters:
  ///   - registry: The session's skills registry, or `nil` for none. A
  ///     `nil` or empty registry adds nothing.
  ///   - agent: The rendered text of the session agent (its body, then
  ///     the bodies of its `skills:` preload), or `nil` when the session
  ///     has no agent. It is the base prompt in place of the builtin. An
  ///     `Instructions.md` of a layer still wins over it.
  ///   - workingDirectoryAgent: The role of the `AGENT.md` of the working
  ///     directory. The default is ``WorkingDirectoryAgent/alias``.
  /// - Returns: The assembled text and the warnings, also logged.
  /// - Throws: `TemplateEngineError` when a document does not render,
  ///   e.g. an untrusted file that uses a disallowed tag.
  public func assemble(
    skills registry: SkillsRegistry? = nil, agent: String? = nil,
    workingDirectoryAgent: WorkingDirectoryAgent = .alias
  ) async throws -> AssembledInstructions {
    let renderer = Renderer(engine: TemplateEngine(partials: stack))
    var warnings: [InstructionsWarning] = []
    var sections = [StyleInstructions.text]
    if let toolModeSection {
      sections.append(toolModeSection)
    }
    sections.append(try basePrompt(renderer: renderer, agent: agent, warnings: &warnings))

    // Already ONE rendered string, joined with blank lines — never
    // rendered again and never iterated.
    if let preloadedBodies = await registry?.preloadedBodies(), !preloadedBodies.isEmpty {
      sections.append(preloadedBodies)
    }

    if let userAgents = try renderedStackFile(
      Self.agentsFileName, renderer: renderer, warnings: &warnings)
    {
      sections.append(userAgents)
    }

    sections.append(
      contentsOf: try renderedProjectDocuments(
        renderer: renderer, workingDirectoryAgent: workingDirectoryAgent, warnings: &warnings))

    for warning in warnings {
      warning.log()
    }
    return AssembledInstructions(
      text: sections.joined(separator: Self.sectionSeparator), warnings: warnings)
  }

  // MARK: - The tool mode

  /// The section that the tool mode adds: the ``OpenTestudoInstructions``
  /// text in ``FoundationModelsExtras/ToolMode/sandboxed``, and `nil` in
  /// ``FoundationModelsExtras/ToolMode/open``.
  private var toolModeSection: String? {
    switch toolMode {
    case .open:
      return nil
    case .sandboxed:
      return OpenTestudoInstructions.text(downloadURL: openTestudoDownloadURL)
    }
  }

  // MARK: - The base prompt

  /// The rendered base prompt: the nearest `Instructions.md`, which
  /// replaces the builtin wholesale; else the text of the session agent;
  /// else the builtin floor.
  private func basePrompt(
    renderer: Renderer, agent: String?, warnings: inout [InstructionsWarning]
  ) throws -> String {
    if let replacement = try renderedStackFile(
      Self.instructionsFileName, renderer: renderer, warnings: &warnings)
    {
      return replacement
    }
    if let agent {
      return agent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return try renderer.render(BuiltinInstructions.text, from: nil)
  }

  // MARK: - Stack files

  /// The rendered nearest copy of `relativePath` with its path header, or
  /// `nil` when no layer has the file. A copy that is present but does
  /// not read as UTF-8 appends a warning and gives `nil`.
  private func renderedStackFile(
    _ relativePath: String, renderer: Renderer, warnings: inout [InstructionsWarning]
  ) throws -> String? {
    guard let url = stack.nearest(relativePath) else {
      return nil
    }
    guard let text = stack.content(relativePath) else {
      warnings.append(.fileUnreadable(path: url.path))
      return nil
    }
    let rendered = try renderer.render(text, from: layerSource(of: url, at: relativePath))
    return Self.divided(rendered, byHeaderFor: url.path)
  }

  /// The source of the layer that `url` resolved from — the layer whose
  /// root joined with `relativePath` gives `url`, exactly how
  /// `stack.nearest(_:)` built it. Falls back to `.project`, the
  /// least-trusted source, when no layer matches.
  private func layerSource(of url: URL, at relativePath: String) -> DotfolderStack.Source {
    let matched = stack.layers.first { layer in
      layer.root.appendingPathComponent(relativePath).path == url.path
    }
    return matched?.source ?? .project
  }

  // MARK: - Project documents

  /// The rendered project-level AGENTS documents with their path headers,
  /// from the repository root down to the working directory. An
  /// unreadable file appends a warning and gives no documents.
  ///
  /// - Parameters:
  ///   - renderer: The renderer of the assembly.
  ///   - workingDirectoryAgent: The role of the `AGENT.md` of the working
  ///     directory.
  ///   - warnings: The warnings of the assembly.
  /// - Returns: The rendered documents.
  /// - Throws: `TemplateEngineError` when a document does not render.
  private func renderedProjectDocuments(
    renderer: Renderer, workingDirectoryAgent: WorkingDirectoryAgent,
    warnings: inout [InstructionsWarning]
  ) throws -> [String] {
    let documents: [AgentsMd.Document]
    do {
      documents = try projectDocuments(
        workingDirectoryAgent: workingDirectoryAgent, warnings: &warnings)
    } catch let error as AgentsMdError {
      switch error {
      case .fileNotReadable(let path):
        warnings.append(.fileUnreadable(path: path))
      }
      return []
    }
    return try documents.map { document in
      let rendered = try renderer.render(document.text, from: .project)
      return Self.divided(rendered, byHeaderFor: document.url.path)
    }
  }

  /// The project documents of `AgentsMd.documents(from:)`, changed by the
  /// role of the `AGENT.md` of the working directory: without that file
  /// for ``WorkingDirectoryAgent/sessionAgent``, and with that file at the
  /// end for ``WorkingDirectoryAgent/projectInstructions`` when an
  /// `AGENTS.md` beside it hid it.
  ///
  /// - Parameters:
  ///   - workingDirectoryAgent: The role of the `AGENT.md` of the working
  ///     directory.
  ///   - warnings: The warnings of the assembly. An `AGENT.md` that does
  ///     not read as UTF-8 appends a warning.
  /// - Returns: The documents, from the repository root down.
  /// - Throws: `AgentsMdError` when a document of the walk does not read.
  private func projectDocuments(
    workingDirectoryAgent: WorkingDirectoryAgent, warnings: inout [InstructionsWarning]
  ) throws -> [AgentsMd.Document] {
    let walked = try AgentsMd.documents(from: workingDirectory)
    let localAgent = workingDirectory.appendingPathComponent(Self.agentDocumentName)
    let localPath = localAgent.canonicalPath
    let isLocalAgent = { (document: AgentsMd.Document) in
      document.url.canonicalPath == localPath
    }
    switch workingDirectoryAgent {
    case .alias:
      return walked
    case .sessionAgent:
      return walked.filter { !isLocalAgent($0) }
    case .projectInstructions:
      guard FileManager.default.fileExists(atPath: localAgent.path),
        !walked.contains(where: isLocalAgent)
      else {
        return walked
      }
      return walked + readDocument(localAgent, warnings: &warnings)
    }
  }

  /// Reads the `AGENT.md` of the working directory as a project document.
  ///
  /// - Parameters:
  ///   - url: The file.
  ///   - warnings: The warnings of the assembly. A file that does not read
  ///     as UTF-8 appends a warning.
  /// - Returns: The document, or no document when the file does not read.
  private func readDocument(_ url: URL, warnings: inout [InstructionsWarning])
    -> [AgentsMd.Document]
  {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      warnings.append(.fileUnreadable(path: url.path))
      return []
    }
    return [AgentsMd.Document(url: url, directory: workingDirectory, text: text)]
  }

  // MARK: - Headers

  /// Puts the divider header that carries `path` above `rendered`, so the
  /// model and each reader of the session instructions can attribute
  /// each line.
  private static func divided(_ rendered: String, byHeaderFor path: String) -> String {
    "===== \(path) =====\(sectionSeparator)\(rendered)"
  }

  // MARK: - Rendering

  /// Renders each assembled document through one engine, and derives
  /// trust from the layer source in one place.
  private struct Renderer {
    /// The engine, built over the assembler's stack so `{% include %}`
    /// resolves `_partials/` through the same layering.
    let engine: TemplateEngine

    /// The context every render of one assembly shares.
    let context = TemplateContext()

    /// Renders `text` with the trust `source` gives.
    ///
    /// - Parameters:
    ///   - text: The document text to render.
    ///   - source: The layer the text came from, or `nil` for the
    ///     compiled-in floor.
    /// - Returns: The rendered text.
    /// - Throws: `TemplateEngineError` when the text does not render.
    func render(_ text: String, from source: DotfolderStack.Source?) throws -> String {
      try engine.render(text, context: context, trust: Self.trust(for: source))
    }

    /// The single source-to-trust derivation: the
    /// compiled-in floor (`nil`) and the shipped-defaults layer render
    /// trusted; each file from the user, project, or marketplace layer
    /// renders untrusted. There is no third answer.
    private static func trust(for source: DotfolderStack.Source?) -> TemplateEngine.Trust {
      switch source {
      case nil, .some(.defaults):
        return .trusted
      case .some(.user), .some(.project), .some(.marketplace):
        return .untrusted
      }
    }
  }
}
