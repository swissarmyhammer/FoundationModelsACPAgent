import Foundation
import FoundationModelsRouter

/// What one lookup of a model reference gave (cli-plan.md §5.12, the
/// Profile row).
///
/// A lookup never throws. `doctor` runs every check, so a refusal must
/// travel as a value that the component turns into a finding, and never as
/// an error that stops the run.
public enum ModelLookup: Equatable, Sendable {
    /// The repository is on the Hub. `downloadBytes` is what the next run
    /// must still fetch: zero when the cache already holds every file.
    case found(downloadBytes: Int64)

    /// The Hub has no such repository.
    case notFound

    /// The Hub could not be reached. The reason is the text a person
    /// reads.
    case unreachable(reason: String)

    /// The lookup did not answer inside the timeout.
    case noAnswer
}

/// How ``ProfileDoctor`` reaches Hugging Face and the model cache
/// (cli-plan.md §5.12).
///
/// The component takes a resolver, so a unit test asks no network endpoint
/// and reads no multi-gigabyte cache: it scripts the answers and the
/// findings come out the same on any machine.
/// ``SystemModelResolver`` is the one that does the real work.
public protocol ModelResolver: Sendable {
    /// Looks up one model reference.
    ///
    /// - Parameter reference: The reference to look up.
    /// - Returns: What the lookup gave.
    func lookUp(_ reference: ModelRef) async -> ModelLookup
}

/// The ``ModelResolver`` that does the real work: it reads the repository
/// tree from the Hugging Face Hub, and it compares that tree with the
/// files the local hub cache already holds.
///
/// Only the `doctor` command builds this. Every unit test injects a stub,
/// because this type asks a network endpoint and walks a cache directory
/// that holds gigabytes.
public struct SystemModelResolver: ModelResolver {
    // MARK: - Constants

    /// The environment variable that names the hub cache directly.
    private static let hubCacheVariable = "HF_HUB_CACHE"

    /// The environment variable that names the Hugging Face home, whose
    /// `hub` subdirectory is the cache.
    private static let homeVariable = "HF_HOME"

    /// The subdirectory of `HF_HOME` that holds the cache.
    private static let hubDirectoryName = "hub"

    /// The cache directory of a machine that names neither variable, below
    /// the home directory of the user.
    private static let standardCachePath = ".cache/huggingface/hub"

    /// The prefix of the cache directory of one model repository.
    private static let repositoryPrefix = "models--"

    /// What the owner separator of a repository id becomes in the name of
    /// its cache directory.
    private static let cacheSeparator = "--"

    /// The subdirectory of a repository cache that holds one directory per
    /// revision.
    private static let snapshotsDirectoryName = "snapshots"

    // MARK: - Stored state

    /// How the repository tree is read.
    private let source: any MetadataSource

    /// The hub cache directory, whose snapshots say which files are
    /// already on disk.
    private let cacheDirectory: URL

    // MARK: - Making one

    /// Makes the resolver that reads the real Hub and the real cache.
    ///
    /// - Parameter environment: The environment the cache location is read
    ///   from. See ``hubCacheDirectory(environment:)``.
    public init(environment: [String: String]) {
        self.init(
            source: HuggingFaceMetadataSource(),
            cacheDirectory: Self.hubCacheDirectory(environment: environment))
    }

    /// Makes the resolver over one metadata source and one cache
    /// directory.
    ///
    /// - Parameters:
    ///   - source: How the repository tree is read.
    ///   - cacheDirectory: The hub cache directory.
    init(source: any MetadataSource, cacheDirectory: URL) {
        self.source = source
        self.cacheDirectory = cacheDirectory
    }

    /// The hub cache directory `environment` names.
    ///
    /// The order is the one the Hugging Face libraries use: `HF_HUB_CACHE`
    /// first, then the `hub` subdirectory of `HF_HOME`, then
    /// `~/.cache/huggingface/hub`.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: The cache directory.
    public static func hubCacheDirectory(environment: [String: String]) -> URL {
        if let cache = environment[hubCacheVariable], !cache.isEmpty {
            return directory(atPath: cache)
        }
        if let home = environment[homeVariable], !home.isEmpty {
            return directory(atPath: home).appendingPathComponent(
                hubDirectoryName, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            standardCachePath, isDirectory: true)
    }

    /// One directory URL of a configured path, with a leading tilde
    /// expanded.
    ///
    /// - Parameter path: The configured path.
    /// - Returns: The directory URL.
    private static func directory(atPath path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
    }

    // MARK: - The lookup

    /// Reads the repository tree of `reference`, and prices what the cache
    /// does not already hold.
    ///
    /// A tree that does not decode is a repository the Hub does not serve:
    /// the Hub answers a missing repository with an error document and not
    /// with a listing, so the failed decode is the not-found answer.
    ///
    /// - Parameter reference: The reference to look up.
    /// - Returns: What the lookup gave.
    public func lookUp(_ reference: ModelRef) async -> ModelLookup {
        let (repo, revision) = ModelReferenceFormat.parts(of: reference)
        do {
            let raw = try await source.fetchRawMetadata(repo: repo, revision: revision)
            guard let entries = Self.entries(inTree: raw.treeJSON) else {
                return .notFound
            }
            return .found(downloadBytes: missingBytes(of: entries, repo: repo))
        } catch {
            return .unreachable(reason: String(describing: error))
        }
    }

    // MARK: - The tree

    /// One file of a repository tree listing.
    private struct TreeEntry: Decodable {
        /// The path of the file inside the repository.
        let path: String

        /// The size of the file in bytes, which the listing states for a
        /// file and leaves out for a directory.
        let size: Int64?
    }

    /// The files of one tree listing document.
    ///
    /// - Parameter treeJSON: The listing bytes.
    /// - Returns: The files, or `nil` when the document is not a listing.
    private static func entries(inTree treeJSON: Data) -> [TreeEntry]? {
        try? JSONDecoder().decode([TreeEntry].self, from: treeJSON)
    }

    // MARK: - The cache

    /// The bytes of `entries` that no snapshot of `repo` already holds.
    ///
    /// - Parameters:
    ///   - entries: The files of the repository.
    ///   - repo: The repository id.
    /// - Returns: The bytes the next run must still download.
    private func missingBytes(of entries: [TreeEntry], repo: String) -> Int64 {
        let snapshots = snapshotDirectories(of: repo)
        return entries.reduce(0) { total, entry in
            guard let size = entry.size, !Self.isOnDisk(entry.path, under: snapshots) else {
                return total
            }
            return total + size
        }
    }

    /// The snapshot directories the cache holds for `repo`, one per
    /// revision.
    ///
    /// - Parameter repo: The repository id.
    /// - Returns: The snapshot directories, or an empty array when the
    ///   cache holds none.
    private func snapshotDirectories(of repo: String) -> [URL] {
        let name =
            Self.repositoryPrefix
            + repo.replacingOccurrences(
                of: String(ModelReferenceFormat.ownerSeparator), with: Self.cacheSeparator)
        let snapshots = cacheDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(Self.snapshotsDirectoryName, isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)
        return contents ?? []
    }

    /// Whether one repository file already stands under any snapshot.
    ///
    /// - Parameters:
    ///   - path: The path of the file inside the repository.
    ///   - snapshots: The snapshot directories to look under.
    /// - Returns: `true` when the file is on disk.
    private static func isOnDisk(_ path: String, under snapshots: [URL]) -> Bool {
        snapshots.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path)
        }
    }
}
