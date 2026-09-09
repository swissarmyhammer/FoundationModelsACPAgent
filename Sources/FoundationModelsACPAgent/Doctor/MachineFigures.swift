import Foundation

/// The two figures of the machine the profile check compares against
/// (cli-plan.md §5.12, the Profile row): the memory, and the free disk.
///
/// The figures are read here and injected into ``ProfileDoctor``, so no
/// unit test reads the machine it runs on and no finding changes from one
/// host to the next.
public enum MachineFigures {
    /// The memory of this machine, in bytes.
    public static var physicalMemoryBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// The free space of the volume `directory` stands on, in bytes.
    ///
    /// A directory that is not on disk yet has no volume of its own, so
    /// the figure is read at the nearest directory above it that does
    /// exist. A volume that answers nothing gives zero, which the profile
    /// check reports as too small.
    ///
    /// - Parameter directory: The directory to measure at.
    /// - Returns: The free bytes, or zero when the volume answers nothing.
    public static func freeDiskBytes(at directory: URL) -> Int64 {
        let existing = WritableDirectoryCheck.nearestExistingDirectory(
            of: directory.standardizedFileURL)
        let values = try? existing.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
