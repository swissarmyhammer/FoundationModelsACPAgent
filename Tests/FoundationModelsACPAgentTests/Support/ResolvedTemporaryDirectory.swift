import Foundation

/// Makes a throwaway directory that already sits under `/private/tmp`, so
/// its resolved path equals its written path and equality checks stay
/// exact. The OS reclaims `/tmp` on its own schedule.
///
/// - Parameter label: The prefix that names the calling suite and the
///   directory's role, so a leftover directory says where it came from.
/// - Returns: The created directory.
func makeResolvedDirectory(label: String) -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    return directory
}
