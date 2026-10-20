import Foundation
import FoundationModelsACP
import FoundationModelsHooks

/// The hook objects of one agent: one `HookDispatcher` and one
/// `SnapshotStore`.
///
/// Router owns the hook events and the lineage of each session. This package
/// makes the shared objects and gives them to their clients:
///
/// - The composition gives ``dispatcher`` to `Router.init(hooks:)`, so each
///   session of the router sends its hook events to it. The router does not
///   publish its dispatcher, thus the agent gets the same value
///   (`RoutedACPAgent.init(...hooks:)`): `RoutedACPAgent.registerHookVisitors(_:)`
///   adds visitors to it, and the close of the connection drains it.
/// - ``snapshotStore`` goes to `SnapshotHook`, which ``init(dataDirectory:)``
///   registers on the dispatcher, and to the Multitool `snapshots` capability
///   of each session (`ToolCatalog.makeRegistry(context:)`).
public struct AgentHooks: Sendable {
    /// The environment key of the base directory of the user data files, in
    /// the XDG Base Directory specification.
    static let dataHomeEnvironmentKey = "XDG_DATA_HOME"

    /// The base directory of the user data files when `XDG_DATA_HOME` is not
    /// an absolute path, relative to the home directory.
    static let defaultDataHomePath = ".local/share"

    /// The name of the folder of the hook data, under the data folder of the
    /// dotfolder name.
    static let hooksFolderName = "hooks"

    /// The name of the folder of the snapshots, under the data directory.
    static let snapshotFolderName = "snapshot"

    /// The dispatcher that each Router session sends its hook events to.
    public let dispatcher: HookDispatcher

    /// The store of the workspace snapshots, which `SnapshotHook` and the
    /// Multitool `snapshots` capability share.
    public let snapshotStore: SnapshotStore

    /// Makes the dispatcher and the store, and registers `SnapshotHook` on
    /// the dispatcher as its first visitor.
    ///
    /// - Parameter dataDirectory: The directory where the hooks keep their
    ///   data. The snapshots go into its ``snapshotFolderName`` folder.
    public init(dataDirectory: URL) {
        dispatcher = HookDispatcher(dataDirectory: dataDirectory)
        snapshotStore = SnapshotStore(directory: Self.snapshotDirectory(in: dataDirectory))
        dispatcher.register(SnapshotHook(store: snapshotStore))
    }

    /// The hook data directory of a host: `$XDG_DATA_HOME/<name>/hooks` when
    /// `environment` has an absolute `XDG_DATA_HOME`, and
    /// `~/.local/share/<name>/hooks` when not.
    ///
    /// The XDG Base Directory specification tells that a relative value is
    /// not valid, thus a relative `XDG_DATA_HOME` gives the default. The
    /// `acp-agent` CLI has the dotfolder name `acp-agent`.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name of the host.
    ///   - environment: The environment that `XDG_DATA_HOME` is read from.
    /// - Returns: The hook data directory. The call does not make it.
    public static func dataDirectory(name: DotfolderName, environment: [String: String]) -> URL {
        dataHome(environment: environment)
            .appendingPathComponent(name.rawValue, isDirectory: true)
            .appendingPathComponent(hooksFolderName, isDirectory: true)
    }

    /// The directory of the snapshots under a hook data directory.
    ///
    /// - Parameter dataDirectory: The hook data directory.
    /// - Returns: The ``snapshotFolderName`` folder of `dataDirectory`.
    static func snapshotDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(snapshotFolderName, isDirectory: true)
    }

    /// The base directory of the user data files.
    ///
    /// - Parameter environment: The environment that `XDG_DATA_HOME` is read
    ///   from.
    /// - Returns: The absolute `XDG_DATA_HOME`, or `~/.local/share`.
    private static func dataHome(environment: [String: String]) -> URL {
        guard let dataHome = environment[dataHomeEnvironmentKey], dataHome.hasPrefix("/") else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(defaultDataHomePath, isDirectory: true)
        }
        return URL(fileURLWithPath: dataHome, isDirectory: true)
    }
}

/// The hook lineage that the host gives a new Router session: the key of
/// the lineage, and the origin of the `SessionStart` of the session
/// (`SessionConfiguration.hookSessionKey` and `SessionConfiguration.hookOrigin`).
///
/// The two values go together: a host that sets a lineage sets both.
struct HookLineage: Sendable, Equatable {
    /// The key of the lineage, which the hooks see in each event of the
    /// session.
    let sessionKey: String

    /// The origin of the `SessionStart` of the session.
    let origin: SessionOrigin

    /// The lineage of a model-slot replacement: the key of the ACP session,
    /// and the origin `replacement`. The ACP session id is the id of the
    /// first Router session of the ACP session, and Router gives that id as
    /// the key of the first session. Thus the replacement continues the
    /// lineage of the session that it replaces.
    ///
    /// - Parameter sessionId: The ACP session that the replacement serves.
    /// - Returns: The lineage of the replacement.
    static func replacement(in sessionId: SessionId) -> HookLineage {
        HookLineage(sessionKey: sessionId.rawValue, origin: .replacement)
    }
}
