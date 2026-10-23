import Foundation
import FoundationModelsACP
import FoundationModelsHooks
import Synchronization

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
    /// The name of the folder of the snapshots, under the data directory.
    static let snapshotFolderName = "snapshot"

    /// The dispatcher that each Router session sends its hook events to.
    public let dispatcher: HookDispatcher

    /// The store of the workspace snapshots, which `SnapshotHook` and the
    /// Multitool `snapshots` capability share. It is the one store of the
    /// snapshot folder in the process (`SnapshotStore.shared(directory:)`), so
    /// two agents of one process on one data directory share the open keys
    /// of the store and do not race on a timeline.
    public let snapshotStore: SnapshotStore

    /// Makes the dispatcher, takes the shared store of the snapshot folder,
    /// and registers `SnapshotHook` on the dispatcher as its first visitor.
    ///
    /// - Parameter dataDirectory: The directory where the hooks keep their
    ///   data, for example ``AgentHome/hooksDirectory``. The snapshots go
    ///   into its ``snapshotFolderName`` folder.
    public init(dataDirectory: URL) {
        dispatcher = HookDispatcher(dataDirectory: dataDirectory)
        snapshotStore = SnapshotStore.shared(directory: Self.snapshotDirectory(in: dataDirectory))
        dispatcher.register(SnapshotHook(store: snapshotStore))
    }

    /// The directory of the snapshots under a hook data directory.
    ///
    /// - Parameter dataDirectory: The hook data directory.
    /// - Returns: The ``snapshotFolderName`` folder of `dataDirectory`.
    static func snapshotDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(snapshotFolderName, isDirectory: true)
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
}

extension HookLineage {
    /// The lineage of a session of the agent in `workingDirectory`: the key
    /// of the working directory (``AgentHome/projectKey(of:)``), so each
    /// session in one folder, and the replacement of a model-slot switch, has
    /// one key and one snapshot timeline. A rollback restores the whole work
    /// tree, so one timeline for each folder is the timeline that each of
    /// its sessions sees.
    ///
    /// - Parameters:
    ///   - workingDirectory: The working directory of the session.
    ///   - origin: The origin of the `SessionStart` of the session.
    init(workingDirectory: URL, origin: SessionOrigin) {
        self.init(sessionKey: AgentHome.projectKey(of: workingDirectory), origin: origin)
    }
}

/// The snapshot session key of each ACP session that an agent of this
/// process opened or resumed, for the `sessionKey` resolver of the Multitool
/// `snapshots` endpoints.
///
/// The change log of one `SnapshotStore` reads the resolver of the first
/// endpoint over that store, and `SnapshotStore.shared(directory:)` gives one
/// store to each agent of the process on one folder. Thus the agent endpoint
/// and the capability of each session of each such agent must map a session
/// to its key in the same way: they all read this one map. A session id is a
/// ULID, so the sessions of two agents never collide in it.
final class SnapshotSessionKeys: Sendable {
    /// The map of the process.
    static let shared = SnapshotSessionKeys()

    /// The key of each session, by the ACP session id.
    private let keys = Mutex<[String: String]>([:])

    /// Records the key of a session that the agent opened or resumed.
    ///
    /// - Parameters:
    ///   - sessionKey: The hook session key of the session.
    ///   - sessionId: The ACP session id.
    func record(_ sessionKey: String, for sessionId: SessionId) {
        keys.withLock { $0[sessionId.rawValue] = sessionKey }
    }

    /// Forgets a deleted session.
    ///
    /// - Parameter sessionId: The ACP session id.
    func forget(_ sessionId: SessionId) {
        _ = keys.withLock { $0.removeValue(forKey: sessionId.rawValue) }
    }

    /// The key of a session.
    ///
    /// - Parameter sessionId: The session id, as the endpoint names it.
    /// - Returns: The key, or `nil` for a session that no agent of the
    ///   process opened.
    func sessionKey(of sessionId: String) -> String? {
        keys.withLock { $0[sessionId] }
    }

    /// The `sessionKey` resolver of a Multitool `snapshots` endpoint over
    /// this map.
    var resolver: @Sendable (String) async -> String? {
        { [self] sessionId in sessionKey(of: sessionId) }
    }
}
