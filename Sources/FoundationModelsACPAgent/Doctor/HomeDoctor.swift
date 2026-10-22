import Foundation
import FoundationModelsExtras

/// The `doctor` component of the home (task ^98a44n7): it shows the
/// resolved home, one row for the synced root and one for the local root.
///
/// Each row names its folder, so a person sees which home the agent uses:
/// the XDG folders of the CLI, or the folders that `--home` or
/// `ACP_AGENT_HOME` name. A root passes when it is a directory that can be
/// written, or when the nearest directory above it can be written, because
/// the agent makes the root the first time it writes there
/// (``WritableDirectoryCheck``).
///
/// The component reads no process environment, so a test drives it over a
/// custom home in a temporary folder.
public struct HomeDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "home"

    /// The check of the synced root.
    private static let syncedCheckName = "the synced home"

    /// What stands at the synced root, for the message of a path that a
    /// file already blocks.
    private static let syncedSubject = "synced home folder"

    /// The check of the local root.
    private static let localCheckName = "the local home"

    /// What stands at the local root, for the message of a path that a file
    /// already blocks.
    private static let localSubject = "local home folder"

    // MARK: - Stored state

    /// The home the rows show.
    private let home: AgentHome

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = HomeDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = HomeDoctor.category

    /// Makes the component over one home.
    ///
    /// - Parameter home: The resolved home of the agent.
    public init(home: AgentHome) {
        self.home = home
    }

    /// Reports the synced root, then the local root.
    ///
    /// - Returns: The two findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        [
            Self.check(of: home.synced, name: Self.syncedCheckName, subject: Self.syncedSubject),
            Self.check(of: home.local, name: Self.localCheckName, subject: Self.localSubject),
        ]
    }

    // MARK: - The roots

    /// The finding of one root of the home.
    ///
    /// - Parameters:
    ///   - root: The root folder.
    ///   - name: What the finding is called in the report.
    ///   - subject: What stands at the root, as a noun phrase.
    /// - Returns: A pass that names the folder, or the failure that says why
    ///   the folder cannot be used.
    private static func check(of root: URL, name: String, subject: String) -> HealthCheck {
        WritableDirectoryCheck.check(
            of: root, name: name, subject: subject, category: category, fix: fix(naming:))
    }

    /// The fix of a root that cannot be used: make the folder writable, or
    /// choose another home.
    ///
    /// - Parameter directory: The directory that stands in the way.
    /// - Returns: The fix text.
    private static func fix(naming directory: URL) -> String {
        "make \(directory.path) writable, or choose another home with --home or ACP_AGENT_HOME"
    }
}
