import Foundation
import FoundationModelsHooks
import FoundationModelsRouter

/// Whether the project store has a session for a snapshot key.
public enum SnapshotRecordedState: String, Codable, Sendable {
    /// A recording root of a registered project has a listable session
    /// folder whose session id is the key.
    case recorded

    /// No recording root of a registered project has a listable session
    /// folder for the key.
    case unrecorded
}

/// One snapshot folder of the inventory: the session key, the summary of its
/// timeline, and its recorded state.
///
/// The working directory is local data for the user of the CLI. No log
/// record holds it.
public struct SnapshotInventoryEntry: Codable, Equatable, Sendable {
    /// The session key: the name of the shadow folder, which is the ACP
    /// session id of the session that made it.
    public let sessionKey: String

    /// The number of checkpoints after the baseline, or `nil` when the key
    /// has no timeline or the timeline cannot be read.
    public let checkpointCount: Int?

    /// The time of the last checkpoint, or `nil` when the timeline has no
    /// checkpoint, the key has no timeline, or the timeline cannot be read.
    public let lastCheckpointDate: Date?

    /// The path of the working directory that the timeline recorded, or
    /// `nil` when the timeline recorded none, the key has no timeline, or the
    /// timeline cannot be read.
    public let workingDirectory: String?

    /// Whether a registered project has a session for the key.
    public let recordedState: SnapshotRecordedState

    /// Makes the entry of one key.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key.
    ///   - summary: The summary of the timeline of the key, or `nil` when the
    ///     key has no timeline or the timeline cannot be read.
    ///   - recordedState: Whether a registered project has a session for
    ///     the key.
    init(sessionKey: String, summary: SnapshotTimelineSummary?, recordedState: SnapshotRecordedState) {
        self.sessionKey = sessionKey
        checkpointCount = summary?.checkpointCount
        lastCheckpointDate = summary?.lastCheckpointDate
        workingDirectory = summary?.workingDirectory?.path
        self.recordedState = recordedState
    }
}

/// A condition that the inventory reports and continues past.
///
/// The description is a text for the stderr of the CLI. It can hold a path,
/// thus no log record holds it.
public enum SnapshotInventoryWarning: Equatable, Sendable, CustomStringConvertible {
    /// The project store cannot be read.
    case registryUnreadable(errorCase: String)

    /// The settings of one registered project cannot be read.
    case projectUnreadable(projectPath: String, errorCase: String)

    /// The session folders of one recording root cannot be read: the root
    /// cannot be listed, or the `index.md` of a session folder does not
    /// decode.
    case indexUnreadable(recordingRootPath: String, errorCase: String)

    /// The timeline of one key cannot be read. The key has no checkpoint
    /// count in the listing.
    case timelineUnreadable(sessionKey: String, errorCase: String)

    /// The sentence that ends the text of a warning that makes the recorded
    /// state unknown.
    private static let unknownStateSentence = "The recorded state of the keys is not known."

    /// Whether the warning makes the recorded state of the keys unknown: a
    /// session that the inventory cannot read can have a key, and that key
    /// then shows as `unrecorded`.
    public var makesRecordedStateUnknown: Bool {
        switch self {
        case .registryUnreadable, .projectUnreadable, .indexUnreadable: true
        case .timelineUnreadable: false
        }
    }

    /// The text of the warning, with the case of the error.
    public var description: String {
        switch self {
        case .registryUnreadable(let errorCase):
            "The project store cannot be read (\(errorCase)). \(Self.unknownStateSentence)"
        case .projectUnreadable(let projectPath, let errorCase):
            "The settings of the project \(projectPath) cannot be read (\(errorCase)). \(Self.unknownStateSentence)"
        case .indexUnreadable(let recordingRootPath, let errorCase):
            "The session folders of \(recordingRootPath) cannot be read (\(errorCase)). "
                + Self.unknownStateSentence
        case .timelineUnreadable(let sessionKey, let errorCase):
            "The timeline of the key \(sessionKey) cannot be read (\(errorCase))."
        }
    }

    /// The warning of a recording root that the resolution cannot give.
    ///
    /// - Parameter failure: The failure of the resolution.
    init(_ failure: RegisteredRecordingRoots.Failure) {
        switch failure {
        case .registryUnreadable(let error):
            self = .registryUnreadable(errorCase: ACPAgentTelemetry.errorCaseName(of: error))
        case .projectUnreadable(let project, let error):
            self = .projectUnreadable(projectPath: project.path, errorCase: ACPAgentTelemetry.errorCaseName(of: error))
        }
    }
}

/// What one ``SnapshotInventory/list()`` gives.
public struct SnapshotInventoryListing: Equatable, Sendable {
    /// One entry for each shadow folder, sorted by session key.
    public let entries: [SnapshotInventoryEntry]

    /// Each warning of the read, in the order of the read.
    public let warnings: [SnapshotInventoryWarning]

    /// Whether the recorded state of each entry is known: no warning makes
    /// it unknown.
    public var isRecordedStateKnown: Bool {
        !warnings.contains(where: \.makesRecordedStateUnknown)
    }

    /// The session key of each `unrecorded` entry, sorted.
    public var unrecordedKeys: [String] {
        entries.filter { $0.recordedState == .unrecorded }.map(\.sessionKey)
    }
}

/// The result of the remove of one session key.
public enum SnapshotRemovalOutcome: Equatable, Sendable {
    /// The shadow folder of the key is gone.
    case removed(sessionKey: String)

    /// The key has no shadow folder, for example because the user mistyped
    /// it. The inventory did not call the remove.
    case noSnapshotFolder(sessionKey: String)

    /// The remove of the key failed. `errorCase` names the case of the
    /// error, for example `sessionKeyOpen`, or the type of a `FileManager`
    /// error.
    case failed(sessionKey: String, errorCase: String)
}

/// The snapshot folders of a host, and the explicit remove of them.
///
/// The agent keeps the shadow folder of each session key after the session
/// ends, and it removes no orphan folder with a sweep: many sessions can work
/// in one folder at the same time, and a sweep at start can remove the
/// snapshots of a session that another process runs. Only `session/delete`
/// removes the timeline of its own session. The user lists the folders with
/// ``list()`` and removes the ones that they select with
/// ``remove(sessionKeys:)``.
///
/// A key is `recorded` when a recording root of a project of the project
/// store has a listable session folder whose session id is the key
/// (``TranscriptStore/listableRecords(in:)``). The recording root of each
/// project comes from the same resolution as the one of `session/delete`.
///
/// ```swift
/// let inventory = SnapshotInventory(hooksDataDirectory: directory, settingsStore: store)
/// let listing = try await inventory.list()
/// if listing.isRecordedStateKnown {
///     let outcomes = try await inventory.remove(sessionKeys: listing.unrecordedKeys)
/// }
/// ```
public struct SnapshotInventory: Sendable {
    /// The store of the shadow folders.
    let snapshotStore: SnapshotStore

    /// The store that gives the project store and the settings of each
    /// project.
    let settingsStore: SettingsStore

    /// Makes the inventory of the snapshots of one hook data directory.
    ///
    /// - Parameters:
    ///   - hooksDataDirectory: The hook data directory, for example
    ///     ``AgentHome/hooksDirectory``. The snapshots are
    ///     in its `snapshot` folder.
    ///   - settingsStore: The store that gives the project store and the
    ///     settings of each project.
    public init(hooksDataDirectory: URL, settingsStore: SettingsStore) {
        snapshotStore = SnapshotStore(directory: AgentHooks.snapshotDirectory(in: hooksDataDirectory))
        self.settingsStore = settingsStore
    }

    /// Reads each shadow folder, the summary of its timeline, and its
    /// recorded state. The call writes nothing.
    ///
    /// A folder whose summary throws `SnapshotError.noTimeline` is listed
    /// with no checkpoint count, so that the user can remove it. A folder
    /// whose summary throws another error is listed in the same way, with a
    /// ``SnapshotInventoryWarning/timelineUnreadable(sessionKey:errorCase:)``.
    ///
    /// - Returns: The entries and the warnings.
    /// - Throws: The error of `FileManager` when the snapshot directory exists
    ///   but cannot be read.
    public func list() async throws -> SnapshotInventoryListing {
        let sessionKeys = try await snapshotStore.shadowSessionKeys()
        let recorded = await recordedSessionIds()
        var entries: [SnapshotInventoryEntry] = []
        var warnings = recorded.warnings
        for sessionKey in sessionKeys {
            let read = await summary(of: sessionKey)
            entries.append(
                SnapshotInventoryEntry(
                    sessionKey: sessionKey, summary: read.summary,
                    recordedState: recorded.sessionIds.contains(sessionKey) ? .recorded : .unrecorded))
            if let warning = read.warning {
                warnings.append(warning)
            }
        }
        return SnapshotInventoryListing(entries: entries, warnings: warnings)
    }

    /// Reads the timeline summary of one key.
    ///
    /// - Parameter sessionKey: The key.
    /// - Returns: The summary, or `nil` when the key has no timeline or the
    ///   timeline cannot be read. The warning is not `nil` only for a
    ///   timeline that cannot be read: a key with no timeline is not a
    ///   warning.
    private func summary(
        of sessionKey: String
    ) async -> (summary: SnapshotTimelineSummary?, warning: SnapshotInventoryWarning?) {
        do {
            return (try await snapshotStore.timelineSummary(sessionKey: sessionKey), nil)
        } catch SnapshotError.noTimeline {
            return (nil, nil)
        } catch {
            return (nil, .timelineUnreadable(sessionKey: sessionKey, errorCase: ACPAgentTelemetry.errorCaseName(of: error)))
        }
    }

    /// Removes the shadow folder of each key, in order. The error of one key
    /// does not stop the remove of the next key.
    ///
    /// The call reads the shadow folders one time first. A key that has no
    /// shadow folder gets ``SnapshotRemovalOutcome/noSnapshotFolder(sessionKey:)``
    /// and no remove, thus a mistyped key never shows as removed.
    ///
    /// - Parameter sessionKeys: The keys to remove.
    /// - Returns: One outcome for each key, in the order of `sessionKeys`.
    /// - Throws: The error of `FileManager` when the snapshot directory exists
    ///   but cannot be read. Then the call removes nothing.
    public func remove(sessionKeys: [String]) async throws -> [SnapshotRemovalOutcome] {
        let shadowSessionKeys = Set(try await snapshotStore.shadowSessionKeys())
        var outcomes: [SnapshotRemovalOutcome] = []
        for sessionKey in sessionKeys {
            guard shadowSessionKeys.contains(sessionKey) else {
                outcomes.append(.noSnapshotFolder(sessionKey: sessionKey))
                continue
            }
            outcomes.append(await remove(sessionKey: sessionKey))
        }
        return outcomes
    }

    /// Removes the shadow folder of one key.
    ///
    /// - Parameter sessionKey: The key to remove.
    /// - Returns: The outcome. A failure names the case of the error.
    private func remove(sessionKey: String) async -> SnapshotRemovalOutcome {
        do {
            try await snapshotStore.remove(sessionKey: sessionKey)
            return .removed(sessionKey: sessionKey)
        } catch {
            return .failed(sessionKey: sessionKey, errorCase: ACPAgentTelemetry.errorCaseName(of: error))
        }
    }

    /// The session id of each listable session folder of each recording
    /// root of each registered project, and a warning for each project
    /// store, project or root that cannot be read. Two projects can share
    /// one recording root, thus the call reads each root one time, in the
    /// order of the project store.
    ///
    /// - Returns: The recorded session ids and the warnings.
    private func recordedSessionIds() async -> (sessionIds: Set<String>, warnings: [SnapshotInventoryWarning]) {
        let resolution = await RegisteredRecordingRoots.resolve(in: settingsStore)
        var sessionIds: Set<String> = []
        var warnings = resolution.failures.map(SnapshotInventoryWarning.init)
        var readRoots: Set<URL> = []
        for root in resolution.roots.map(\.standardizedFileURL) where readRoots.insert(root).inserted {
            do {
                sessionIds.formUnion(try TranscriptStore.listableRecords(in: root).map(\.sessionId.description))
            } catch {
                warnings.append(
                    .indexUnreadable(recordingRootPath: root.path, errorCase: ACPAgentTelemetry.errorCaseName(of: error)))
            }
        }
        return (sessionIds, warnings)
    }
}
