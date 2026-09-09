import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The `doctor` component of the transcripts (cli-plan.md §5.12, row 3):
/// the resolved recording root exists, or the nearest directory above it
/// can be written, so Router can create it.
///
/// With `recording.level: off` nothing is ever written there, so the
/// component reports ``isApplicable`` as `false` and stays silent rather
/// than checking a directory no session will use.
///
/// The component takes the resolved configuration and the stack the load
/// read. It reads no process environment, so a test drives it over a
/// temporary stack.
public struct TranscriptsDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "transcripts"

    /// The one check this component states.
    private static let checkName = "the transcripts directory"

    /// The dotted key path of the location a fix names.
    private static let locationKey =
        AgentConfiguration.CodingKeys.transcripts.stringValue
        + LoadedConfiguration.keyPathSeparator
        + TranscriptsConfiguration.CodingKeys.location.stringValue

    // MARK: - Stored state

    /// The resolved configuration, which names the location and the
    /// recording level.
    private let configuration: AgentConfiguration

    /// The layer stack, which roots a `home` location under its user layer.
    private let stack: DotfolderStack

    /// The dotfolder name, which names the project dotfolder.
    private let name: DotfolderName

    /// The session working directory, which roots a `project` location and
    /// gives the slug of a `home` one.
    private let workingDirectory: URL

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = TranscriptsDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = TranscriptsDoctor.category

    /// Whether anything will be recorded at all.
    public var isApplicable: Bool {
        configuration.recording.level != .off
    }

    /// Makes the component over one resolved configuration and the stack
    /// that produced it.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration.
    ///   - stack: The layer stack, whose user layer roots a `home` location.
    ///   - name: The dotfolder name of that stack.
    ///   - workingDirectory: The session working directory.
    public init(
        configuration: AgentConfiguration, stack: DotfolderStack, name: DotfolderName,
        workingDirectory: URL
    ) {
        self.configuration = configuration
        self.stack = stack
        self.name = name
        self.workingDirectory = workingDirectory
    }

    /// Reports the one finding of the resolved recording root.
    ///
    /// - Returns: That finding.
    public func runHealthChecks() async -> [HealthCheck] {
        [Self.check(of: recordingRoot)]
    }

    // MARK: - The recording root

    /// The directory Router records each session under (plan.md §4.1).
    private var recordingRoot: URL {
        configuration.transcripts.location.recordingRoot(
            workingDirectory: workingDirectory, name: name, userDirectory: userDirectory)
    }

    /// The user layer root, which a `home` location writes under.
    ///
    /// `DotfolderStack` always appends a user layer, so the working
    /// directory is a fallback no stack the loader builds ever reaches.
    private var userDirectory: URL {
        stack.layers.last { $0.source == .user }?.root ?? workingDirectory
    }

    /// The finding of one recording root: it exists and can be written, or
    /// the nearest directory above it can be written, so Router creates it.
    ///
    /// - Parameter root: The resolved recording root.
    /// - Returns: A pass, or the failure that says why the directory cannot
    ///   be used.
    private static func check(of root: URL) -> HealthCheck {
        let target = root.standardizedFileURL
        guard !isFile(target) else {
            return .error(
                name: checkName,
                message: "\(target.path) is a file, so no transcripts directory can stand there",
                fix: fix(naming: target), category: category)
        }
        let existing = nearestExistingDirectory(of: target)
        guard FileManager.default.isWritableFile(atPath: existing.path) else {
            return .error(
                name: checkName,
                message: "\(existing.path) cannot be written, so \(target.path) cannot be used",
                fix: fix(naming: existing), category: category)
        }
        guard existing != target else {
            return .ok(
                name: checkName, message: "\(target.path) exists and can be written",
                category: category)
        }
        return .ok(
            name: checkName,
            message: "\(target.path) is not on disk yet, and \(existing.path) can be written",
            category: category)
    }

    /// The fix of a recording root that cannot be used: make the directory
    /// writable, or point the configuration key somewhere else.
    ///
    /// - Parameter directory: The directory that stands in the way.
    /// - Returns: The fix text.
    private static func fix(naming directory: URL) -> String {
        "make \(directory.path) writable, or set \(locationKey) in "
            + "\(ConfigurationLoader.configFileName) to a directory that can be written"
    }

    /// Whether `url` names something on disk that is not a directory.
    ///
    /// - Parameter url: The path to test.
    /// - Returns: `true` when something stands there and it is not a
    ///   directory.
    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The nearest directory of `url`'s path that is on disk: `url` itself
    /// when it exists, else the closest one above it.
    ///
    /// - Parameter url: The path to walk up from.
    /// - Returns: The nearest existing directory. The walk ends at the file
    ///   system root, which always exists.
    private static func nearestExistingDirectory(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else {
                return candidate
            }
            candidate = parent
        }
        return candidate
    }
}
