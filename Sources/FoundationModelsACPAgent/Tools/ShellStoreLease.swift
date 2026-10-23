import Foundation
import FoundationModelsMultitool
import Synchronization

/// The hold of one session on the shell store of its store directory.
///
/// The store can be shared: the sessions of one store directory hold one
/// store, and each holds its own lease. ``release`` gives this lease back;
/// the registry drops the store at the release of its last lease.
struct ShellStoreLease: Sendable {
    /// The shell store that the lease holds.
    let store: ShellStore

    /// Gives the lease back. A second call is not allowed.
    let release: @Sendable () async -> Void
}

/// The one registry of the shell stores of the process (task ^v3xvh4t): the
/// sessions of one store directory share one `ShellStore`, thus one history,
/// one log and one set of command records. A session of one working
/// directory reads the commands that another session of it ran.
///
/// The key is the resolved store directory: the folder that
/// `tools.shell.storeDirectory` names, or the
/// ``AgentHome/shellStoreDirectory(of:)`` of the working directory, with the
/// symbolic links of its path resolved. Two `ShellStore` values over one
/// directory stay two histories, so every session must lease its store here.
///
/// The registry drops a store when its last lease is given back, so no store
/// stays in memory after the last session of its directory closed.
actor ShellStores {
    /// The one registry of the process.
    static let shared = ShellStores()

    /// One store and the count of its leases.
    private struct Entry {
        /// The store, made by the first lease of its directory.
        let store: ShellStore

        /// The count of the leases on the store.
        var leaseCount: Int
    }

    /// The stores that hold at least one lease, by the resolved path of their
    /// store directory (``key(of:)``).
    private var entries: [String: Entry] = [:]

    /// Leases the shell store of `directory`, and makes it when no lease
    /// holds it.
    ///
    /// - Parameter directory: The resolved store directory of the session.
    /// - Returns: The lease.
    /// - Throws: Whatever `ShellStore(storeDirectory:)` throws when the store
    ///   cannot prepare.
    func acquire(directory: URL) throws -> ShellStoreLease {
        let key = Self.key(of: directory)
        if var entry = entries[key] {
            entry.leaseCount += 1
            entries[key] = entry
            return makeLease(of: entry.store, key: key)
        }
        let store = try ShellStore(storeDirectory: directory)
        entries[key] = Entry(store: store, leaseCount: 1)
        return makeLease(of: store, key: key)
    }

    /// Makes the lease of `store`, whose release counts one lease less on
    /// `key`.
    ///
    /// - Parameters:
    ///   - store: The leased store.
    ///   - key: The registry key of the store.
    /// - Returns: The lease.
    private func makeLease(of store: ShellStore, key: String) -> ShellStoreLease {
        ShellStoreLease(store: store) { await self.release(key: key) }
    }

    /// Counts one lease less on the store of `key`, and drops the store at
    /// zero.
    ///
    /// - Parameter key: The registry key of the store.
    private func release(key: String) {
        guard var entry = entries[key] else {
            return
        }
        entry.leaseCount -= 1
        entries[key] = entry.leaseCount > 0 ? entry : nil
    }

    /// The registry key of `directory`: its path with the symbolic links of
    /// its longest existing ancestor resolved by `realpath(3)`, and the
    /// missing components after it as they are.
    ///
    /// The store directory may not exist yet at the first lease, and the
    /// store makes it. A plain resolve would then give the first lease and a
    /// later lease two keys: Foundation strips `/private` from a path only
    /// once the path exists. `realpath(3)` keeps `/private` and resolves only
    /// what exists, so each lease of one directory gets one key.
    ///
    /// - Parameter directory: The store directory.
    /// - Returns: The key.
    private static func key(of directory: URL) -> String {
        resolvedPath(of: directory.standardizedFileURL)
    }

    /// The path of `url` with its longest existing ancestor resolved by
    /// `realpath(3)`.
    ///
    /// - Parameter url: A standardized file URL.
    /// - Returns: The resolved path, or the path of `url` as it is when no
    ///   ancestor resolves.
    private static func resolvedPath(of url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else {
            return url.path
        }
        return resolvedPath(of: parent) + "/" + url.lastPathComponent
    }
}

/// The ACP session id that the shell of one session records as the owner of
/// each command it runs.
///
/// The shell capability is built before the session exists, so the id is
/// bound late: the activation of the session binds it, once the session is
/// made. The capability reads ``current`` when each command starts. A model
/// slot switch makes a new Router session over the same tools and binds
/// nothing, so the shell keeps the ACP session id.
final class ShellSessionIdentity: Sendable {
    /// The bound ACP session id, or `nil` until ``bind(_:)`` runs.
    private let sessionID = Mutex<String?>(nil)

    /// Binds the ACP session id of the session.
    ///
    /// - Parameter sessionID: The ACP session id.
    func bind(_ sessionID: String) {
        self.sessionID.withLock { $0 = sessionID }
    }

    /// The bound ACP session id, or `nil` before the bind.
    var current: String? {
        sessionID.withLock { $0 }
    }
}
