import Foundation
import FoundationModelsACP
import FoundationModelsHooks
import FoundationModelsMultitool
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
/// `snapshots` endpoints, and the map between the ACP sessions and the Router
/// sessions that own the store, for their `hostSession` and `storeOwner`
/// resolvers.
///
/// The change log of one `SnapshotStore` reads the resolvers of the first
/// endpoint over that store, and `SnapshotStore.shared(directory:)` gives one
/// store to each agent of the process on one folder. Thus the agent endpoint
/// and the capability of each session of each such agent must map a session
/// in the same way: they all read this one map, through
/// ``makeEndpoint(over:)`` and ``makeCapability(over:)``. A session id is a
/// ULID, so the sessions of two agents never collide in it.
///
/// The owners of the store are Router session ids. The first Router session
/// of an ACP session has the id of the ACP session, so it needs no mapping.
/// A model-slot switch replaces it with a Router session of a new id
/// (``recordReplacement(_:of:)``): the endpoints then name the ACP session
/// as the owner of each checkpoint of the replacement, and act as the
/// replacement for the ACP session.
final class SnapshotSessionKeys: Sendable {
    /// The maps of one process, under one lock.
    private struct Maps {
        /// The key of each session, by the ACP session id.
        var keys: [String: String] = [:]

        /// The ACP session of each replacement, by its Router session id.
        var hostSessions: [String: String] = [:]

        /// The live Router session of each switched ACP session, by the ACP
        /// session id.
        var storeOwners: [String: String] = [:]
    }

    /// The map of the process.
    static let shared = SnapshotSessionKeys()

    /// The maps.
    private let maps = Mutex(Maps())

    /// Records the key of a session that the agent opened or resumed.
    ///
    /// - Parameters:
    ///   - sessionKey: The hook session key of the session.
    ///   - sessionId: The ACP session id.
    func record(_ sessionKey: String, for sessionId: SessionId) {
        maps.withLock { $0.keys[sessionId.rawValue] = sessionKey }
    }

    /// Records the Router session that a model-slot switch made to serve an
    /// ACP session: its checkpoints name the ACP session as their owner, and
    /// it is the live store owner of the ACP session.
    ///
    /// - Parameters:
    ///   - owner: The Router session id of the replacement.
    ///   - sessionId: The ACP session that the replacement serves.
    func recordReplacement(_ owner: String, of sessionId: SessionId) {
        maps.withLock { maps in
            maps.hostSessions[owner] = sessionId.rawValue
            maps.storeOwners[sessionId.rawValue] = owner
        }
    }

    /// Forgets the live store owner of a session whose Router session the
    /// agent released. The host session of each replacement stays, so its
    /// checkpoints still name the ACP session.
    ///
    /// - Parameter sessionId: The ACP session id.
    func forgetLiveOwner(of sessionId: SessionId) {
        _ = maps.withLock { $0.storeOwners.removeValue(forKey: sessionId.rawValue) }
    }

    /// Forgets a deleted session: its key, its live store owner, and the
    /// host session of each of its replacements.
    ///
    /// - Parameter sessionId: The ACP session id.
    func forget(_ sessionId: SessionId) {
        maps.withLock { maps in
            maps.keys.removeValue(forKey: sessionId.rawValue)
            maps.storeOwners.removeValue(forKey: sessionId.rawValue)
            maps.hostSessions = maps.hostSessions.filter { $0.value != sessionId.rawValue }
        }
    }

    /// The key of a session.
    ///
    /// - Parameter sessionId: The session id, as the endpoint names it.
    /// - Returns: The key, or `nil` for a session that no agent of the
    ///   process opened.
    func sessionKey(of sessionId: String) -> String? {
        value(for: sessionId, in: \.keys)
    }

    /// The ACP session of an owner of the store.
    ///
    /// - Parameter owner: The Router session id of the owner.
    /// - Returns: The ACP session that the owner serves as a replacement, or
    ///   `nil` for an owner that is no replacement: its id is the id of its
    ///   ACP session.
    func hostSession(of owner: String) -> String? {
        value(for: owner, in: \.hostSessions)
    }

    /// The live store owner of an ACP session.
    ///
    /// - Parameter sessionId: The ACP session id.
    /// - Returns: The Router session id of the replacement that serves the
    ///   session now, or `nil` when the session has no live replacement: its
    ///   own id owns the store.
    func storeOwner(of sessionId: String) -> String? {
        value(for: sessionId, in: \.storeOwners)
    }

    /// Makes the agent `snapshots` endpoint over `store` with the resolvers
    /// of this map.
    ///
    /// - Parameter store: The store of the endpoint.
    /// - Returns: The endpoint.
    func makeEndpoint(over store: SnapshotStore) -> SnapshotsGraph {
        make(over: store, with: SnapshotsGraph.init(store:sessionKey:hostSession:storeOwner:))
    }

    /// Makes the `snapshots` capability of a session over `store` with the
    /// resolvers of this map.
    ///
    /// - Parameter store: The store of the capability.
    /// - Returns: The capability.
    func makeCapability(over store: SnapshotStore) -> SnapshotsCapability {
        make(over: store, with: SnapshotsCapability.init(store:sessionKey:hostSession:storeOwner:))
    }

    /// A resolver of a Multitool `snapshots` endpoint: it maps one session id
    /// to another, or to `nil`.
    private typealias Resolver = @Sendable (String) async -> String?

    /// Makes a Multitool `snapshots` endpoint over `store` with the resolvers
    /// of this map: ``sessionKey(of:)``, ``hostSession(of:)`` and
    /// ``storeOwner(of:)``.
    ///
    /// - Parameters:
    ///   - store: The store of the endpoint.
    ///   - initializer: The `init(store:sessionKey:hostSession:storeOwner:)`
    ///     of the endpoint type.
    /// - Returns: The endpoint.
    private func make<Endpoint>(
        over store: SnapshotStore,
        with initializer: (SnapshotStore, @escaping Resolver, @escaping Resolver, @escaping Resolver) -> Endpoint
    ) -> Endpoint {
        initializer(store, sessionKey(of:), hostSession(of:), storeOwner(of:))
    }

    /// Reads one entry of one map under the lock.
    ///
    /// - Parameters:
    ///   - id: The key of the entry.
    ///   - map: The map to read.
    /// - Returns: The value of the entry, or `nil` when the map has none.
    private func value(for id: String, in map: KeyPath<Maps, [String: String]>) -> String? {
        maps.withLock { $0[keyPath: map][id] }
    }
}
