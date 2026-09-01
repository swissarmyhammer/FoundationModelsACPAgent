import Foundation
import FoundationModelsExtras
import FoundationModelsSkills
import os

/// The logger the assembler reports each unreadable-file warning to.
private let instructionsLogger = Logger(
    subsystem: "FoundationModelsACPAgent", category: "Instructions")

/// A condition the assembler reports and continues past (plan.md §3): a
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
}

/// What one assembly gives: the session instructions text and the warnings
/// the assembly logged on the way.
public struct AssembledInstructions: Equatable, Sendable {
    /// The assembled instructions text, ready for `makeSession(instructions:)`.
    public let text: String

    /// Each warning the assembly logged, in assembly order.
    public let warnings: [InstructionsWarning]
}

/// Assembles the per-session instructions (plan.md §3), in this order:
///
/// 1. The base prompt: the nearest `Instructions.md` through
///    `stack.content(_:)`, which **replaces the builtin wholesale**; with no
///    file in any layer the compiled-in ``BuiltinInstructions`` renders.
/// 2. The preloaded skill bodies: `registry.preloadedBodies()`, one already-
///    rendered string.
/// 3. The user-level `AGENTS.md` through `stack.content(_:)`.
/// 4. The project-level documents through `AgentsMd.documents(from:)`, from
///    the repository root down to the working directory.
///
/// A header with the absolute path divides each file that came from disk,
/// so each reader of the session instructions can attribute each line.
///
/// The assembly runs once at session creation. A new session gets the
/// edits; a running session keeps its text through each compaction fold.
public struct InstructionsAssembler: Sendable {
    /// The file that replaces the builtin prompt wholesale (plan.md §3.1).
    public static let instructionsFileName = "Instructions.md"

    /// The additive agent-instructions file (plan.md §3.2).
    public static let agentsFileName = "AGENTS.md"

    /// The blank line that joins the assembled sections.
    private static let sectionSeparator = "\n\n"

    /// The stack `Instructions.md`, `AGENTS.md` and `_partials/` resolve
    /// against.
    public let stack: DotfolderStack

    /// The session working directory the project-level AGENTS.md walk
    /// starts from.
    public let workingDirectory: URL

    /// Creates an assembler for one session.
    ///
    /// - Parameters:
    ///   - stack: The dotfolder stack of the session's dotfolder name and
    ///     working directory, e.g. `ConfigurationLoader.stack`.
    ///   - workingDirectory: The session working directory (ACP's
    ///     `session/new(cwd)`), never the process cwd.
    public init(stack: DotfolderStack, workingDirectory: URL) {
        self.stack = stack
        self.workingDirectory = workingDirectory
    }

    /// Assembles the instructions text for one session.
    ///
    /// Call it again to pick up edits: it reads `registry` at call time, so
    /// a watching registry's rebuilt catalog shows in the next assembly.
    ///
    /// - Parameter registry: The session's skills registry, or `nil` for
    ///   none. A `nil` or empty registry adds nothing.
    /// - Returns: The assembled text and the warnings, also logged.
    /// - Throws: `TemplateEngineError` when a document does not render,
    ///   e.g. an untrusted file that uses a disallowed tag.
    public func assemble(skills registry: SkillsRegistry? = nil) throws -> AssembledInstructions {
        let renderer = Renderer(engine: TemplateEngine(partials: stack))
        var warnings: [InstructionsWarning] = []
        var sections = [try basePrompt(renderer: renderer, warnings: &warnings)]

        // Already ONE rendered string, joined with blank lines — never
        // rendered again and never iterated (plan.md §3.1).
        if let preloadedBodies = registry?.preloadedBodies(), !preloadedBodies.isEmpty {
            sections.append(preloadedBodies)
        }

        if let userAgents = try renderedStackFile(
            Self.agentsFileName, renderer: renderer, warnings: &warnings)
        {
            sections.append(userAgents)
        }

        sections.append(
            contentsOf: try renderedProjectDocuments(renderer: renderer, warnings: &warnings))

        for warning in warnings {
            instructionsLogger.warning("\(warning.description, privacy: .public)")
        }
        return AssembledInstructions(
            text: sections.joined(separator: Self.sectionSeparator), warnings: warnings)
    }

    // MARK: - The base prompt

    /// The rendered base prompt: the nearest `Instructions.md`, which
    /// replaces the builtin wholesale, or the builtin floor when no layer
    /// has the file (plan.md §3.1).
    private func basePrompt(
        renderer: Renderer, warnings: inout [InstructionsWarning]
    ) throws -> String {
        if let replacement = try renderedStackFile(
            Self.instructionsFileName, renderer: renderer, warnings: &warnings)
        {
            return replacement
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
    /// from the repository root down to the working directory (plan.md
    /// §3.2). An unreadable file appends a warning and gives no documents.
    private func renderedProjectDocuments(
        renderer: Renderer, warnings: inout [InstructionsWarning]
    ) throws -> [String] {
        let documents: [AgentsMd.Document]
        do {
            documents = try AgentsMd.documents(from: workingDirectory)
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

    // MARK: - Headers

    /// Puts the divider header that carries `path` above `rendered`, so the
    /// model and each reader of the session instructions can attribute
    /// each line (plan.md §3.2).
    private static func divided(_ rendered: String, byHeaderFor path: String) -> String {
        "===== \(path) =====\(sectionSeparator)\(rendered)"
    }

    // MARK: - Rendering

    /// Renders each assembled document through one engine, and derives
    /// trust from the layer source in one place (plan.md §3.1).
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

        /// The single source-to-trust derivation (plan.md §3.1): the
        /// compiled-in floor (`nil`) and the shipped-defaults layer render
        /// trusted; each file from the user or project layer renders
        /// untrusted. There is no third case.
        private static func trust(for source: DotfolderStack.Source?) -> TemplateEngine.Trust {
            switch source {
            case nil, .some(.defaults):
                return .trusted
            case .some(.user), .some(.project):
                return .untrusted
            }
        }
    }
}
