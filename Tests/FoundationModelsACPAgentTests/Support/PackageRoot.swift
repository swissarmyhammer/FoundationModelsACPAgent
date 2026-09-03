import Foundation

/// Locates the repository root — the directory that holds the root
/// `Package.swift` — from a source file inside it.
///
/// A suite that asserts on a checked-in file (the README, a workflow) has
/// to find that file at run time. `#filePath` is the only anchor that
/// survives: a test bundle stands under `.build`, and the working
/// directory of a test run is not promised. This one home keeps the walk,
/// so a suite that moves between directories does not carry a hand-counted
/// chain of `deletingLastPathComponent()` with it.
enum PackageRoot {
    /// The names that together mark the root of this repository. The
    /// nested `IntegrationTests` package holds a `Package.swift` too, so
    /// the manifest alone does not identify the root.
    private static let rootMarkers = ["Package.swift", "Sources"]

    /// What the walk refused.
    enum RootError: Error, CustomStringConvertible {
        /// No ancestor of `path` holds every name of ``rootMarkers``.
        case rootNotFound(fromFile: String)

        /// A human-readable description of this error.
        var description: String {
            switch self {
            case .rootNotFound(let path):
                return
                    "No ancestor directory of \"\(path)\" holds \(rootMarkers.joined(separator: " and ")); the repository root cannot be resolved from this file."
            }
        }
    }

    /// The repository root, found by walking up from `filePath`.
    ///
    /// - Parameter filePath: A source file inside the repository. The
    ///   default is the calling file, which is what every caller wants.
    /// - Returns: The directory that holds the root `Package.swift`.
    /// - Throws: ``RootError/rootNotFound(fromFile:)`` when no ancestor
    ///   qualifies.
    static func directory(fromFile filePath: StaticString = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while true {
            if rootMarkers.allSatisfy({
                FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent($0).path)
            }) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else {
                throw RootError.rootNotFound(fromFile: "\(filePath)")
            }
            candidate = parent
        }
    }
}
