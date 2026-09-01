import Foundation
import FoundationModelsACP
import FoundationModelsRouter

/// What each builder call of the tool catalog needs (plan.md §11.1): the
/// session working directory, the session's additional roots, the decoded
/// configuration, the resolved profile, and the client's per-session MCP
/// servers.
///
/// The name is `CatalogContext` because Router's `Hosting/` substrate owns
/// the name `ToolContext`.
public struct CatalogContext: Sendable {
    /// The session working directory: the base a relative path resolves
    /// against, and the root set's first and mandatory member.
    public let workingDirectory: URL

    /// The session's additional roots (plan.md §7.2), in order. Together
    /// with ``workingDirectory`` they are the root set that confines the
    /// files verbs and bounds the shell sandbox's writes.
    public let additionalRoots: [URL]

    /// The decoded configuration whose sections decide which capabilities
    /// the catalog constructs (plan.md §11.2), and with which options.
    public let configuration: AgentConfiguration

    /// The resolved profile the catalog draws its models from.
    ///
    /// Held strongly on purpose (plan.md §11.1): each `RoutedModel` holds
    /// its owning profile weakly, and `makeSession` traps when the profile
    /// was released before the call.
    public let profile: LanguageModelProfile

    /// The client-supplied per-session MCP servers (plan.md §7.3), in wire
    /// order — the `mcpServers` of `session/new` or `session/resume`.
    ///
    /// Session scope only: this list is never persisted, because the
    /// `headers` of an http entry carry bearer tokens and `sessions.jsonl`
    /// is committed (§4.3). `session/resume` supplies the list again.
    public let clientMCPServers: [FoundationModelsACP.MCPServer]

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
    public init(
        workingDirectory: URL,
        additionalRoots: [URL] = [],
        configuration: AgentConfiguration,
        profile: LanguageModelProfile,
        clientMCPServers: [FoundationModelsACP.MCPServer] = []
    ) {
        self.workingDirectory = workingDirectory
        self.additionalRoots = additionalRoots
        self.configuration = configuration
        self.profile = profile
        self.clientMCPServers = clientMCPServers
    }
}
