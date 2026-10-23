import Foundation
import FoundationModelsCodeContext
import FoundationModelsRouter

/// The hold of one session on the code context of its working directory.
///
/// The context can be shared: the sessions of one working directory hold
/// one context, and each holds its own lease. ``release`` gives this lease
/// back; the context stops at the release of its last lease.
struct CodeContextLease: Sendable {
    /// The code context that the lease holds.
    let context: CodeContext<ProcessLanguageServerConnection>

    /// Gives the lease back. A second call is not allowed.
    let release: @Sendable () async -> Void
}

/// The one registry of the code contexts of the process (task ^sxgcjds):
/// the sessions of one working directory share one code context, thus one
/// file watcher, one index loop, one fleet of language servers and one
/// database pool.
///
/// The registry keeps one `CodeContextManager` for each set of the pieces
/// that a manager gives every context it opens (``ManagerSettings``): the
/// embedder, the language server install, and the home whose local root
/// holds the index. A manager has one embedder by the rule of the code
/// context package, so a session whose profile has another embedder, or
/// whose `semanticSearch` is off, gets another manager. The manager keys
/// each root with `CodeContextManager.rootKey(for:)`, and a session in a
/// folder inside an open root leases the context of that root.
///
/// The index of each context is in ``AgentHome/codeContextIndexDirectory(of:)``
/// of the home, never in the working directory, which can be in a synced
/// folder.
///
/// The registry drops a manager when its last lease is given back, so no
/// manager keeps the embedder of a profile after the last session of that
/// profile closed.
actor CodeContextLeases {
    /// The one registry of the process.
    static let shared = CodeContextLeases()

    /// The pieces that one manager gives each code context it opens.
    struct ManagerSettings: Sendable {
        /// The embedder of each context, or `nil` when `semanticSearch` is
        /// off: the embedding slot of the resolved profile of the session.
        let embedder: RoutedEmbedder?

        /// The language server install of each context.
        let autoInstall: LspAutoInstall

        /// The home whose local root holds the index of each context.
        let home: AgentHome

        /// The key of the manager these settings make.
        var key: ManagerKey {
            ManagerKey(
                embedder: embedder.map(ObjectIdentifier.init), autoInstall: autoInstall, localRoot: home.local)
        }

        /// The embedder that each context of the manager embeds with.
        var pooledEmbedder: (any PooledEmbedding)? {
            embedder.map(ProfileEmbedding.init(embedder:))
        }
    }

    /// The identity of one manager: two sessions share a manager when their
    /// settings give the same key.
    struct ManagerKey: Hashable, Sendable {
        /// The identity of the embedding handle, or `nil` for no embedder.
        let embedder: ObjectIdentifier?

        /// The language server install of each context.
        let autoInstall: LspAutoInstall

        /// The local root of the home, which holds the index of each context.
        let localRoot: URL

        /// Whether two keys name one manager: the same embedder, the same
        /// language server install and the same local root.
        ///
        /// - Parameters:
        ///   - lhs: One key.
        ///   - rhs: The other key.
        /// - Returns: Whether the keys name one manager.
        static func == (lhs: ManagerKey, rhs: ManagerKey) -> Bool {
            lhs.embedder == rhs.embedder && lhs.autoInstall == rhs.autoInstall && lhs.localRoot == rhs.localRoot
        }

        /// Hashes the embedder and the local root. `LspAutoInstall` is
        /// `Equatable` only, and equal keys always have equal embedders and
        /// equal local roots, so the hash stays consistent with `==`.
        ///
        /// - Parameter hasher: The hasher to feed.
        func hash(into hasher: inout Hasher) {
            hasher.combine(embedder)
            hasher.combine(localRoot)
        }
    }

    /// One manager and the count of its leases.
    private struct Entry {
        /// The manager, made once by the first lease of its key. The task
        /// lets a second acquire that comes during the make wait for the
        /// same manager.
        let manager: Task<CodeContextManager<ProcessLanguageServerConnection>, Never>

        /// The count of the leases on any context of the manager, the
        /// acquires still in progress included.
        var leaseCount: Int
    }

    /// The managers that hold at least one lease, by key.
    private var entries: [ManagerKey: Entry] = [:]

    /// Leases the code context of `root`, and opens and starts it when no
    /// context of the same manager covers `root`.
    ///
    /// A root inside an open root leases the context of that open root. A
    /// root that is a parent of an open root cannot share: the open context
    /// covers only its own folder. That session gets a context of its own,
    /// which no other session leases and which stops at its release.
    ///
    /// - Parameters:
    ///   - root: The working directory of the session.
    ///   - settings: The settings of the manager of the context.
    /// - Returns: The lease.
    /// - Throws: Whatever the open or the start of the context throws.
    func acquire(root: URL, settings: ManagerSettings) async throws -> CodeContextLease {
        let key = settings.key
        let manager = reserveLease(of: settings)
        let context: CodeContext<ProcessLanguageServerConnection>
        do {
            context = try await manager.value.acquire(root: root)
        } catch CodeContextError.overlappingRoot {
            giveBackLease(of: key)
            return try await makeUnsharedLease(root: root, settings: settings)
        } catch {
            giveBackLease(of: key)
            throw error
        }
        return CodeContextLease(context: context) { await self.release(root: root, key: key) }
    }

    /// Counts one more lease on the manager of `settings`, and makes the
    /// manager when it has no entry.
    ///
    /// The count goes up before the first suspension of the acquire, so a
    /// release that runs during the acquire never drops the manager.
    ///
    /// - Parameter settings: The settings of the manager.
    /// - Returns: The task that makes the manager.
    private func reserveLease(
        of settings: ManagerSettings
    ) -> Task<CodeContextManager<ProcessLanguageServerConnection>, Never> {
        let key = settings.key
        if var entry = entries[key] {
            entry.leaseCount += 1
            entries[key] = entry
            return entry.manager
        }
        let manager = Task { await Self.makeManager(settings: settings) }
        entries[key] = Entry(manager: manager, leaseCount: 1)
        return manager
    }

    /// Gives back one lease of the context of `root`, and drops the manager
    /// when that was its last lease.
    ///
    /// The manager stops the context at the last lease of the context. The
    /// count goes down after that release, so an acquire for the same root
    /// that comes during the stop uses the same manager, which opens a new
    /// context only after the old one stopped.
    ///
    /// - Parameters:
    ///   - root: The root that the lease acquired.
    ///   - key: The key of the manager of the lease.
    private func release(root: URL, key: ManagerKey) async {
        guard let entry = entries[key] else {
            return
        }
        await entry.manager.value.release(root: root)
        giveBackLease(of: key)
    }

    /// Counts one lease less on the manager of `key`, and drops the manager
    /// at zero. A manager at zero holds no open context: each context it
    /// opened came from an acquire, and each acquire gave its lease back.
    ///
    /// - Parameter key: The key of the manager.
    private func giveBackLease(of key: ManagerKey) {
        guard var entry = entries[key] else {
            return
        }
        entry.leaseCount -= 1
        entries[key] = entry.leaseCount > 0 ? entry : nil
    }

    /// Opens and starts a code context that no other session shares, for a
    /// root that the manager cannot open because it is a parent of an open
    /// root. Its index is in the same folder as a shared context of that
    /// root would have.
    ///
    /// - Parameters:
    ///   - root: The working directory of the session.
    ///   - settings: The settings of the context.
    /// - Returns: The lease, whose release stops the context.
    /// - Throws: Whatever the open or the start of the context throws. After
    ///   a failed start the context is stopped.
    private func makeUnsharedLease(root: URL, settings: ManagerSettings) async throws -> CodeContextLease {
        let context = try await CodeContext(
            rootDirectory: root,
            embedder: settings.pooledEmbedder,
            autoInstall: settings.autoInstall,
            indexDirectory: settings.home.codeContextIndexDirectory(of: root))
        do {
            try await context.start()
        } catch {
            await context.stop()
            throw error
        }
        return CodeContextLease(context: context) { await context.stop() }
    }

    /// Makes the manager of `settings`: each context it opens gets the
    /// embedder and the language server install of `settings`, and keeps
    /// its index in the local root of the home of `settings`.
    ///
    /// - Parameter settings: The settings of the manager.
    /// - Returns: The manager, with no open root.
    private static func makeManager(
        settings: ManagerSettings
    ) async -> CodeContextManager<ProcessLanguageServerConnection> {
        let home = settings.home
        return await CodeContextManager(
            embedder: settings.pooledEmbedder,
            autoInstall: settings.autoInstall,
            indexDirectory: { root in home.codeContextIndexDirectory(of: root) })
    }
}
