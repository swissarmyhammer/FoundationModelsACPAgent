import Foundation
import FoundationModelsRouter

/// The recording roots of the projects of the project store of the home.
///
/// Each root comes from the settings of its project
/// (``LoadedSessionContext/load(workingDirectory:from:)``), thus it is the
/// root that `session/new` records the sessions of that project under. Two
/// clients walk the project store with this one resolution:
/// `session/delete` searches the roots for the folder of a session that is
/// not in the table, and ``SnapshotInventory`` lists the session folders of
/// each root to find the recorded session keys.
struct RegisteredRecordingRoots: Sendable {
    /// A recording root that the resolution cannot give.
    enum Failure: Sendable {
        /// The project store cannot be read. The resolution gives no root.
        case registryUnreadable(any Error)

        /// The settings of one registered project cannot be read. The
        /// resolution gives no root for that project.
        case projectUnreadable(project: URL, error: any Error)
    }

    /// The resolved recording roots, one for each registered project whose
    /// settings can be read, in the order of the project store.
    let roots: [URL]

    /// Each root that the resolution cannot give, in the order of the
    /// project store.
    let failures: [Failure]

    /// The folder of the project store of `settingsStore`: the projects
    /// folder of its home (``AgentHome/projectsDirectory``), one file for
    /// each project.
    ///
    /// - Parameter settingsStore: The store whose settings folders give the
    ///   home.
    /// - Returns: The projects folder.
    static func projectsDirectory(of settingsStore: SettingsStore) -> URL {
        settingsStore.settingsFolders.home.projectsDirectory
    }

    /// Reads the project store of `settingsStore` and resolves the
    /// recording root of each registered project.
    ///
    /// The call writes no log record. Each caller reports the failures in
    /// its own way: the agent logs them, and the CLI writes them to stderr.
    ///
    /// - Parameter settingsStore: The store that gives the projects folder
    ///   and the settings of each project.
    /// - Returns: The roots, and each failure.
    static func resolve(in settingsStore: SettingsStore) async -> RegisteredRecordingRoots {
        let projects: [ProjectRecord]
        do {
            projects = try ProjectStore(directory: projectsDirectory(of: settingsStore)).projects()
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
