import Foundation
import FoundationModelsMultitool

/// The `sandbox:` section (plan.md §11.7): the one key, `extraWritePaths`.
/// The section builds the write confinement the shell capability runs
/// under, `SeatbeltSandbox.Options`, over the session root set.
///
/// **Stated limit (plan.md §2.5):** the sandbox bounds writing and deleting
/// only. Reads are free and the network is open, so exfiltration is not
/// bounded.
public struct SandboxConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// Extra write grants beyond the session root set, for a file or a
    /// directory the host needs writable without a grant of a whole root.
    /// They do not widen containment: a working directory must still sit
    /// inside the writable roots.
    public var extraWritePaths: [String] = []

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case extraWritePaths
    }

    /// The default: no extra write paths.
    public init() {}

    /// Decodes `extraWritePaths` when present and keeps the default
    /// otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extraWritePaths =
            try container.decodeIfPresent([String].self, forKey: .extraWritePaths)
            ?? extraWritePaths
    }
}

extension SandboxConfiguration {
    /// Builds the write confinement over the session root set: the working
    /// directory plus the additional roots become the writable roots, and
    /// the configured `extraWritePaths` ride along.
    ///
    /// The options build only through
    /// `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)`, which runs
    /// `realpath(3)` over both lists — the resolved-path precondition of
    /// `CommandSandbox`. `URL.resolvingSymlinksInPath()` never substitutes:
    /// on macOS it strips `/private` and gives exactly the form Seatbelt
    /// cannot match (plan.md §2.5).
    ///
    /// - Parameters:
    ///   - workingDirectory: The session working directory — the root set's
    ///     first and mandatory member, so the writable roots are never
    ///     empty and never fall back to the process working directory.
    ///   - additionalRoots: The session's additional roots, in order.
    /// - Returns: The options a `SeatbeltSandbox` over the session root set
    ///   is made from.
    public func sandboxOptions(workingDirectory: URL, additionalRoots: [URL] = [])
        -> SeatbeltSandbox.Options
    {
        SeatbeltSandbox.Options(
            writableRoots: ([workingDirectory] + additionalRoots).map(\.path),
            extraWritePaths: extraWritePaths)
    }
}
