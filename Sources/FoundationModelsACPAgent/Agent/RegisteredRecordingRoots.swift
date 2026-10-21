import Foundation
import FoundationModelsRouter

/// The recording roots of the projects of the user-layer project registry.
///
/// Each root comes from the settings of its project
/// (``LoadedSessionContext/load(workingDirectory:from:)``), thus it is the
/// root that `session/new` records the sessions of that project under. Two
/// clients walk the registry with this one resolution: `session/delete`
/// searches the roots for the directory of a session that is not in the
/// table, and ``SnapshotInventory`` reads the `sessions.jsonl` of each root
/// to find the recorded session keys.
struct RegisteredRecordingRoots: Sendable {
    /// A recording root that the resolution cannot give.
    enum Failure: Sendable {
        /// The project registry cannot be read. The resolution gives no root.
        case registryUnreadable(any Error)

        /// The settings of one registered project cannot be read. The
        /// resolution gives no root for that project.
        case projectUnreadable(project: URL, error: any Error)
    }

    /// The placeholder working directory that the registry read resolves
    /// its dotfolder stack against. Only the user layer is read from that
    /// stack, and the user layer does not depend on the working directory,
    /// thus each absolute directory gives the same root.
    private static let registryPlaceholderDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    /// The resolved recording roots, one for each registered project whose
    /// settings can be read, in registry order.
    let roots: [URL]

    /// Each root that the resolution cannot give, in registry order.
    let failures: [Failure]

    /// The user layer root that the project registry is in, resolved with
    /// no project: the stack is made over ``registryPlaceholderDirectory``,
    /// because the user layer is the same for each working directory.
    ///
    /// - Parameter settingsStore: The store whose settings folders give the
    ///   stack.
    /// - Returns: The user layer root.
    static func registryDirectory(of settingsStore: SettingsStore) -> URL {
        SessionSetup.userLayerRoot(
            of: settingsStore.makeConfigurationLoader(workingDirectory: registryPlaceholderDirectory).stack)
    }

    /// Reads the project registry of `settingsStore` and resolves the
    /// recording root of each registered project.
    ///
    /// The call writes no log record. Each caller reports the failures in
    /// its own way: the agent logs them, and the CLI writes them to stderr.
    ///
    /// - Parameter settingsStore: The store that gives the registry folder
    ///   and the settings of each project.
    /// - Returns: The roots, and each failure.
    static func resolve(in settingsStore: SettingsStore) async -> RegisteredRecordingRoots {
        let projects: [ProjectRegistryRecord]
        do {
            projects = try ProjectRegistry(directory: registryDirectory(of: settingsStore)).projects()
        } catch {
            return RegisteredRecordingRoots(roots: [], failures: [.registryUnreadable(error)])
        }
        var roots: [URL] = []
        var failures: [Failure] = []
        for project in projects {
            let directory = URL(fileURLWithPath: project.path, isDirectory: true)
            do {
                roots.append(
                    try await LoadedSessionContext.load(workingDirectory: directory, from: settingsStore).transcriptRoot)
            } catch {
                failures.append(.projectUnreadable(project: directory, error: error))
            }
        }
        return RegisteredRecordingRoots(roots: roots, failures: failures)
    }
}
