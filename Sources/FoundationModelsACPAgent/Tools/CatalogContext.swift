import Foundation
import FoundationModelsACP
import FoundationModelsHooks
import FoundationModelsRouter

/// What each builder call of the tool catalog needs: the
/// session working directory, the session's additional roots, the decoded
/// configuration, the resolved profile, the client's per-session MCP
/// servers, the settings folders of the host, and the environment of the
/// host.
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

    /// The settings folders that the `skills` and `agents` dotfolder stacks
    /// of the session come from (``ToolCatalog/makeSkillsSource(context:)``,
    /// ``AgentsComposition/makeAgentRegistry(context:marketplaces:)``). The
    /// session composition of the agent gives the settings folders of the
    /// agent, thus with a root settings folder from the host no stack holds
    /// a folder in the home directory or in `XDG_CONFIG_HOME`.
    public let settingsFolders: SettingsFolders

    /// The environment of the host: the session composition of the agent
    /// gives `RoutedACPAgent.environment` (task ^b2kb6j1).
    ///
    /// The web capability reads its API keys from it (task ^ba231ka). The
    /// keys of `tools.web.apiKeys` are put in over it, so a configured key
    /// wins. The skills marketplace store reads its cache folder and its
    /// seed folder from it. The `skills` and `agents` dotfolder stacks read
    /// the environment of ``settingsFolders``.
    ///
    /// Three session tools read the process environment and not this one,
    /// because Multitool takes no environment for them: the
    /// `tools.environment` verbs, each shell command, and each stdio MCP
    /// server (``ToolCatalog/makeRegistry(context:)``,
    /// ``MCPComposition``).
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

    /// Whether a user can answer the questions of the sessions of this
    /// surface: the same value as the Router session
    /// (``RoutedACPAgent/userPresence``). Each MCP server of the surface
    /// gets it (``MCPComposition``): a headless server advertises no
    /// elicitation capability and cancels each `elicitation/create` with the
    /// reason "no user is present".
    public let userPresence: UserPresence

    /// The snapshot store of the agent (``AgentHooks/snapshotStore``), or
    /// `nil` for a catalog that has no agent. With a store, the Multitool
    /// registry of the session mounts the `snapshots` capability over it
    /// (``ToolCatalog/makeRegistry(context:)``).
    public let snapshotStore: SnapshotStore?

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
    ///   - settingsFolders: The settings folders that the `skills` and
    ///     `agents` stacks come from (``settingsFolders``).
    ///   - environment: The environment of the host, which the session tools
    ///     read (``environment``). Defaults to the environment of the
    ///     process, for a caller that composes a catalog with no host.
    ///   - inlineSettleGrace: The settle period of the sessions of the
    ///     surface, in seconds. Defaults to ``defaultInlineSettleGrace``.
    ///   - userPresence: Whether a user can answer the questions of the
    ///     sessions (``userPresence``). Defaults to `.interactive`.
    ///   - snapshotStore: The snapshot store of the agent, or `nil` (the
    ///     default) for no `snapshots` capability (``snapshotStore``).
    public init(
        workingDirectory: URL,
        additionalRoots: [URL] = [],
        configuration: AgentConfiguration,
        profile: LanguageModelProfile,
        clientMCPServers: [FoundationModelsACP.MCPServer] = [],
        settingsFolders: SettingsFolders,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace,
        userPresence: UserPresence = .interactive,
        snapshotStore: SnapshotStore? = nil
    ) {
        self.snapshotStore = snapshotStore
        self.workingDirectory = workingDirectory
        self.additionalRoots = additionalRoots
        self.configuration = configuration
        self.profile = profile
        self.clientMCPServers = clientMCPServers
        self.settingsFolders = settingsFolders
        self.environment = environment
        self.inlineSettleGrace = inlineSettleGrace
        self.userPresence = userPresence
    }
}
