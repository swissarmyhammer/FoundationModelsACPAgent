import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// What each builder call of the tool catalog needs: the
/// session working directory, the session's additional roots, the decoded
/// configuration, the resolved profile, the client's per-session MCP
/// servers, and the process environment.
///
/// The name is `CatalogContext` because Router's `Hosting/` substrate owns
/// the name `ToolContext`.
public struct CatalogContext: Sendable {
    /// The session working directory: the base a relative path resolves
    /// against, and the root set's first and mandatory member.
    public let workingDirectory: URL

    /// The session's additional roots, in order. Together
    /// with ``workingDirectory`` they are the root set that confines the
    /// files verbs and bounds the shell sandbox's writes.
    public let additionalRoots: [URL]

    /// The decoded configuration whose sections decide which capabilities
    /// the catalog constructs, and with which options. A capability that
    /// the configuration does not mention is on.
    public let configuration: AgentConfiguration

    /// The resolved profile the catalog draws its models from.
    ///
    /// Held strongly on purpose: each `RoutedModel` holds
    /// its owning profile weakly, and `makeSession` traps when the profile
    /// was released before the call.
    public let profile: LanguageModelProfile

    /// The client-supplied per-session MCP servers, in wire
    /// order — the `mcpServers` of `session/new` or `session/resume`.
    ///
    /// Session scope only: this list is never persisted, because the
    /// `headers` of an http entry carry bearer tokens and `sessions.jsonl`
    /// is committed with the transcripts. `session/resume` supplies the
    /// list again.
    public let clientMCPServers: [FoundationModelsACP.MCPServer]

    /// The process environment that the web capability reads its API keys
    /// from (task ^ba231ka). The keys of `tools.web.apiKeys` are put in over
    /// it, so a configured key wins. The skills marketplace store reads its
    /// cache folder and its seed folder from it too
    /// (``ToolCatalog/makeSkillsSource(context:)``).
    public let environment: [String: String]

    /// The settle period of each session that this agent makes: the
    /// settle period of the Router session, `ToolMount.defaultInlineSettleGrace`.
    public static let defaultInlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace

    /// The settle period of the sessions of this surface, in seconds: how
    /// long a background call, for example `start agent`, waits for its own
    /// work before it gives the pending envelope.
    ///
    /// This is the one source of the value. The surface gives it to
    /// `AgentEnvironment.make(inlineSettleGrace:)`, thus to the session of
    /// each agent run, and keeps it as ``SessionSurface/inlineSettleGrace``.
    /// The root session takes it from there through
    /// `RoutedLLM.makeBudgetedSession(...inlineSettleGrace:)`.
    public let inlineSettleGrace: TimeInterval

    /// Makes a catalog context.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory.
    ///   - additionalRoots: The session's additional roots, in order.
    ///     Defaults to none.
    ///   - configuration: The decoded configuration.
    ///   - profile: The resolved profile, retained by this context.
    ///   - clientMCPServers: The client-supplied per-session MCP servers,
    ///     in wire order. Defaults to none.
    ///   - environment: The environment that the web capability reads its
    ///     API keys from, and that the skills marketplace store reads its
    ///     cache folder and its seed folder from. Defaults to the environment
    ///     of the process.
    ///   - inlineSettleGrace: The settle period of the sessions of the
    ///     surface, in seconds. Defaults to ``defaultInlineSettleGrace``.
    public init(
        workingDirectory: URL,
        additionalRoots: [URL] = [],
        configuration: AgentConfiguration,
        profile: LanguageModelProfile,
        clientMCPServers: [FoundationModelsACP.MCPServer] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace
    ) {
        self.workingDirectory = workingDirectory
        self.additionalRoots = additionalRoots
        self.configuration = configuration
        self.profile = profile
        self.clientMCPServers = clientMCPServers
        self.environment = environment
        self.inlineSettleGrace = inlineSettleGrace
    }
}
